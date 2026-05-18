//
//  MenuBarController.swift
//
//  Owns the lifecycle of the NSStatusItem (the icon you see in the
//  top-right of the menu bar) and the NSPopover (the connect/disconnect
//  panel that drops down when you click it).
//
//  Click handling:
//    - Left click  -> toggle popover open/closed
//    - Right click -> show a small context menu (Connect, Disconnect,
//                     Preferences, Quit) for users who prefer that
//                     interaction model. Matches macOS conventions for
//                     menu bar utilities.
//

import AppKit
import SwiftUI
import Combine

@MainActor
final class MenuBarController: NSObject {

    private let statusItem: NSStatusItem
    private let popover: NSPopover
    private let connection: ConnectionViewModel

    /// Used to detect taps outside the popover so we can dismiss it,
    /// the same way a real Mac menu bar app behaves. Without this, the
    /// popover sticks around when the user clicks elsewhere.
    private var eventMonitor: Any?

    init(connection: ConnectionViewModel) {
        self.connection = connection
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        self.popover = NSPopover()
        super.init()

        configureStatusButton()
        configurePopover()
    }

    deinit {
        if let monitor = eventMonitor {
            NSEvent.removeMonitor(monitor)
        }
    }

    // MARK: - Status button

    private func configureStatusButton() {
        guard let button = statusItem.button else { return }
        // Default to the "disconnected" icon. AppDelegate will start
        // pushing real state updates via `updateIcon(for:)` as soon as
        // the connection view model produces its first value.
        button.image = StatusItemIcon.image(for: .disconnected)
        button.image?.isTemplate = true   // Lets macOS tint it correctly in light/dark menu bar
        button.target = self
        button.action = #selector(handleButtonClick(_:))
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        button.toolTip = "Lattice VPN"
    }

    @objc private func handleButtonClick(_ sender: NSStatusBarButton) {
        guard let event = NSApp.currentEvent else { return }
        if event.type == .rightMouseUp {
            presentRightClickMenu(at: sender)
        } else {
            togglePopover(at: sender)
        }
    }

    // MARK: - Popover

    private func configurePopover() {
        popover.behavior = .transient   // Auto-dismisses on click-outside
        popover.animates = true
        popover.contentSize = NSSize(width: 360, height: 480)
        popover.contentViewController = NSHostingController(
            rootView: ConnectionPopoverView()
                .environmentObject(connection)
                .frame(width: 360, height: 480)
        )
    }

    private func togglePopover(at sender: NSStatusBarButton) {
        if popover.isShown {
            popover.performClose(nil)
        } else {
            popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
            // Bring the app forward so the popover gets keyboard focus
            // and OS chrome (e.g. cursor changes inside text fields).
            NSApp.activate(ignoringOtherApps: true)
            startEventMonitor()
        }
    }

    private func startEventMonitor() {
        if let monitor = eventMonitor {
            NSEvent.removeMonitor(monitor)
        }
        // Listen for clicks outside our popover. NSPopover's .transient
        // behavior is mostly fine on its own, but a global monitor adds
        // a backstop for edge cases (clicks on certain system UI).
        eventMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            self?.popover.performClose(nil)
        }
    }

    // MARK: - Right-click context menu

    private func presentRightClickMenu(at button: NSStatusBarButton) {
        let menu = NSMenu()
        let statusItemLabel = NSMenuItem(title: connection.status.menuTitle, action: nil, keyEquivalent: "")
        statusItemLabel.isEnabled = false
        menu.addItem(statusItemLabel)
        menu.addItem(.separator())

        if connection.status.isConnected {
            menu.addItem(withAction: #selector(disconnect), target: self, title: "Disconnect")
        } else {
            menu.addItem(withAction: #selector(quickConnect), target: self, title: "Connect to fastest region")
        }
        menu.addItem(.separator())
        menu.addItem(withAction: #selector(openPreferences), target: self, title: "Preferences…", keyEquivalent: ",")
        menu.addItem(.separator())
        menu.addItem(withAction: #selector(quit), target: self, title: "Quit Lattice VPN", keyEquivalent: "q")

        statusItem.menu = menu
        button.performClick(nil)
        // Important: clear the menu after showing it, otherwise the
        // status item *only* shows the menu and the left-click popover
        // stops working.
        statusItem.menu = nil
    }

    // MARK: - Menu actions

    @objc private func quickConnect() {
        Task { await connection.connect() }
    }

    @objc private func disconnect() {
        Task { await connection.disconnect() }
    }

    @objc private func openPreferences() {
        if #available(macOS 14.0, *) {
            NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
        } else {
            NSApp.sendAction(Selector(("showPreferencesWindow:")), to: nil, from: nil)
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    // MARK: - Icon updates (called from AppDelegate)

    func updateIcon(for status: ConnectionStatus) {
        statusItem.button?.image = StatusItemIcon.image(for: status)
        statusItem.button?.image?.isTemplate = true
        statusItem.button?.toolTip = "Lattice VPN — \(status.menuTitle)"
    }
}

// MARK: - NSMenu convenience

private extension NSMenu {
    func addItem(withAction action: Selector, target: AnyObject, title: String, keyEquivalent: String = "") {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: keyEquivalent)
        item.target = target
        addItem(item)
    }
}
