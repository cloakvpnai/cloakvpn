// SPDX-License-Identifier: MIT
//
// Lattice VPN — PacketTunnelProvider for the CloakTunnel NetworkExtension
// target.
//
// 2026-04-27 ROOT-CAUSE FIX (see docs/TRIAGE_2026-04-27.md):
// Our SwiftPM dep is mullvad/wireguard-apple (mullvad-master). Mullvad's
// `WireGuardAdapter.start()` was rewritten to support multi-hop and DAITA
// and in the process REMOVED the `setTunnelNetworkSettings` call that
// upstream wireguard-apple makes in `start()`. Mullvad expects the host
// app to install network settings via a higher-level coordinator they
// don't ship publicly. Without that call, iOS never installs IPs / DNS /
// routes on the utun, so the wireguard-go data plane runs blind: WG
// handshake completes (UDP, doesn't traverse utun), keepalives flow
// (internal heartbeat), but no application traffic enters utun.
//
// This file compensates by calling `setTunnelNetworkSettings`
// EXPLICITLY before `adapter.start`. We can't switch to upstream
// wireguard-apple as a SwiftPM dep because upstream's Package.swift has
// been broken since 2023 (declares swift-tools-version:5.3 but uses
// .macOS(.v12)/.iOS(.v15) which require 5.5+).
//
// Layout of this file:
//   - Lifecycle: startTunnel / stopTunnel
//   - handleAppMessage: opcode 0x00 GET_RUNTIME_CONFIG, 0x01 SET_PSK
//   - applyPresharedKey: builds new TunnelConfiguration with PSK and
//     hands it to WireGuardAdapter.update()
//   - makeTunnelConfiguration: CloakConfig wire format → WireGuardKit
//     model
//   - makeNetworkSettings: TunnelConfiguration → NEPacketTunnelNetwork-
//     Settings (port of upstream's PacketTunnelSettingsGenerator.
//     generateNetworkSettings — this is the bit Mullvad's adapter is
//     missing)
//
// Opcodes 0x02-0x04 (Option D rosenpass UDP relay) will be re-added
// after this file is validated end-to-end with plain WG.

import Foundation
import Network
import NetworkExtension
import os.log
import WireGuardKit

final class PacketTunnelProvider: NEPacketTunnelProvider {
    private let log = OSLog(subsystem: "ai.cloakvpn.CloakVPN.tunnel", category: "tunnel")

    /// The WireGuardKit adapter. Lazily constructed so initialization
    /// happens on the same thread that drives startTunnel — matches
    /// upstream's pattern.
    private lazy var adapter: WireGuardAdapter = {
        return WireGuardAdapter(with: self) { [weak self] logLevel, message in
            os_log("wg: %{public}s",
                   log: self?.log ?? .default,
                   type: logLevel.osLogType,
                   message)
        }
    }()

    /// The active tunnel configuration. Kept so PSK rotations can build
    /// a new TunnelConfiguration with the same interface + peer settings
    /// but a fresh preshared key, then call adapter.update().
    private var currentConfig: TunnelConfiguration?

    /// PSK from a SET_PSK message that arrived before adapter.start
    /// finished. WireGuardKit's adapter rejects update() calls with
    /// `.invalidState` until start completes — so a fast rosenpass
    /// exchange that fires during the brief startTunnel → adapter.start
    /// window would otherwise have its first PSK silently dropped, leaving
    /// iPhone-side wg-go with zero PSK while the server already has the
    /// derived PSK from the exchange. Result: every WG handshake fails
    /// with "Received invalid response message" until the next rotation
    /// cycle. We buffer the PSK here and apply it as soon as adapter.start
    /// completes. Cleared after successful apply.
    private var pendingPresharedKey: Data?

    /// In-process rosenpass driver. Replaces the old host-app
    /// RosenpassBridge ↔ NE IPC dance with a direct UDP socket + direct
    /// PSK application. Critical fix for the host-app-suspension wedge —
    /// see RosenpassDriver.swift for the full rationale. Lifecycle:
    /// instantiated and started inside the adapter.start success
    /// callback in startTunnel (so we know wg-go is ready to receive
    /// PSK updates); stopped in stopTunnel.
    private var rosenpassDriver: RosenpassDriver?

    /// IP literal of the rosenpass server, parsed from
    /// CloakConfig.rpEndpoint at startTunnel. Used for two things:
    ///   (1) Adding an `excludedRoute` in `makeNetworkSettings` so iOS
    ///       doesn't route NE-side traffic to this IP through utun
    ///       (which would loop the rosenpass UDP socket back into the
    ///       very tunnel whose PSK it's deriving — chicken/egg).
    ///   (2) Parsing the same endpoint a second time in
    ///       `ensureRosenpassConnection` to build the NWConnection.
    /// nil means PQC is disabled OR rpEndpoint couldn't be parsed; in
    /// both cases the rosenpass UDP relay is inert.
    private var rosenpassServerIP: String?

    /// NE-side UDP socket to the rosenpass server. Lazily created when
    /// the host app's RosenpassBridge first asks us to relay traffic
    /// (opcode 0x02), torn down on opcode 0x04 or stopTunnel.
    /// Sized for one peer at a time — there's only ever one rosenpass
    /// concentrator per tunnel.
    private var rosenpassUDP: NWConnection?

    /// Dispatch queue for the NE-side rosenpass NWConnection's
    /// callbacks. Separate from the NE's main queue so a slow rosenpass
    /// receive can't stall WG packet shovelling.
    private let rosenpassQueue = DispatchQueue(label: "ai.cloakvpn.tunnel.rosenpass")

    // MARK: - Health monitoring (Layer 1 — instrumentation only)
    //
    // Polls WireGuardKit's getRuntimeConfiguration every 15s and emits an
    // os_log line per tick with rx/tx byte deltas, last-handshake age, and
    // last-PSK-applied age. Also tracks a "would-be-wedged" heuristic and
    // logs "WEDGE SUSPECTED" when it trips, but takes NO ACTION yet — Layer
    // 2 (calling self.cancelTunnelWithError to force-respawn the NE) will
    // be wired up after we have ~24h of real-device telemetry to threshold-
    // tune. See HANDOFF_2026-04-27_session4.md for the full architecture.

    /// Repeating timer that drives health checks. Lives for the duration
    /// of the active tunnel; cancelled in stopTunnel.
    private var healthCheckTimer: DispatchSourceTimer?

    /// Dedicated serial queue for health-check state mutations so the
    /// timer fire path and the getRuntimeConfiguration callback never
    /// race on the cached counters.
    private let healthCheckQueue = DispatchQueue(label: "ai.cloakvpn.tunnel.health")

    /// Previous tick's WG transfer counters, for delta computation.
    private var lastRxBytes: UInt64 = 0
    private var lastTxBytes: UInt64 = 0

