//
//  LatticeMacTunnelProvider.swift
//
//  Thin macOS shell around the shared `PacketTunnelProvider` (lives in
//  ../../ios/CloakTunnel/PacketTunnelProvider.swift, added to the Mac
//  PTP target via Xcode target membership).
//
//  Why a shell instead of using the iOS class directly? Two reasons:
//
//    1. The Info.plist principal class for the Mac extension needs to
//       resolve to *this* module's symbol, so even if we share 99% of
//       the code we need a concrete class in this target.
//
//    2. The Mac PTP runs as a NetworkExtension System Extension (not an
//       App Extension like iOS), which has slightly different lifecycle
//       hooks — `startTunnel(options:completionHandler:)` is the same,
//       but app-group container paths, IPC channels, and logging
//       facilities differ. We override those hooks here when needed and
//       defer everything else to the shared base.
//
//  When iOS and Mac diverge meaningfully on a particular method, that
//  divergence stays here (not in the shared file). Keeps the shared
//  file free of #if os(macOS) noise.
//

import NetworkExtension

final class LatticeMacTunnelProvider: PacketTunnelProvider {

    // MARK: - Lifecycle overrides

    override func startTunnel(options: [String: NSObject]?,
                              completionHandler: @escaping (Error?) -> Void) {
        // Mac System Extensions get an extra second of grace before the
        // OS marks them unresponsive; not currently used but documented
        // here so future startup-flow tuning has a hook.
        super.startTunnel(options: options, completionHandler: completionHandler)
    }

    override func stopTunnel(with reason: NEProviderStopReason,
                             completionHandler: @escaping () -> Void) {
        // Direct-Download builds (non-sandboxed) get an opportunity here
        // to flush a diagnostic log to ~/Library/Logs/LatticeVPN before
        // the extension is torn down. App Store builds skip the flush
        // because the sandbox container goes away with the extension.
        #if !APPSTORE_BUILD
        flushDiagnosticLogIfNeeded()
        #endif
        super.stopTunnel(with: reason, completionHandler: completionHandler)
    }

    // MARK: - Mac-specific helpers

    private func flushDiagnosticLogIfNeeded() {
        // TODO[Phase 3]: copy the rolling provider log to
        //   ~/Library/Logs/LatticeVPN/tunnel-<timestamp>.log
        // so Direct-Download users can attach it to support tickets.
    }
}
