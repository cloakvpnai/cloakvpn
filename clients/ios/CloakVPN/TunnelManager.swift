import Combine
import CryptoKit
import Foundation
import NetworkExtension
import SwiftUI

@MainActor
final class TunnelManager: ObservableObject {
    enum Status: Equatable, CustomStringConvertible {
        case disconnected, connecting, connected, reasserting, disconnecting, invalid

        var color: Color {
            switch self {
            case .connected: return .green
            case .connecting, .reasserting: return .yellow
            case .disconnected: return .secondary
            case .disconnecting: return .orange
            case .invalid: return .red
            }
        }
        var description: String {
            switch self {
            case .disconnected: return "Disconnected"
            case .connecting: return "Connecting…"
            case .connected: return "Connected"
            case .reasserting: return "Reasserting"
            case .disconnecting: return "Disconnecting"
            case .invalid: return "Invalid"
            }
        }
    }

    @Published private(set) var status: Status = .disconnected
    @Published private(set) var config: CloakConfig?

    /// Currently-selected Cloak region. Driven by the in-app region
    /// picker (ContentView's flag strip). Persisted in UserDefaults so
    /// the user's last region survives app restarts. Nil before the
    /// first selection.
    @Published private(set) var selectedRegion: CloakRegion?
    private static let selectedRegionUserDefaultsKey = "selectedCloakRegionID"

    /// True while a region selection (provisioning + import) is in flight.
    /// Drives a spinner on the region's flag tile.
    @Published private(set) var regionSelectionInProgress: Bool = false

    /// User's actual public IP (their home / cellular IP, NOT the VPN
    /// endpoint). Fetched + cached when the VPN is OFF, so the
    /// "IP → VPN IP" display pattern works even when connected.
    /// Persists across launches via UserDefaults so the user sees their
    /// real IP immediately even if launching with VPN already up.
    @Published private(set) var publicIP: String?
    private static let publicIPUserDefaultsKey = "lastKnownPublicIP"

    /// The post-quantum key exchange driver. Owned by the main app
    /// (never the NE — see docs/IOS_PQC.md). Bridges PSKs into the NE
    /// via `sendProviderMessage` opcode 0x01.
    let rosenpass = RosenpassBridge()

    /// Base64 of the device's locally-generated rosenpass public key,
    /// once available. Published so the UI can render a fingerprint and
    /// expose a "Share my public key" affordance. nil during the brief
    /// window between app launch and `ensureLocalKeypair()` completion
    /// on first install. Stable across launches once persisted.
    @Published private(set) var localPublicKeyB64: String?

    private var manager: NETunnelProviderManager?
    private var statusObserver: NSObjectProtocol?

    /// Forwards nested-ObservableObject change notifications from
    /// `rosenpass` (a let property of this class) up to TunnelManager's
    /// own publisher chain. Without this, SwiftUI views observing
    /// `tunnel: TunnelManager` via @EnvironmentObject don't redraw when
    /// `tunnel.rosenpass.status` changes — they only redraw when one of
    /// TunnelManager's own @Published properties changes. Surfaced today
    /// 2026-04-27 as the "PQC: rotation N" UI text not updating until
    /// the user tapped Test PQC FFI (which mutated a @State and forced a
    /// re-render that then read the fresh rosenpass.status).
    private var rosenpassChangeForwarder: AnyCancellable?

    // MARK: - Layer 3 — auto-reconnect on detected wedge recovery
    //
    // When the NE calls `cancelTunnelWithError` from Layer 2, iOS marks
    // the tunnel as disconnected with our specific error attached
    // (domain="ai.cloakvpn.CloakTunnel", code=-1001). We watch for that
    // signature in the status-change notification and auto-fire a fresh
    // connect, bridging the gap between Layer 2 (NE self-kills) and full
    // transparent customer-facing recovery. Without this, the user has
    // to manually tap Connect after every wedge — better than the
    // pre-Layer-2 state (delete VPN profile in iOS Settings) but still
    // unshippable as the steady-state UX.

    /// Sliding window of auto-reconnect timestamps for rate limiting.
    /// Mirrors the Layer 2 self-kill rate limiter on the NE side: if
    /// recovery keeps failing (server outage, persistent state desync,
    /// etc.) we eventually stop trying and surface to the user.
    private var autoReconnectTimestamps: [Date] = []
    private static let maxAutoReconnectsPerWindow: Int = 3
    private static let autoReconnectWindowSec: TimeInterval = 300

    /// Brief delay between detecting the wedge-recovery disconnect and
    /// firing the new connect. Lets iOS finish tearing down the old NE
    /// process and releasing the utun before we ask for a new one.
    /// Empirically 1-2s is enough; below ~500ms iOS can refuse the new
    /// startVPNTunnel with "another connection is in progress".
    private static let autoReconnectDelaySec: TimeInterval = 1.5