    /// Wallclock timestamp of the last successful PSK application
    /// (= last successful rosenpass exchange the NE has heard about).
    /// Set by applyPresharedKey on success. Read by performHealthCheck.
    private var lastPSKAppliedAt: Date?

    /// Wallclock timestamp of when the tunnel came up. Used to suppress
    /// spurious wedge warnings during the first 60s of warm-up while
    /// the initial WG handshake completes and the first PQ exchange
    /// runs.
    private var tunnelUpAt: Date?

    /// Consecutive ticks where the stall heuristic tripped. Reset to 0
    /// the moment a tick sees rx growth. Logged each tick so we can see
    /// patterns in Console.app without needing to correlate timestamps.
    private var consecutiveStallTicks: Int = 0

    /// Health-check tick interval. 15s is short enough to surface a
    /// wedge well before keepalive timeout (180s in WG protocol) but
    /// long enough that getRuntimeConfiguration overhead stays
    /// negligible.
    private static let healthCheckIntervalSec: Int = 15

    /// Stall detection thresholds. When tripped, Layer 2 calls
    /// self.cancelTunnelWithError to terminate the NE process; iOS
    /// re-spawns it on the next user-initiated connect (or via the host
    /// app's auto-reconnect when Layer 3 ships). Thresholds tuned from
    /// real-device telemetry captured 2026-04-27 — stall_ticks=4 +
    /// handshake_age>=120s correlated cleanly with observed wedge events.
    /// Bumped from the original Layer-1-only stall_ticks>=3 to >=4 to
    /// avoid spurious recoveries on transient single-tick rx-zero
    /// fluctuations.
    private static let wedgeStallTickThreshold: Int = 4
    private static let wedgeHandshakeAgeSec: Int = 120
    private static let wedgePSKAgeSec: Int = 300
    private static let warmupSuppressionSec: TimeInterval = 60

    // MARK: - Layer 2 — wedge auto-recovery state

    /// Sliding window of recent self-kill (cancelTunnelWithError) timestamps.
    /// Prevents an infinite restart loop if the wedge condition is itself
    /// caused by an unrecoverable factor (server unreachable, bad PSK
    /// state on server, etc.) — after maxSelfKillsPerWindow attempts in
    /// selfKillWindowSec, we stop self-killing and just log; user must
    /// intervene manually.
    private var selfKillTimestamps: [Date] = []

    /// Set to true between cancelTunnelWithError invocation and the iOS
    /// stopTunnel callback that follows. Suppresses repeat-firing on
    /// subsequent timer ticks during the brief shutdown window.
    private var selfKillInFlight: Bool = false

    /// Layer 2 thresholds. Three self-kills per 5 min = at most one
    /// every 100s on average. Past that, the issue is likely environ-
    /// mental (server PSK desync, network outage, etc.) and more
    /// restarts won't help.
    private static let maxSelfKillsPerWindow: Int = 3
    private static let selfKillWindowSec: TimeInterval = 300

    // MARK: - Lifecycle

    override func startTunnel(
        options: [String: NSObject]?,
        completionHandler: @escaping (Error?) -> Void
    ) {
        os_log("startTunnel", log: log, type: .info)

        // Pull the serialized CloakConfig out of the NE's
        // providerConfiguration dictionary (populated by the host app's
        // TunnelManager.importConfig).
        guard
            let proto = protocolConfiguration as? NETunnelProviderProtocol,
            let dict = proto.providerConfiguration
        else {
            os_log("startTunnel: missing providerConfiguration", log: log, type: .error)
            completionHandler(PacketTunnelError.missingProtocol)
            return
        }

        let cloakCfg: CloakConfig
        do {
            cloakCfg = try CloakConfig(dict: dict)
        } catch {
            os_log("startTunnel: bad CloakConfig: %{public}s",
                   log: log, type: .error, String(describing: error))
            completionHandler(error)
            return
        }

        // Stash the rosenpass server IP so makeNetworkSettings can carve
        // out an excludedRoute for it. Inert if PQC is disabled OR
        // rpEndpoint isn't a parseable host:port — in either case the
        // rosenpass UDP relay opcodes are no-ops.
        if cloakCfg.pqEnabled, !cloakCfg.rpEndpoint.isEmpty {
            self.rosenpassServerIP = Self.extractIP(from: cloakCfg.rpEndpoint)
            if self.rosenpassServerIP == nil {
                os_log("startTunnel: couldn't parse IP from rpEndpoint %{public}s; PQC routing exclude disabled",
                       log: log, type: .error, cloakCfg.rpEndpoint)
            } else {
                os_log("startTunnel: PQC excludedRoute target %{public}s",
                       log: log, type: .info, self.rosenpassServerIP!)
            }
        } else {
            self.rosenpassServerIP = nil
        }

        // Build a WireGuardKit TunnelConfiguration directly from
        // CloakConfig fields. Mullvad's wireguard-apple fork exposes
        // only `WireGuardKit` and `WireGuardKitTypes` as public products
        // — the wg-quick parser lives in their internal `Shared`
        // module, not reachable from here. So we wire each field
        // through manually. See `makeTunnelConfiguration` below.
        let tunnelCfg: TunnelConfiguration
        do {
            tunnelCfg = try Self.makeTunnelConfiguration(from: cloakCfg)
        } catch {
            os_log("startTunnel: TunnelConfiguration build failed: %{public}s",
                   log: log, type: .error, String(describing: error))
            completionHandler(error)
            return
        }
        self.currentConfig = tunnelCfg

        // ROOT-CAUSE FIX: install network settings on the utun BEFORE
        // adapter.start. Upstream's WireGuardAdapter does this for you;
        // Mullvad's fork (which we depend on via SwiftPM) does NOT.
        // Without this call, the utun has no IPs/routes/DNS and iOS
        // routes nothing into the tunnel even though wireguard-go is
        // running and WG handshakes complete.
        let networkSettings = Self.makeNetworkSettings(
            from: tunnelCfg,
            rosenpassServerIP: self.rosenpassServerIP
        )
        os_log("setTunnelNetworkSettings: applying", log: log, type: .info)
        setTunnelNetworkSettings(networkSettings) { [weak self] settingsError in
            guard let self = self else { return }
            if let settingsError = settingsError {
                os_log("setTunnelNetworkSettings failed: %{public}s",
                       log: self.log, type: .error,
                       String(describing: settingsError))
                completionHandler(settingsError)
                return
            }
            os_log("setTunnelNetworkSettings: applied; starting adapter",
                   log: self.log, type: .info)

            // Now hand off to WireGuardAdapter. With Mullvad's fork the
            // adapter will:
            //   1. NOT call setTunnelNetworkSettings (we did it above)
            //   2. Resolve endpoints, build the wg UAPI config string
            //   3. Call wgTurnOnIAN to start the wireguard-go data plane
            //      against the utun fd we already configured
            self.adapter.start(tunnelConfiguration: tunnelCfg) { [weak self] adapterError in
                guard let self = self else { return }
                if let adapterError = adapterError {
                    os_log("WireGuardAdapter.start failed: %{public}s",
                           log: self.log, type: .error,
                           String(describing: adapterError))
                    completionHandler(adapterError)
                    return
                }
                let ifaceName = self.adapter.interfaceName ?? "unknown"
                os_log("tunnel up on interface %{public}s",
                       log: self.log, type: .info, ifaceName)
                self.tunnelUpAt = Date()
                self.startHealthMonitoring()

                // If a SET_PSK arrived during the startTunnel → adapter.start
                // window (the race condition that surfaced 2026-04-27), it
                // was buffered into self.pendingPresharedKey instead of
                // being silently dropped. Apply it now that the adapter
                // is ready. Without this drain, iPhone-side wg-go would
                // have zero PSK while the server already holds the
                // rosenpass-derived PSK → every WG handshake fails with
                // "Received invalid response message" until the host app's
                // rosenpass loop runs its NEXT rotation (~120s later).
                if let pending = self.pendingPresharedKey {
                    self.pendingPresharedKey = nil
                    os_log("startTunnel: applying buffered PSK that arrived before adapter was ready",
                           log: self.log, type: .info)
                    self.applyPresharedKey(pending) { [weak self] ok in
                        os_log("startTunnel: buffered PSK apply: %{public}s",
                               log: self?.log ?? .default, type: ok ? .info : .error,
                               ok ? "ok" : "failed")
                    }
                }

                // Task #17 — start the in-NE rosenpass driver. This
                // replaces the host-app RosenpassBridge for the rotation
                // loop. Critical because host-app RosenpassBridge stops
                // running whenever iOS suspends the host app (every time
                // the user backgrounds Cloak), causing PSK desync ->
                // tunnel wedge. The NE-side driver runs as long as the
                // tunnel is up regardless of host-app state. The host
                // app's RosenpassBridge can keep running (when not
                // suspended) without harm — they're idempotent and the
                // last successful exchange wins; eventually we'll
                // disable RosenpassBridge entirely for cleanliness.
                if cloakCfg.pqEnabled {
                    self.startRosenpassDriverIfPossible(cloakCfg: cloakCfg)
                }

                completionHandler(nil)
            }
        }
    }

