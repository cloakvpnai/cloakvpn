//
//  ConnectionViewModel.swift
//
//  Phase 3: wires the menu bar popover to the real `TunnelManager`
//  shared with iOS (lives in clients/ios/CloakVPN/, added to the
//  LatticeMac target via project.yml sources).
//
//  Architecture:
//
//      ConnectionPopoverView   <-- SwiftUI observes @Published values
//          ▲
//          │  @EnvironmentObject
//          │
//      ConnectionViewModel     <-- this file
//          ▲
//          │  Combine sinks mirror the iOS @Published surface into the
//          │  Mac-flavored ConnectionStatus / RegionSummary types
//          │
//      TunnelManager           <-- shared iOS class (NEPacketTunnelProvider,
//                                  rosenpass PSK derivation, region picker,
//                                  warmup, etc.)
//
//  Why a separate ConnectionStatus enum instead of using TunnelManager.Status
//  directly? Two reasons: (a) the menu bar surfaces a slightly different
//  set of states (we collapse .disconnecting into .disconnected since it's
//  visually meaningless in a popover; we add a .reconnecting state we use
//  for network-change auto-recovery), and (b) the view doesn't need to
//  depend on NetworkExtension imports.
//

import Foundation
import Combine
import SwiftUI

@MainActor
final class ConnectionViewModel: ObservableObject {

    // MARK: - Published state consumed by the SwiftUI views

    @Published private(set) var status: ConnectionStatus = .disconnected
    @Published private(set) var selectedRegion: RegionSummary?
    @Published private(set) var availableRegions: [RegionSummary] = []
    @Published private(set) var publicIP: String?
    @Published private(set) var tunnelIP: String?
    @Published private(set) var lastError: String?

    /// Bytes-transferred counters surfaced under the status pill. Only
    /// meaningful while connected; reset on disconnect. Phase 3.1 will
    /// wire these via the NEPacketTunnelProvider session's bytecount
    /// callback; for now they stay at zero (the popover shows the
    /// fields but they don't update during a session).
    @Published private(set) var bytesIn: UInt64 = 0
    @Published private(set) var bytesOut: UInt64 = 0

    // MARK: - Underlying tunnel

    /// The shared iOS TunnelManager — does ALL the heavy lifting:
    /// provisioning a peer from cloak-api-server, installing the
    /// NETunnelProviderManager preference, deriving the PSK via
    /// rosenpass, starting the tunnel, monitoring connection health,
    /// auto-recovering from wedges. We just feed it region selections
    /// and reflect its published state back into our own published
    /// surface.
    private let tunnel = TunnelManager()

    /// Combine subscriptions kept alive for the lifetime of the VM.
    private var cancellables = Set<AnyCancellable>()

    // MARK: - Init

    init() {
        // Seed the region list from the shared CloakRegion catalog.
        availableRegions = CloakRegion.all.map(RegionSummary.init(_:))

        // Wire up Combine sinks from TunnelManager -> us. Each iOS
        // @Published property has a corresponding mirror here so the
        // SwiftUI views observe stable Mac-flavored types and never
        // import NetworkExtension symbols themselves.
        bindToTunnel()
    }

    private func bindToTunnel() {
        // Status: iOS Status -> Mac ConnectionStatus
        tunnel.$status
            .receive(on: DispatchQueue.main)
            .sink { [weak self] iosStatus in
                self?.status = ConnectionStatus(iosStatus)
            }
            .store(in: &cancellables)

        // Selected region: CloakRegion -> RegionSummary
        tunnel.$selectedRegion
            .receive(on: DispatchQueue.main)
            .sink { [weak self] cloakRegion in
                self?.selectedRegion = cloakRegion.map(RegionSummary.init(_:))
            }
            .store(in: &cancellables)

        // Public IP: pass-through
        tunnel.$publicIP
            .receive(on: DispatchQueue.main)
            .assign(to: \.publicIP, on: self)
            .store(in: &cancellables)

        // Region selection errors: surface as our generic lastError
        tunnel.$lastRegionError
            .receive(on: DispatchQueue.main)
            .sink { [weak self] errMsg in
                self?.lastError = errMsg
            }
            .store(in: &cancellables)
    }

    // MARK: - Boot

    /// Called once from AppDelegate at applicationDidFinishLaunching.
    /// Tells TunnelManager to load any existing NETunnelProviderManager
    /// preference + restore the user's last-used region, then fetch the
    /// current public IP for the popover's "Your IP" label.
    func bootstrap() async {
        await tunnel.load()
        await tunnel.refreshPublicIPIfNotConnected()
    }

    // MARK: - Connection actions

