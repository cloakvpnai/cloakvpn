import Foundation
import NetworkExtension
import os.log

// NOTE: This file compiles once the Xcode target is configured with the
// WireGuardKit package (see clients/ios/README.md). Import path:
//     import WireGuardKit
// We keep it commented to allow this skeleton to compile standalone before
// WireGuardKit is attached.
// import WireGuardKit

final class PacketTunnelProvider: NEPacketTunnelProvider {
    private let log = OSLog(subsystem: "com.cloakvpn.app.tunnel", category: "tunnel")

    // private var adapter: WireGuardAdapter!

    override func startTunnel(
        options: [String: NSObject]?,
        completionHandler: @escaping (Error?) -> Void
    ) {
        os_log("startTunnel", log: log)

        guard
            let proto = protocolConfiguration as? NETunnelProviderProtocol,
            let dict = proto.providerConfiguration
        else {
            completionHandler(TunnelErr.missingProtocol); return
        }

        do {
            let cfg = try CloakConfig(dict: dict)
            let settings = buildNetworkSettings(for: cfg)
            setTunnelNetworkSettings(settings) { [weak self] err in
                guard let self = self else { return }
                if let err = err {
                    os_log("setTunnelNetworkSettings error: %{public}s",
                           log: self.log, err.localizedDescription)
                    completionHandler(err); return
                }

                // TODO: Start WireGuardKit adapter with cfg
                // self.adapter = WireGuardAdapter(with: self) { level, message in
                //     os_log("[wg] %{public}s", log: self.log, message)
                // }
                // let wgConfig = cfg.asWireGuardConfigString()
                // self.adapter.start(tunnelConfiguration: try! TunnelConfiguration(fromWgQuickConfig: wgConfig)) { adapterErr in
                //     completionHandler(adapterErr)
                // }

                // TODO: Start Rosenpass PSK rotation loop
                // RosenpassBridge.start(...)

                completionHandler(nil)
            }
        } catch {
            completionHandler(error)
        }
    }

    override func stopTunnel(
        with reason: NEProviderStopReason,
        completionHandler: @escaping () -> Void
    ) {
        os_log("stopTunnel reason=%d", log: log, reason.rawValue)
        // RosenpassBridge.stop()
        // adapter?.stop { _ in completionHandler() }
        completionHandler()
    }

    // MARK: - Helpers

    private func buildNetworkSettings(for cfg: CloakConfig) -> NEPacketTunnelNetworkSettings {
        let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: cfg.endpoint.components(separatedBy: ":").first ?? "")
        // IPv4
        let v4 = NEIPv4Settings(addresses: [cfg.addressV4.components(separatedBy: "/").first!], subnetMasks: ["255.255.255.0"])
        v4.includedRoutes = [NEIPv4Route.default()]
        settings.ipv4Settings = v4
        // IPv6
        let v6 = NEIPv6Settings(addresses: [cfg.addressV6.components(separatedBy: "/").first!], networkPrefixLengths: [128])
        v6.includedRoutes = [NEIPv6Route.default()]
        settings.ipv6Settings = v6
        // DNS
        settings.dnsSettings = NEDNSSettings(servers: cfg.dns)
        // MTU — 1420 is safe for WireGuard over most transports
        settings.mtu = 1420
        return settings
    }
}

enum TunnelErr: Error { case missingProtocol }