    override func stopTunnel(
        with reason: NEProviderStopReason,
        completionHandler: @escaping () -> Void
    ) {
        os_log("stopTunnel reason=%d", log: log, type: .info, reason.rawValue)
        // Stop the health monitor first so its callbacks can't fire
        // mid-teardown and try to inspect a stopped adapter.
        stopHealthMonitoring()
        // Stop the in-NE rosenpass driver (task #17) — cancels the
        // rotation loop and tears down its UDP socket.
        rosenpassDriver?.stop()
        rosenpassDriver = nil
        // Tear down the rosenpass UDP socket BEFORE stopping the
        // adapter — otherwise its callback queue could fire after the
        // NE process has been told to terminate.
        closeRosenpassConnection()
        self.rosenpassServerIP = nil
        adapter.stop { [weak self] error in
            if let error = error {
                os_log("adapter.stop error: %{public}s",
                       log: self?.log ?? .default, type: .error,
                       String(describing: error))
            }
            self?.currentConfig = nil
            completionHandler()
        }
    }

    // MARK: - PSK rotation (called from the main app via sendProviderMessage)

    /// Receives messages from the main app process.
    ///
    /// Wire format (kept dumb on purpose so it survives across OS
    /// versions and matches upstream's pattern of a single first-byte
    /// opcode):
    ///
    ///   First byte = opcode:
    ///     0x00 = "get runtime config" (upstream-compat; returns UAPI
    ///            config string for diagnostics)
    ///     0x01 = "set preshared key": the next 32 bytes are the new
    ///            PSK from rosenpass. Response is single byte: 0 = ok,
    ///            non-zero = error code.
    ///
    /// Anything else is logged and dropped.
    ///
    /// NOTE: opcodes 0x02-0x04 (the Option D rosenpass UDP relay we
    /// shipped on 2026-04-26) are temporarily removed here. They will
    /// be re-added on top of this known-working base when PQC is
    /// re-enabled. For now: plain WG.
    override func handleAppMessage(
        _ messageData: Data,
        completionHandler: ((Data?) -> Void)? = nil
    ) {
        guard let completionHandler = completionHandler else { return }
        guard let opcode = messageData.first else {
            os_log("handleAppMessage: empty payload", log: log, type: .error)
            completionHandler(Data([0xFF]))
            return
        }

        switch opcode {
        case 0x00: // GET_RUNTIME_CONFIG (upstream-compat diagnostic path)
            adapter.getRuntimeConfiguration { settings in
                completionHandler(settings?.data(using: .utf8))
            }

        case 0x01: // SET_PSK
            let psk = messageData.dropFirst()
            guard psk.count == 32 else {
                os_log("SET_PSK: wrong PSK length %d (want 32)",
                       log: log, type: .error, psk.count)
                completionHandler(Data([0xFE]))
                return
            }
            applyPresharedKey(Data(psk)) { ok in
                completionHandler(Data([ok ? 0x00 : 0xFD]))
            }

        case 0x02: // SEND_RP_UDP
            // payload = N rosenpass UDP bytes for the rosenpass server
            // response = 1 byte (0x00 ok / 0xEE failed)
            let payload = Data(messageData.dropFirst())
            sendRosenpassUDP(payload) { [weak self] err in
                if let err = err {
                    os_log("SEND_RP_UDP failed: %{public}s",
                           log: self?.log ?? .default, type: .error,
                           String(describing: err))
                    completionHandler(Data([0xEE]))
                } else {
                    completionHandler(Data([0x00]))
                }
            }

        case 0x03: // RECV_RP_UDP
            // payload = optional 1-byte timeoutSec (1..255), default 8s
            // response = N bytes of one rosenpass UDP datagram, or empty
            //            on timeout/error (host side maps to budget err)
            let timeoutSec: Int
            if messageData.count >= 2 {
                timeoutSec = Int(messageData[messageData.startIndex + 1])
            } else {
                timeoutSec = 8
            }
            receiveRosenpassUDP(timeoutSeconds: timeoutSec) { [weak self] data in
                if let data = data {
                    completionHandler(data)
                } else {
                    os_log("RECV_RP_UDP timed out after %ds",
                           log: self?.log ?? .default, type: .info, timeoutSec)
                    completionHandler(Data())
                }
            }

        case 0x04: // CLOSE_RP_UDP
            // payload = (none); tear down the NE-side rosenpass socket
            // between handshakes so each new handshake gets a fresh
            // ephemeral source port.
            closeRosenpassConnection()
            completionHandler(Data([0x00]))

        default:
            os_log("handleAppMessage: unknown opcode 0x%02x",
                   log: log, type: .error, opcode)
            completionHandler(Data([0xFC]))
        }
    }

