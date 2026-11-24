//
//  SettingsView.swift
//
//  The app's one window. Lattice lives in the menu bar; this window is where
//  a customer subscribes or restores, signs in with an account number, and
//  sees their plan.
//
//    - Connect        status, Connect button and the region list
//    - General        what the app is and how to use it
//    - Account        account-number sign-in, sign out
//    - Subscription   current plan, App Store plans, Restore Purchases
//    - About          version and build
//

import StoreKit
import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var connection: ConnectionViewModel

    var body: some View {
        TabView {
            // Same controls as the menu bar panel: status, Connect, regions.
            ConnectionPopoverView(inWindow: true)
                .tabItem { Label("Connect", systemImage: "shield.lefthalf.filled") }

            GeneralSettingsView()
                .tabItem { Label("General", systemImage: "gearshape") }

            AccountSettingsView()
                .tabItem { Label("Account", systemImage: "person.crop.circle") }

            SubscriptionSettingsView()
                .tabItem { Label("Subscription", systemImage: "creditcard") }

            AboutSettingsView()
                .tabItem { Label("About", systemImage: "info.circle") }
        }
        .padding(20)
        .frame(minWidth: 560, idealWidth: 640, minHeight: 520, idealHeight: 680)
    }
}

// MARK: - General

struct GeneralSettingsView: View {
    var body: some View {
        Form {
            Section("Lattice VPN") {
                Text("Lattice lives in your menu bar. Click the shield icon at the top of the screen to choose a region and connect.")
                Text("Every connection uses a TLS 1.3 tunnel with the CNSA 2.0 algorithm suite: ML-KEM-1024, ML-DSA-87 and AES-256. All traffic goes through the tunnel while you are connected.")
                    .foregroundStyle(.secondary)
            }
            Section("Getting started") {
                Text("1. Subscribe or restore your purchase on the Subscription tab. If you already have a Lattice account number, enter it on the Account tab instead.")
                Text("2. Click the shield icon in the menu bar, pick a region, and click Connect.")
                Text("3. The first time you connect, macOS asks for permission to add a VPN configuration.")
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
            Section("Lattice account") {
                if connection.isSignedIn {
                    Label("Signed in", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    SubscriptionStatusContent()
                    Button("Sign out") { confirmSignOut = true }
                        .foregroundStyle(.red)
                        .disabled(connection.status.isBusy)
                } else {
                    Text("Lattice has no email or password. Your account number is your only credential.")
                        .foregroundStyle(.secondary)
                    Text("Subscribed with your Apple Account? Use Restore Purchases on the Subscription tab. Already have an account number? Enter it here.")
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

/// Current plan, the App Store plans, and Restore Purchases. Purchases use
/// the same StoreKit products and the same server redemption as the iPhone
/// app, so one subscription covers both.
struct SubscriptionSettingsView: View {
    @EnvironmentObject private var connection: ConnectionViewModel
    @Environment(\.openURL) private var openURL
    @StateObject private var store = StoreManager()

    @State private var busyProductID: String?
    @State private var restoring = false
    @State private var message: String?

    private let termsURL = URL(string: "https://latticevpn.ai/terms")!
    private let privacyURL = URL(string: "https://latticevpn.ai/privacy")!
    private let manageURL = URL(string: "https://apps.apple.com/account/subscriptions")!

    private var anyBusy: Bool { busyProductID != nil || restoring || connection.signInBusy }

    private var hasActivePlan: Bool {
        connection.isSignedIn
            && connection.accountStatusError == nil
            && connection.accountStatusVerifiedAt != nil
            && (connection.accountStatus?.isActive ?? false)
    }

    var body: some View {
        Form {
            Section("Current plan") {
                SubscriptionStatusContent()
            }

            if !hasActivePlan {
                Section("Choose a plan") {
                    plans
                }
            }

            Section {
                HStack {
                    Button("Restore Purchases") { restore() }
                        .disabled(anyBusy)
                        .accessibilityIdentifier("lattice-restore-purchases")
                    if restoring { ProgressView().controlSize(.small) }
                    Spacer()
                    Button("Manage Subscription") { openURL(manageURL) }
                }
                if let message {
                    Text(message).foregroundStyle(.red)
                }
            } footer: {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Payment is charged to your Apple Account at confirmation of purchase. Subscriptions renew automatically for the same price and duration unless cancelled at least 24 hours before the end of the current period. Manage or cancel any time in your Apple Account settings.")
                    HStack(spacing: 14) {
                        Button("Terms of Use") { openURL(termsURL) }
                        Button("Privacy Policy") { openURL(privacyURL) }
                    }
                    .buttonStyle(.link)
                }
                .font(.footnote)
                .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .task { await store.loadProducts() }
    }

    @ViewBuilder
    private var plans: some View {
        if store.loadState == .loading && store.products.isEmpty {
            HStack {
                ProgressView().controlSize(.small)
                Text("Loading plans…").foregroundStyle(.secondary)
            }
        }
        if let problem = store.loadState.message {
            Text(problem).foregroundStyle(.secondary)
            Button("Try Again") { Task { await store.loadProducts() } }
        }
        ForEach(store.sortedProducts, id: \.id) { product in
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(product.displayName).font(.headline)
                    Text(product.description)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    if let period = product.subscription?.subscriptionPeriod {
                        Text("\(product.displayPrice) per \(Self.unitName(period))")
                            .font(.subheadline)
                    }
                }
                Spacer()
                if busyProductID == product.id {
                    ProgressView().controlSize(.small)
                } else {
                    Button("Subscribe") { buy(product) }
                        .buttonStyle(.borderedProminent)
                        .disabled(anyBusy)
                }
            }
            .padding(.vertical, 2)
        }
    }

    private static func unitName(_ period: Product.SubscriptionPeriod) -> String {
        let unit: String
        switch period.unit {
        case .day:   unit = "day"
        case .week:  unit = "week"
        case .month: unit = "month"
        case .year:  unit = "year"
        @unknown default: unit = "period"
        }
        return period.value == 1 ? unit : "\(period.value) \(unit)s"
    }

    private func buy(_ product: Product) {
        guard !anyBusy else { return }
        message = nil
        busyProductID = product.id
        Task {
            defer { busyProductID = nil }
            do {
                switch try await store.purchase(product) {
                case .success(let number):
                    await signIn(with: number)
                case .pending:
                    message = "Your purchase is pending approval. You'll be signed in once it's approved."
                case .cancelled:
                    break
                }
            } catch {
                message = error.localizedDescription
            }
        }
    }

    private func restore() {
        guard !anyBusy else { return }
        message = nil
        restoring = true
        Task {
            defer { restoring = false }
            do {
                await signIn(with: try await store.restore())
            } catch {
                message = error.localizedDescription
            }
        }
    }

    /// Feed the account number the server issued for this subscription into
    /// the normal sign-in path, then refresh the plan shown above.
    private func signIn(with number: String) async {
        guard !number.isEmpty else {
            message = "Subscription confirmed, but no account number was returned. Try Restore Purchases."
            return
        }
        if let error = await connection.signIn(number) {
            message = error
        } else {
            await connection.refreshAccountStatus()
        }
    }
}

/// Only validated metadata is displayed. A failed refresh never looks like an
/// inactive plan, and the account credential is never included in this view.
private struct SubscriptionStatusContent: View {
    @EnvironmentObject private var connection: ConnectionViewModel

    var body: some View {
        if !connection.isSignedIn {
            Text("No subscription on this Mac yet. Choose a plan below, or use Restore Purchases if you already subscribed with your Apple Account.")
                .foregroundStyle(.secondary)
        } else {
            if let error = connection.accountStatusError {
                Text("Subscription could not be verified").font(.headline)
                Text(error).foregroundStyle(.red)
            } else if let status = connection.accountStatus, connection.accountStatusVerifiedAt != nil {
                Text(status.isActive ? "Active subscription" : "No active subscription")
                    .font(.headline)
                LabeledContent("Plan", value: status.tier.isEmpty ? "None" : status.tier.capitalized)
                LabeledContent("Devices", value: "\(status.deviceCount) of \(status.deviceLimit)")
                if let expiry = status.activeUntilDate, expiry > Date(timeIntervalSince1970: 0) {
                    LabeledContent("Paid through", value: expiry.formatted(date: .abbreviated, time: .shortened))
                }
            } else {
                Text("Checking your subscription…").foregroundStyle(.secondary)
            }
            HStack {
                Button("Refresh") { Task { await connection.refreshAccountStatus() } }
                    .disabled(connection.accountRefreshBusy)
                if connection.accountRefreshBusy { ProgressView().controlSize(.small) }
            }
        }
    }
}

// MARK: - About

struct AboutSettingsView: View {
    @Environment(\.openURL) private var openURL

    var body: some View {
        Form {
            Section("Lattice VPN") {
                LabeledContent("Version", value: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "")
                LabeledContent("Build", value: Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "")
                LabeledContent("Encryption", value: "CNSA 2.0 (TLS 1.3)")
            }
            Section("Support") {
                Button("support@latticevpn.ai") {
                    if let url = URL(string: "mailto:support@latticevpn.ai") { openURL(url) }
                }
                .buttonStyle(.link)
            }
        }
        .formStyle(.grouped)
    }
}

#Preview {
    SettingsView()
        .environmentObject(ConnectionViewModel())
}
