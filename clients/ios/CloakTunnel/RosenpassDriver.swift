// SPDX-License-Identifier: MIT
//
// Cloak VPN — RosenpassDriver
//
// In-NE-process driver for the rosenpass post-quantum key-exchange loop.
// Replaces the host-app-resident RosenpassBridge that broke whenever iOS
// suspended the host app (every time the user backgrounded Cloak to use
// another app — which is essentially constant in real use).
//
// Why this exists (the bug it fixes — captured in detail in
// HANDOFF_2026-04-27_session4.md and task #17):
//
//   - The original architecture lived in TunnelManager.RosenpassBridge,
//     in the host-app (CloakVPN) process.
//   - When the user backgrounded the Cloak app to switch to YouTube /
//     Safari / etc., iOS suspended the host app within ~30 seconds.
//   - With the host-app suspended, RosenpassBridge stopped rotating
//     PSKs. Server-side rosenpass kept emitting "stale"/new PSKs,
//     server's psk-installer kept applying them, server's wg-go ended
//     up with a different PSK than the iPhone's wg-go.
//   - WG handshakes started failing with "Received invalid response
//     message" — because the response was authenticated with a PSK
//     the client didn't have.
//   - Eventually we ship Layers 1-4 of wedge auto-recovery to detect
//     and force-reconnect through this state, but the recovery cycle
//     produces a perceptible flicker every ~5 minutes for real users.
//
// This driver runs entirely inside the NE process. iOS keeps the NE
// alive for as long as the VPN is active — backgrounding the host app
// has no effect on the NE. So rosenpass rotations continue uninterrupted,
// PSK never desyncs, and the wedge never happens in the first place.
//
// What's still in the host app:
//   - One-time generation of the device's static rosenpass keypair
//     (ensureLocalKeypair → generateStaticKeypair). McEliece keygen has
//     a brief 2-4 MB working-set spike that we keep out of the NE's
//     ~50 MiB jetsam limit. This runs once on first install; the
//     keypair is persisted to App Group container; the NE reads it on
//     every tunnel start.
//   - Importing config blocks and persisting the server's rosenpass
//     pubkey (importConfig → AppGroupKeyStore.saveServerPublicKey).
//   - UI and lifecycle.

import Foundation
import Network
import os.log

/// Drives the Rosenpass V03 protocol from inside the NetworkExtension
/// process. Replaces the now-obsolete RosenpassBridge → NETunnelTransport
/// IPC path entirely.
final class RosenpassDriver {

    // MARK: - Inputs (set at start)

    private let clientSecret: Data
    private let clientPublic: Data
    private let serverPublic: Data
    private let serverHost: String
    private let serverPort: UInt16
    private let rotationSeconds: Int

    // MARK: - PSK delivery

    /// Called on each successful PQ exchange with the freshly-derived
    /// 32-byte PSK. The PacketTunnelProvider applies it directly to
    /// wg-go via the WireGuardKitAdapter (no IPC, no opcode 0x01 round
    /// trip, no race with adapter.start). Set by the provider in
    /// startTunnel before calling `start()` on the driver.
    var onPSKDerived: ((Data) -> Void)?

    // MARK: - Internal state

    private let log: OSLog
    private var loopTask: Task<Void, Never>?
    private var udpConnection: NWConnection?
    private let connQueue = DispatchQueue(label: "ai.cloakvpn.tunnel.rp-driver")

    /// Last successful exchange wallclock — used for the App Group
    /// status export (see writeStatusToAppGroup). 0 means no exchange
    /// has succeeded yet on this driver instance.
    private var rotationCount: Int = 0
    private var lastSuccessAt: Date?

    /// App Group container path for exposing rotation state to the host
    /// app. The host app's UI polls this so the user still sees a live
    /// "PQC: N rotations" indicator even though the actual loop is now
    /// in the NE.
    ///
    /// File-based, NOT UserDefaults: iOS doesn't reliably propagate
    /// UserDefaults across processes in real time — the first cross-
    /// process write tends to land, but subsequent writes get stuck in
    /// the reader's UserDefaults cache and never become visible to the
    /// host app's poll. App Group file writes have well-defined cross-
    /// process semantics (kernel-level shared filesystem; mtime + read
    /// always reflect the latest write). Originally surfaced 2026-04-27
    /// as "PQC: 1 rotation" frozen on the iPhone UI even though the
    /// server logs showed 5+ successful exchanges.
    private static let appGroupID = "group.ai.cloakvpn.CloakVPN"
    private static let statusFilename = "ne-rosenpass-status.json"