    // MARK: - Rosenpass UDP relay (NE-side)

    /// Lazily create or return the existing UDP connection to the
    /// rosenpass server. Combined with the `excludedRoutes` carve-out
    /// installed by `setTunnelNetworkSettings`, this reliably routes
    /// rosenpass UDP over the physical interface even with
    /// `includeAllNetworks = true`.
    private func ensureRosenpassConnection(_ done: @escaping (NWConnection?, Error?) -> Void) {
        if let c = rosenpassUDP, c.state == .ready {
            rosenpassQueue.async { done(c, nil) }
            return
        }
        rosenpassUDP?.cancel()
        rosenpassUDP = nil

        guard let proto = protocolConfiguration as? NETunnelProviderProtocol,
              let dict = proto.providerConfiguration,
              let cfg = try? CloakConfig(dict: dict) else {
            done(nil, PacketTunnelError.missingProtocol)
            return
        }
        // Build NWEndpoint from rpEndpoint. Explicit `Network.` prefix
        // because NetworkExtension also exports an NWEndpoint symbol
        // (an older NSObject-based class) and both modules are
        // imported in this file — without the qualification the
        // compiler errors with "'NWEndpoint' is ambiguous".
        let endpoint: Network.NWEndpoint
        if cfg.rpEndpoint.hasPrefix("[") {
            // [v6]:port form
            guard let close = cfg.rpEndpoint.firstIndex(of: "]"),
                  let lastColon = cfg.rpEndpoint.lastIndex(of: ":"),
                  lastColon > close,
                  let port = UInt16(cfg.rpEndpoint[cfg.rpEndpoint.index(after: lastColon)...])
            else {
                done(nil, PacketTunnelError.badField("rpEndpoint", cfg.rpEndpoint))
                return
            }
            let host = String(cfg.rpEndpoint[cfg.rpEndpoint.index(after: cfg.rpEndpoint.startIndex)..<close])
            endpoint = Network.NWEndpoint.hostPort(
                host: Network.NWEndpoint.Host(host),
                port: Network.NWEndpoint.Port(rawValue: port)!
            )
        } else {
            guard let lastColon = cfg.rpEndpoint.lastIndex(of: ":"),
                  let port = UInt16(cfg.rpEndpoint[cfg.rpEndpoint.index(after: lastColon)...])
            else {
                done(nil, PacketTunnelError.badField("rpEndpoint", cfg.rpEndpoint))
                return
            }
            let host = String(cfg.rpEndpoint[..<lastColon])
            endpoint = Network.NWEndpoint.hostPort(
                host: Network.NWEndpoint.Host(host),
                port: Network.NWEndpoint.Port(rawValue: port)!
            )
        }

        let params = NWParameters.udp
        // Even though we're inside the NE (and exempt from the NECP
        // host-app rules that ban tunnel-bypass under
        // includeAllNetworks=true), we still need to keep this socket
        // off utun. utun is a virtual interface owned by US; sending
        // rosenpass UDP through it would loop the packets right back
        // into the WG tunnel whose PSK we're trying to derive.
        params.prohibitedInterfaceTypes = [.other]
        let conn = NWConnection(to: endpoint, using: params)
        self.rosenpassUDP = conn

        var fired = false
        conn.stateUpdateHandler = { [weak self, weak conn] state in
            guard let conn = conn else { return }
            switch state {
            case .ready:
                if !fired {
                    fired = true
                    os_log("rosenpass UDP ready (NE-side)",
                           log: self?.log ?? .default, type: .info)
                    done(conn, nil)
                }
            case .failed(let err):
                if !fired {
                    fired = true
                    os_log("rosenpass UDP failed: %{public}s",
                           log: self?.log ?? .default, type: .error,
                           String(describing: err))
                    done(nil, err)
                }
            case .cancelled:
                if !fired {
                    fired = true
                    done(nil, CancellationError())
                }
            default:
                break
            }
        }
        conn.start(queue: rosenpassQueue)
    }

    /// Send a rosenpass UDP packet via the NE-side socket.
    private func sendRosenpassUDP(_ data: Data, completion: @escaping (Error?) -> Void) {
        ensureRosenpassConnection { conn, err in
            if let err = err {
                completion(err)
                return
            }
            guard let conn = conn else {
                completion(PacketTunnelError.missingProtocol)
                return
            }
            conn.send(content: data, completion: .contentProcessed { sendErr in
                completion(sendErr)
            })
        }
    }

    /// Receive a single UDP datagram from the rosenpass server, with a
    /// timeout. Calls back with nil on timeout or error so the host
    /// side maps it to its existing exceeded-budget error.
    private func receiveRosenpassUDP(timeoutSeconds: Int, completion: @escaping (Data?) -> Void) {
        ensureRosenpassConnection { [weak self] conn, _ in
            guard let conn = conn, let self = self else {
                completion(nil)
                return
            }
            // Race the receive against a wall-clock timeout. Whichever
            // fires first wins; the loser's callback is suppressed.
            var settled = false
            let lock = NSLock()
            func tryComplete(_ data: Data?) {
                lock.lock()
                defer { lock.unlock() }
                if settled { return }
                settled = true
                completion(data)
            }
            conn.receiveMessage { content, _, _, recvErr in
                if let recvErr = recvErr {
                    os_log("rosenpass UDP receive error: %{public}s",
                           log: self.log, type: .error,
                           String(describing: recvErr))
                    tryComplete(nil)
                    return
                }
                tryComplete(content)
            }
            self.rosenpassQueue.asyncAfter(deadline: .now() + .seconds(timeoutSeconds)) {
                tryComplete(nil)
            }
        }
    }

    /// Tear down the NE-side rosenpass UDP connection. Called on
    /// CLOSE_RP_UDP from the host app (between handshakes) and on
    /// stopTunnel.
    private func closeRosenpassConnection() {
        rosenpassUDP?.cancel()
        rosenpassUDP = nil
    }

