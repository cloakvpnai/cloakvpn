import Combine
import Foundation
import Network
import os.log

/// Drives the Rosenpass post-quantum key exchange against the Cloak
/// concentrator's UDP rosenpass listener (typically `<region>.cloakvpn.ai:9999`).
///
/// Architecture (see docs/IOS_PQC.md):
///   - Crypto state machine runs in the MAIN APP only (NE's ~50 MiB
///     jetsam cap is too tight for rosenpass keygen).
///   - Rosenpass UDP transport runs in the NE process. The host app
///     (this class) relays bytes through the NE via opcodes 0x02 (SEND)
///     / 0x03 (RECV) / 0x04 (CLOSE) on `NETunnelProviderSession.sendProviderMessage`.
///     The NE owns the actual NWConnection to the rosenpass server.
///     This is required under `includeAllNetworks = true` because iOS
///     NECP forbids host-app sockets from bypassing the tunnel — but
///     NE-process sockets are exempt (the NE *is* the tunnel).
///   - For each rotation cycle:
///       1. Constructs a fresh `RosenpassSession` from the imported keys.
///       2. Calls `.initiate()` to get InitHello bytes; transport-sends.
///       3. Loops on transport-receive → `session.handleMessage()` →
///          reply, ending when the FFI surfaces a 32-byte PSK
///          (either via `.derivedPsk` or stashed in `lastDerivedPsk()`
///          after a `.sendMessage` containing the V03 InitConf bytes
///          that the responder needs in order to commit).
///       4. Surfaces the 32-byte PSK via `onPSKDerived`.
///       5. Sleeps until the next rotation deadline (default 120 s).
///   - On `stop()` or app termination, cancels the loop.
@MainActor
final class RosenpassBridge: ObservableObject {
    enum Status: Equatable, CustomStringConvertible {
        case idle
        case connecting
        case handshaking
        case established(rotations: Int)
        case error(String)

        var description: String {
            switch self {
            case .idle: return "PQC: idle"
            case .connecting: return "PQC: connecting"
            case .handshaking: return "PQC: handshaking…"
            case .established(let n):
                return "PQC: \(n) rotation\(n == 1 ? "" : "s") ✓"
            case .error(let s): return "PQC: \(s)"
            }
        }
    }

    @Published private(set) var status: Status = .idle

    /// Called on the MainActor when a fresh 32-byte PSK is derived.
    /// The receiver (TunnelManager) is expected to push it to the NE
    /// via `NETunnelProviderSession.sendProviderMessage` opcode 0x01.
    var onPSKDerived: ((Data) -> Void)?

    /// Relays a `sendProviderMessage` round-trip to the NE process.
    /// Must be set by the owning TunnelManager before `start(...)` is
    /// called (otherwise the run loop errors out with neSessionUnavailable).
    /// The closure is `@Sendable` because singleHandshake runs in a
    /// detached Task off the MainActor, but the underlying NETunnel-
    /// ProviderSession.sendProviderMessage call must be made on the
    /// MainActor — see TunnelManager.connect().
    var sendNE: (@Sendable (Data) async throws -> Data)?

    private static let log = OSLog(subsystem: "ai.cloakvpn.CloakVPN", category: "rosenpass")

    private struct SessionConfig {
        let clientSecret: Data
        let clientPublic: Data
        let serverPublic: Data
        let serverHost: String
        let serverPort: UInt16
        let rotationSeconds: Int
    }

    private var loopTask: Task<Void, Never>?
    private var config: SessionConfig?

    // MARK: - App Group status polling (post task #17 — NE drives the loop)
    //
    // The actual rosenpass rotation loop now runs in the NE process via
    // RosenpassDriver (clients/ios/CloakTunnel/RosenpassDriver.swift). We
    // poll the App Group UserDefaults where it writes rotation count and
    // last-success epoch, and update self.status so the existing UI
    // (ContentView's infoPanel) keeps showing live "PQC: N rotations"
    // without requiring any UI refactor.

    private var statusPollTimer: Timer?

    private static let appGroupID = "group.ai.cloakvpn.CloakVPN"
    private static let neRotationCountKey = "ne.rosenpass.rotationCount"
    private static let neLastSuccessEpochKey = "ne.rosenpass.lastSuccessEpoch"

