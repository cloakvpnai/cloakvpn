//
//  SettingsView.swift
//
//  Top-level Mac Settings scene. macOS Settings windows are tab-based
//  (System Settings convention) and we follow that — four tabs:
//
//    - General        general preferences, launch at login, auto-connect
//    - Account        signed-in user, JWT status, sign out
//    - Subscription   plan + renewal (App Store: StoreKit; Direct: license key)
//    - Advanced       kill switch, exclude apps, diagnostics, server pubkey
//
//  This file is the container; each tab is its own View. Most are stubs
//  in Phase 1 with the structure laid out so Phase 4 can fill them in
//  one at a time without restructuring the navigation.
//

import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var connection: ConnectionViewModel

    var body: some View {
        TabView {
            GeneralSettingsView()
                .tabItem { Label("General", systemImage: "gearshape") }

            AccountSettingsView()
                .tabItem { Label("Account", systemImage: "person.crop.circle") }

            SubscriptionSettingsView()
                .tabItem { Label("Subscription", systemImage: "creditcard") }

            AdvancedSettingsView()
                .tabItem { Label("Advanced", systemImage: "slider.horizontal.3") }
        }
        .padding(20)
        .frame(minWidth: 560, idealWidth: 620, minHeight: 420, idealHeight: 480)
    }
}

// MARK: - General

struct GeneralSettingsView: View {
    @AppStorage("launchAtLogin")        private var launchAtLogin = false
    @AppStorage("autoConnectUntrusted") private var autoConnectUntrusted = true
    @AppStorage("showInDock")           private var showInDock = false
    @AppStorage("notifyOnConnect")      private var notifyOnConnect = true

    var body: some View {
        Form {
            Section("Startup") {
                Toggle("Launch Lattice VPN at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, newValue in
                        // TODO[Phase 4]: wire to SMAppService.mainApp.register()
                        // / .unregister() so the macOS Login Items service tracks us.
                        _ = newValue
                    }
                Toggle("Show in Dock (in addition to menu bar)", isOn: $showInDock)
                    .help("Requires app restart.")
            }
            Section("Auto-connect") {
                Toggle("Connect automatically on untrusted Wi-Fi", isOn: $autoConnectUntrusted)
                    .help("Untrusted = any network not in your saved list. Manage in Network → Trusted Wi-Fi.")
                NavigationLink("Manage trusted Wi-Fi networks…") {
                    Text("Trusted networks list — Phase 4")
                        .padding()
                }
            }
            Section("Notifications") {
                Toggle("Notify when connected / disconnected", isOn: $notifyOnConnect)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Account

struct AccountSettingsView: View {
    @State private var email: String = ""
    @State private var isSignedIn = false

    var body: some View {
        Form {
            Section {
                if isSignedIn {
                    LabeledContent("Signed in as", value: email.isEmpty ? "—" : email)
                    LabeledContent("Subscription", value: "Loading…")
                    Button("Sign out") { isSignedIn = false; email = "" }
                        .foregroundStyle(.red)
                } else {
                    HStack {
                        Image(systemName: "person.crop.circle.badge.questionmark")
                            .font(.system(size: 32))
                            .foregroundStyle(.secondary)
                        VStack(alignment: .leading) {
                            Text("Not signed in")
                                .font(.system(size: 13, weight: .semibold))
                            Text("Sign in to manage your subscription and sync settings across devices.")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 4)
                    Button("Sign in with Apple") {
                        // TODO[Phase 4]: wire ASAuthorizationController + AppleIDProvider
                        // and exchange the credential for a Cloak API JWT (matches the
                        // iOS flow in CloakAuthClient.swift).
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Subscription

struct SubscriptionSettingsView: View {
    var body: some View {
        Form {
            Section("Current plan") {
                LabeledContent("Plan",          value: "Lattice Pro")
                LabeledContent("Renews",        value: "—")
                LabeledContent("Devices",       value: "—")
            }
            Section {
                // We branch UX based on distribution channel — App Store
                // builds open the iOS-style manage-subscription sheet;
                // Direct Download builds open the customer portal.
                #if APPSTORE_BUILD
                Button("Manage subscription") {
                    // TODO[Phase 4]: AppStore.showManageSubscriptions(in:)
                }
                #else
                Button("Enter license key…") {
                    // TODO[Phase 4]: license-key entry sheet, validates against
                    // cloak-api-server /v1/license/redeem
                }
                Button("Buy a license") {
                    // TODO[Phase 4]: opens https://latticevpn.ai/pricing in default browser
                }
                #endif
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Advanced

struct AdvancedSettingsView: View {
    @AppStorage("killSwitch")     private var killSwitch = true
    @AppStorage("blockLAN")       private var blockLAN = false
    @AppStorage("dnsLeakProtect") private var dnsLeakProtect = true

    var body: some View {
        Form {
            Section("Network protection") {
                Toggle("Kill switch (block traffic if VPN drops)", isOn: $killSwitch)
                    .help("Uses includeAllNetworks=true on the NEPacketTunnelProvider — prevents IP leaks during reconnects.")
                Toggle("Block LAN access while connected", isOn: $blockLAN)
                Toggle("DNS leak protection", isOn: $dnsLeakProtect)
            }
            Section("Diagnostics") {
                Button("Export diagnostic log…") {
                    // TODO[Phase 4]: collect provider log, redact private keys, save bundle
                }
                Button("Reset stored credentials") {
                    // TODO[Phase 4]: clears App Group keychain + JWT, prompts confirm
                }
                .foregroundStyle(.red)
            }
            Section("Build") {
                LabeledContent("Version", value: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—")
                LabeledContent("Build",   value: Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "—")
            }
        }
        .formStyle(.grouped)
    }
}

#Preview {
    SettingsView()
        .environmentObject(ConnectionViewModel())
}