    /// Specific error code we use when calling cancelTunnelWithError
    /// from the NE's Layer 2 wedge recovery. Matched against
    /// `connection.fetchLastDisconnectError` to distinguish recoverable
    /// wedges from user-initiated disconnects, server-side disconnects,
    /// network unavailability, etc. Must stay in sync with the constant
    /// in PacketTunnelProvider.swift's attemptWedgeRecovery.
    private static let ne_wedgeRecoveryErrorDomain = "ai.cloakvpn.CloakTunnel"
    private static let ne_wedgeRecoveryErrorCode = -1001

    init() {
        // Forward derived PSKs into the NE.
        rosenpass.onPSKDerived = { [weak self] psk in
            self?.pushPresharedKey(psk)
        }
        // Belt-and-suspenders: any legacy server-shipped client keys
        // sitting on disk from earlier builds get cleaned up on every
        // launch. New code path never reads them, but no point letting
        // stale files linger in the App Group container.
        AppGroupKeyStore.deleteLegacyClientKeys()

        // Re-publish rosenpass.objectWillChange events as our own. Without
        // this, SwiftUI views observing TunnelManager via @EnvironmentObject
        // don't see updates when rosenpass.status changes (because
        // `rosenpass` is a `let` property, not @Published — and SwiftUI
        // doesn't traverse nested ObservableObjects automatically).
        rosenpassChangeForwarder = rosenpass.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.objectWillChange.send()
            }

        // Restore last-selected region from UserDefaults so the picker
        // shows the user's chosen flag highlighted on app relaunch.
        if let savedID = UserDefaults.standard.string(forKey: Self.selectedRegionUserDefaultsKey) {
            selectedRegion = CloakRegion.byID(savedID)
        }

