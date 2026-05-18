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
        menuBar = MenuBarController(connection: connection)

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
    }

    /// We never want the app to terminate just because the (non-existent)
    /// last window closed. A menu bar app lives until the user explicitly
    /// quits from the popover.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return false
    }
}
