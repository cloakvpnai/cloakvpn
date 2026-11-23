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
    var body: some View {
        Form {
            Section("Lattice VPN") {
                Text("Lattice lives in your menu bar. Sign in on the Account tab, choose a region, then connect from the menu bar.")
            }
            Section("Startup") {
                Text("Launch at login and automatic connection are not available in this build.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Account

struct AccountSettingsView: View {
    @EnvironmentObject private var connection: ConnectionViewModel
    @State private var accountNumber = ""
    @State private var signInError: String?
    @State private var confirmSignOut = false

    var body: some View {
        Form {
            Section("Apple subscription support") {
                Text("This development build cannot yet restore your existing Apple subscription. Apple Account sign-in and purchase restoration are not implemented here.")
                Text("Do not enter your Apple password or purchase another plan. The account-number field below is for existing direct Lattice accounts only.")
                    .foregroundStyle(.secondary)
            }
            Section("Direct Lattice account (optional)") {
                if connection.isSignedIn {
                    Label("Signed in", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    SubscriptionStatusContent()
                    Button("Sign out") { confirmSignOut = true }
                        .foregroundStyle(.red)
                        .disabled(connection.status.isBusy)
                } else {
                    Text("Enter the account number from your Lattice subscription.")
                        .foregroundStyle(.secondary)
                    SecureField("Account number", text: $accountNumber)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { signIn() }
                        .accessibilityIdentifier("lattice-account-number")
                    HStack {
                        Button("Sign in") { signIn() }
                            .buttonStyle(.borderedProminent)
                            .disabled(connection.signInBusy || accountNumber.isEmpty)
                        if connection.signInBusy { ProgressView().controlSize(.small) }
                    }
                    if let signInError {
                        Text(signInError).foregroundStyle(.red)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .confirmationDialog("Sign out of Lattice? This disconnects the VPN.", isPresented: $confirmSignOut) {
            Button("Sign out", role: .destructive) { Task { await connection.signOut() } }
        }
    }

    private func signIn() {
        guard !connection.signInBusy else { return }
        signInError = nil
        Task {
            signInError = await connection.signIn(accountNumber)
            if signInError == nil { accountNumber = "" }
        }
    }
}

// MARK: - Subscription

struct SubscriptionSettingsView: View {
    @EnvironmentObject private var connection: ConnectionViewModel

    var body: some View {
        Form {
            Section("Test build limitation") {
                Text("Existing Apple subscriptions are not linked in this build. Subscription status below applies only to a signed-in direct Lattice account.")
            }
            Section("Current plan") {
                SubscriptionStatusContent()
            }
            Section {
                Link("Manage subscription at latticevpn.ai", destination: URL(string: "https://latticevpn.ai")!)
            }
        }
        .formStyle(.grouped)
    }
}

/// Only validated metadata is displayed. A failed refresh never looks like an
/// inactive plan, and the account credential is never included in this view.
private struct SubscriptionStatusContent: View {
    @EnvironmentObject private var connection: ConnectionViewModel

    var body: some View {
        if !connection.isSignedIn {
            Text("Sign in on the Account tab to see your subscription.")
                .foregroundStyle(.secondary)
        } else {
            if let error = connection.accountStatusError {
                Text("Subscription could not be verified").font(.headline)
                Text(error).foregroundStyle(.red)
            } else if let status = connection.accountStatus, connection.accountStatusVerifiedAt != nil {
                Text(status.isActive ? "Active subscription" : "No active subscription reported by Lattice")
                    .font(.headline)
                LabeledContent("Plan", value: status.tier.isEmpty ? "None" : status.tier.capitalized)
                LabeledContent("Devices", value: "\(status.deviceCount) of \(status.deviceLimit)")
                if let expiry = status.activeUntilDate, expiry > Date(timeIntervalSince1970: 0) {
                    LabeledContent("Paid through", value: expiry.formatted(date: .abbreviated, time: .shortened))
                }
                if let checked = connection.accountStatusVerifiedAt {
                    LabeledContent("Verified", value: checked.formatted(date: .abbreviated, time: .standard))
                }
            } else {
                Text("Subscription has not been verified.").foregroundStyle(.secondary)
            }
            HStack {
                Button("Refresh subscription") { Task { await connection.refreshAccountStatus() } }
                    .disabled(connection.accountRefreshBusy)
                if connection.accountRefreshBusy { ProgressView().controlSize(.small) }
            }
        }
    }
}

// MARK: - Advanced

struct AdvancedSettingsView: View {
    var body: some View {
        Form {
            Section("Network protection") {
                Text("Custom network protection settings are not available in this build.")
                    .foregroundStyle(.secondary)
            }
            Section("Build") {
                LabeledContent("Version", value: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—")
                LabeledContent("Build", value: Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "—")
            }
        }
        .formStyle(.grouped)
    }
}

#Preview {
    SettingsView()
        .environmentObject(ConnectionViewModel())
}
