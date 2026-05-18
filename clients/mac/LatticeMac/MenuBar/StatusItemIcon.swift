//
//  StatusItemIcon.swift
//
//  Generates the menu bar icon for each connection state. Using
//  template images (isTemplate = true) means macOS automatically tints
//  them white on dark menu bars and black on light menu bars — no
//  manual color management required.
//
//  We use SF Symbols for crisp rendering at any DPI. Falls back to a
//  procedural NSImage if SF Symbols isn't available (shouldn't happen
//  on macOS 11+, but defensive).
//

import AppKit

enum StatusItemIcon {

    /// Map each connection state to an SF Symbol name. The disconnected
    /// state uses a "lock open" outline so it's visually distinct from
    /// the protected state at a glance. Connected = solid lock.
    /// Connecting = an arrow-circle that visually implies motion (we
    /// could also animate this via a layer rotation if we want to be
    /// extra fancy in a later pass).
    static func image(for status: ConnectionStatus) -> NSImage? {
        let symbolName: String
        switch status {
        case .disconnected:
            symbolName = "shield"
        case .connecting, .reconnecting:
            symbolName = "shield.lefthalf.filled"
        case .connected:
            symbolName = "shield.fill"
        case .error:
            symbolName = "exclamationmark.shield"
        }

        let config = NSImage.SymbolConfiguration(pointSize: 16, weight: .medium)
        if let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: status.menuTitle)?
            .withSymbolConfiguration(config) {
            return image
        }
        // Fallback for older OSes (shouldn't trigger on macOS 11+)
        return NSImage(named: NSImage.lockLockedTemplateName)
    }
}