    /// "Connect to fastest region" — used from the popover's primary
    /// button when no region is explicitly selected, and from the
    /// right-click menu's "Connect to fastest region" item.
    ///
    /// If the user hasn't explicitly picked a region yet, fall back to
    /// the first region in the catalog. (Phase 3.1: replace with a
    /// 5-region latency probe + lowest-RTT pick — for v1 ship the
    /// simple version.)
    func connect() async {
        guard !status.isBusy, !status.isConnected else { return }
        let region: CloakRegion
        if let summary = selectedRegion, let cloak = CloakRegion.byID(summary.id) {
            region = cloak
        } else if let first = CloakRegion.all.first {
            region = first
        } else {
            lastError = "No regions available"
            return
        }
        await tunnel.selectRegion(region)
    }

    /// Connect to a specific region. Called when the user clicks a
    /// region row in the popover's region picker. Three behaviors:
    ///   - Same region as current      → no-op
    ///   - Different region while off  → just update selection (don't auto-connect)
    ///   - Different region while on   → swap regions; TunnelManager
    ///                                    handles the disconnect+reconnect
    ///                                    in one selectRegion call
    func connect(to region: RegionSummary) async {
        let switchingRegion = (selectedRegion?.id != region.id)
        let wasConnected = status.isConnected || status.isBusy
        guard let cloak = CloakRegion.byID(region.id) else {
            lastError = "Unknown region \(region.id)"
            return
        }
        // Always update visual selection up front so the checkmark moves
        // even when we don't actually trigger a connect.
        selectedRegion = region

        guard switchingRegion else { return }

        if wasConnected {
            // TunnelManager.selectRegion is idempotent + handles the
            // disconnect+reconnect itself when the region changes (it
            // detects the diff against its own currently-active region).
            await tunnel.selectRegion(cloak)
        }
        // If we were disconnected, just update the in-memory selection
        // — user will press the primary Connect button when they want
        // to actually go live.
    }

    /// Stop the tunnel. Best-effort — TunnelManager.disconnect can throw
    /// if the underlying NEVPNManager call rejects (e.g. session already
    /// in mid-teardown), but we treat that as success from the UI's POV.
    func disconnect() async {
        guard status.isConnected || status.isBusy else { return }
        do {
            try await tunnel.disconnect()
        } catch {
            lastError = "Disconnect failed: \(error.localizedDescription)"
        }
        // Reset locally-tracked counters; tunnel.$publicIP refresh is
        // gated on status != .connected and will repopulate on its own.
        bytesIn = 0
        bytesOut = 0
        tunnelIP = nil
    }

    /// Manual IP refresh — bound to the small refresh button in the
    /// popover header. No-ops while connected (we'd just get the
    /// tunnel endpoint back).
    func refreshPublicIP() async {
        await tunnel.refreshPublicIPIfNotConnected()
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

    init(_ s: TunnelManager.Status) {
        switch s {
        case .disconnected, .disconnecting: self = .disconnected
        case .connecting:                   self = .connecting
        case .connected:                    self = .connected
        case .reasserting:                  self = .reconnecting
        case .invalid:                      self = .error
        }
    }

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

/// Lightweight region descriptor for the popover's region picker.
/// Initializable from the shared CloakRegion so the conversion happens
/// in one place.
struct RegionSummary: Identifiable, Equatable {
    let id: String
    let displayName: String
    let countryFlag: String
    let endpointDisplay: String   // a teaser IP for the connected-state UI

    init(_ region: CloakRegion) {
        self.id = region.id
        self.displayName = region.displayName
        self.countryFlag = region.countryFlag
        self.endpointDisplay = region.endpointIP
    }

    /// Fallback used by `RegionSummary.builtIn` for the SwiftUI preview
    /// of ConnectionPopoverView when CloakRegion isn't available.
    init(id: String, displayName: String, countryFlag: String, endpointDisplay: String) {
        self.id = id
        self.displayName = displayName
        self.countryFlag = countryFlag
        self.endpointDisplay = endpointDisplay
    }

    /// Used only by SwiftUI #Preview. Real region data comes from
    /// CloakRegion.all via the convenience init above.
    static let builtIn: [RegionSummary] = [
        .init(id: "us-west-1",  displayName: "US West (Oregon)",    countryFlag: "🇺🇸", endpointDisplay: "—"),
        .init(id: "us-east-1",  displayName: "US East (Virginia)",  countryFlag: "🇺🇸", endpointDisplay: "—"),
        .init(id: "de1",        displayName: "Germany (Frankfurt)", countryFlag: "🇩🇪", endpointDisplay: "—"),
        .init(id: "fi1",        displayName: "Finland (Helsinki)",  countryFlag: "🇫🇮", endpointDisplay: "—"),
    ]
}
