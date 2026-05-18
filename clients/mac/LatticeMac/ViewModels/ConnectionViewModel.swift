//
//  ConnectionViewModel.swift
//
//  Bridge between the SwiftUI popover/settings views and the underlying
//  `TunnelManager` (shared from the iOS target via Xcode target
//  membership). Two responsibilities:
//
//    1. Translate TunnelManager's iOS-flavored Status enum into a
//       Mac-flavored ConnectionStatus that includes a few extra cases
//       we surface in the menu bar icon (`.reconnecting`, `.error`).
//
//    2. Expose @Published state in shapes the SwiftUI views consume
//       directly, so the views stay thin (no .map / .filter chains
//       inside `body`).
//
//  This view model is intentionally still partially-mocked in Phase 1
//  so the menu bar / popover UI can be built and iterated visually
//  without waiting on TunnelManager wiring (Phase 3). Every method that
//  currently logs a `// TODO` comment is the integration point for that
//  wiring step.
//

import Foundation
import Combine
import SwiftUI

@MainActor
final class ConnectionViewModel: ObservableObject {

    // MARK: - Published state consumed by the SwiftUI views

    @Published private(set) var status: ConnectionStatus = .disconnected
    @Published private(set) var selectedRegion: RegionSummary?
    @Published private(set) var availableRegions: [RegionSummary] = RegionSummary.builtIn
    @Published private(set) var publicIP: String?
    @Published private(set) var tunnelIP: String?
    @Published private(set) var lastError: String?

    /// Bytes-transferred counters surfaced under the status pill. Only
    /// meaningful while connected; reset on disconnect. Updated via
    /// PacketTunnelProvider IPC every 2s once connected.
    @Published private(set) var bytesIn: UInt64 = 0
    @Published private(set) var bytesOut: UInt64 = 0

    // MARK: - Boot

    /// Called once from AppDelegate at applicationDidFinishLaunching.
    /// Pulls the persisted preferred region from UserDefaults, fetches
    /// the current public IP, and asks the kernel for any existing
    /// NETunnelProviderManager preference so the popover reflects
    /// reality immediately on first show.
    func bootstrap() async {
        // TODO[Phase 3]: wire to TunnelManager.shared.load() and mirror
        // its @Published properties (status, selectedRegion, publicIP)
        // into our own published surface via Combine sinks.
        selectedRegion = availableRegions.first
        await refreshPublicIP()
    }

    // MARK: - Connection actions

    /// "Connect to fastest region" — used from the popover's primary
    /// button when no region is explicitly selected, and from the
    /// right-click menu's "Connect to fastest region" item.
    func connect() async {
        // TODO[Phase 3]: defer to TunnelManager.shared.selectRegion(
        //   bestRegionByLatency()) which already runs a 5-region ping
        //   and picks the lowest-RTT host.
        guard status != .connecting, status != .connected else { return }
        await transition(to: .connecting)
        try? await Task.sleep(nanoseconds: 1_200_000_000)
        await transition(to: .connected)
        tunnelIP = selectedRegion?.endpointDisplay ?? "—"
    }

    /// Connect to a specific region. Called when the user clicks a
    /// region row in the popover's region picker.
    func connect(to region: RegionSummary) async {
        selectedRegion = region
        await connect()
    }

    func disconnect() async {
        // TODO[Phase 3]: call TunnelManager.shared.stop() (the wrapper
        //   over NETunnelProviderSession.stopVPNTunnel()).
        guard status == .connected || status == .connecting else { return }
        // We don't model an explicit `.disconnecting` state in the menu
        // bar UI — too short-lived to be useful, just go straight from
        // the current state to `.disconnected` after the (mock) hand-off.
        try? await Task.sleep(nanoseconds: 600_000_000)
        await transition(to: .disconnected)
        tunnelIP = nil
        bytesIn = 0
        bytesOut = 0
    }

    /// Pulls down current public IP via ipapi.co (same provider the
    /// website uses, kept consistent so the "Your IP" surface matches
    /// across our properties). No-op if a tunnel is up — we don't want
    /// to leak the tunnel IP into ourselves, and the request would also
    /// just return the tunnel exit anyway.
    func refreshPublicIP() async {
        guard status != .connected else { return }
        // TODO[Phase 3]: defer to TunnelManager.shared.refreshPublicIPIfNotConnected()
        // — that path already handles provider fallback (ipapi.co ->
        // ifconfig.me -> icanhazip) and VPN-endpoint detection.
        do {
            let url = URL(string: "https://ipapi.co/ip/")!
            var req = URLRequest(url: url)
            req.timeoutInterval = 4
            let (data, _) = try await URLSession.shared.data(for: req)
            let ip = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            publicIP = ip.isEmpty ? nil : ip
        } catch {
            publicIP = nil
        }
    }

    // MARK: - Internal

    private func transition(to newStatus: ConnectionStatus) async {
        status = newStatus
        if newStatus != .error { lastError = nil }
    }
}

// MARK: - ConnectionStatus

/// View-model-level status. Maps from TunnelManager.Status (and adds a
/// couple of Mac-only meta-states) so the menu bar icon and popover can
/// distinguish e.g. an in-flight reconnect from an idle disconnected.
enum ConnectionStatus: Equatable {
    case disconnected
    case connecting
    case connected
    case reconnecting     // brief transient when network changes; auto-recovers
    case error            // user-actionable failure

    var menuTitle: String {
        switch self {
        case .disconnected: return "Disconnected"
        case .connecting:   return "Connecting…"
        case .connected:    return "Protected"
        case .reconnecting: return "Reconnecting…"
        case .error:        return "Error"
        }
    }

    var isConnected: Bool { self == .connected }
    var isBusy: Bool { self == .connecting || self == .reconnecting }
}

// MARK: - RegionSummary

/// Lightweight region descriptor for the popover's region picker. The
/// shared `CloakRegion` model (from iOS) carries server URLs, endpoint
/// IPs, and provisioning metadata — none of which the popover needs to
/// render a single row. We map down to this summary in Phase 3.
struct RegionSummary: Identifiable, Equatable {
    let id: String
    let displayName: String
    let countryFlag: String
    let endpointDisplay: String   // a teaser IP for the connected-state UI

    /// Built-in placeholders shown until TunnelManager publishes the
    /// real region list. Kept in sync with `CloakRegion.all` from the
    /// iOS Region.swift.
    static let builtIn: [RegionSummary] = [
        .init(id: "us-west-1",  displayName: "US West (Oregon)",    countryFlag: "🇺🇸", endpointDisplay: "—"),
        .init(id: "us-east-1",  displayName: "US East (Virginia)",  countryFlag: "🇺🇸", endpointDisplay: "—"),
        .init(id: "de1",        displayName: "Germany (Frankfurt)", countryFlag: "🇩🇪", endpointDisplay: "—"),
        .init(id: "fi1",        displayName: "Finland (Helsinki)",  countryFlag: "🇫🇮", endpointDisplay: "—"),
    ]
}

// MARK: - Bridge from TunnelManager.Status

#if canImport(NetworkExtension)
// Phase 3 will uncomment this once TunnelManager is added to the Mac
// target. Kept here as a reference so the integration is mechanical.
//
// extension ConnectionStatus {
//     init(_ s: TunnelManager.Status) {
//         switch s {
//         case .disconnected, .disconnecting: self = .disconnected
//         case .connecting:                   self = .connecting
//         case .connected:                    self = .connected
//         case .reasserting:                  self = .reconnecting
//         case .invalid:                      self = .error
//         }
//     }
// }
#endif