    /// Apply a Rosenpass-derived PSK by rebuilding the tunnel config
    /// with the new preshared key on the (single) peer and asking
    /// WireGuardKit to swap it in. WireGuardKit reuses the underlying
    /// utun and only reconfigures the wireguard-go session, so this is
    /// cheap (~ms) and doesn't drop in-flight UDP.
    private func applyPresharedKey(
        _ psk: Data,
        completion: @escaping (Bool) -> Void
    ) {
        guard let current = currentConfig else {
            os_log("applyPresharedKey: no current config", log: log, type: .error)
            completion(false)
            return
        }

        var peers = current.peers
        guard !peers.isEmpty else {
            os_log("applyPresharedKey: no peers", log: log, type: .error)
            completion(false)
            return
        }
        peers[0].preSharedKey = PreSharedKey(rawValue: psk)

        let updated = TunnelConfiguration(
            name: current.name,
            interface: current.interface,
            peers: peers
        )

        adapter.update(tunnelConfiguration: updated) { [weak self] error in
            if let error = error {
                let errStr = String(describing: error)
                // The .invalidState case means adapter.start hasn't
                // completed yet. Buffer the PSK; we'll apply it as soon
                // as startTunnel's adapter.start callback fires success.
                // This is the race that caused the "PSK silently dropped
                // on first rotation after connect" bug surfaced 2026-04-27:
                // host app's rosenpass loop completes its first exchange
                // out-of-band (rosenpass UDP doesn't depend on WG) and
                // pushes SET_PSK to the NE before adapter.start finishes
                // (~600ms gap on iPhone 17 Pro Max). Without this buffer,
                // every reconnect leaves iPhone-side wg-go with zero PSK
                // while the server has the derived PSK → handshakes fail
                // until next rotation (~120s) at minimum, often longer
                // because Layer 2 may self-kill before the next rotation
                // can push a fresh PSK.
                if errStr.contains("invalidState") {
                    os_log("applyPresharedKey: adapter not yet ready (race with startTunnel) — buffering PSK; will apply on adapter.start completion",
                           log: self?.log ?? .default, type: .info)
                    self?.pendingPresharedKey = psk
                    // Optimistic success response: the buffered apply
                    // fires reliably from startTunnel's adapter.start
                    // callback within ~600ms. Returning false here would
                    // make the host app's UI show "NE rejected rosenpass"
                    // even though we're going to apply the PSK shortly.
                    // If the deferred apply ever fails, the host app's
                    // next rotation (~120s) will push a fresh PSK and
                    // the system self-corrects. Net: better UX, no
                    // correctness regression.
                    completion(true)
                    return
                }
                os_log("applyPresharedKey adapter.update failed: %{public}s",
                       log: self?.log ?? .default, type: .error, errStr)
                completion(false)
                return
            }
            self?.currentConfig = updated
            // Stamp the rosenpass-success wallclock so the health monitor
            // can compute "psk_age" — distinguishes "stopped getting
            // PSK rotations" (stuck rosenpass loop) from "stopped getting
            // bytes" (network-layer wedge).
            self?.healthCheckQueue.async {
                self?.lastPSKAppliedAt = Date()
            }
            os_log("PSK rotated", log: self?.log ?? .default, type: .info)
            completion(true)
        }
    }

    // MARK: - In-NE rosenpass driver (task #17 — host-app suspension fix)

    /// Read the device's rosenpass keys from the App Group container,
    /// parse the rosenpass server endpoint from the active CloakConfig,
    /// instantiate a RosenpassDriver, wire its onPSKDerived callback to
    /// applyPresharedKey, and start the rotation loop. Silent no-op (with
    /// log line) on any error — the tunnel will still come up classically
    /// without PQ in that case, rather than the user being stranded.
    private func startRosenpassDriverIfPossible(cloakCfg: CloakConfig) {
        let clientKeys: (secretB64: String, publicB64: String)
        let serverPubB64: String
        do {
            clientKeys = try AppGroupKeyStore.loadLocalKeypair()
            serverPubB64 = try AppGroupKeyStore.loadServerPublicKey()
        } catch {
            os_log("RosenpassDriver: keys unavailable in App Group, skipping (%{public}s)",
                   log: log, type: .error, String(describing: error))
            return
        }

        guard let clientSecret = Data(base64Encoded: clientKeys.secretB64),
              let clientPublic = Data(base64Encoded: clientKeys.publicB64),
              let serverPublic = Data(base64Encoded: serverPubB64) else {
            os_log("RosenpassDriver: bad base64 in stored keys, skipping",
                   log: log, type: .error)
            return
        }

        // Parse "host:port" from rpEndpoint. We only support v4 here for
        // now — the four current regions all use v4 rosenpass endpoints.
        // V6 / bracketed-form parsing lives in ensureRosenpassConnection
        // for the legacy IPC path; if we ever need v6 here we can lift
        // that helper into the driver.
        let parts = cloakCfg.rpEndpoint.split(separator: ":", maxSplits: 1)
        guard parts.count == 2,
              let port = UInt16(parts[1]) else {
            os_log("RosenpassDriver: malformed rpEndpoint %{public}s, skipping",
                   log: log, type: .error, cloakCfg.rpEndpoint)
            return
        }

        let driver = RosenpassDriver(
            clientSecret: clientSecret,
            clientPublic: clientPublic,
            serverPublic: serverPublic,
            serverHost: String(parts[0]),
            serverPort: port,
            rotationSeconds: cloakCfg.pskRotationSeconds,
            log: log
        )

        // Direct PSK application — no IPC, no opcode 0x01 round-trip,
        // no race with adapter.start (we're already past adapter.start
        // success when this is called from startTunnel's callback). PSK
        // tracking for the Layer 1 health monitor happens automatically
        // because applyPresharedKey stamps lastPSKAppliedAt on success.
        driver.onPSKDerived = { [weak self] psk in
            guard let self = self else { return }
            self.applyPresharedKey(psk) { ok in
                os_log("RosenpassDriver: PSK apply: %{public}s",
                       log: self.log, type: ok ? .info : .error,
                       ok ? "ok" : "failed")
            }
        }

        self.rosenpassDriver = driver
        driver.start()
        os_log("RosenpassDriver: instantiated and started", log: log, type: .info)
    }

    // MARK: - Health monitoring implementation

    /// Spin up the recurring health-check timer. Idempotent — if a
    /// timer is already running, it's cancelled and replaced.
    private func startHealthMonitoring() {
        healthCheckQueue.async { [weak self] in
            guard let self = self else { return }
            self.healthCheckTimer?.cancel()
            // Reset state so a previous tunnel session's counters don't
            // bleed into this one (stopTunnel + startTunnel reuses the
            // same NE process between iOS toggle cycles).
            self.lastRxBytes = 0
            self.lastTxBytes = 0
            self.consecutiveStallTicks = 0

            let timer = DispatchSource.makeTimerSource(queue: self.healthCheckQueue)
            timer.schedule(
                deadline: .now() + .seconds(Self.healthCheckIntervalSec),
                repeating: .seconds(Self.healthCheckIntervalSec),
                leeway: .seconds(2)
            )
            timer.setEventHandler { [weak self] in
                self?.performHealthCheck()
            }
            timer.resume()
            self.healthCheckTimer = timer
            os_log("health: monitor started (interval=%ds)",
                   log: self.log, type: .info, Self.healthCheckIntervalSec)
        }
    }