        // Restore last-known public IP (cached from a previous launch
        // while VPN was off) so the "IP" display has something to
        // show immediately on cold start, even if the user launches
        // the app with the VPN already connected.
        publicIP = UserDefaults.standard.string(forKey: Self.publicIPUserDefaultsKey)
    }

    /// Fetch the user's actual public IP from a third-party service and
    /// cache it. Call only when the VPN is OFF — when ON, the response
    /// is the VPN endpoint's IP, which would overwrite the user's real
    /// home IP cache. The status observer also calls this on transitions
    /// to .disconnected to refresh the cache for the next session.
    func refreshPublicIPIfNotConnected() async {
        guard status == .disconnected else {
            debugLog("refreshPublicIPIfNotConnected: VPN is up, skipping (would overwrite real-IP cache)")
            return
        }
        guard let url = URL(string: "https://api.ipify.org") else { return }
        do {
            var req = URLRequest(url: url)
            req.timeoutInterval = 6
            let (data, _) = try await URLSession.shared.data(for: req)
            if let ip = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
               !ip.isEmpty {
                self.publicIP = ip
                UserDefaults.standard.set(ip, forKey: Self.publicIPUserDefaultsKey)
                debugLog("refreshPublicIPIfNotConnected: cached \(ip)")
            }
        } catch {
            debugLog("refreshPublicIPIfNotConnected: fetch failed: \(error.localizedDescription)")
        }
    }

    /// Customer-facing region selection. Called when the user taps a
    /// flag in ContentView's quick-connect strip. Runs the provisioning
    /// API for that region (POST /api/v1/peers with our local public
    /// keys), imports the returned config, and persists the choice.
    /// The user can then tap the big Connect button to bring up the
    /// tunnel.
    ///
    /// Idempotent: tapping the same region multiple times is safe (the
    /// server's add-peer.sh derives peer name from the rosenpass pubkey
    /// hash, so we just re-register the same peer; existing peer entry
    /// in wg0.conf is preserved).
    func selectRegion(_ region: CloakRegion) async {
        guard !regionSelectionInProgress else { return }
        regionSelectionInProgress = true
        defer { regionSelectionInProgress = false }

        debugLog("selectRegion: \(region.id) — provisioning via \(region.serverURL)")
        do {
            try await provisionFromAPI(
                serverBase: region.serverURL,
                apiKey: CloakRegion.bundledAPIKey,
                peerName: nil  // server auto-derives from rp pubkey hash
            )
            selectedRegion = region
            UserDefaults.standard.set(region.id, forKey: Self.selectedRegionUserDefaultsKey)
            debugLog("selectRegion: \(region.id) configured successfully")
        } catch {
            debugLog("selectRegion: \(region.id) failed: \(error.localizedDescription)")
            // Surface to UI via the existing tunnel.config flow OR via
            // a dedicated lastError @Published. For now the caller
            // (ContentView) inspects regionSelectionInProgress only;
            // we throw nothing because async funcs without throws are
            // simpler from SwiftUI Task closures. Errors will surface
            // when the user taps Connect against a half-provisioned
            // state.
            // TODO: add @Published lastRegionError for inline error UI.
        }
    }

    /// Ensure this device has a locally-generated WireGuard keypair
    /// persisted in the App Group container. Idempotent — if a keypair
    /// already exists from a prior launch, no-op. Otherwise generates a
    /// fresh Curve25519 keypair via CryptoKit (instant on any iPhone)
    /// and persists. Used by the cloak-api-server provisioning flow,
    /// which sends only the public key to the server. The private key
    /// never leaves the device.
    func ensureLocalWGKeypair() async {
        if AppGroupKeyStore.hasLocalWGKeypair() { return }
        do {
            // CryptoKit's Curve25519.KeyAgreement.PrivateKey uses X25519
            // semantics with RFC 7748 clamping — wire-compatible with
            // WireGuard's `wg genkey`. rawRepresentation yields the 32
            // raw bytes; base64 yields the 44-char form WG expects.
            let privKey = Curve25519.KeyAgreement.PrivateKey()
            let secretB64 = privKey.rawRepresentation.base64EncodedString()
            let publicB64 = privKey.publicKey.rawRepresentation.base64EncodedString()
            try AppGroupKeyStore.saveLocalWGKeypair(secretB64: secretB64, publicB64: publicB64)
            debugLog("ensureLocalWGKeypair: generated & persisted (pub=\(publicB64.prefix(16))…)")
        } catch {
            debugLog("ensureLocalWGKeypair: persistence failed: \(error)")
        }
    }

    /// Ensure this device has a locally-generated rosenpass keypair
    /// persisted in the App Group container. Idempotent — if a keypair
    /// already exists from a prior launch, just publishes the cached
    /// public key. Otherwise generates a fresh one via the FFI's
    /// `generateStaticKeypair()` (~50-200ms on iPhone 13 Pro Max,
    /// imperceptible to the user) and persists.
    ///
    /// Should be called on app launch, ideally from the SwiftUI
    /// `.task { await tunnel.ensureLocalKeypair() }` modifier on the
    /// root view. Safe to call multiple times.
    func ensureLocalKeypair() async {
        // Fast path — keypair already on disk.
        if AppGroupKeyStore.hasLocalKeypair() {
            do {
                let kp = try AppGroupKeyStore.loadLocalKeypair()
                self.localPublicKeyB64 = kp.publicB64
            } catch {
                debugLog("ensureLocalKeypair: load failed despite has=true, regenerating: \(error)")
                AppGroupKeyStore.clearLocalKeypair()
                await generateAndPersistLocalKeypair()
            }
            return
        }
        await generateAndPersistLocalKeypair()
    }

    /// Generate a fresh rosenpass keypair via the FFI and persist to the
    /// App Group container. Heavy lifting (McEliece keygen, ~1-3 MB
    /// working set, hundreds of ms) is done off the MainActor.
    private func generateAndPersistLocalKeypair() async {
        do {
            let kp = try await Task.detached(priority: .userInitiated) {
                try generateStaticKeypair()
            }.value
            let secretB64 = kp.secretKey.base64EncodedString()
            let publicB64 = kp.publicKey.base64EncodedString()
            try AppGroupKeyStore.saveLocalKeypair(secretB64: secretB64, publicB64: publicB64)
            self.localPublicKeyB64 = publicB64
            debugLog("ensureLocalKeypair: generated & persisted (pk=\(kp.publicKey.count) B, sk=\(kp.secretKey.count) B)")
        } catch {
            debugLog("ensureLocalKeypair: generation failed: \(error)")
            // Don't crash — the UI will see localPublicKeyB64 stay nil
            // and can show a "PQC identity unavailable" state.
        }
    }

    /// Load existing VPN configurations from the system preferences.
    func load() async {
        do {
            let managers = try await NETunnelProviderManager.loadAllFromPreferences()
            manager = managers.first
            if let m = manager {
                updateStatus(m.connection.status)
                observeStatus(m.connection)
                if let cfgDict = (m.protocolConfiguration as? NETunnelProviderProtocol)?.providerConfiguration,
                   let cfg = try? CloakConfig(dict: cfgDict) {
                    config = cfg
                }
            }
        } catch {
            print("TunnelManager.load error: \(error)")
        }
    }

    /// Persist a new config and attach it to an NETunnelProviderManager.
    ///
    /// New (privacy-fixed) data flow:
    ///   - WG fields + small PQ flags → `providerConfiguration` (small,
    ///     persisted by iOS, readable by both processes).
    ///   - Server's rosenpass public key → App Group container via
    ///     `AppGroupKeyStore.saveServerPublicKey`. ~700 KB on disk.
    ///   - Any `client_secret_key_b64` / `client_public_key_b64` fields
    ///     in the imported config block are IGNORED. The device's local
    ///     keypair (already generated by `ensureLocalKeypair`) is the
    ///     only client-side identity that ever participates in handshakes.
    ///     Server-shipped client keys break PQC privacy — see
    ///     docs/IOS_PQC.md "Open items" §22.
    ///
    /// If writing the server pubkey to the App Group fails we abort the
    /// whole import — saving an `NETunnelProviderManager` without the
    /// pubkey on disk would put the user in a state where Connect appears
    /// to work but PQC silently never engages. Failing loud is better.
    func importConfig(_ text: String) throws {
        var parsed = try ConfigParser.parse(text)

        // If the config came from cloak-api-server (which omits
        // private_key — server doesn't have ours), fill it in from
        // the locally-stored WG keypair. provisionFromAPI ensures
        // ensureLocalWGKeypair has run before getting here. Legacy
        // configs that DO carry a private_key keep their existing
        // value untouched.
        if parsed.wgPrivateKey.isEmpty {
            do {
                let wg = try AppGroupKeyStore.loadLocalWGKeypair()
                parsed.wgPrivateKey = wg.secretB64
                debugLog("importConfig: filled in wgPrivateKey from local WG keypair")
            } catch {
                throw TunnelError.parse(
                    "config has no private_key and no local WG keypair available: \(error.localizedDescription)"
                )
            }
        }

        // Stash just the server's pubkey (the only PQC blob we still
        // accept from the config). If this fails, abort before we touch
        // the system VPN preferences — leaves the device in a clean state.
        if parsed.pqEnabled {
            guard !parsed.serverRPPublicKeyB64.isEmpty else {
                throw TunnelError.parse("PQ enabled but server_public_key_b64 is empty")
            }
            try AppGroupKeyStore.saveServerPublicKey(parsed.serverRPPublicKeyB64)
        } else {
            // Re-importing a non-PQ config; clear stale server pubkey so
            // a future PQ config doesn't silently inherit a wrong one.
            // Local keypair is preserved — the device's identity is
            // stable across config re-imports.
            AppGroupKeyStore.clearServerPublicKey()
        }

        let manager = self.manager ?? NETunnelProviderManager()

        let proto = NETunnelProviderProtocol()
        // MUST match the CloakTunnel target's PRODUCT_BUNDLE_IDENTIFIER
        // exactly. iOS uses this string to locate the NetworkExtension
        // binary to launch when startVPNTunnel() is called. A mismatch
        // here results in iOS silently doing nothing (or briefly
        // transitioning to Connecting then snapping back to Disconnected
        // with no logs), which is one of the most painful failure modes
        // in NE-land — there's no error surfaced to the host app.
        proto.providerBundleIdentifier = "ai.cloakvpn.CloakVPN.CloakTunnel"
        proto.serverAddress = parsed.endpoint
        // .asDictionary deliberately excludes the three big Rosenpass keys
        // — see ConfigParser.swift. They're already on disk in the App
        // Group container by the time we reach this line.
        proto.providerConfiguration = parsed.asDictionary

        // Secrets (WireGuard private key) currently flow through
        // providerConfiguration plaintext. TODO: move to Keychain via the
        // App Group's `kSecAttrAccessGroup`. Tracked separately — same
        // posture Mullvad shipped with for months. Not blocking the
        // first PQC smoke test.
        proto.passwordReference = nil

        // Full-tunnel + kill-switch. Required for the tunnel to actually
        // CARRY app traffic — with includeAllNetworks=false, iOS path-eval
        // routes Safari/Chrome over WiFi instead of utun, and the tunnel
        // exists but is bypassed (this is the "ifconfig.me shows ISP IP"
        // leak we confirmed 2026-04-27 ~01:30 HST: test-ipv6.com showed
        // <USER_NAT_IP> — the user's home NAT IP — while our app was
        // active).
        //
        // The earlier "no internet with includeAllNetworks=true" symptom
        // was misleading — we were testing with ICMP ping, which iOS
        // doesn't pass through tunnels reliably. Real TCP/UDP traffic
        // (Safari, Chrome) works fine through full-tunnel mode once
        // iOS is forced to use utun via includeAllNetworks=true.
        //
        // First activation per signing identity prompts the user with
        // "Cloak VPN would like to monitor all your network traffic" —
        // accept once and iOS retains consent.
        proto.includeAllNetworks = true

        // Match the official WireGuard iOS app's minimal approach: set
        // ONLY includeAllNetworks=true and let iOS use sensible
        // defaults for the other exclusion flags. Manual overrides
        // (enforceRoutes, excludeLocalNetworks, etc.) didn't fix the
        // 2026-04-26 traffic-not-flowing bug, and may have made things
        // worse. Stripping back to the upstream minimum.

        manager.protocolConfiguration = proto
        manager.localizedDescription = "Cloak VPN"
        manager.isEnabled = true

        Task {
            do {
                try await manager.saveToPreferences()
                try await manager.loadFromPreferences()
                self.manager = manager
                self.config = parsed
                self.observeStatus(manager.connection)
            } catch {
                print("importConfig save error: \(error)")
            }
        }
    }

    /// "Add Region" — provision this iPhone as a peer against a Cloak
    /// region by POSTing both locally-generated public keys to the
    /// region's cloak-api-server. The server returns a complete client
    /// config block (without private_key — we already have the WG
    /// secret locally). Auto-imports on success.
    ///
    /// Privacy: only public keys cross the wire. The iPhone's WG and
    /// rosenpass private keys never leave the device.
    ///
    /// - Parameters:
    ///   - serverBase: full base URL of the API, e.g.
    ///     "http://5.78.203.171:8443" (production should be HTTPS via
    ///     the operator's nginx + Let's Encrypt).
    ///   - apiKey: shared-secret token configured at
    ///     /etc/cloak/api-token on the server. The operator distributes
    ///     this to authorized users out-of-band.
    ///   - peerName: optional human-readable peer name. If absent, the
    ///     server auto-generates one from a hash of the rosenpass pubkey.
    func provisionFromAPI(
        serverBase: String,
        apiKey: String,
        peerName: String? = nil
    ) async throws {
        // 1. Make sure we have both keypairs locally before talking to
        // the server. ensureLocalKeypair handles rosenpass; the new
        // ensureLocalWGKeypair handles WG. Both are idempotent.
        await ensureLocalKeypair()
        await ensureLocalWGKeypair()

        let rpKeys = try AppGroupKeyStore.loadLocalKeypair()
        let wgKeys = try AppGroupKeyStore.loadLocalWGKeypair()

        // 2. Build the request.
        var url = serverBase.trimmingCharacters(in: .whitespacesAndNewlines)
        if url.hasSuffix("/") { url.removeLast() }
        guard let endpoint = URL(string: "\(url)/api/v1/peers") else {
            throw TunnelError.parse("invalid serverBase URL: \(serverBase)")
        }

        var body: [String: Any] = [
            "wg_pubkey_b64": wgKeys.publicB64,
            "rosenpass_pubkey_b64": rpKeys.publicB64,
        ]
        if let n = peerName, !n.isEmpty {
            body["peer_name"] = n
        }
        let bodyData = try JSONSerialization.data(withJSONObject: body)

        var req = URLRequest(url: endpoint)
        req.httpMethod = "POST"
        req.setValue(apiKey, forHTTPHeaderField: "X-Cloak-API-Key")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = bodyData
        // Provisioning involves running add-peer.sh + restarting
        // cloak-rosenpass.service on the server — give it some
        // headroom but cap to keep the UI responsive.
        req.timeoutInterval = 30

        debugLog("provisionFromAPI: POST \(endpoint.absoluteString) (wg_pub=\(wgKeys.publicB64.prefix(8))…, rp_pub=\(rpKeys.publicB64.prefix(12))…)")

        // 3. Hit the API.
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse else {
            throw TunnelError.parse("non-HTTP response from server")
        }
        if http.statusCode != 200 {
            let msg = String(data: data, encoding: .utf8) ?? "<binary>"
            throw TunnelError.parse("API returned HTTP \(http.statusCode): \(msg.prefix(200))")
        }

        guard let configText = String(data: data, encoding: .utf8) else {
            throw TunnelError.parse("API response not valid UTF-8")
        }

        debugLog("provisionFromAPI: got config (\(configText.count) chars), importing…")

        // 4. Import the returned config. The config block omits
        // private_key (the server doesn't have ours and doesn't need
        // to send it back); the parser tolerates that and importConfig
        // picks up the locally-stored WG private key when wgPrivateKey
        // is empty.
        try importConfig(configText)
    }

    func connect() async throws {
        debugLog("connect() called, current status=\(status)")
        guard let m = manager else {
            debugLog("connect() FAILING: manager is nil")
            throw TunnelError.noConfig
        }
        debugLog("connect(): starting VPN tunnel via NETunnelProviderManager")
        try m.connection.startVPNTunnel()

        // Rotation loop now runs IN the NE (task #17). The host-app
        // RosenpassBridge is repurposed: instead of running the loop, it
        // polls the App Group UserDefaults that the NE-side
        // RosenpassDriver writes to, and updates its `status` for the
        // existing ContentView UI to consume. Net effect: the user keeps
        // seeing "PQC: N rotations ✓" in the app, but the actual key
        // exchange happens in the NE which iOS never suspends.
        guard let cfg = config, cfg.pqEnabled else { return }
        rosenpass.startStatusPolling()
    }

    /// Async wrapper around NETunnelProviderSession.sendProviderMessage.
    /// Hops to the MainActor to make the call (NE session methods are
    /// MainActor-bound) and bridges the completion-handler API to async/
    /// await. Returns the raw response bytes (or empty Data if the NE
    /// returned nil — caller decides what nil/empty means).
    nonisolated private static func sendProviderMessageAsync(
        _ payload: Data,
        manager: NETunnelProviderManager?
    ) async throws -> Data {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Data, Error>) in
            Task { @MainActor in
                guard let session = manager?.connection as? NETunnelProviderSession else {
                    cont.resume(throwing: TunnelError.noConfig)
                    return
                }
                do {
                    try session.sendProviderMessage(payload) { response in
                        cont.resume(returning: response ?? Data())
                    }
                } catch {
                    cont.resume(throwing: error)
                }
            }
        }
    }

    /// Layer 4 — last-resort manual recovery escape hatch.
    ///
    /// Tears down the entire NETunnelProviderManager and recreates it
    /// using the cached CloakConfig. Equivalent to "Settings → VPN →
    /// Delete + reopen app + re-import" in one tap, except iOS will
    /// still prompt the user once for permission to add the new VPN
    /// configuration (Apple's hard requirement; not a UX choice we can
    /// bypass). Used when Layers 1-3 of wedge auto-recovery have all
    /// failed — typically because Layer 3's rate limit (3 reconnects /
    /// 5min) was hit while the underlying issue keeps recurring, and
    /// the only remaining option is to fully reset iOS's VPN state.
    ///
    /// Sequence:
    ///   1. Stop the rosenpass loop and unwire sendNE.
    ///   2. Stop any running tunnel cleanly.
    ///   3. removeFromPreferences (deletes the iOS VPN profile).
    ///   4. Wait briefly for iOS to settle.
    ///   5. Build a fresh NETunnelProviderManager with the same config.
    ///   6. saveToPreferences (triggers iOS permission prompt — user
    ///      must tap Allow once).
    ///   7. observeStatus + connect.
    ///
    /// Throws if there's no cached config to recreate from (user has
    /// never imported one). Otherwise propagates errors from
    /// removeFromPreferences / saveToPreferences / connect — the UI
    /// should surface these in an alert.
    func resetTunnel() async throws {
        debugLog("resetTunnel: starting")

        guard let cfg = self.config else {
            throw TunnelError.noConfig
        }

        // 1. Stop rosenpass loop and clear NE relay closure.
        rosenpass.stop()
        rosenpass.sendNE = nil

        // 2 + 3. Stop existing tunnel and remove the manager from prefs.
        if let m = manager {
            let st = m.connection.status
            if st == .connected || st == .connecting || st == .reasserting {
                debugLog("resetTunnel: stopping active tunnel")
                m.connection.stopVPNTunnel()
                // Brief wait for the stop to propagate before removeFromPreferences
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
            debugLog("resetTunnel: removeFromPreferences")
            try await m.removeFromPreferences()
        }
        self.manager = nil

        // 4. Settle delay. Without this, the subsequent
        // saveToPreferences sometimes races with iOS's profile-deletion
        // bookkeeping and either fails or silently doesn't show the
        // permission prompt.
        try? await Task.sleep(nanoseconds: 1_000_000_000)

        // 5. Rebuild a fresh manager from the cached config. Mirrors
        // the inner logic of importConfig but skips the parse step
        // since we already have a CloakConfig in self.config.
        let manager = NETunnelProviderManager()
        let proto = NETunnelProviderProtocol()
        proto.providerBundleIdentifier = "ai.cloakvpn.CloakVPN.CloakTunnel"
        proto.serverAddress = cfg.endpoint
        proto.providerConfiguration = cfg.asDictionary
        proto.passwordReference = nil
        proto.includeAllNetworks = true
        manager.protocolConfiguration = proto
        manager.localizedDescription = "Cloak VPN"
        manager.isEnabled = true

        // 6. Save (triggers iOS permission prompt the first time after
        // a removeFromPreferences). User must tap "Allow" — without
        // user action this hangs.
        debugLog("resetTunnel: saveToPreferences (iOS may prompt for permission)")
        try await manager.saveToPreferences()
        try await manager.loadFromPreferences()
        self.manager = manager

        // 7. Wire up status observation + connect.
        self.observeStatus(manager.connection)
        debugLog("resetTunnel: profile recreated, calling connect()")
        try await connect()
    }

    func disconnect() async throws {
        debugLog("disconnect() called, current status=\(status)")
        rosenpass.stop()
        // Drop the NE relay closure so a stale capture can't fire
        // sendProviderMessage after the session goes away.
        rosenpass.sendNE = nil
        guard let m = manager else {
            debugLog("disconnect(): manager is nil, nothing to stop")
            return
        }
        debugLog("disconnect(): stopping VPN tunnel")
        m.connection.stopVPNTunnel()
    }

    // MARK: - PSK delivery to the NE

    /// Wire format: opcode (1 byte) + payload.
    /// 0x01 = SET_PSK, payload = 32-byte preshared key.
    /// (Mirrors PacketTunnelProvider.handleAppMessage on the receiving side.)
    private static let opcodeSetPsk: UInt8 = 0x01

    /// Push a Rosenpass-derived PSK to the running PacketTunnelProvider
    /// extension via `sendProviderMessage`. Best-effort — if the tunnel
    /// isn't up yet, the message is dropped and we'll retry on the next
    /// rotation tick.
    private func pushPresharedKey(_ psk: Data) {
        guard let session = manager?.connection as? NETunnelProviderSession else {
            print("pushPresharedKey: tunnel not connected, dropping (will retry on next rotation)")
            return
        }
        guard psk.count == 32 else {
            print("pushPresharedKey: refusing to push PSK of length \(psk.count)")
            return
        }
        var payload = Data()
        payload.append(Self.opcodeSetPsk)
        payload.append(psk)

        do {
            try session.sendProviderMessage(payload) { response in
                if let response = response, let code = response.first {
                    if code == 0 {
                        print("PSK accepted by NE")
                    } else {
                        print("PSK rejected by NE, code=0x\(String(code, radix: 16))")
                    }
                } else {
                    print("PSK push: no response from NE")
                }
            }
        } catch {
            print("pushPresharedKey send error: \(error)")
        }
    }

    // MARK: - Status observation

    private func observeStatus(_ conn: NEVPNConnection) {
        if let o = statusObserver { NotificationCenter.default.removeObserver(o) }
        statusObserver = NotificationCenter.default.addObserver(
            forName: .NEVPNStatusDidChange, object: conn, queue: .main
        ) { [weak self] note in
            // Swift 6 strict concurrency: NotificationCenter's callback is
            // @Sendable, so we can't capture `self` and just dereference it
            // inside a Task. Instead pull the only thing we need (the new
            // status enum, which IS Sendable) out of the notification on the
            // notification queue, THEN hop to the main actor.
            guard let newStatus = (note.object as? NEVPNConnection)?.status else { return }
            Task { @MainActor [weak self] in
                self?.updateStatus(newStatus)
            }
        }
    }

    private func updateStatus(_ s: NEVPNStatus) {
        let old = status
        switch s {
        case .connected: status = .connected
        case .connecting: status = .connecting
        case .disconnected: status = .disconnected
        case .disconnecting: status = .disconnecting
        case .reasserting: status = .reasserting
        case .invalid: status = .invalid
        @unknown default: status = .invalid
        }
        debugLog("status change: \(old) → \(status) (raw NEVPNStatus=\(s.rawValue))")

        // Refresh the user's real public IP cache on transitions to
        // .disconnected. With the VPN off, the next api.ipify.org
        // response is the user's home/cellular IP — exactly what we
        // want to display in the "IP → VPN IP" panel for next session.
        if status == .disconnected, old != .disconnected {
            Task { [weak self] in
                await self?.refreshPublicIPIfNotConnected()
            }
        }

        // Layer 3: detect wedge-recovery transitions and auto-reconnect.
        // We only attempt the auto-reconnect when the previous state was
        // an "active" tunnel state (.connected, .connecting, .reasserting)
        // because that filters out two cases:
        //   1. Already-disconnected -> still-disconnected idle transitions.
        //   2. App-launch initial state read where status starts as
        //      .disconnected and we observe it.
        // Within those active states, we still verify the actual disconnect
        // error matches our wedge-recovery signature before reconnecting.
        if status == .disconnected,
           old == .connected || old == .connecting || old == .reasserting {
            checkForWedgeRecoveryAutoReconnect()
        }
    }

    /// Inspect the connection's last disconnect error. If it matches our
    /// wedge-recovery error signature (domain=ai.cloakvpn.CloakTunnel,
    /// code=-1001), schedule an auto-reconnect. Otherwise no-op.
    ///
    /// `fetchLastDisconnectError` is callback-style; we bridge to the
    /// MainActor for the actual auto-reconnect call.
    private func checkForWedgeRecoveryAutoReconnect() {
        guard let conn = manager?.connection else {
            debugLog("checkForWedgeRecoveryAutoReconnect: no connection — skipping")
            return
        }
        conn.fetchLastDisconnectError { [weak self] error in
            // Hop to MainActor for state mutations and connect() call.
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                guard let nsErr = error as NSError?,
                      nsErr.domain == Self.ne_wedgeRecoveryErrorDomain,
                      nsErr.code == Self.ne_wedgeRecoveryErrorCode else {
                    self.debugLog("checkForWedgeRecoveryAutoReconnect: not a wedge-recovery disconnect (err=\(String(describing: error))); skipping auto-reconnect")
                    return
                }
                self.attemptAutoReconnect(reason: nsErr.localizedDescription)
            }
        }
    }

    /// Schedule an auto-reconnect after a brief settle delay, with rate
    /// limiting to avoid pathological reconnect loops if recovery itself
    /// keeps failing (e.g. server is genuinely down — after maxAutoReconnects
    /// in window, we stop trying and require manual user intervention).
    private func attemptAutoReconnect(reason: String) {
        let now = Date()
        // Drop entries older than the rolling window
        autoReconnectTimestamps.removeAll { now.timeIntervalSince($0) > Self.autoReconnectWindowSec }

        if autoReconnectTimestamps.count >= Self.maxAutoReconnectsPerWindow {
            debugLog("autoReconnect: rate-limited (\(autoReconnectTimestamps.count) in last \(Int(Self.autoReconnectWindowSec))s) — manual reconnect required")
            return
        }

        autoReconnectTimestamps.append(now)
        let attemptNumber = autoReconnectTimestamps.count
        debugLog("autoReconnect: scheduling (#\(attemptNumber) in window) after \(Self.autoReconnectDelaySec)s delay; reason=\(reason)")

        // Tear down stale rosenpass loop state from before the wedge —
        // the NE that the loop was talking to is gone. The new connect()
        // call below re-spins it up cleanly with sendNE rebound to the
        // freshly spawned NE process.
        rosenpass.stop()
        rosenpass.sendNE = nil

        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.autoReconnectDelaySec * 1_000_000_000))
            guard let self = self else { return }
            do {
                try await self.connect()
                self.debugLog("autoReconnect: connect() initiated successfully (attempt #\(attemptNumber))")
            } catch {
                self.debugLog("autoReconnect: connect() failed: \(error)")
            }
        }
    }

    /// Debug-only logging. Stripped from release builds entirely so the
    /// `[TunnelManager]` prefix doesn't show up in production Console.app
    /// captures. We added these during the 2026-04-25 PQC smoke-test
    /// debugging marathon — keeping them around behind `#if DEBUG` because
    /// the next time iOS NetworkExtension state goes weird, having them
    /// pre-wired saves an hour of "wait, where's the connect path going?"
    private func debugLog(_ message: @autoclosure () -> String) {
        #if DEBUG
        print("[TunnelManager] \(message())")
        #endif
    }

    // MARK: - Local pubkey export (for server-side registration)

    /// Short hex fingerprint of a base64 rosenpass public key — first
    /// 16 hex chars (8 bytes) of SHA-256 over the base64 string. Used
    /// for the UI's "your PQC identity" display and as part of the
    /// share filename so the user can recognize which device they
    /// AirDropped from.
    ///
    /// Note: this fingerprints the base64 STRING, not the raw key
    /// bytes. Either is fine for human-recognition purposes; the
    /// string-based hash matches what they'll see in a rendered
    /// config or copy-paste view.
    static func pubkeyFingerprint(_ b64: String) -> String {
        let hash = SHA256.hash(data: Data(b64.utf8))
        return hash.prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    /// Computed convenience for the UI — the short fingerprint of the
    /// currently-loaded local pubkey, or nil if generation hasn't
    /// completed yet. SwiftUI re-evaluates this whenever
    /// `localPublicKeyB64` changes.
    var localPubkeyFingerprint: String? {
        localPublicKeyB64.map(Self.pubkeyFingerprint)
    }

    /// Write the local pubkey (base64) to a tmp-dir file with a
    /// recognizable filename including the fingerprint, and return
    /// the URL for SwiftUI's ShareLink. Caller is responsible for
    /// not retaining the returned URL after the share sheet closes —
    /// the file lives in the system's autocleaned tmp directory.
    ///
    /// File contents are exactly the base64 of the rosenpass public
    /// key, no extra framing. The server's `add-peer.sh` (when
    /// invoked with this file as its second argument) base64-decodes
    /// and writes the binary to /etc/rosenpass/<peer>.rosenpass-public.
    func makeLocalPubkeyShareFile() throws -> URL {
        guard let pubB64 = self.localPublicKeyB64 else {
            throw TunnelError.parse("local rosenpass keypair not yet generated")
        }
        let fp = Self.pubkeyFingerprint(pubB64)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("cloakvpn-pubkey-\(fp).b64")
        try pubB64.write(to: url, atomically: true, encoding: .utf8)
        return url
    }
}

// `TunnelError` lives in ConfigParser.swift so the NetworkExtension
// target (which compiles ConfigParser.swift but NOT this file) can see
// it too. Don't redeclare it here.