    // MARK: - Init / lifecycle

    init(
        clientSecret: Data,
        clientPublic: Data,
        serverPublic: Data,
        serverHost: String,
        serverPort: UInt16,
        rotationSeconds: Int,
        log: OSLog
    ) {
        self.clientSecret = clientSecret
        self.clientPublic = clientPublic
        self.serverPublic = serverPublic
        self.serverHost = serverHost
        self.serverPort = serverPort
        // Floor at 30s — tighter rotations risk overlapping handshakes
        // and don't materially improve forward secrecy.
        self.rotationSeconds = max(rotationSeconds, 30)
        self.log = log
    }

    /// Spin up the rotation loop. Idempotent — calling again replaces
    /// the in-flight task.
    func start() {
        loopTask?.cancel()
        os_log("RosenpassDriver: starting (rotation=%ds, server=%{public}s:%d)",
               log: log, type: .info,
               rotationSeconds, serverHost, Int(serverPort))
        loopTask = Task { [weak self] in
            await self?.runLoop()
        }
    }

    /// Cancel the loop and tear down the UDP socket. Safe to call
    /// multiple times. Driver is single-use after stop — create a new
    /// one for the next tunnel session.
    func stop() {
        os_log("RosenpassDriver: stopping (had %d successful rotations)",
               log: log, type: .info, rotationCount)
        loopTask?.cancel()
        loopTask = nil
        closeConnection()
    }

    // MARK: - Rotation loop

    private func runLoop() async {
        var consecutiveFailures = 0
        while !Task.isCancelled {
            do {
                let psk = try await singleHandshake()
                rotationCount += 1
                lastSuccessAt = Date()
                consecutiveFailures = 0
                writeStatusToAppGroup()
                os_log("RosenpassDriver: rotation #%d successful (%d byte PSK)",
                       log: log, type: .info, rotationCount, psk.count)
                onPSKDerived?(psk)

                // Sleep until the next rotation deadline, abortable by
                // task cancellation (e.g. stopTunnel).
                try await Task.sleep(nanoseconds: UInt64(rotationSeconds) * 1_000_000_000)
            } catch is CancellationError {
                return
            } catch {
                consecutiveFailures += 1
                os_log("RosenpassDriver: handshake failed (%d consecutive): %{public}s",
                       log: log, type: .error,
                       consecutiveFailures, error.localizedDescription)
                // Exponential backoff capped at 60s. Same behavior as
                // the old RosenpassBridge — keeps a healthy retry cadence
                // without DoSing the server during transient outages.
                let delaySec = min(60, 1 << min(consecutiveFailures, 6))
                try? await Task.sleep(nanoseconds: UInt64(delaySec) * 1_000_000_000)
            }
        }
    }

