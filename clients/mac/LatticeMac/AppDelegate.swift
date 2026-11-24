//
//  AppDelegate.swift
//
//  Owns the menu bar status item and bootstraps the connection view
//  model. Because LSUIElement=YES suppresses the Dock icon, we DON'T
//  get the default SwiftUI window — the user's only entry point is the
//  status item we create here, plus the Settings window opened from the
//  popover.
//

import AppKit
import SwiftUI
import Combine

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    /// The status bar item we manage from app launch -> app quit.
    /// Held strongly here so it isn't deallocated when the popover dismisses.
    private var menuBar: MenuBarController?
    private var settingsWindow: NSWindow?

    /// Shared view model. Created here so MenuBarController and the
    /// SwiftUI App body both reference the same instance via
    /// EnvironmentObject downstream.
    let connection = ConnectionViewModel()

    /// Combine subscriptions kept alive for the app's lifetime.
    private var cancellables = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Wire up the menu bar. The MenuBarController owns the
        // NSStatusItem and NSPopover; we hand it our shared model so the
        // popover content can read/mutate the same state the Settings
        // scene sees.
        menuBar = MenuBarController(connection: connection) { [weak self] in
            self?.showLatticeSettings(nil)
        }

        #if DEBUG
        // Lab only: `-LatticeCNSA2Lab <base64 JSON>` starts the CNSA 2.0
        // (TLS 1.3) tunnel against a development gateway.
        if let blob = UserDefaults.standard.string(forKey: "LatticeCNSA2Lab") {
            Task { @MainActor in await self.connection.startCNSA2Lab(blob) }
        }
        #endif

        // Mirror the connection state into the menu bar icon. Changing
        // the icon based on state (idle / connecting / connected /
        // error) is the most important always-visible feedback the user
        // gets — they should be able to glance up and know if traffic is
        // protected without opening the popover.
        connection.$status
            .receive(on: DispatchQueue.main)
            .sink { [weak self] status in
                self?.menuBar?.updateIcon(for: status)
            }
            .store(in: &cancellables)

        // Kick off any boot-time work: load the last-used region,
        // restore the saved tunnel preference from NEVPNManager, fetch
        // current public IP for the popover's "your IP" label.
        Task { await connection.bootstrap() }
        DispatchQueue.main.async { [weak self] in self?.showLatticeSettings(nil) }
    }

    /// Own one predictable window: opening the app must never appear to do nothing.
    @objc func showLatticeSettings(_ sender: Any?) {
        if settingsWindow == nil {
            let controller = NSHostingController(rootView:
                SettingsView().environmentObject(connection))
            let window = NSWindow(contentViewController: controller)
            window.title = "Lattice VPN"
            window.setContentSize(NSSize(width: 640, height: 680))
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            window.isReleasedWhenClosed = false
            window.center()
            settingsWindow = window
        }
        settingsWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showLatticeSettings(nil)
        return true
    }

    /// We never want the app to terminate just because the (non-existent)
    /// last window closed. A menu bar app lives until the user explicitly
    /// quits from the popover.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return false
    }
}
