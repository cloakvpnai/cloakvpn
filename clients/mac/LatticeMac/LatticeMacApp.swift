//
//  LatticeMacApp.swift
//  LatticeMac — Lattice VPN for macOS
//
//  Menu-bar-first VPN client. The app is configured with LSUIElement=YES
//  so it does NOT show in the Dock or app switcher — only as a status
//  icon in the top-right of the menu bar (NordVPN / ExpressVPN / Mullvad
//  pattern). A separate Settings scene opens as a window when the user
//  picks "Preferences…" from the popover.
//
//  The bulk of menu-bar lifecycle work happens in `AppDelegate` and
//  `MenuBarController`. The SwiftUI `App` body exists mostly to host the
//  Settings scene (which gets its own window via `Settings { … }` —
//  SwiftUI's canonical way to register a preferences window on macOS).
//

import SwiftUI

@main
struct LatticeMacApp: App {

    // AppDelegate handles the AppKit-side menu bar bookkeeping. SwiftUI
    // on macOS still needs an NSApplicationDelegate to own the status
    // item — the `Settings` scene below covers the windowed UI surface.
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    // App-wide connection state. Lives at the App level so the popover
    // and the Settings window share the same source of truth.
    @StateObject private var connection = ConnectionViewModel()

    var body: some Scene {
        // The Settings scene is what users open via the popover's
        // "Preferences…" button (or ⌘,). SwiftUI auto-creates the window
        // chrome, title bar, and toolbar; we just provide the content.
        Settings {
            SettingsView()
                .environmentObject(connection)
                .frame(minWidth: 560, minHeight: 420)
        }
    }
}
