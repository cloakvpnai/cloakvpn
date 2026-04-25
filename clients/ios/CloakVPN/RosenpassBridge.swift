import Combine
import Foundation
import Network
import os.log

/// Drives the Rosenpass post-quantum key exchange against the Cloak
/// concentrator's UDP rosenpass listener (typically `<region>.cloakvpn.ai:9999`).
///
/// Architecture (see docs/IOS_PQC.md):
///   - Runs in the MAIN APP only, never inside the NetworkExtension.
///     Rosenpass keygen/handshake peaks at 1-3 MB working set; the NE's
///     50 MiB jetsam cap is too tight to host this safely.
///   - For each rotation cycle:
///       1. Constructs a fresh `RosenpassSession` from the imported keys.
///       2. Calls `.initiate()` to get InitHello bytes; UDP-sends them.
///       3. Loops on UDP receive → `session.handleMessage()` → reply
///          until `handleMessage` returns `.derivedPsk`.
///       4. Surfaces the 32-byte PSK via `onPSKDerived`.
///       5. Sleeps until the next rotation deadline (default 120 s).
///   - On `stop()` or app termination, cancels the loop.
///
/// Routing note: Rosenpass UDP traffic must NOT go through the WireGuard
/// tunnel (the tunnel itself depends on the PSK we're trying to derive —
/// chicken/egg). We force the underlying NWConnection to bypass virtual
/// interfaces via `prohibitedInterfaceTypes = [.other]`, so the UDP
/// goes directly over WiFi/cellular.
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
        status = .idle
    }

    // MARK: - Internal loop

    private func runLoop() async {
        guard let cfg = self.config else { return }
        var rotations = 0
        var consecutiveFailures = 0

        while !Task.isCancelled {
            self.status = .handshaking
            do {
                let psk = try await Self.singleHandshake(cfg: cfg)
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
    private static func singleHandshake(cfg: SessionConfig) async throws -> Data {
        try await Task.detached(priority: .userInitiated) {
            let session = try RosenpassSession(
                ourSecretKey: cfg.clientSecret,
                ourPublicKey: cfg.clientPublic,
                peerPublicKey: cfg.serverPublic
            )

            let udp = UDPClient(host: cfg.serverHost, port: cfg.serverPort)
            try await udp.connect()
            defer { udp.close() }

            let firstMsg = try session.initiate()
            try await udp.send(firstMsg)

            // Rosenpass v0.3 needs a single round-trip in steady state, but
            // we allow up to ~6 messages to handle retransmits and the
            // optional InitConf path. This is well below any sane cap.
            for _ in 0..<6 {
                try Task.checkCancellation()
                let inbound = try await udp.receive(timeoutSeconds: 8)
                let result = try session.handleMessage(bytes: inbound)
                switch result {
                case .sendMessage(let bytes):
                    try await udp.send(bytes)
                case .derivedPsk(let psk):
                    guard psk.count == 32 else {
                        throw RosenpassBridgeError.badPskLength(psk.count)
                    }
                    return psk
                case .idle:
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

    var errorDescription: String? {
        switch self {
        case .badPskLength(let n): return "PSK length \(n) ≠ 32"
        case .exceededMessageBudget: return "handshake exceeded message budget"
        }
    }
}

// MARK: - UDPClient

/// Minimal async UDP wrapper around NWConnection. Single peer, no
/// fancy buffering — fits Rosenpass's unicast request/response shape
/// exactly. Bypasses virtual interfaces (the WireGuard tunnel) so
/// rosenpass UDP doesn't try to flow through the very tunnel whose
/// PSK it's deriving.
private final class UDPClient: @unchecked Sendable {
    private let connection: NWConnection
    private let queue = DispatchQueue(label: "ai.cloakvpn.rosenpass.udp")

    init(host: String, port: UInt16) {
        let endpoint = NWEndpoint.hostPort(
            host: NWEndpoint.Host(host),
            port: NWEndpoint.Port(rawValue: port)!
        )
        let params = NWParameters.udp
        // Don't route over the utun interface our own NE created; that
        // would be a chicken/egg loop (the tunnel needs the PSK we're
        // trying to derive). `.other` covers utun and similar virtual
        // interfaces.
        params.prohibitedInterfaceTypes = [.other]
        self.connection = NWConnection(to: endpoint, using: params)
    }

    func connect() async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            var resumed = false
            connection.stateUpdateHandler = { state in
                guard !resumed else { return }
                switch state {
                case .ready:
                    resumed = true
                    cont.resume()
                case .failed(let err):
                    resumed = true
                    cont.resume(throwing: err)
                case .cancelled:
                    resumed = true
                    cont.resume(throwing: CancellationError())
                default:
                    break
                }
            }
            connection.start(queue: queue)
        }
    }

    func send(_ data: Data) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { err in
                if let err = err { cont.resume(throwing: err) }
                else { cont.resume() }
            })
        }
    }

    func receive(timeoutSeconds: TimeInterval) async throws -> Data {
        try await withThrowingTaskGroup(of: Data.self) { group in
            group.addTask {
                try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Data, Error>) in
                    self.connection.receiveMessage { content, _, _, err in
                        if let err = err { cont.resume(throwing: err); return }
                        cont.resume(returning: content ?? Data())
                    }
                }
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(timeoutSeconds * 1_000_000_000))
                throw RosenpassBridgeError.exceededMessageBudget
            }
            let result = try await group.next()!
            group.cancelAll()
            return result
        }
    }

    func close() {
        connection.cancel()
    }
}
