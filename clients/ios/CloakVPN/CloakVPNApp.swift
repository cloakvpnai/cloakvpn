import SwiftUI

@main
struct CloakVPNApp: App {
    @StateObject private var tunnel = TunnelManager()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(tunnel)
                .task {
                    // load() must complete BEFORE preCreateManagerIfNeeded
                    // so we don't double-create on second launches. The
                    // keypair + IP work runs in parallel since none of it
                    // depends on the manager state.
                    async let _ = tunnel.ensureLocalKeypair()
                    async let _ = tunnel.ensureLocalWGKeypair()
                    async let _ = tunnel.refreshPublicIPIfNotConnected()

                    await tunnel.load()
                    // CRITICAL UX: trigger the iOS "Cloak VPN Would Like
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
                }
        }
    }
}
