import Combine
import CryptoKit
import Foundation
import os.log
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

    /// Currently-selected Cloak region. Driven by the in-app region
    /// picker (ContentView's flag strip). Persisted in UserDefaults so
    /// the user's last region survives app restarts. Nil before the
    /// first selection.
    @Published private(set) var selectedRegion: CloakRegion?
    private static let selectedRegionUserDefaultsKey = "selectedCloakRegionID"

    /// True while a region selection (provisioning + import) is in flight.
    /// Drives a spinner on the region's flag tile.
    @Published private(set) var regionSelectionInProgress: Bool = false

    /// Last error from a region-selection attempt. Surface via an alert
    /// or status banner so the user actually sees provisioning
    /// failures instead of silent no-op (which is what users observed
    /// when an early build's selectRegion swallowed errors).
    @Published var lastRegionError: String?

    /// True once the running tunnel has completed its CNSA 2.0 handshake.
    /// NetworkExtension's "connected" only means the interface exists; this is
    /// what the UI uses before it claims the post-quantum tunnel is active.
    @Published private(set) var handshakeVerified = false
    private var handshakeVerifyTask: Task<Void, Never>?

    private static let provisionedConfigsCacheKey = "provisionedRegionConfigsV1"

    /// User's actual public IP (their home / cellular IP, NOT the VPN
    /// endpoint). Fetched + cached when the VPN is OFF, so the
    /// "IP → VPN IP" display pattern works even when connected.
    /// Persists across launches via UserDefaults so the user sees their
    /// real IP immediately even if launching with VPN already up.
    @Published private(set) var publicIP: String?
    private static let publicIPUserDefaultsKey = "lastKnownPublicIP"

    // MARK: - Account (no-account billing model)
    //
    // The customer's only credential is the account number from
    // latticevpn.ai. It authorizes every call to the central account
    // API; there is no email/password. See docs/BILLING_INTEGRATION.md.

    /// The stored account number in canonical hyphenated form, or nil
    /// when the customer has not signed in. Restored from the App Group
    /// container on launch.
    @Published private(set) var accountNumber: String?

    /// Subscription state last fetched from the account API — tier,
    /// device limit/count, paid-through date. nil until the first
    /// fetchAccount lands.
    @Published private(set) var accountStatus: AccountStatus?
    @Published private(set) var accountStatusError: String?
    @Published private(set) var accountRefreshBusy = false
    @Published private(set) var accountStatusVerifiedAt: Date?

    /// True while a sign-in (account-number validation) is in flight.
    @Published private(set) var signInBusy: Bool = false

    /// True when the API rejected the stored account number and it could not
    /// be recovered automatically. The region-error alert then offers
    /// "Sign Out" so the customer reaches Restore Purchases / number entry.
    @Published private(set) var accountNeedsReentry: Bool = false

    /// In-flight silent account-number recovery. Concurrent callers (launch
    /// refresh, warm-up, a region tap, the Account sheet) all await this one
    /// task instead of each redeeming the entitlement separately.
    private var accountRecoveryTask: Task<String?, Never>?

    /// When the last recovery attempt FAILED. Blocks retries for 60 s so a
    /// persistent failure can never turn into a redeem loop.
    private var lastFailedAccountRecovery: Date?

    /// True once a validated account number is stored.
    var isSignedIn: Bool { !(accountNumber ?? "").isEmpty }

    /// Stateless client for the central account + provisioning API.
    private let accountClient = LatticeAccountClient()

    private var manager: NETunnelProviderManager?
    private var statusObserver: NSObjectProtocol?

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

    // The packet tunnel extension has the same bundle ID on iOS and macOS.
    private static let providerBundleIdentifier = "ai.cloakvpn.CloakVPN.CloakTunnel"

    init() {
        // Belt-and-suspenders: any legacy server-shipped client keys
        // sitting on disk from earlier builds get cleaned up on every
        // launch. New code path never reads them, but no point letting
        // stale files linger in the App Group container.
        AppGroupKeyStore.eraseLegacyFiles()

        // Restore the customer's account number so the app knows on
        // launch whether to show the sign-in cover or the main UI.
        accountNumber = AppGroupKeyStore.loadAccountNumber()

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

        // Configurations cached by a WireGuard-based version of the app are no use to this one.
        UserDefaults.standard.removeObject(forKey: Self.provisionedConfigsCacheKey)
    }

    // MARK: - Account sign-in / sign-out

    /// Validate `number` against the account API and, on success, store
    /// it as the device's credential. Returns nil on success, or a
    /// customer-facing error message to show in the entry screen.
    func signIn(_ number: String) async -> String? {
        let formatted = LatticeAPI.format(number)
        signInBusy = true
        defer { signInBusy = false }
        do {
            let status = try await accountClient.fetchAccount(accountNumber: formatted)
            try? AppGroupKeyStore.saveAccountNumber(formatted)
            accountNumber = formatted
            accountStatus = status
            accountStatusError = nil
            accountStatusVerifiedAt = Date()
            accountNeedsReentry = false
            SubscriptionInfo.recordTier(status.tier)
            return nil
        } catch let e as AccountError {
            return e.userMessage
        } catch {
            return error.localizedDescription
        }
    }

    /// Re-fetch status without presenting stale data as a verified result.
    /// Mac validation disables recovery so this GET cannot mint a new credential.
    func refreshAccountStatus(allowRecovery: Bool = true) async {
        guard let number = accountNumber, !number.isEmpty, !accountRefreshBusy else { return }
        accountRefreshBusy = true
        accountStatusError = nil
        defer { accountRefreshBusy = false }
        do {
            let status = try await accountClient.fetchAccount(accountNumber: number)
            guard accountNumber == number else { return }
            accountStatus = status
            accountStatusVerifiedAt = Date()
            SubscriptionInfo.recordTier(status.tier)
        } catch AccountError.unauthorized(let serverKeepsPreviousNumbers) {
            guard accountNumber == number else { return }
            accountStatusVerifiedAt = nil
            accountStatusError = AccountError.unauthorized(serverKeepsPreviousNumbers: serverKeepsPreviousNumbers).userMessage
            if allowRecovery && serverKeepsPreviousNumbers {
                _ = await recoverAccountNumberFromAppStore()
            }
        } catch let error as AccountError {
            guard accountNumber == number else { return }
            accountStatusVerifiedAt = nil
            accountStatusError = error.userMessage
        } catch {
            guard accountNumber == number else { return }
            accountStatusVerifiedAt = nil
            accountStatusError = "Couldn't verify your subscription. Please refresh and try again."
        }
    }

    /// Recover from an account number the API no longer recognizes, without
    /// involving the customer: if this device holds a verified App Store
    /// subscription, redeem it for a fresh number (no Apple ID prompt), adopt
    /// it, and return it. Returns nil when there is nothing to recover from
    /// (web/Stripe customers) or a FAILED attempt ran in the last 60 seconds.
    /// Concurrent callers share one in-flight attempt.
    ///
    /// Safe because the server keeps previously issued numbers valid on a
    /// restore (account_number_aliases), so this does not sign out the
    /// customer's other devices. Deploy that server change BEFORE shipping
    /// this build.
    private func recoverAccountNumberFromAppStore() async -> String? {
        if let inFlight = accountRecoveryTask {
            return await inFlight.value
        }
        if let last = lastFailedAccountRecovery, Date().timeIntervalSince(last) < 60 {
            debugLog("accountRecovery: skipped (last attempt failed \(Int(Date().timeIntervalSince(last)))s ago)")
            return nil
        }
        let task = Task { @MainActor [weak self] () -> String? in
            await self?.performAccountRecovery()
        }
        accountRecoveryTask = task
        let result = await task.value
        accountRecoveryTask = nil
        if result == nil { lastFailedAccountRecovery = Date() }
        return result
    }

    /// The body of recoverAccountNumberFromAppStore. Call only through it.
    private func performAccountRecovery() async -> String? {
        // The number that failed. If it changes while the redeem is in
        // flight (sign-out, or sign-out + sign-in with a typed number), the
        // customer has acted: never overwrite their choice.
        guard let failing = accountNumber else { return nil }
        let fresh: String
        do {
            guard let n = try await StoreManager.redeemCurrentEntitlement(), !n.isEmpty else {
                debugLog("accountRecovery: no App Store entitlement on this device")
                return nil
            }
            fresh = n
        } catch {
            debugLog("accountRecovery: redeem failed: \(error.localizedDescription)")
            return nil
        }
        guard accountNumber == failing else {
            debugLog("accountRecovery: account changed during redeem — discarding recovered number")
            return nil
        }
        let formatted = LatticeAPI.format(fresh)
        do {
            try AppGroupKeyStore.saveAccountNumber(formatted)
        } catch {
            // Still usable for this session; it will be re-recovered on the
            // next launch if the write keeps failing.
            debugLog("accountRecovery: could not persist recovered number: \(error)")
        }
        accountNumber = formatted
        accountNeedsReentry = false
        debugLog("accountRecovery: adopted a recovered account number")
        do {
            let status = try await accountClient.fetchAccount(accountNumber: formatted)
            accountStatus = status
            accountStatusError = nil
            accountStatusVerifiedAt = Date()
            SubscriptionInfo.recordTier(status.tier)
        } catch let error as AccountError {
            accountStatusVerifiedAt = nil
            accountStatusError = error.userMessage
        } catch {
            accountStatusVerifiedAt = nil
            accountStatusError = "Couldn't verify your subscription. Please refresh and try again."
        }
        return formatted
    }

    /// Forget the account number and all per-region tunnel state. Drops
    /// the tunnel first if it is up — the credential is gone, so it must
    /// not keep running.
    func signOut() async {
        if status == .connected || status == .connecting || status == .reasserting {
            try? await disconnect()
        }
        // Give up this device's CNSA 2.0 identity: the server revokes its certificate and
        // the key is erased, so a signed-out device cannot keep using the service.
        if let number = accountNumber, !number.isEmpty {
            await CNSA2Enroller.shared.forget(accountNumber: number)
        }
        AppGroupKeyStore.clearAccountNumber()
        accountNumber = nil
        accountStatus = nil
        accountStatusError = nil
        accountStatusVerifiedAt = nil
        accountNeedsReentry = false
    }

    /// Fetch the user's actual public IP from a third-party service.
    /// Always tries the fetch (regardless of VPN state) but discards
    /// results that match any known Cloak region's VPN endpoint —
    /// those are the VPN's IP, not the user's home IP, and caching
    /// them would corrupt the "IP → VPN IP" UI display.
    ///
    /// Tries multiple providers for resilience: api.ipify.org first,
    /// then ipinfo.io as fallback. Both return plain-text IP only.
    func refreshPublicIPIfNotConnected() async {
        // Set of Cloak region endpoint IPs — we know these are VPN
        // exits, not user home IPs, so any match means the VPN was on
        // when the lookup ran.
        let vpnEndpoints = Set(CloakRegion.all.map { $0.endpointIP })

        let providers = [
            "https://api.ipify.org",
            "https://ipinfo.io/ip",
        ]

        for providerURL in providers {
            guard let url = URL(string: providerURL) else { continue }
            do {
                var req = URLRequest(url: url)
                req.timeoutInterval = 6
                let (data, _) = try await URLSession.shared.data(for: req)
                guard let raw = String(data: data, encoding: .utf8) else { continue }
                let ip = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !ip.isEmpty else { continue }

                if vpnEndpoints.contains(ip) {
                    // The VPN was up when we asked; this response is
                    // the VPN endpoint, NOT the user's real IP. Skip
                    // updating the cache — preserves whatever real IP
                    // we cached on a previous (VPN-off) launch.
                    debugLog("refreshPublicIP: \(ip) matches a Cloak region; skipping cache (VPN on)")
                    return
                }

                self.publicIP = ip
                UserDefaults.standard.set(ip, forKey: Self.publicIPUserDefaultsKey)
                debugLog("refreshPublicIP: cached \(ip) from \(providerURL)")
                return  // success, stop trying more providers
            } catch {
                debugLog("refreshPublicIP: \(providerURL) failed: \(error.localizedDescription)")
                continue
            }
        }
        debugLog("refreshPublicIP: all providers failed; publicIP stays \(publicIP ?? "nil")")
    }

    /// Called when the customer taps a region. Remembers the choice, and if the tunnel is
    /// up, restarts it through the new region's gateway.
    func selectRegion(_ region: CloakRegion) async {
        guard !regionSelectionInProgress else { return }
        regionSelectionInProgress = true
        defer { regionSelectionInProgress = false }

        lastRegionError = nil  // clear previous error before retry
        accountNeedsReentry = false  // re-set only by THIS attempt's 401

        // A region only chooses the gateway. Nothing is provisioned on the server for it.
        let wasActive = (status == .connected || status == .connecting || status == .reasserting)
        selectedRegion = region
        UserDefaults.standard.set(region.id, forKey: Self.selectedRegionUserDefaultsKey)
        if wasActive {
            await disconnectAndWait()
            if let failure = await startCNSA2(regionID: region.id) { lastRegionError = failure }
        }
    }

    /// Disconnect and poll until the tunnel is actually `.disconnected`, then a
    /// brief beat for iOS to release the utun. Used to take the tunnel down
    /// BEFORE a switch-provision so the control-plane request goes out-of-tunnel.
    private func disconnectAndWait() async {
        do { try await disconnect() } catch { debugLog("disconnectAndWait: disconnect threw \(error)") }
        let deadline = Date().addingTimeInterval(8.0)
        while Date() < deadline && status != .disconnected {
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
        try? await Task.sleep(nanoseconds: 500_000_000)
    }

    /// Load existing VPN configurations from the system preferences.
    func load() async {
        do {
            let managers = try await NETunnelProviderManager.loadAllFromPreferences()
            manager = managers.first {
                ($0.protocolConfiguration as? NETunnelProviderProtocol)?.providerBundleIdentifier == Self.providerBundleIdentifier
            }
            if let m = manager {
                observeStatus(m.connection)
                updateStatus(m.connection.status)
                // CNSA 2.0 is the only mode. A profile saved by an older build is a WireGuard
                // profile: if it is running, replace it now. If it is not, the next Connect
                // writes the CNSA 2.0 profile over it.
                let savedIsCNSA2 = (m.protocolConfiguration as? NETunnelProviderProtocol)?.providerConfiguration?["cnsa2"] != nil
                let running = [.connected, .connecting, .reasserting].contains(m.connection.status)
                if !savedIsCNSA2, running {
                    Task { @MainActor [weak self] in
                        guard let self else { return }
                        await self.disconnectAndWait()
                        if let failure = await self.startCNSA2() { self.lastRegionError = failure }
                    }
                }
            }
        } catch {
            print("TunnelManager.load error: \(error)")
        }
    }

    /// On a fresh install, save a placeholder VPN profile so the system's "Would Like to
    /// Add VPN Configurations" prompt appears as the app opens, not at the first connect.
    ///
    /// The customer allows it once. Later saves, at connect time, update the same approved
    /// profile with no second prompt. The placeholder is disabled and has a dummy server
    /// address, so it cannot be connected by accident.
    ///
    /// Does nothing when a profile already exists.
    func preCreateManagerIfNeeded() async {
        if manager != nil {
            debugLog("preCreateManager: existing manager found, skipping")
            return
        }
        debugLog("preCreateManager: no existing manager — creating placeholder to trigger iOS permission prompt early")

        let placeholder = NETunnelProviderManager()
        let proto = NETunnelProviderProtocol()
        // Bundle ID must match the real CloakTunnel target — wrong here
        // and iOS would later need to revoke + re-prompt when we update
        // to the correct one.
        proto.providerBundleIdentifier = Self.providerBundleIdentifier
        // Placeholder server address. The real value is set at the first connect,
        // when user picks a region. iOS doesn't validate this until
        // startVPNTunnel() is called, which we never do on the placeholder
        // (isEnabled=false).
        proto.serverAddress = "placeholder"
        proto.providerConfiguration = ["placeholder": "true"]
        // includeAllNetworks MUST match the eventual real config to avoid
        // re-prompting on the first real save. The CNSA 2.0 profile sets
        // includeAllNetworks=true, so we set it here too.
        proto.includeAllNetworks = true
        placeholder.protocolConfiguration = proto
        placeholder.localizedDescription = "LATTICE VPN"
        placeholder.isEnabled = false  // user can't accidentally connect to nothing

        do {
            try await placeholder.saveToPreferences()
            try await placeholder.loadFromPreferences()
            self.manager = placeholder
            self.observeStatus(placeholder.connection)
            debugLog("preCreateManager: placeholder profile saved (user accepted prompt)")
        } catch {
            // Most likely: user tapped "Don't Allow". Fall through —
            // the next selectRegion attempt will re-trigger via the
            // connect path, and the user will see the prompt
            // again at that point. Nothing we can do besides retry.
            debugLog("preCreateManager: saveToPreferences failed (user denied?): \(error)")
        }
    }

    func connect() async throws {
        debugLog("connect() called, current status=\(status)")
        if let failure = await startCNSA2() { throw CNSA2Renewal.Failure(status: 0, message: failure) }
    }

    /// Display name of the region whose CNSA 2.0 gateway was last used, for the UI.
    var cnsa2GatewayRegionName: String? {
        guard let id = UserDefaults.standard.string(forKey: "cnsa2.gateway.current") else { return nil }
        return CloakRegion.byID(id)?.displayName ?? id
    }

    /// The CNSA 2.0 suite is the only way the app connects: Connect and the region list
    /// use the TLS 1.3 tunnel. There is no setting for it and nothing falls back to WireGuard.
    @Published private(set) var cnsa2Mode = true

    var isCNSA2Mode: Bool { cnsa2Mode }

    /// When the running tunnel came up, for the session clock. Nil when not connected.
    var connectedSince: Date? { manager?.connection.connectedDate }

    /// Traffic and key changes for the running session, asked of the tunnel extension.
    /// Round trip to the gateway through the tunnel, in seconds.
    func gatewayLatency() async -> TimeInterval? {
        guard status == .connected else { return nil }
        #if os(macOS)
        guard let data = try? await Self.sendProviderMessageAsync(Data([0x01]), manager: manager),
              let text = String(data: data, encoding: .utf8), let trip = Double(text), trip > 0 else { return nil }
        return trip
        #else
        return await LatticePing.roundTrip(to: LatticePing.gatewayInTunnel)
        #endif
    }

    func cnsa2SessionStats() async -> CNSA2SessionStats? {
        guard status == .connected,
              let data = try? await Self.sendProviderMessageAsync(Data([0x00]), manager: manager),
              let text = String(data: data, encoding: .utf8) else { return nil }
        var values: [String: String] = [:]
        for line in text.split(separator: "\n") {
            let parts = line.split(separator: "=", maxSplits: 1)
            if parts.count == 2 { values[String(parts[0])] = String(parts[1]) }
        }
        guard values["mode"] == "cnsa2" else { return nil }
        return CNSA2SessionStats(received: UInt64(values["cnsa2_rx_bytes"] ?? "") ?? 0,
                                 sent: UInt64(values["cnsa2_tx_bytes"] ?? "") ?? 0,
                                 keyChanges: Int(values["cnsa2_rekeys"] ?? "") ?? 0)
    }

    /// Seconds since the running tunnel last completed its handshake,
    /// or nil if it has not completed one (or the provider can't be asked).
    /// "Connected" from NetworkExtension only means the interface is up; this
    /// is the signal that the tunnel can actually carry traffic.
    func lastHandshakeAge() async -> TimeInterval? {
        guard let data = try? await Self.sendProviderMessageAsync(Data([0x00]), manager: manager),
              let text = String(data: data, encoding: .utf8) else { return nil }
        let key = "last_handshake_time_sec="
        for line in text.split(separator: "\n") where line.hasPrefix(key) {
            if let sec = TimeInterval(line.dropFirst(key.count)), sec > 0 {
                return max(0, Date().timeIntervalSince1970 - sec)
            }
        }
        return nil
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

    /// Last-resort manual recovery: delete the saved VPN profile, create it again and
    /// reconnect. The system asks the customer to allow the new profile once.
    func resetTunnel() async throws {
        debugLog("resetTunnel: starting")

        // Stop the tunnel and remove the saved VPN profile.
        if let m = manager {
            let st = m.connection.status
            if st == .connected || st == .connecting || st == .reasserting {
                debugLog("resetTunnel: stopping active tunnel")
                m.connection.stopVPNTunnel()
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
            debugLog("resetTunnel: removeFromPreferences")
            try await m.removeFromPreferences()
        }
        self.manager = nil

        // Give the system a moment, or the save below can race with its own cleanup.
        try? await Task.sleep(nanoseconds: 1_000_000_000)

        // Connect again. This writes a fresh profile, and the system asks the customer
        // to allow it once.
        debugLog("resetTunnel: profile removed, calling connect()")
        try await connect()
    }

    func disconnect() async throws {
        debugLog("disconnect() called, current status=\(status)")
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

    // MARK: - Status observation

    #if DEBUG
    /// Lab only. `-LatticeCNSA2Enroll <device name>` makes this device's key if needed and
    /// leaves a certificate request in the shared container; `-LatticeCNSA2Certificate
    /// <base64 DER>` stores the certificate issued for it.
    static func runCNSA2LabEnrollment() {
        let defaults = UserDefaults.standard
        let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: "group.ai.cloakvpn.CloakVPN")
        let lab = OSLog(subsystem: "ai.cloakvpn.CloakVPN", category: "cnsa2lab")
        func note(_ text: String) {
            os_log("cnsa2lab: %{public}s", log: lab, type: .default, text)
            if let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first {
                try? Data(text.utf8).write(to: docs.appendingPathComponent("cnsa2-enroll.txt"))
            }
            guard let url = container?.appendingPathComponent("cnsa2-enroll.txt") else { return }
            try? Data(text.utf8).write(to: url)
        }
        // `-LatticeCNSA2PretendDaysLeft <n>`: tell this device its certificate expires in n days,
        // to watch a renewal without waiting three weeks. The real certificate is untouched.
        if defaults.object(forKey: "LatticeCNSA2PretendDaysLeft") != nil, CNSA2Identity.certificate() != nil {
            let days = defaults.double(forKey: "LatticeCNSA2PretendDaysLeft")
            try? CNSA2Identity.setCertificateExpiry(Date().addingTimeInterval(days * 86400))
            note("pretending the certificate expires in \(days) days")
        }
        if let name = defaults.string(forKey: "LatticeCNSA2Enroll") {
            do {
                let request = try CNSA2Identity.certificateRequest(commonName: name)
                if let url = container?.appendingPathComponent("cnsa2-request.der") { try request.write(to: url) }
                // also in the app's own Documents folder, which development tools can read on iOS
                if let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first {
                    try? request.write(to: docs.appendingPathComponent("cnsa2-request.der"))
                }
                // The request holds no secrets. It also goes to the log in pieces, because on
                // macOS other processes cannot read an app's group container.
                let b64 = request.base64EncodedString()
                let size = 600
                let count = (b64.count + size - 1) / size
                for i in 0..<count {
                    let start = b64.index(b64.startIndex, offsetBy: i * size)
                    let end = b64.index(start, offsetBy: min(size, b64.count - i * size))
                    os_log("cnsa2lab: request %{public}d/%{public}d %{public}s", log: lab, type: .default, i + 1, count, String(b64[start..<end]))
                }
                note("request written for \(name)")
            } catch { note("enroll failed: \(error)") }
        }
        if let b64 = defaults.string(forKey: "LatticeCNSA2Certificate"), let der = Data(base64Encoded: b64) {
            do { try CNSA2Identity.storeCertificate(der); note("certificate stored") } catch { note("certificate refused: \(error)") }
        }
    }

    /// Lab only (debug builds): point the tunnel at a CNSA 2.0 (TLS 1.3) gateway
    /// described by a base64 JSON blob (see CNSA2TunnelController) and start it.
    /// Replaces the saved VPN configuration until a region is selected again.
    func startCNSA2Lab(_ base64JSON: String) async {
        guard let data = Data(base64Encoded: base64JSON),
              let cfg = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            debugLog("cnsa2 lab: unreadable configuration")
            return
        }
        do {
            try await startCNSA2Tunnel(cfg)
            debugLog("cnsa2 lab: tunnel start requested")
        } catch {
            debugLog("cnsa2 lab: failed: \(error)")
        }
    }

    #endif

    /// Connects in CNSA 2.0 mode through the production
    /// account API: enrolls this device if it has no usable certificate, then starts
    /// the TLS 1.3 tunnel to the gateway the server named. Never falls back to
    /// WireGuard. `routes` overrides what the gateway assigns (used for testing).
    /// Returns a message for the user on failure, nil on success.
    func startCNSA2(routes: [String]? = nil, regionID: String? = nil) async -> String? {
        guard let number = accountNumber, !number.isEmpty else {
            return "Sign in with your account number to use CNSA 2.0 mode."
        }
        do {
            // The gateway follows the region the user has selected.
            var cfg = try await CNSA2Enroller.shared.configuration(
                accountNumber: number, regionID: regionID ?? selectedRegion?.id)
            if let routes { cfg["routes"] = routes }
            try await startCNSA2Tunnel(cfg)
            debugLog("cnsa2: tunnel start requested")
            // Renew ahead of expiry with the same key. The live tunnel keeps its current certificate.
            await renewCNSA2IfDue()
            return nil
        } catch let error as AccountError {
            return error.userMessage
        } catch {
            debugLog("cnsa2: failed: \(error)")
            return error.localizedDescription
        }
    }

    /// Renews the CNSA 2.0 certificate if it is in its last 10 days. Safe to call often.
    func renewCNSA2IfDue() async {
        #if DEBUG
        // set by a test option, so the tunnel extension's renewal can be watched alone
        if UserDefaults.standard.object(forKey: "LatticeCNSA2PretendDaysLeft") != nil { return }
        #endif
        guard let number = accountNumber, !number.isEmpty else { return }
        do {
            if try await CNSA2Enroller.shared.renewIfDue(accountNumber: number) {
                debugLog("cnsa2: certificate renewed")
            }
        } catch {
            debugLog("cnsa2: renewal failed: \(error)")
        }
    }

    private func startCNSA2Tunnel(_ cfg: [String: Any]) async throws {
        let existing = try await NETunnelProviderManager.loadAllFromPreferences()
        let m = existing.first ?? NETunnelProviderManager()
        let proto = NETunnelProviderProtocol()
        proto.providerBundleIdentifier = Self.providerBundleIdentifier
        proto.serverAddress = (cfg["host"] as? String) ?? "cnsa2"
        proto.providerConfiguration = ["cnsa2": cfg]
        proto.includeAllNetworks = false
        m.protocolConfiguration = proto
        m.localizedDescription = "LATTICE VPN"
        m.isEnabled = true
        try await m.saveToPreferences()
        try await m.loadFromPreferences()
        manager = m
        observeStatus(m.connection)
        try m.connection.startVPNTunnel()
    }

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

        // Drive the PQC status poller off the connection state (not only the
        // in-app connect() path) so the indicator reflects the NE's live
        // rotations on cold launch / reconnect instead of sticking on "idle".
        // Host-only: cannot affect the NE's actual exchange. startStatusPolling
        // is idempotent. This also gives the self-heal correct status input.
        // Layer 5: arm PQC self-heal on connect; disarm when leaving connected.
        if status == .connected, old != .connected {
            startHandshakeVerification()
        } else if status != .connected, old == .connected {
            handshakeVerifyTask?.cancel()
            handshakeVerifyTask = nil
            handshakeVerified = false
        }
    }

    /// Poll the provider until it reports a completed handshake. Keeps trying
    /// while connected, since the first handshake can lag on a weak network.
    private func startHandshakeVerification() {
        handshakeVerifyTask?.cancel()
        handshakeVerified = false
        handshakeVerifyTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self, self.status == .connected else { return }
                if await self.lastHandshakeAge() != nil {
                    if !Task.isCancelled { self.handshakeVerified = true }
                    return
                }
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
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

}

// `TunnelError` lives in ConfigParser.swift so the NetworkExtension
// target (which compiles ConfigParser.swift but NOT this file) can see
// it too. Don't redeclare it here.

/// What the tunnel extension reports about the running session.
struct CNSA2SessionStats: Equatable {
    let received: UInt64
    let sent: UInt64
    let keyChanges: Int
}

/// Errors the tunnel manager raises on its own account.
enum TunnelError: LocalizedError {
    case noConfig

    var errorDescription: String? {
        switch self {
        case .noConfig: return "The VPN is not set up yet. Connect once to set it up."
        }
    }
}
