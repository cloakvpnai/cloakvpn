// PacketTunnelProvider.swift — Lattice VPN packet tunnel
//
// The tunnel extension for iPhone, iPad and Mac. It runs one kind of tunnel:
// TLS 1.3 with the CNSA 2.0 suite (ML-KEM-1024, ML-DSA-87, AES-256-GCM,
// SHA-384), driven by CNSA2TunnelController. There is no other mode and no
// fallback. A saved profile that is not a CNSA 2.0 profile is refused.

import Foundation
import NetworkExtension
import os.log

// Not `final`: the macOS app subclasses this in LatticeMacTunnelProvider.
class PacketTunnelProvider: NEPacketTunnelProvider {
    private let log = OSLog(subsystem: "ai.cloakvpn.CloakVPN.tunnel", category: "tunnel")

    /// The running tunnel, from startTunnel until stopTunnel.
    private var cnsa2: CNSA2TunnelController?

    override func startTunnel(
        options: [String: NSObject]?,
        completionHandler: @escaping (Error?) -> Void
    ) {
        os_log("startTunnel", log: log, type: .info)

        guard
            let proto = protocolConfiguration as? NETunnelProviderProtocol,
            let dict = proto.providerConfiguration
        else {
            os_log("startTunnel: missing providerConfiguration", log: log, type: .error)
            completionHandler(PacketTunnelError.missingProtocol)
            return
        }

        // A profile with no "cnsa2" section was saved by an older, WireGuard-based
        // version of the app. This version cannot run it and will not try. The app
        // writes the CNSA 2.0 profile over it at the next Connect.
        guard let cnsa2Config = dict["cnsa2"] as? [String: Any] else {
            os_log("startTunnel: refusing a profile that is not CNSA 2.0", log: log, type: .error)
            completionHandler(PacketTunnelError.notCNSA2)
            return
        }

        let controller = CNSA2TunnelController(provider: self)
        cnsa2 = controller
        controller.start(cnsa2Config, completion: completionHandler)
    }

    override func stopTunnel(
        with reason: NEProviderStopReason,
        completionHandler: @escaping () -> Void
    ) {
        os_log("stopTunnel reason=%d", log: log, type: .info, reason.rawValue)
        guard let controller = cnsa2 else {
            completionHandler()
            return
        }
        cnsa2 = nil
        controller.stop(completion: completionHandler)
    }

    /// The app's status query (opcode 0x00): the suite in use, when the keys were last
    /// replaced, how many times, and the bytes carried this session.
    override func handleAppMessage(
        _ messageData: Data,
        completionHandler: ((Data?) -> Void)? = nil
    ) {
        guard let completionHandler else { return }
        guard messageData.first == 0x00, let controller = cnsa2 else {
            completionHandler(Data([0xFF]))
            return
        }
        completionHandler(controller.statusReport.data(using: .utf8))
    }
}

enum PacketTunnelError: Error, LocalizedError {
    case missingProtocol
    case notCNSA2

    var errorDescription: String? {
        switch self {
        case .missingProtocol:
            return "Missing or malformed VPN configuration."
        case .notCNSA2:
            return "This saved VPN profile is from an older version of Lattice VPN. Open the app and connect again."
        }
    }
}