    /// Threshold past which we surface a degraded "stale" status to the
    /// user. Matches the NE-side health monitor's wedgePSKAgeSec — if
    /// the NE hasn't reported a successful rotation in 5 minutes,
    /// something's wrong even though Layer 2 may not have fired yet.
    private static let staleThresholdSec: TimeInterval = 300

    // MARK: - Public API

    /// Start the periodic Rosenpass handshake loop. Idempotent — calling
    /// it again replaces any in-flight session.
    func start(
        clientSecretKeyB64: String,
        clientPublicKeyB64: String,
        serverPublicKeyB64: String,
        serverEndpoint: String,
        rotationSeconds: Int
    ) {
        // Tear down any prior loop FIRST so the new state isn't visible
        // mid-rotation.
        stop()

        guard let sk = Data(base64Encoded: clientSecretKeyB64),
              let pk = Data(base64Encoded: clientPublicKeyB64),
              let serverPk = Data(base64Encoded: serverPublicKeyB64) else {
            self.status = .error("invalid base64 in keys")
            return
        }

        let parts = serverEndpoint.split(separator: ":", maxSplits: 1)
        guard parts.count == 2,
              let port = UInt16(parts[1]) else {
            self.status = .error("bad endpoint \(serverEndpoint)")
            return
        }

        self.config = SessionConfig(
            clientSecret: sk,
            clientPublic: pk,
            serverPublic: serverPk,
            serverHost: String(parts[0]),
            serverPort: port,
            rotationSeconds: max(rotationSeconds, 30)
        )
        self.status = .connecting
        self.loopTask = Task { [weak self] in
            await self?.runLoop()
        }
    }

    /// Cancel the loop and clear in-memory state. Safe to call multiple
    /// times.
    func stop() {
        loopTask?.cancel()
        loopTask = nil
        config = nil
        stopStatusPolling()
        status = .idle
    }

    // MARK: - App Group status polling