    /// Cancel the health-check timer. Safe to call when no timer is
    /// running (e.g. stopTunnel after a startTunnel that errored out).
    private func stopHealthMonitoring() {
        healthCheckQueue.async { [weak self] in
            guard let self = self else { return }
            self.healthCheckTimer?.cancel()
            self.healthCheckTimer = nil
            os_log("health: monitor stopped", log: self.log, type: .info)
        }
    }

    /// One health-check tick. Pulls the wg UAPI runtime config, parses
    /// the byte counters and last-handshake timestamp, computes the
    /// stall heuristic, logs everything. Layer 1 takes no action on
    /// "WEDGE SUSPECTED" — it just logs. Layer 2 will replace the log
    /// line with a self.cancelTunnelWithError(...) call once thresholds
    /// are validated against real-device telemetry.
    private func performHealthCheck() {
        // adapter.getRuntimeConfiguration is async with its own callback
        // queue; bounce results back onto healthCheckQueue so all state
        // mutations stay serialized on one queue.
        adapter.getRuntimeConfiguration { [weak self] settings in
            guard let self = self else { return }
            self.healthCheckQueue.async {
                self.parseAndLogHealth(settings: settings)
            }
        }
    }

    /// Parse the wg UAPI runtime config string and emit one os_log line
    /// summarising the tunnel's health for this tick. Runs on
    /// healthCheckQueue.
    ///
    /// Expected wg UAPI format (subset we care about):
    ///
    ///   private_key=...            (interface, ignored)
    ///   public_key=<peer>          (start of peer block)
    ///   preshared_key=...
    ///   endpoint=ip:port
    ///   last_handshake_time_sec=<unix-seconds>
    ///   last_handshake_time_nsec=<nanos>
    ///   rx_bytes=<count>
    ///   tx_bytes=<count>
    ///   persistent_keepalive_interval=<n>
    ///
    /// We aggregate across all peers (currently always 1 in CloakVPN)
    /// so this code is robust if a future multi-peer config arrives.
    private func parseAndLogHealth(settings: String?) {
        guard let settings = settings, !settings.isEmpty else {
            os_log("health: getRuntimeConfiguration returned nil/empty (adapter not ready?)",
                   log: log, type: .error)
            return
        }

        var rxTotal: UInt64 = 0
        var txTotal: UInt64 = 0
        var lastHandshakeSec: UInt64 = 0  // max across peers — we want the freshest

        for line in settings.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let eq = line.firstIndex(of: "=") else { continue }
            let key = String(line[..<eq])
            let val = String(line[line.index(after: eq)...])
            switch key {
            case "rx_bytes":
                if let n = UInt64(val) { rxTotal &+= n }
            case "tx_bytes":
                if let n = UInt64(val) { txTotal &+= n }
            case "last_handshake_time_sec":
                if let n = UInt64(val), n > lastHandshakeSec { lastHandshakeSec = n }
            default:
                break
            }
        }

        let now = Date()
        let nowEpoch = UInt64(now.timeIntervalSince1970)

        // Deltas. Counters monotonically increase in WG (only reset on
        // wg-go session restart inside the NE) so subtraction is safe
        // unless wg-go reset; in that case rxTotal < lastRxBytes and we
        // treat the delta as 0 (next tick will catch up).
        let rxDelta = rxTotal >= lastRxBytes ? rxTotal - lastRxBytes : 0
        let txDelta = txTotal >= lastTxBytes ? txTotal - lastTxBytes : 0
        lastRxBytes = rxTotal
        lastTxBytes = txTotal

        // Handshake age. last_handshake_time_sec=0 means "never
        // handshook" — different from "old handshake".
        let handshakeAgeStr: String
        let handshakeAgeSec: Int
        if lastHandshakeSec == 0 {
            handshakeAgeStr = "never"
            handshakeAgeSec = Int.max
        } else {
            // Guard against clock skew (handshake in the future would
            // produce a negative age; clamp to 0).
            handshakeAgeSec = max(0, Int(nowEpoch) - Int(lastHandshakeSec))
            handshakeAgeStr = "\(handshakeAgeSec)s"
        }

        // PSK age. Tracks the rosenpass success path independently of
        // WG's own handshake (they're different layers — WG handshake
        // can succeed without a fresh PQ exchange if the peer already
        // has the current PSK).
        let pskAgeStr: String
        let pskAgeSec: Int
        if let lastPSK = lastPSKAppliedAt {
            pskAgeSec = max(0, Int(now.timeIntervalSince(lastPSK)))
            pskAgeStr = "\(pskAgeSec)s"
        } else {
            pskAgeStr = "never"
            pskAgeSec = Int.max
        }

        // Stall heuristic: zero rx for this tick AND handshake older
        // than wedgeHandshakeAgeSec. (Tx-only flows still count as
        // healthy because the iPhone might be uploading — what matters
        // is whether the server is responding.) This is the same logic
        // Layer 2 will use to decide whether to cancelTunnelWithError.
        let isStalled = (rxDelta == 0) &&
            (handshakeAgeSec >= Self.wedgeHandshakeAgeSec)
        if isStalled {
            consecutiveStallTicks += 1
        } else {
            consecutiveStallTicks = 0
        }

        // Suppress wedge warnings during the warmup window — the first
        // ~60s after tunnel-up has no rx/handshake yet and would
        // otherwise spam false positives.
        let suppressWarning: Bool
        if let upAt = tunnelUpAt {
            suppressWarning = now.timeIntervalSince(upAt) < Self.warmupSuppressionSec
        } else {
            suppressWarning = false
        }

        os_log("health: rx_delta=%llu tx_delta=%llu rx_total=%llu tx_total=%llu handshake_age=%{public}s psk_age=%{public}s stall_ticks=%d",
               log: log, type: .info,
               rxDelta, txDelta, rxTotal, txTotal,
               handshakeAgeStr, pskAgeStr, consecutiveStallTicks)