    /// One round-trip of the rosenpass V03 protocol:
    ///   tx: InitHello → rx: RespHello → tx: InitConf → done.
    /// Fetches the derived PSK from the FFI's `lastDerivedPsk()` after
    /// sending InitConf because V03 surfaces PSK via SendMessage(InitConf)
    /// rather than DerivedPsk — see RosenpassBridge.singleHandshake's
    /// comment for the full rationale.
    private func singleHandshake() async throws -> Data {
        return try await Task.detached(priority: .userInitiated) { [self] in
            let session = try RosenpassSession(
                ourSecretKey: clientSecret,
                ourPublicKey: clientPublic,
                peerPublicKey: serverPublic
            )

            try await ensureConnection()
            // Close the UDP socket at the end of every handshake (success
            // OR failure), exactly as the original host-app RosenpassBridge
            // / NETunnelTransport.close() does. Without this, stale rosenpass
            // response packets from a PREVIOUS handshake remain buffered in
            // the kernel UDP receive queue, get consumed by the NEXT
            // handshake's receiveUDP() call, and fail to validate against
            // the new session's ID — producing the "handle_msg: Got
            // RespHello packet for non-existent session [...]" error
            // pattern. Each handshake gets a fresh ephemeral source port +
            // empty receive buffer.
            defer { closeConnection() }

            let firstMsg = try session.initiate()
            try await sendUDP(firstMsg)

            // Up to 6 iterations: handles V03's 1.5-RTT pattern plus
            // any retransmits from the server side under loss.
            for _ in 0..<6 {
                try Task.checkCancellation()
                let inbound = try await receiveUDP(timeoutSeconds: 8)
                let result = try session.handleMessage(bytes: inbound)
                switch result {
                case .sendMessage(let bytes):
                    try await sendUDP(bytes)
                    // V03 initiator: PSK may have been derived during
                    // the same handle_message call that produced these
                    // outgoing bytes (the RespHello that requires us to
                    // emit InitConf). Fetch it from the session's stash.
                    if let psk = session.lastDerivedPsk(), psk.count == 32 {
                        return psk
                    }
                case .derivedPsk(let psk):
                    guard psk.count == 32 else {
                        throw RosenpassDriverError.badPskLength(psk.count)
                    }
                    return psk
                case .idle:
                    if let psk = session.lastDerivedPsk(), psk.count == 32 {
                        return psk
                    }
                    continue
                }
            }
            throw RosenpassDriverError.exceededMessageBudget
        }.value
    }

    // MARK: - UDP transport (direct, no IPC)

    /// Lazily create or return the existing UDP socket to the rosenpass
    /// server. NWConnection inside the NE process is exempt from the
    /// includeAllNetworks=true NECP rules that block host-app sockets,
    /// AND it's straightforward to scope off-utun via prohibitedInter-
    /// faceTypes. We carve out the rosenpass server IP via excluded-
    /// Routes in PacketTunnelProvider.makeNetworkSettings to keep this
    /// connection routing through the physical interface.
    private func ensureConnection() async throws {
        if let c = udpConnection, c.state == .ready {
            return
        }
        udpConnection?.cancel()
        udpConnection = nil

        guard let portValue = NWEndpoint.Port(rawValue: serverPort) else {
            throw RosenpassDriverError.badEndpoint("\(serverHost):\(serverPort)")
        }
        let endpoint = NWEndpoint.hostPort(host: NWEndpoint.Host(serverHost),
                                            port: portValue)

        let params = NWParameters.udp
        // Keep this connection off utun. The excludedRoute carve-out in
        // makeNetworkSettings does the heavy lifting at the routing
        // table level; this is belt-and-suspenders.
        params.prohibitedInterfaceTypes = [.other]

        let conn = NWConnection(to: endpoint, using: params)
        self.udpConnection = conn

        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            var fired = false
            conn.stateUpdateHandler = { [weak self, weak conn] state in
                guard let conn = conn else { return }
                switch state {
                case .ready:
                    if !fired {
                        fired = true
                        os_log("RosenpassDriver: UDP connection ready",
                               log: self?.log ?? .default, type: .info)
                        cont.resume()
                    }
                case .failed(let err):
                    if !fired {
                        fired = true
                        os_log("RosenpassDriver: UDP connection failed: %{public}s",
                               log: self?.log ?? .default, type: .error,
                               String(describing: err))
                        cont.resume(throwing: err)
                    }
                case .cancelled:
                    if !fired {
                        fired = true
                        cont.resume(throwing: CancellationError())
                    }
                default:
                    break
                }
            }
            conn.start(queue: connQueue)
        }
    }

    private func sendUDP(_ data: Data) async throws {
        guard let conn = udpConnection else {
            throw RosenpassDriverError.connectionUnavailable
        }
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            conn.send(content: data, completion: .contentProcessed { err in
                if let err = err {
                    cont.resume(throwing: err)
                } else {
                    cont.resume()
                }
            })
        }
    }

    /// Receive one rosenpass UDP datagram, with a wallclock timeout.
    /// Throws `exceededMessageBudget` on timeout to match the existing
    /// runLoop's exponential-backoff handling.
    private func receiveUDP(timeoutSeconds: Int) async throws -> Data {
        guard let conn = udpConnection else {
            throw RosenpassDriverError.connectionUnavailable
        }
        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Data, Error>) in
            // Race a single-shot receive against a wallclock timeout.
            // Whichever fires first wins; the loser's resume is
            // suppressed via `settled`.
            var settled = false
            let lock = NSLock()
            func tryComplete(_ result: Result<Data, Error>) {
                lock.lock()
                defer { lock.unlock() }
                if settled { return }
                settled = true
                switch result {
                case .success(let d): cont.resume(returning: d)
                case .failure(let e): cont.resume(throwing: e)
                }
            }
            conn.receiveMessage { content, _, _, recvErr in
                if let recvErr = recvErr {
                    tryComplete(.failure(recvErr))
                    return
                }
                tryComplete(.success(content ?? Data()))
            }
            connQueue.asyncAfter(deadline: .now() + .seconds(timeoutSeconds)) {
                tryComplete(.failure(RosenpassDriverError.exceededMessageBudget))
            }
        }
    }

    private func closeConnection() {
        udpConnection?.cancel()
        udpConnection = nil
    }

    // MARK: - App Group status export

    /// Publish rotation count + last-success timestamp to a shared file
    /// in the App Group container so the host app's UI can read and
    /// display them. Without this, the host app would have no visibility
    /// into rosenpass progress and the existing "PQC: N rotations" UI
    /// would appear permanently idle. Best-effort — failures are logged
    /// but don't abort the rotation loop (the actual key exchange is
    /// what matters; UI freshness is cosmetic).
    private func writeStatusToAppGroup() {
        guard let dir = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: Self.appGroupID
        ) else {
            os_log("RosenpassDriver: App Group container unavailable — UI status export skipped",
                   log: log, type: .error)
            return
        }
        let target = dir.appendingPathComponent(Self.statusFilename)

        // Tiny JSON: one line, predictable shape, easy to parse on
        // host-app side without pulling in JSONDecoder ceremony.
        let lastEpoch = lastSuccessAt?.timeIntervalSince1970 ?? 0
        let json = "{\"rotationCount\":\(rotationCount),\"lastSuccessEpoch\":\(lastEpoch)}"
        guard let data = json.data(using: .utf8) else { return }
        do {
            try data.write(to: target, options: [.atomic])
        } catch {
            os_log("RosenpassDriver: failed to write status file: %{public}s",
                   log: log, type: .error, String(describing: error))
        }
    }
}

