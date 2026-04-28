import SwiftUI

@main
struct CloakVPNApp: App {
    @StateObject private var tunnel = TunnelManager()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(tunnel)
                .task {
                    // Run startup tasks concurrently — they're
                    // independent (loading existing VPN profile vs.
                    // ensuring local keypairs) and we don't want any
                    // blocking the others. The two ensure* calls each
                    // generate one keypair on first launch (rosenpass
                    // McEliece keygen ~50-200 ms; Curve25519 WG keygen
                    // <1 ms) and are fast-path no-ops on subsequent
                    // launches.
                    async let _ = tunnel.load()
                    async let _ = tunnel.ensureLocalKeypair()
                    async let _ = tunnel.ensureLocalWGKeypair()
                    // Refresh the user's real public IP (only fires
                    // when VPN is currently OFF, otherwise we'd
                    // overwrite the home-IP cache with the VPN
                    // endpoint's IP).
                    async let _ = tunnel.refreshPublicIPIfNotConnected()
                }
        }
    }
}