        // Wedge detection — same condition Layer 2 acts on.
        let wedgeByStall = consecutiveStallTicks >= Self.wedgeStallTickThreshold
        let wedgeByPSK = pskAgeSec >= Self.wedgePSKAgeSec && lastPSKAppliedAt != nil
        if (wedgeByStall || wedgeByPSK) && !suppressWarning {
            let reason: String
            if wedgeByStall {
                reason = "stall_ticks=\(consecutiveStallTicks), handshake_age=\(handshakeAgeStr)"
            } else {
                reason = "psk_age=\(pskAgeStr)"
            }
            os_log("health: WEDGE DETECTED — %{public}s",
                   log: log, type: .fault, reason)
            attemptWedgeRecovery(reason: reason)
        }
    }

    /// Layer 2 — Force-restart the NE process on detected wedge.
    ///
    /// `cancelTunnelWithError` signals to iOS that the NE cannot continue.
    /// iOS responds by:
    ///   1. Marking NETunnelProviderManager status as `.disconnected` with
    ///      our supplied error attached (visible to host app via
    ///      `connection.fetchLastDisconnectError`).
    ///   2. Calling our `stopTunnel(with:.userInitiated)` to clean up.
    ///   3. Terminating the NE process.
    ///
    /// On the NEXT user-initiated connect (or, when Layer 3 ships, an
    /// auto-restart from the host app on `NEVPNStatusDidChange`), iOS
    /// spawns a fresh NE process. The fresh process has clean
    /// wireguard-go state, no stale PSK, no wedged sockets — equivalent
    /// to the manual "delete VPN profile + re-import" recovery the user
    /// has been doing all session, but with one tap instead of seven.
    ///
    /// Rate-limited via `selfKillTimestamps` to avoid pathological loops:
    /// after maxSelfKillsPerWindow recoveries in selfKillWindowSec, we
    /// stop killing and require manual intervention. This protects
    /// against environmental causes (server-side PSK desync, network
    /// outage) where killing won't help.
    private func attemptWedgeRecovery(reason: String) {
        if selfKillInFlight { return }

        let now = Date()
        // Drop timestamps older than the rolling window
        selfKillTimestamps.removeAll { now.timeIntervalSince($0) > Self.selfKillWindowSec }

        if selfKillTimestamps.count >= Self.maxSelfKillsPerWindow {
            os_log("health: rate-limited (%d self-kills in last %.0fs window) — refusing to cancel; manual intervention required",
                   log: log, type: .fault,
                   selfKillTimestamps.count, Self.selfKillWindowSec)
            return
        }

        selfKillTimestamps.append(now)
        selfKillInFlight = true

        os_log("health: TRIGGERING WEDGE RECOVERY (kill #%d in last %.0fs window) — reason: %{public}s",
               log: log, type: .fault,
               selfKillTimestamps.count, Self.selfKillWindowSec, reason)

        let err = NSError(
            domain: "ai.cloakvpn.CloakTunnel",
            code: -1001,
            userInfo: [
                NSLocalizedDescriptionKey:
                    "Tunnel wedge auto-recovery (\(reason)). NE process restarting; reconnect via the Cloak app."
            ]
        )
        cancelTunnelWithError(err)
    }
}

// MARK: - Errors

enum PacketTunnelError: Error, LocalizedError {
    case missingProtocol
    case badField(String, String) // (fieldName, value)

    var errorDescription: String? {
        switch self {
        case .missingProtocol:
            return "Missing or malformed VPN protocolConfiguration."
        case let .badField(name, value):
            return "Invalid \(name) in tunnel config: \(value.prefix(40))…"
        }
    }
}

// MARK: - WireGuardLogLevel → OSLogType

private extension WireGuardLogLevel {
    var osLogType: OSLogType {
        switch self {
        case .verbose: return .debug
        case .error: return .error
        }
    }
}

// MARK: - CloakConfig → WireGuardKit TunnelConfiguration

extension PacketTunnelProvider {
    /// Translate our wire-format CloakConfig (raw base64 strings,
    /// "host:port" strings, "10.0.0.1/24" strings) into the
    /// strongly-typed WireGuardKit model that WireGuardAdapter can
    /// consume.
    ///
    /// Throws `PacketTunnelError.badField` on the first malformed input
    /// so the user sees a precise error rather than a wg-quick parser's
    /// cryptic message.
    static func makeTunnelConfiguration(from cfg: CloakConfig) throws -> TunnelConfiguration {
        // ---- Interface (the local end of the tunnel) ----
        guard let skBytes = Data(base64Encoded: cfg.wgPrivateKey),
              let privateKey = PrivateKey(rawValue: skBytes) else {
            throw PacketTunnelError.badField("wgPrivateKey", cfg.wgPrivateKey)
        }
        var iface = InterfaceConfiguration(privateKey: privateKey)

        // Interface addresses: typically one v4 + one v6 in CIDR form.
        guard let v4 = IPAddressRange(from: cfg.addressV4) else {
            throw PacketTunnelError.badField("addressV4", cfg.addressV4)
        }
        guard let v6 = IPAddressRange(from: cfg.addressV6) else {
            throw PacketTunnelError.badField("addressV6", cfg.addressV6)
        }
        iface.addresses = [v4, v6]

        // DNS — drop any malformed entries with a log, don't fail the
        // whole tunnel.
        iface.dns = cfg.dns.compactMap { DNSServer(from: $0) }
        iface.mtu = 1420 // safe default for WireGuard over most transports

        // ---- Peer (the concentrator) ----
        guard let pkBytes = Data(base64Encoded: cfg.peerPublicKey),
              let publicKey = PublicKey(rawValue: pkBytes) else {
            throw PacketTunnelError.badField("peerPublicKey", cfg.peerPublicKey)
        }
        var peer = PeerConfiguration(publicKey: publicKey)

        // AllowedIPs — usually "0.0.0.0/0, ::/0" for full-tunnel.
        peer.allowedIPs = try cfg.allowedIPs.map { rangeStr in
            guard let range = IPAddressRange(from: rangeStr) else {
                throw PacketTunnelError.badField("allowedIPs", rangeStr)
            }
            return range
        }

        guard let endpoint = Endpoint(from: cfg.endpoint) else {
            throw PacketTunnelError.badField("endpoint", cfg.endpoint)
        }
        peer.endpoint = endpoint
        peer.persistentKeepAlive = UInt16(clamping: cfg.persistentKeepalive)
        // peer.preSharedKey is left nil; the Rosenpass-derived PSK will
        // be installed later via handleAppMessage → applyPresharedKey.

        return TunnelConfiguration(name: "Cloak", interface: iface, peers: [peer])
    }
}

// MARK: - TunnelConfiguration → NEPacketTunnelNetworkSettings
//
// Port of upstream wireguard-apple's
// PacketTunnelSettingsGenerator.generateNetworkSettings, with logic kept
// identical so the routing/DNS behaviour matches the official WG iOS app
// exactly. We need this because Mullvad's WireGuardAdapter doesn't call
// setTunnelNetworkSettings on our behalf.
//
// SPDX-License-Identifier: MIT (the inlined logic below is © 2018-2023
// WireGuard LLC, MIT-licensed in upstream wireguard-apple).
extension PacketTunnelProvider {
    static func makeNetworkSettings(
        from tunnelCfg: TunnelConfiguration,
        rosenpassServerIP: String? = nil
    ) -> NEPacketTunnelNetworkSettings {
        // iOS requires a tunnelRemoteAddress, but WG can have many or
        // zero peers — 127.0.0.1 is the upstream-blessed placeholder.
        let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: "127.0.0.1")

