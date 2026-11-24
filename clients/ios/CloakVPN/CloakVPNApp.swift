import SwiftUI

@main
struct CloakVPNApp: App {
    @StateObject private var tunnel = TunnelManager()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(tunnel)
                #if DEBUG
                // Lab only: `-LatticeCNSA2Lab <base64 JSON>` starts the CNSA 2.0
                // (TLS 1.3) tunnel against a development gateway.
                .task {
                    TunnelManager.runCNSA2LabEnrollment()
                    if let blob = UserDefaults.standard.string(forKey: "LatticeCNSA2Lab") {
                        try? await Task.sleep(nanoseconds: 2_000_000_000)
                        await tunnel.startCNSA2Lab(blob)
                    }
                    // `-LatticeCNSA2Connect full` enrolls through the account API and connects,
                    // the same as the preview button. The outcome goes to Documents for test tools.
                    if UserDefaults.standard.string(forKey: "LatticeCNSA2Connect") != nil {
                        try? await Task.sleep(nanoseconds: 4_000_000_000)
                        let failure = await tunnel.startCNSA2()
                        if let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first {
                            try? Data((failure ?? "started").utf8).write(to: docs.appendingPathComponent("cnsa2-connect.txt"))
                        }
                    }
                    // Renew the CNSA 2.0 certificate when it is in its last 10 days.
                    try? await Task.sleep(nanoseconds: 15_000_000_000)
                    await tunnel.renewCNSA2IfDue()
                }
                #endif
                .task {
                    // load() must complete BEFORE preCreateManagerIfNeeded
                    // so we don't double-create on second launches. The
                    // keypair + IP work runs in parallel since none of it
                    // depends on the manager state.
                    async let _ = tunnel.ensureLocalKeypair()
                    async let _ = tunnel.ensureLocalWGKeypair()
                    async let _ = tunnel.refreshPublicIPIfNotConnected()

                    await tunnel.load()
                    // CRITICAL UX: trigger the iOS "Lattice VPN Would Like
                    // to Add VPN Configurations" prompt the MOMENT the app
                    // opens, not later when the user taps a region (which
                    // would force them to wait through a 3-8s server
                    // provisioning round-trip first). Pre-creating an
                    // approved-but-disabled placeholder profile means
                    // every subsequent saveToPreferences (during real
                    // region picks) silently updates that profile with
                    // no second prompt — they tap a region and Connect,
                    // and the tunnel just comes up.
                    await tunnel.preCreateManagerIfNeeded()

                    // Re-apply the saved subscription icon assignment
                    // on every cold start. Cheap no-op when the icon
                    // already matches (the inner alternateIconName
                    // check short-circuits before iOS shows its
                    // "icon changed" alert).
                    SubscriptionInfo.applyIconForCurrentTier()

                    // Refresh subscription state from the central account
                    // API for the stored account number (no-op when the
                    // customer hasn't signed in yet). Keeps the Account
                    // screen and the Basic/Pro app icon current.
                    await tunnel.refreshAccountStatus()

                    // Warm-up: kick off a background provision call for
                    // the user's most-likely-to-tap region (last-used or
                    // default). Doesn't block UI — by the time the user
                    // accepts the VPN prompt and taps a region, the
                    // network round-trip is complete and the cache is
                    // populated. Their tap is then a local cache hit
                    // (~200ms) instead of waiting 2.5-4.5s for the
                    // server round-trip to complete in the foreground.
                    Task.detached(priority: .background) { [tunnel] in
                        await tunnel.warmUpPreferredRegion()
                    }
                }
        }
    }
}