    /// Start a 3-second poll of App Group UserDefaults for the NE-driven
    /// rotation count. Call from TunnelManager.connect when the in-NE
    /// RosenpassDriver becomes responsible for the rotation loop. The
    /// poll updates self.status so the existing ContentView indicator
    /// stays live ("PQC: N rotations ✓") without any UI refactor.
    func startStatusPolling() {
        stopStatusPolling()
        // Show .connecting until the first rotation completes; the
        // NE driver typically gets a fresh PSK within 30-60 seconds.
        status = .connecting
        // Fire once immediately so any cached values from a prior session
        // surface right away rather than waiting up to 3s.
        refreshStatusFromAppGroup()
        let timer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [weak self] _ in
            // Timer callback runs on the main run loop; bridge to MainActor
            // explicitly because RosenpassBridge is @MainActor-isolated.
            Task { @MainActor [weak self] in
                self?.refreshStatusFromAppGroup()
            }
        }
        self.statusPollTimer = timer
    }

    /// Stop the status poll timer. Idempotent.
    func stopStatusPolling() {
        statusPollTimer?.invalidate()
        statusPollTimer = nil
    }

    private func refreshStatusFromAppGroup() {
        guard let ud = UserDefaults(suiteName: Self.appGroupID) else {
            status = .error("App Group unavailable")
            return
        }
        let rotations = ud.integer(forKey: Self.neRotationCountKey)
        let lastSuccessEpoch = ud.double(forKey: Self.neLastSuccessEpochKey)

        guard rotations > 0 else {
            // No rotations have been published yet — driver is still
            // doing its first handshake. Keep the user informed without
            // looking idle.
            status = .handshaking
            return
        }

        // Detect stale state: NE driver has stopped successfully rotating.
        // Means the driver is failing repeatedly OR the NE process is
        // somehow not getting CPU. Either way, surface it visually.
        if lastSuccessEpoch > 0 {
            let age = Date().timeIntervalSince1970 - lastSuccessEpoch
            if age > Self.staleThresholdSec {
                status = .error("PSK stale (\(Int(age))s old)")
                return
            }
        }

        status = .established(rotations: rotations)
    }

    // MARK: - Internal loop

    private func runLoop() async {
        guard let cfg = self.config else { return }
        var rotations = 0
        var consecutiveFailures = 0

        while !Task.isCancelled {
            self.status = .handshaking
            do {
                guard let sendNE = self.sendNE else {
                    throw RosenpassBridgeError.neSessionUnavailable
                }
                let psk = try await Self.singleHandshake(cfg: cfg, sendNE: sendNE)
                rotations += 1
                consecutiveFailures = 0
                self.status = .established(rotations: rotations)
                onPSKDerived?(psk)

                try await Task.sleep(nanoseconds: UInt64(cfg.rotationSeconds) * 1_000_000_000)
            } catch is CancellationError {
                return
            } catch {
                consecutiveFailures += 1
                let msg = error.localizedDescription
                os_log("Rosenpass handshake failed (%d): %{public}s",
                       log: Self.log, type: .error, consecutiveFailures, msg)
                self.status = .error(msg)
                // Exponential backoff capped at 60 s.
                let delaySec = min(60, 2 << consecutiveFailures)
                try? await Task.sleep(nanoseconds: UInt64(delaySec) * 1_000_000_000)
            }
        }
    }

    /// One round-trip of the Rosenpass protocol. Heavy lifting (FFI
    /// calls into Rust crypto) happens on a detached priority-userInitiated
    /// task so we don't block the main actor with megabyte allocations.
    /// UDP I/O is relayed through the NE via the supplied sendNE closure.
    private static func singleHandshake(
        cfg: SessionConfig,
        sendNE: @escaping @Sendable (Data) async throws -> Data
    ) async throws -> Data {
        try await Task.detached(priority: .userInitiated) {
            let session = try RosenpassSession(
                ourSecretKey: cfg.clientSecret,
                ourPublicKey: cfg.clientPublic,
                peerPublicKey: cfg.serverPublic
            )

            let transport = NETunnelTransport(sendNE: sendNE)
            try await transport.connect()
            defer { transport.close() }

            let firstMsg = try session.initiate()
            try await transport.send(firstMsg)

            // Rosenpass V03 protocol flow against a responder peer:
            //   tx: InitHello       (we just sent this)
            //   rx: RespHello       → handle_msg derives PSK on our side
            //                         AND emits InitConf bytes
            //   tx: InitConf        (we send this; responder commits)
            //   rx: <none>          (responder typically doesn't ack)
            //
            // After step 2 above, the FFI returns SendMessage(InitConf)
            // (NOT DerivedPsk) — because the InitConf bytes MUST be sent
            // for the responder to commit. The PSK is stashed in the
            // session's last_psk field; we fetch it via lastDerivedPsk()
            // after sending. If we returned DerivedPsk and exited the
            // loop here, we'd drop InitConf on the floor and leave the
            // responder's WireGuard with no PSK installed — which broke
            // us-west-1's full-tunnel mode for ~3 hours 2026-04-26
            // evening before we tracked it down.
            //
            // Up to 6 iterations to handle retransmits.
            for _ in 0..<6 {
                try Task.checkCancellation()
                let inbound = try await transport.receive(timeoutSeconds: 8)
                let result = try session.handleMessage(bytes: inbound)
                switch result {
                case .sendMessage(let bytes):
                    try await transport.send(bytes)
                    // V03 initiator: PSK may have been derived during
                    // this same handle_message call (the one that
                    // produced these outgoing bytes). The responder
                    // needed the bytes to commit; we still need the PSK
                    // to push to the NE. Fetch it from the session's
                    // stash.
                    if let psk = session.lastDerivedPsk(), psk.count == 32 {
                        return psk
                    }
                case .derivedPsk(let psk):
                    guard psk.count == 32 else {
                        throw RosenpassBridgeError.badPskLength(psk.count)
                    }
                    return psk
                case .idle:
                    // V03 responder may surface PSK via Idle (no resp,
                    // PSK derived from InitConf). Check the stash.
                    if let psk = session.lastDerivedPsk(), psk.count == 32 {
                        return psk
                    }
                    continue
                }
            }
            throw RosenpassBridgeError.exceededMessageBudget
        }.value
    }
}

private enum RosenpassBridgeError: LocalizedError {
    case badPskLength(Int)
    case exceededMessageBudget
    case neSessionUnavailable
    case neSendFailed(code: UInt8)