// MARK: - FfiError → LocalizedError (CloakTunnel target copy)
//
// The uniffi-generated FfiError carries useful `message: String` payloads
// on every case but uniffi only adds Error conformance — not
// LocalizedError. Without this extension, any FfiError surfaced through
// `error.localizedDescription` collapses to the unhelpful "CloakTunnel.
// FfiError error <N>" form, hiding the payload that explains what
// actually went wrong (which is exactly what we hit on first deploy of
// the in-NE driver — "handshake failed: ...FfiError error 0" with no
// message visible). RosenpassBridge.swift in the host-app target has an
// identical extension; we duplicate it here because rosenpassffi.swift
// is shared between targets but extensions on FfiError are
// target-scoped (each target gets its own).
extension FfiError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .Rosenpass(let m):    return "rosenpass: \(m)"
        case .InvalidInput(let m): return "invalid input: \(m)"
        case .InvalidState(let m): return "invalid state: \(m)"
        case .Internal(let m):     return "internal: \(m)"
        }
    }
}

// MARK: - Errors

enum RosenpassDriverError: LocalizedError {
    case badEndpoint(String)
    case badPskLength(Int)
    case exceededMessageBudget
    case connectionUnavailable

    var errorDescription: String? {
        switch self {
        case .badEndpoint(let s):     return "rosenpass endpoint malformed: \(s)"
        case .badPskLength(let n):    return "PSK length \(n) ≠ 32"
        case .exceededMessageBudget:  return "rosenpass handshake exceeded message budget (timeout)"
        case .connectionUnavailable:  return "rosenpass UDP connection not ready"
        }
    }
}
