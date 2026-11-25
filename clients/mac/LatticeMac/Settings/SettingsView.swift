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

    private enum Page: String, CaseIterable, Identifiable {
        case connect = "Connect", general = "General", account = "Account", subscription = "Subscription", about = "About"
        var id: String { rawValue }
        var symbol: String {
            switch self {
            case .connect: return "shield.lefthalf.filled"
            case .general: return "gearshape"
            case .account: return "person.crop.circle"
            case .subscription: return "creditcard"
            case .about: return "info.circle"
            }
        }
    }

    @State private var page: Page = .connect

    var body: some View {
        VStack(spacing: 0) {
            // A tab bar of our own: the system's tabs are too small to read on a large display.
            HStack(spacing: 10) {
                ForEach(Page.allCases) { item in
                    Button {
                        page = item
                    } label: {
                        Label(item.rawValue, systemImage: item.symbol)
                            .font(.system(size: 21, weight: .semibold))
                            .foregroundStyle(page == item ? LatticeTheme.text : LatticeTheme.muted)
                            .padding(.horizontal, 20)
                            .padding(.vertical, 11)
                            .background(Capsule().fill(page == item ? LatticeTheme.navyRaised : Color.clear))
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(page == item ? .isSelected : [])
                }
            }
            .padding(.top, 6)
            .padding(.bottom, 14)

            Group {
                switch page {
                // Same controls as the menu bar panel, plus the globe.
                case .connect: ConnectionPopoverView(inWindow: true)
                case .general: GeneralSettingsView()
                case .account: AccountSettingsView()
                case .subscription: SubscriptionSettingsView()
                case .about: AboutSettingsView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .padding(20)
        .background(LatticeTheme.navy)
        .font(.system(size: 21))
        .controlSize(.extraLarge)
        .frame(minWidth: 1240, idealWidth: 1500, minHeight: 800, idealHeight: 900)
    }
}

// MARK: - Page style

/// A page of the window: cards stacked down the full width, on the dark blue background.
private struct LatticePage<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                content
            }
            .padding(34)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// One titled block on a page.
private struct LatticeCard<Content: View>: View {
    let title: String?
    @ViewBuilder var content: Content

    init(_ title: String?, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            if let title {
                Text(title)
                    .font(.system(size: 30, weight: .semibold))
                    .foregroundStyle(LatticeTheme.text)
            }
            content
        }
        .padding(28)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(LatticeTheme.navyRaised))
    }
}

/// A label on the left and its value on the right.
private struct LatticeRow: View {
    let label: String
    let value: String

    init(_ label: String, _ value: String) {
        self.label = label
        self.value = value
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).foregroundStyle(.secondary)
            Spacer(minLength: 16)
            Text(value).fontWeight(.medium)
        }
        .padding(.vertical, 4)
    }
}

/// Buttons sized to match the page text. The system's buttons keep small text on the Mac.
private struct LatticeButtonStyle: ButtonStyle {
    var prominent = false
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 22, weight: .semibold))
            .padding(.horizontal, 24)
            .padding(.vertical, 12)
            .background(
                Capsule().fill(prominent ? Color.accentColor : LatticeTheme.navy)
            )
            .overlay(Capsule().stroke(LatticeTheme.muted.opacity(prominent ? 0 : 0.45), lineWidth: 1))
            .opacity(isEnabled ? (configuration.isPressed ? 0.7 : 1) : 0.45)
            .contentShape(Capsule())
    }
}

private extension View {
    /// Text and control sizes shared by the pages.
    func latticePage() -> some View {
        self
            .font(.system(size: 24))
            .controlSize(.extraLarge)
            .buttonStyle(LatticeButtonStyle())
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(LatticeTheme.navy)
    }
}

// MARK: - General

struct GeneralSettingsView: View {
    var body: some View {
        LatticePage {
            LatticeCard("Lattice VPN") {
                Text("Lattice lives in your menu bar. Click the shield icon at the top of the screen to choose a region and connect.")
                Text("Every connection uses a TLS 1.3 tunnel with the CNSA 2.0 algorithm suite: ML-KEM-1024, ML-DSA-87 and AES-256. All traffic goes through the tunnel while you are connected.")
                    .foregroundStyle(.secondary)
            }
            LatticeCard("Getting started") {
                Text("1. Subscribe or restore your purchase on the Subscription tab. If you already have a Lattice account number, enter it on the Account tab instead.")
                Text("2. Click the shield icon in the menu bar, pick a region, and click Connect.")
                Text("3. The first time you connect, macOS asks for permission to add a VPN configuration.")
            }
        }
        .latticePage()
    }
}

// MARK: - Account

struct AccountSettingsView: View {
    @EnvironmentObject private var connection: ConnectionViewModel
    @State private var accountNumber = ""
    @State private var signInError: String?
    @State private var confirmSignOut = false

