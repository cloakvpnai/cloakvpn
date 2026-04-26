import SwiftUI

@main
struct CloakVPNApp: App {
    @StateObject private var tunnel = TunnelManager()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(tunnel)
                .task {
                    // Run both startup tasks concurrently — they're
                    // independent (loading existing VPN profile vs. ensuring
                    // a local rosenpass keypair) and we don't want either
                    // blocking the other.
                    async let _ = tunnel.load()
                    async let _ = tunnel.ensureLocalKeypair()
                }
        }
    }
}