    var errorDescription: String? {
        switch self {
        case .badPskLength(let n): return "PSK length \(n) ≠ 32"
        case .exceededMessageBudget: return "handshake exceeded message budget"
        case .neSessionUnavailable: return "VPN tunnel not active (sendNE closure missing)"
        case .neSendFailed(let code): return "NE rejected rosenpass UDP (code 0x\(String(code, radix: 16)))"
        }
    }
}

// MARK: - FfiError → LocalizedError
//
// The uniffi-generated `FfiError` enum (in rosenpassffi.swift) carries
// useful `message: String` payloads on every case, but uniffi only adds
// `Error` conformance — not `LocalizedError`. Without this extension,
// any FfiError surfaced through `error.localizedDescription` collapses
// to the unhelpful "CloakVPN.FfiError error <N>" form, hiding the
// payload that explains what actually went wrong (key length mismatch,
// protocol error from the server, etc.).
//
// Defined here rather than alongside the generated bindings so we don't
// fight the codegen on the next FFI regeneration.
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

// MARK: - NETunnelTransport

/// Adapter that mirrors the old UDPClient API but relays every
/// send/receive through the NE process via `sendProviderMessage`. The
/// NE owns the actual UDP socket to the rosenpass server (see
/// PacketTunnelProvider.handleAppMessage opcodes 0x02/0x03/0x04).
///
/// Why route through the NE rather than from the host app directly:
/// under `includeAllNetworks = true` (which we want for IP-leak
/// protection), iOS's NECP forbids host-app sockets from bypassing the
/// tunnel even with explicit interface hints. NE-process sockets ARE
/// the tunnel and so are exempt. By having the host-app rosenpass state
/// machine relay through the NE, we keep the heavy crypto in the
/// high-memory main app process AND get the routing privileges of the
/// NE for the UDP transport.
///
/// `@unchecked Sendable` because the wrapped `sendNE` closure is
/// already `@Sendable` and we don't store any other mutable state.
/// `nonisolated` keeps the type out of the @MainActor isolation that
/// Swift 6 mode would otherwise infer (because this file also contains
/// the @MainActor RosenpassBridge class). The transport itself holds no
/// actor-bound state — all its methods are async and just await the
/// Sendable closure — so MainActor isolation would be both unnecessary
/// and incompatible with `Task.detached` usage in singleHandshake.
nonisolated private final class NETunnelTransport: @unchecked Sendable {
    private let sendNE: @Sendable (Data) async throws -> Data

    init(sendNE: @escaping @Sendable (Data) async throws -> Data) {
        self.sendNE = sendNE
    }

    /// Mirror of the old UDPClient.connect — but the NE creates its
    /// internal NWConnection lazily on first SEND_RP_UDP, so there's
    /// nothing for us to do here. Kept as a public API to preserve the
    /// call shape in singleHandshake.
    func connect() async throws {
        // Intentionally empty.
    }

    /// Send a rosenpass UDP packet via the NE. The NE responds with
    /// a 1-byte status (0x00 = sent, anything else = error code).
    func send(_ data: Data) async throws {
        var payload = Data()
        payload.append(0x02) // SEND_RP_UDP
        payload.append(data)
        let response = try await sendNE(payload)
        let code = response.first ?? 0xFF
        if code != 0x00 {
            throw RosenpassBridgeError.neSendFailed(code: code)
        }
    }

    /// Block in the NE for up to `timeoutSeconds` waiting for a
    /// rosenpass UDP datagram from the server. Empty response from
    /// the NE means timeout/error — we map it onto the existing
    /// `exceededMessageBudget` error so the runLoop's exponential
    /// backoff handles it.
    func receive(timeoutSeconds: TimeInterval) async throws -> Data {
        var payload = Data()
        payload.append(0x03) // RECV_RP_UDP
        // 1-byte timeout, clamped to 1..255 seconds.
        let clamped = max(1, min(255, Int(timeoutSeconds.rounded())))
        payload.append(UInt8(clamped))
        let response = try await sendNE(payload)
        if response.isEmpty {
            throw RosenpassBridgeError.exceededMessageBudget
        }
        return response
    }

    /// Tear down the NE-side UDP connection between handshakes. Best
    /// effort — fire-and-forget so we don't extend a handshake's
    /// happy-path latency by an extra IPC round trip.
    func close() {
        let payload = Data([0x04]) // CLOSE_RP_UDP
        let sendNE = self.sendNE
        Task {
            _ = try? await sendNE(payload)
        }
    }
}