    var body: some View {
        LatticePage {
            LatticeCard("Lattice account") {
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
                            .buttonStyle(LatticeButtonStyle(prominent: true))
                            .disabled(connection.signInBusy || accountNumber.isEmpty)
                        if connection.signInBusy { ProgressView().controlSize(.regular) }
                    }
                    if let signInError {
                        Text(signInError).foregroundStyle(.red)
                    }
                }
            }
        }
        .latticePage()
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
        LatticePage {
            LatticeCard("Current plan") {
                SubscriptionStatusContent()
            }

            if !hasActivePlan {
                LatticeCard("Choose a plan") {
                    plans
                }
            }

            LatticeCard(nil) {
                HStack {
                    Button("Restore Purchases") { restore() }
                        .disabled(anyBusy)
                        .accessibilityIdentifier("lattice-restore-purchases")
                    if restoring { ProgressView().controlSize(.regular) }
                    Spacer()
                    Button("Manage Subscription") { openURL(manageURL) }
                }
                if let message {
                    Text(message).foregroundStyle(.red)
                }
            }
            LatticeCard(nil) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Payment is charged to your Apple Account at confirmation of purchase. Subscriptions renew automatically for the same price and duration unless cancelled at least 24 hours before the end of the current period. Manage or cancel any time in your Apple Account settings.")
                    HStack(spacing: 14) {
                        Button("Terms of Use") { openURL(termsURL) }
                        Button("Privacy Policy") { openURL(privacyURL) }
                    }
                    .buttonStyle(.link)
                }
                .font(.system(size: 21))
                .foregroundStyle(.secondary)
            }
        }
        .latticePage()
        .task { await store.loadProducts() }
    }

    @ViewBuilder
    private var plans: some View {
        if store.loadState == .loading && store.products.isEmpty {
            HStack {
                ProgressView().controlSize(.regular)
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
                    Text(product.displayName).font(.system(size: 30, weight: .semibold))
                    Text(product.description)
                        .font(.system(size: 24))
                        .foregroundStyle(.secondary)
                    if let period = product.subscription?.subscriptionPeriod {
                        Text("\(product.displayPrice) per \(Self.unitName(period))")
                            .font(.system(size: 24))
                    }
                }
                Spacer()
                if busyProductID == product.id {
                    ProgressView().controlSize(.regular)
                } else {
                    Button("Subscribe") { buy(product) }
                        .buttonStyle(LatticeButtonStyle(prominent: true))
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
                Text("Subscription could not be verified").font(.system(size: 30, weight: .semibold))
                Text(error).foregroundStyle(.red)
            } else if let status = connection.accountStatus, connection.accountStatusVerifiedAt != nil {
                Text(status.isActive ? "Active subscription" : "No active subscription")
                    .font(.system(size: 30, weight: .semibold))
                LatticeRow("Plan", status.tier.isEmpty ? "None" : status.tier.capitalized)
                LatticeRow("Devices", "\(status.deviceCount) of \(status.deviceLimit)")
                if let expiry = status.activeUntilDate, expiry > Date(timeIntervalSince1970: 0) {
                    LatticeRow("Paid through", expiry.formatted(date: .abbreviated, time: .shortened))
                }
            } else {
                Text("Checking your subscription…").foregroundStyle(.secondary)
            }
            HStack {
                Button("Refresh") { Task { await connection.refreshAccountStatus() } }
                    .disabled(connection.accountRefreshBusy)
                if connection.accountRefreshBusy { ProgressView().controlSize(.regular) }
            }
        }
    }
}

// MARK: - About

struct AboutSettingsView: View {
    @Environment(\.openURL) private var openURL
    @State private var showLicenses = false

    /// The license notices shipped inside the app.
    private static let notices: String = {
        guard let url = Bundle.main.url(forResource: "ThirdPartyNotices", withExtension: "txt"),
              let text = try? String(contentsOf: url, encoding: .utf8) else {
            return "Lattice VPN includes OpenSSL, used under the Apache License, Version 2.0. The full license text could not be loaded; see latticevpn.ai."
        }
        return text
    }()

    var body: some View {
        LatticePage {
            LatticeCard("Lattice VPN") {
                LatticeRow("Version", Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "")
                LatticeRow("Build", Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "")
                LatticeRow("Encryption", "CNSA 2.0 (TLS 1.3)")
            }
            LatticeCard("Support") {
                Button("support@latticevpn.ai") {
                    if let url = URL(string: "mailto:support@latticevpn.ai") { openURL(url) }
                }
                .buttonStyle(.link)
            }
            LatticeCard("Open-source software") {
                Text("Lattice VPN includes OpenSSL, used under the Apache License, Version 2.0.")
                    .foregroundStyle(.secondary)
                Button(showLicenses ? "Hide licenses" : "Show licenses") { showLicenses.toggle() }
                if showLicenses {
                    Text(Self.notices)
                        .font(.system(size: 15, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .latticePage()
    }
}

#Preview {
    SettingsView()
        .environmentObject(ConnectionViewModel())
}