        // ---- DNS ----
        if !tunnelCfg.interface.dnsSearch.isEmpty || !tunnelCfg.interface.dns.isEmpty {
            let dnsServerStrings = tunnelCfg.interface.dns.map { $0.stringRepresentation }
            let dnsSettings = NEDNSSettings(servers: dnsServerStrings)
            dnsSettings.searchDomains = tunnelCfg.interface.dnsSearch
            if !tunnelCfg.interface.dns.isEmpty {
                // Force ALL DNS through the tunnel. Without this, iOS
                // can leak DNS to the captive resolver via mDNSResponder.
                dnsSettings.matchDomains = [""]
            }
            settings.dnsSettings = dnsSettings
        }

        // ---- MTU ----
        // 1280 is upstream's chosen-by-pain default for iOS (see
        // PacketTunnelSettingsGenerator comment about "broken networks
        // out there"). If our config specifies a non-zero MTU, honor it.
        let mtu = tunnelCfg.interface.mtu ?? 0
        if mtu == 0 {
            settings.mtu = NSNumber(value: 1280)
        } else {
            settings.mtu = NSNumber(value: mtu)
        }

        // ---- Local interface addresses ----
        var ipv4Addresses: [(addr: String, mask: String)] = []
        var ipv6Addresses: [(addr: String, prefix: NSNumber)] = []
        for range in tunnelCfg.interface.addresses {
            if range.address is IPv4Address {
                ipv4Addresses.append(("\(range.address)", "\(range.subnetMask())"))
            } else if range.address is IPv6Address {
                ipv6Addresses.append(("\(range.address)",
                                     NSNumber(value: range.networkPrefixLength)))
            }
        }

        // ---- Included routes (= what gets routed INTO the tunnel) ----
        var ipv4Routes = [NEIPv4Route]()
        var ipv6Routes = [NEIPv6Route]()

        // First: routes to our own interface subnets, with us as gateway.
        for range in tunnelCfg.interface.addresses {
            if range.address is IPv4Address {
                let route = NEIPv4Route(destinationAddress: "\(range.maskedAddress())",
                                        subnetMask: "\(range.subnetMask())")
                route.gatewayAddress = "\(range.address)"
                ipv4Routes.append(route)
            } else if range.address is IPv6Address {
                let route = NEIPv6Route(destinationAddress: "\(range.maskedAddress())",
                                        networkPrefixLength: NSNumber(value: range.networkPrefixLength))
                route.gatewayAddress = "\(range.address)"
                ipv6Routes.append(route)
            }
        }

        // Then: each peer's allowedIPs becomes an included route.
        // For full-tunnel WG (allowedIPs = 0.0.0.0/0, ::/0) this is what
        // installs the default route into the tunnel. THIS is the line
        // whose absence was breaking us.
        for peer in tunnelCfg.peers {
            for range in peer.allowedIPs {
                if range.address is IPv4Address {
                    ipv4Routes.append(NEIPv4Route(destinationAddress: "\(range.address)",
                                                  subnetMask: "\(range.subnetMask())"))
                } else if range.address is IPv6Address {
                    ipv6Routes.append(NEIPv6Route(destinationAddress: "\(range.address)",
                                                  networkPrefixLength: NSNumber(value: range.networkPrefixLength)))
                }
            }
        }

        // ---- Excluded routes (= what gets routed AROUND the tunnel) ----
        // Carve out the rosenpass server's IP so the NE-side rosenpass
        // UDP socket goes over the physical interface, not utun. Without
        // this, NE-side NWConnection traffic to the rosenpass server
        // would loop back into our own utun (since 0.0.0.0/0 is in
        // includedRoutes for full-tunnel mode), creating a chicken/egg
        // where the PSK derivation tries to flow through the tunnel
        // whose PSK it's deriving.
        var ipv4ExcludedRoutes = [NEIPv4Route]()
        var ipv6ExcludedRoutes = [NEIPv6Route]()
        if let ipStr = rosenpassServerIP {
            if let _ = IPv4Address(ipStr) {
                ipv4ExcludedRoutes.append(NEIPv4Route(destinationAddress: ipStr,
                                                     subnetMask: "255.255.255.255"))
            } else if let _ = IPv6Address(ipStr) {
                ipv6ExcludedRoutes.append(NEIPv6Route(destinationAddress: ipStr,
                                                     networkPrefixLength: NSNumber(value: 128)))
            }
            // (Neither v4 nor v6 → already logged at startTunnel; skip
            // exclusion silently here.)
        }

        // ---- IPv4 settings ----
        let v4 = NEIPv4Settings(addresses: ipv4Addresses.map { $0.addr },
                                subnetMasks: ipv4Addresses.map { $0.mask })
        v4.includedRoutes = ipv4Routes
        if !ipv4ExcludedRoutes.isEmpty {
            v4.excludedRoutes = ipv4ExcludedRoutes
        }
        settings.ipv4Settings = v4

        // ---- IPv6 settings ----
        let v6 = NEIPv6Settings(addresses: ipv6Addresses.map { $0.addr },
                                networkPrefixLengths: ipv6Addresses.map { $0.prefix })
        v6.includedRoutes = ipv6Routes
        if !ipv6ExcludedRoutes.isEmpty {
            v6.excludedRoutes = ipv6ExcludedRoutes
        }
        settings.ipv6Settings = v6

        return settings
    }

    /// Parse a "host:port" or "[v6]:port" endpoint string and return the
    /// IP literal. Returns nil if the host part isn't a parseable IPv4
    /// or IPv6 literal — DNS resolution is intentionally NOT done here
    /// because excludedRoutes need a literal IP, not a hostname.
    /// If you switch to DNS-based rpEndpoint values, you'll need to
    /// resolve at startTunnel and re-resolve on roaming.
    static func extractIP(from endpoint: String) -> String? {
        // [v6]:port form
        if endpoint.hasPrefix("[") {
            guard let close = endpoint.firstIndex(of: "]") else { return nil }
            let host = String(endpoint[endpoint.index(after: endpoint.startIndex)..<close])
            return IPv6Address(host) != nil ? host : nil
        }
        // v4-style host:port — split on the LAST colon to be safe with
        // bare-IPv6 (no brackets, no port) inputs, which we then validate.
        if let colon = endpoint.lastIndex(of: ":") {
            let host = String(endpoint[..<colon])
            if IPv4Address(host) != nil { return host }
            // Could be a bare IPv6 with no port — try the whole string.
            if IPv6Address(endpoint) != nil { return endpoint }
            return nil
        }
        // No colon at all — try parsing the whole thing as a literal.
        if IPv4Address(endpoint) != nil { return endpoint }
        if IPv6Address(endpoint) != nil { return endpoint }
        return nil
    }
}
