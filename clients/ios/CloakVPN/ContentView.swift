import SwiftUI
import UniformTypeIdentifiers

// Note on RosenpassFFI: the Swift bindings (rosenpassffi.swift) are
// compiled directly into the CloakVPN app target alongside this file,
// so types like `generateStaticKeypair()` and `StaticKeypair` are
// already in scope — no `import` needed. The bindings themselves
// `import rosenpassffiFFI` (the C module from the xcframework) under
// the hood; that's the only module name in this build.

/// Cloak VPN design system — single source of truth for brand color
/// and typography choices. Centralized here so we can rev the visual
/// language in one place rather than chasing magic constants across
/// the view tree.
enum CloakDesign {
    /// Brand green — used for the Connect button, the QUICK CONNECT
    /// section accent, and connected-state status indicators. Sits
    /// just below pure neon (#00FF66) for a confident-but-not-loud
    /// look. Comparable to PIA's connected green.
    static let brandGreen = Color(red: 0.12, green: 0.74, blue: 0.36)

    /// Slightly deeper green for pressed / disabled states.
    static let brandGreenDeep = Color(red: 0.08, green: 0.58, blue: 0.28)

    /// Headline font — serif design, semibold weight. Apple's serif
    /// face on iOS is "New York"; using it here for the brand title
    /// + Connect button gives the app a premium-tech feel (think
    /// Linear's web type, Stripe's brand) without bundling a custom
    /// font. Sans-serif body keeps reading speed unaffected.
    static func headline(size: CGFloat, weight: Font.Weight = .semibold) -> Font {
        .system(size: size, weight: weight, design: .serif)
    }

    /// Body font — default SF Pro, refined weight. Avoids the chunky
    /// feel of `.bold()` in favor of `.semibold` with letter-tracking
    /// for premium polish.
    static func body(size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .default)
    }

    /// Small-caps style label (for section headers like "QUICK CONNECT").
    static func sectionLabel() -> Font {
        .system(size: 11, weight: .semibold, design: .default)
    }
}

struct ContentView: View {
    @EnvironmentObject var tunnel: TunnelManager
    @State private var configText: String = ""
    @State private var showingImport = false
    @State private var showingFileImporter = false
    @State private var errorMsg: String?

    // Runtime smoke test for the post-quantum FFI. Pressing the button
    // calls into Rust, generates a Classic McEliece-460896 + ML-KEM-768
    // keypair, and reports the key sizes back. Also serves as a memory
    // budget canary — McEliece keygen peaks at 2-4 MB working set; if
    // we ever try to call this from the NetworkExtension (which we
    // shouldn't — see docs/IOS_PQC.md) it will crash on the 50 MiB
    // limit.
    @State private var pqcStatus: String = "PQC: not tested"
    @State private var pqcRunning = false

    // Layer 4 of the NE wedge auto-recovery story — manual reset
    // escape hatch for the rare case where Layers 1-3 have all failed
    // (rate limits hit, repeated wedges, etc.) and the user is stuck.
    // Confirmed via alert because the operation prompts for VPN
    // permission and is destructive enough to warrant intent.
    @State private var showingResetConfirm = false
    @State private var resetInProgress = false

    // "Add Region" provisioning sheet (task #3 — Phase 1->2 in-app
    // provisioning). User enters a region URL + API key; the app POSTs
    // its locally-generated public keys to cloak-api-server and
    // auto-imports the returned config. No more manual scp+base64
    // dance per region.
    @State private var showingAddRegion = false
    @State private var addRegionURL: String = ""
    @State private var addRegionAPIKey: String = ""
    @State private var addRegionPeerName: String = ""
    @State private var addRegionInProgress = false

    // "More…" sheet for developer / admin features (manual config import,
    // PQC FFI smoke test, custom region URL+token). The customer-facing
    // path is the flag strip in the main view; everything else lives
    // here so the main view stays clean.
    @State private var showingMoreSheet = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 18) {
                statusBadge
                bigConnectButton
                currentRegionCard
                quickConnectStrip
                pqcStatusLine
                ipDisplayPanel

                Spacer(minLength: 8)

                bottomToolbar
            }
            .padding()
            .navigationTitle("Cloak VPN")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                // Custom serif title for premium-tech brand feel.
                // Replaces SwiftUI's default sans-serif navigation title.
                ToolbarItem(placement: .principal) {
                    Text("Cloak VPN")
                        .font(CloakDesign.headline(size: 18, weight: .semibold))
                        .tracking(0.8)
                }
                // Hamburger button — opens the PIA-style Settings drawer
                // with account info, region selection link, settings,
                // about, etc.
                ToolbarItem(placement: .navigationBarLeading) {
                    Button {
                        showingMoreSheet = true
                    } label: {
                        Image(systemName: "line.3.horizontal")
                    }
                }
            }
            .alert("Error", isPresented: .constant(errorMsg != nil), actions: {
                Button("OK") { errorMsg = nil }
            }, message: { Text(errorMsg ?? "") })
            // Region-selection errors get their own alert so the user
            // immediately sees why a flag-tap didn't take effect (vs.
            // the silent no-op we shipped initially). Tied to
            // tunnel.lastRegionError; tapping Dismiss clears it.
            .alert("Region select failed", isPresented: .constant(tunnel.lastRegionError != nil), actions: {
                Button("Dismiss") { tunnel.lastRegionError = nil }
            }, message: { Text(tunnel.lastRegionError ?? "") })
            .alert("Reset Tunnel?", isPresented: $showingResetConfirm) {
                Button("Reset", role: .destructive) {
                    Task { await performReset() }
                }
                Button("Cancel", role: .cancel) { }
            } message: {
                Text("This deletes and recreates the iOS VPN profile, then reconnects. iOS will ask you to allow Cloak VPN to add VPN configurations again. Use this only when normal disconnect+reconnect doesn't recover the tunnel.")
            }
            .sheet(isPresented: $showingImport) {
                importSheet
            }
            .sheet(isPresented: $showingAddRegion) {
                addRegionSheet
            }
            .sheet(isPresented: $showingMoreSheet) {
                moreSheet
            }
            // .plainText covers .txt; .data is the catch-all so users can
            // pick a renamed file. We don't enforce a `.cloak` extension
            // because configs come out of `add-peer.sh` as plain text and
            // forcing a custom UTI would just make AirDrop more annoying.
            .fileImporter(
                isPresented: $showingFileImporter,
                allowedContentTypes: [.plainText, .text, .data],
                allowsMultipleSelection: false
            ) { result in
                handleFileImport(result)
            }
        }
    }

    /// Read a peer config file the user picked from Files / iCloud Drive /
    /// AirDrop and feed it into TunnelManager.importConfig.
    ///
    /// Files chosen via the document picker live OUTSIDE the app sandbox,
    /// so we have to bracket the read with
    /// `startAccessingSecurityScopedResource` / `stopAccessing…` — without
    /// it, `Data(contentsOf:)` returns a permissions error even though
    /// the user just explicitly granted access.
    private func handleFileImport(_ result: Result<[URL], Error>) {
        switch result {
        case .failure(let err):
            errorMsg = "Couldn't open file: \(err.localizedDescription)"
        case .success(let urls):
            guard let url = urls.first else { return }
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            do {
                let text = try String(contentsOf: url, encoding: .utf8)
                try tunnel.importConfig(text)
            } catch let e as TunnelError {
                errorMsg = e.errorDescription ?? "Parse error"
            } catch {
                errorMsg = "Read failed: \(error.localizedDescription)"
            }
        }
    }

    private var statusBadge: some View {
        HStack(spacing: 8) {
            Circle().fill(tunnel.status.color).frame(width: 10, height: 10)
            Text(tunnel.status.description)
                .font(CloakDesign.headline(size: 17, weight: .semibold))
                .tracking(0.3)
        }
    }

    private var bigConnectButton: some View {
        Button(action: {
            Task {
                do {
                    if tunnel.status == .connected { try await tunnel.disconnect() }
                    else { try await tunnel.connect() }
                } catch {
                    errorMsg = error.localizedDescription
                }
            }
        }) {
            Text(tunnel.status == .connected ? "Disconnect" : "Connect")
                .font(CloakDesign.headline(size: 30, weight: .semibold))
                .tracking(0.8)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 22)
                .background(
                    tunnel.status == .connected
                        ? Color.red
                        : CloakDesign.brandGreen
                )
                .foregroundStyle(.white)
                .clipShape(RoundedRectangle(cornerRadius: 14))
                .shadow(
                    color: (tunnel.status == .connected
                            ? Color.red
                            : CloakDesign.brandGreen).opacity(0.25),
                    radius: 8, x: 0, y: 4
                )
        }
        .disabled(tunnel.config == nil)
    }

    /// Currently-selected region card. Shows the chosen region's flag
    /// + display name + endpoint hint, OR a "Choose a region" placeholder
    /// if no region is selected yet. Tapping the card scrolls the flag
    /// strip into focus (just visual; the actual selection is via the
    /// flag strip below).
    private var currentRegionCard: some View {
        HStack(spacing: 12) {
            if let r = tunnel.selectedRegion {
                Text(r.countryFlag).font(.system(size: 32))
                VStack(alignment: .leading, spacing: 2) {
                    Text(r.displayName)
                        .font(CloakDesign.headline(size: 16, weight: .semibold))
                    Text(r.endpointIP)
                        .font(.system(size: 12, weight: .regular, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            } else {
                Image(systemName: "globe")
                    .font(.system(size: 28))
                    .foregroundStyle(CloakDesign.brandGreen)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Choose a region")
                        .font(CloakDesign.headline(size: 16, weight: .semibold))
                    Text("Tap a flag below to provision")
                        .font(CloakDesign.body(size: 12))
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            if tunnel.regionSelectionInProgress {
                ProgressView()
                    .scaleEffect(0.9)
                    .tint(CloakDesign.brandGreen)
            }
        }
        .padding()
        .frame(maxWidth: .infinity)
        .background(Color.secondary.opacity(0.1))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    /// Horizontal scrolling strip of all available regions. Tap a flag
    /// to provision against that region (HTTP API call to its
    /// cloak-api-server) and auto-import the resulting config. PIA-style
    /// quick-connect pattern.
    private var quickConnectStrip: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Circle()
                    .fill(CloakDesign.brandGreen)
                    .frame(width: 6, height: 6)
                Text("QUICK CONNECT")
                    .font(CloakDesign.sectionLabel())
                    .tracking(1.4)
                    .foregroundStyle(CloakDesign.brandGreen)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 14) {
                    ForEach(CloakRegion.all) { region in
                        regionTile(region)
                    }
                }
                .padding(.horizontal, 4)  // breathing room for selection ring
                .padding(.vertical, 8)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(CloakDesign.brandGreen.opacity(0.10))
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(CloakDesign.brandGreen.opacity(0.35), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }

    @ViewBuilder
    private func regionTile(_ region: CloakRegion) -> some View {
        let isSelected = tunnel.selectedRegion?.id == region.id
        Button {
            Task { await tunnel.selectRegion(region) }
        } label: {
            VStack(spacing: 4) {
                Text(region.countryFlag)
                    .font(.system(size: 38))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 4)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(
                                isSelected ? CloakDesign.brandGreen : Color.clear,
                                lineWidth: 2
                            )
                    )
                Text(region.shortLabel)
                    .font(CloakDesign.body(size: 11, weight: isSelected ? .semibold : .regular))
                    .tracking(0.4)
                    .foregroundStyle(isSelected ? CloakDesign.brandGreen : .secondary)
            }
        }
        .buttonStyle(.plain)
        .disabled(tunnel.regionSelectionInProgress)
    }

    /// Compact PQC rotation status line. Replaces the older multi-line
    /// infoPanel; the customer mostly wants one quick visual on PQ
    /// activity, not the endpoint URL repeated.
    private var pqcStatusLine: some View {
        HStack(spacing: 6) {
            if case .established = tunnel.rosenpass.status {
                Image(systemName: "lock.shield.fill").foregroundStyle(.green)
            } else if case .error = tunnel.rosenpass.status {
                Image(systemName: "exclamationmark.shield").foregroundStyle(.orange)
            } else {
                Image(systemName: "lock.shield").foregroundStyle(.secondary)
            }
            Text(tunnel.rosenpass.status.description)
                .font(.system(.footnote, design: .monospaced))
                .foregroundStyle(.secondary)
            Spacer()
        }
    }

    /// IP / VPN IP block — PIA-style. Left column shows the user's
    /// real public IP (their home / cellular IP, which the VPN HIDES
    /// when connected — useful as a "this is what you'd expose
    /// without the VPN" indicator). Right column shows the VPN
    /// endpoint IP when connected, "---" otherwise. Arrow between
    /// the two reinforces the "IP → VPN IP" mental model.
    ///
    /// Tappable: long-tap or single-tap triggers a manual public-IP
    /// refresh. Useful when the cache is stale (e.g. fresh install
    /// with the VPN already on — we can't auto-detect because every
    /// fetch goes through the tunnel and returns the VPN endpoint IP).
    private var ipDisplayPanel: some View {
        Button {
            Task { await tunnel.refreshPublicIPIfNotConnected() }
        } label: {
            HStack(alignment: .center, spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("IP")
                        .font(.system(size: 10, weight: .semibold))
                        .tracking(0.6)
                        .foregroundStyle(.secondary)
                    Text(publicIPDisplayValue)
                        .font(.system(size: 13, weight: .medium, design: .monospaced))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                        .truncationMode(.middle)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Image(systemName: "arrow.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(
                        tunnel.status == .connected
                            ? CloakDesign.brandGreen
                            : Color.secondary
                    )
                    .layoutPriority(1)

                VStack(alignment: .trailing, spacing: 2) {
                    Text("VPN IP")
                        .font(.system(size: 10, weight: .semibold))
                        .tracking(0.6)
                        .foregroundStyle(.secondary)
                    Text(vpnIPDisplayValue)
                        .font(.system(size: 13, weight: .medium, design: .monospaced))
                        .foregroundStyle(
                            tunnel.status == .connected
                                ? CloakDesign.brandGreen
                                : Color.secondary
                        )
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                        .truncationMode(.middle)
                }
                .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(Color.secondary.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
    }

    /// Display string for the user's real public IP. Shows the
    /// cached value when present; a hint about how to populate the
    /// cache when nil. Cache populates automatically on transitions
    /// to .disconnected, OR on tap of this panel while disconnected.
    private var publicIPDisplayValue: String {
        if let ip = tunnel.publicIP { return ip }
        if tunnel.status == .connected {
            return "(disconnect to detect)"
        }
        return "(tap to detect)"
    }

    /// VPN IP shown in the right column. Only populated when the tunnel
    /// is actually up — preserves the "your traffic appears to come from
    /// here NOW" semantic. When disconnected, "---" matches PIA's idiom.
    private var vpnIPDisplayValue: String {
        if tunnel.status == .connected, let r = tunnel.selectedRegion {
            return r.endpointIP
        }
        return "---"
    }

    /// Bottom row: tiny utility buttons. Hides developer-style entry
    /// points (Paste config, Import from file, Add Region with custom
    /// URL, PQC FFI smoke test) inside a "More…" sheet so the main
    /// view stays focused on the customer-facing connect flow.
    private var bottomToolbar: some View {
        HStack(spacing: 16) {
            Button {
                showingResetConfirm = true
            } label: {
                Label("Reset", systemImage: "arrow.counterclockwise")
                    .font(.footnote)
            }
            .buttonStyle(.bordered)
            .disabled(tunnel.config == nil || resetInProgress)

            Spacer()

            Button {
                showingMoreSheet = true
            } label: {
                Label("More…", systemImage: "ellipsis.circle")
                    .font(.footnote)
            }
            .buttonStyle(.bordered)
        }
    }

    /// PIA-style Settings drawer. Top: account header (subscription
    /// tier + Manage link). Middle: navigation rows for major user-
    /// facing functions. Bottom: about / support / privacy / version.
    /// Developer-only paths (custom region URL+token, paste config,
    /// import from file, PQC smoke test) are still here but in a
    /// less-prominent "Advanced" section so the customer-facing layout
    /// still feels clean.
    private var moreSheet: some View {
        let sub = SubscriptionInfo.current
        return NavigationStack {
            List {
                // ---- Account header ----
                Section {
                    HStack(spacing: 12) {
                        Image(systemName: "lock.shield.fill")
                            .resizable()
                            .frame(width: 44, height: 44)
                            .foregroundStyle(Color.accentColor)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(sub.accountID)
                                .font(.headline)
                            Text(sub.displayLine)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                            Button("Manage subscription") {
                                // Placeholder — wire to App Store
                                // subscription manager when IAP ships.
                            }
                            .font(.caption)
                            .padding(.top, 2)
                        }
                        Spacer()
                    }
                    .padding(.vertical, 4)
                }

                // ---- Primary navigation ----
                Section {
                    Button {
                        showingMoreSheet = false
                        // Region selection lives on the main screen
                        // already (the flag strip). Closing this sheet
                        // returns the user to it.
                    } label: {
                        Label("Region selection", systemImage: "mappin.and.ellipse")
                    }
                    NavigationLink {
                        accountDetailView(sub: sub)
                    } label: {
                        Label("Account", systemImage: "person.crop.circle")
                    }
                    NavigationLink {
                        settingsDetailView
                    } label: {
                        Label("Settings", systemImage: "gear")
                    }
                }

                // ---- Information & support ----
                Section {
                    NavigationLink {
                        aboutDetailView
                    } label: {
                        Label("About", systemImage: "info.circle")
                    }
                    Link(destination: URL(string: "https://cloakvpn.ai/privacy")!) {
                        Label("Privacy policy", systemImage: "shield.lefthalf.filled")
                    }
                    Link(destination: URL(string: "mailto:support@cloakvpn.ai")!) {
                        Label("Support", systemImage: "bubble.left.and.bubble.right")
                    }
                }

                // ---- Advanced (developer / power-user) ----
                Section("Advanced") {
                    Button {
                        showingMoreSheet = false
                        showingAddRegion = true
                    } label: {
                        Label("Add region (custom URL & key)",
                              systemImage: "globe.badge.chevron.backward")
                    }
                    Button {
                        showingMoreSheet = false
                        showingImport = true
                    } label: {
                        Label("Paste config", systemImage: "doc.text")
                    }
                    Button {
                        showingMoreSheet = false
                        showingFileImporter = true
                    } label: {
                        Label("Import from file…", systemImage: "tray.and.arrow.down")
                    }
                    NavigationLink {
                        pqcDiagnosticsView
                    } label: {
                        Label("PQC diagnostics", systemImage: "key.fill")
                    }
                }

                // ---- Footer: version ----
                Section {
                    HStack {
                        Spacer()
                        Text("Cloak VPN \(appVersionDisplay)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                    }
                    .listRowBackground(Color.clear)
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { showingMoreSheet = false }
                }
            }
        }
    }

    /// "Account" detail view — placeholder for now. Will hold subscription
    /// details, payment method, sign-in info once IAP / account
    /// infrastructure exists.
    private func accountDetailView(sub: SubscriptionInfo) -> some View {
        Form {
            Section("Subscription") {
                LabeledContent("Account ID", value: sub.accountID)
                LabeledContent("Plan", value: sub.tier.displayName)
                if let r = sub.renewalDate {
                    LabeledContent("Renews",
                                   value: r.formatted(date: .long, time: .omitted))
                }
            }
            Section {
                Button("Log out", role: .destructive) {
                    // Placeholder — clears local credentials when
                    // account auth ships.
                }
                .frame(maxWidth: .infinity, alignment: .center)
            }
        }
        .navigationTitle("Account")
    }

    /// "Settings" detail view — tunnel preferences. For now mostly a
    /// stub with a single Reset Tunnel action; future settings (kill
    /// switch toggle, on-demand rules, custom DNS) live here.
    private var settingsDetailView: some View {
        Form {
            Section("Connection") {
                Button(role: .destructive) {
                    showingMoreSheet = false
                    showingResetConfirm = true
                } label: {
                    Label("Reset tunnel", systemImage: "arrow.counterclockwise")
                }
                .disabled(tunnel.config == nil || resetInProgress)
            }
        }
        .navigationTitle("Settings")
    }

    /// "About" detail view.
    private var aboutDetailView: some View {
        Form {
            Section {
                LabeledContent("Version", value: appVersionDisplay)
                LabeledContent("Build", value: appBuildDisplay)
            }
            Section {
                Text("Cloak VPN combines WireGuard with the post-quantum Rosenpass key-exchange protocol. Your traffic is protected against both classical and quantum-capable adversaries.")
                    .font(.footnote)
            }
        }
        .navigationTitle("About")
    }

    /// "PQC diagnostics" — formerly the on-main-screen PQC FFI smoke
    /// test + identity panel. Tucked here so the main screen stays
    /// customer-clean.
    private var pqcDiagnosticsView: some View {
        Form {
            Section("Local PQC identity") {
                pqcIdentityPanel
            }
            Section("FFI smoke test") {
                pqcSmokeTestPanel
            }
        }
        .navigationTitle("PQC diagnostics")
    }

    /// CFBundleShortVersionString for display (e.g. "1.0").
    private var appVersionDisplay: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
    }

    /// CFBundleVersion (build number) for display.
    private var appBuildDisplay: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "—"
    }

    private var infoPanel: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let cfg = tunnel.config {
                Text("Endpoint: \(cfg.endpoint)").font(.footnote)
                Text("PQC: Rosenpass \(cfg.pqEnabled ? "ENABLED" : "disabled")").font(.footnote)
                Text(tunnel.rosenpass.status.description)
                    .font(.system(.footnote, design: .monospaced))
                    .foregroundStyle(.secondary)
            } else {
                Text("No config imported.").font(.footnote).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(Color.secondary.opacity(0.1))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    /// Shows this device's locally-generated rosenpass public key
    /// fingerprint plus a Share button to AirDrop the full base64
    /// pubkey to a Mac for server-side registration. The local
    /// keypair is generated on first launch via the FFI's
    /// generateStaticKeypair() — secret never leaves the device.
    /// See docs/IOS_PQC.md for the privacy rationale.
    private var pqcIdentityPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "key.fill")
                    .foregroundStyle(.tint)
                Text("Your PQC Identity")
                    .font(.subheadline.bold())
            }

            if let fp = tunnel.localPubkeyFingerprint {
                Text("Fingerprint: \(fp)")
                    .font(.system(.footnote, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)

                if let url = try? tunnel.makeLocalPubkeyShareFile() {
                    ShareLink(
                        item: url,
                        subject: Text("Cloak VPN PQC public key"),
                        message: Text("Register this with `sudo add-peer.sh <peer-name> <this-file>` on your Cloak server.")
                    ) {
                        Label("Share my public key…", systemImage: "square.and.arrow.up")
                            .font(.footnote)
                    }
                    .buttonStyle(.bordered)
                }
            } else {
                HStack(spacing: 8) {
                    ProgressView().scaleEffect(0.7)
                    Text("Generating PQC identity…")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(Color.secondary.opacity(0.1))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private var pqcSmokeTestPanel: some View {
        VStack(spacing: 8) {
            Text(pqcStatus)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            Button {
                runPqcSmokeTest()
            } label: {
                if pqcRunning {
                    HStack(spacing: 8) {
                        ProgressView().scaleEffect(0.8)
                        Text("Generating PQC keypair…")
                    }
                } else {
                    Text("Test PQC FFI")
                }
            }
            .buttonStyle(.bordered)
            .disabled(pqcRunning)
        }
    }

    /// Layer 4 of the wedge auto-recovery story — last-resort manual
    /// "Reset Tunnel" affordance. Shows a small destructive button at
    /// the bottom of the main view. Disabled when no config is
    /// imported or when a reset is already in flight.
    private var troubleshootingPanel: some View {
        VStack(spacing: 6) {
            Divider()
            Button {
                showingResetConfirm = true
            } label: {
                if resetInProgress {
                    HStack(spacing: 6) {
                        ProgressView().scaleEffect(0.7)
                        Text("Resetting tunnel…")
                    }
                    .font(.footnote)
                } else {
                    Label("Reset Tunnel (last resort)", systemImage: "arrow.counterclockwise")
                        .font(.footnote)
                }
            }
            .buttonStyle(.bordered)
            .disabled(tunnel.config == nil || resetInProgress)
        }
    }

    /// Calls TunnelManager.resetTunnel and surfaces any error in the
    /// shared error alert. Spinner state via resetInProgress disables
    /// the button while the reset is running so the user can't double-
    /// trigger it.
    private func performReset() async {
        resetInProgress = true
        defer { resetInProgress = false }
        do {
            try await tunnel.resetTunnel()
        } catch {
            errorMsg = "Reset failed: \(error.localizedDescription)"
        }
    }

    private func runPqcSmokeTest() {
        pqcRunning = true
        pqcStatus = "PQC: working…"
        // Off the main actor — McEliece keygen takes ~50-200 ms on a
        // modern iPhone and peaks at 2-4 MB working set. Don't block UI.
        Task.detached(priority: .userInitiated) {
            let started = Date()
            do {
                let kp = try generateStaticKeypair()
                let elapsed = Date().timeIntervalSince(started)
                let pkKB = kp.publicKey.count / 1024
                let skKB = kp.secretKey.count / 1024
                let line = String(
                    format: "PQC: ✓ pk=%d KB sk=%d KB in %.0f ms",
                    pkKB, skKB, elapsed * 1000
                )
                await MainActor.run {
                    pqcStatus = line
                    pqcRunning = false
                }
            } catch {
                await MainActor.run {
                    pqcStatus = "PQC: ✗ \(error.localizedDescription)"
                    pqcRunning = false
                }
            }
        }
    }

    /// "Add Region" sheet — the new privacy-correct provisioning flow.
    /// User enters the region's API URL + API key; the app POSTs its
    /// locally-generated WG and rosenpass public keys (private keys
    /// never leave the device) and gets back a config block to
    /// auto-import.
    private var addRegionSheet: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Server URL", text: $addRegionURL,
                              prompt: Text("http://5.78.203.171:8443"))
                        .textInputAutocapitalization(.never)
                        .keyboardType(.URL)
                        .autocorrectionDisabled()
                    TextField("API Key", text: $addRegionAPIKey,
                              prompt: Text("from /etc/cloak/api-token"))
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField("Peer name (optional)", text: $addRegionPeerName,
                              prompt: Text("auto-generated if blank"))
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } header: {
                    Text("Region details")
                } footer: {
                    Text("The server URL is where the Cloak provisioning API runs. The API key is a shared secret from /etc/cloak/api-token on the server. Both keys generated by your phone are stored locally — only the public halves are sent to the server.")
                        .font(.caption)
                }

                Section {
                    Button {
                        Task { await performAddRegion() }
                    } label: {
                        if addRegionInProgress {
                            HStack(spacing: 8) {
                                ProgressView().scaleEffect(0.8)
                                Text("Provisioning…")
                            }
                        } else {
                            Text("Add Region")
                                .frame(maxWidth: .infinity, alignment: .center)
                                .fontWeight(.semibold)
                        }
                    }
                    .disabled(addRegionInProgress
                              || addRegionURL.isEmpty
                              || addRegionAPIKey.isEmpty)
                }
            }
            .navigationTitle("Add a Cloak region")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        showingAddRegion = false
                    }
                    .disabled(addRegionInProgress)
                }
            }
        }
    }

    private func performAddRegion() async {
        addRegionInProgress = true
        defer { addRegionInProgress = false }
        do {
            try await tunnel.provisionFromAPI(
                serverBase: addRegionURL.trimmingCharacters(in: .whitespacesAndNewlines),
                apiKey: addRegionAPIKey.trimmingCharacters(in: .whitespacesAndNewlines),
                peerName: addRegionPeerName.isEmpty
                    ? nil
                    : addRegionPeerName.trimmingCharacters(in: .whitespacesAndNewlines)
            )
            // Success — close the sheet, leave the URL+key fields populated
            // so a re-attempt is easy if needed.
            showingAddRegion = false
        } catch {
            errorMsg = "Provisioning failed: \(error.localizedDescription)"
        }
    }

    private var importSheet: some View {
        NavigationStack {
            VStack {
                TextEditor(text: $configText)
                    .font(.system(.caption, design: .monospaced))
                    .border(.secondary)
                    .padding()
                Button("Save") {
                    do {
                        try tunnel.importConfig(configText)
                        showingImport = false
                    } catch {
                        errorMsg = error.localizedDescription
                    }
                }
                .buttonStyle(.borderedProminent)
                .padding(.bottom)
            }
            .navigationTitle("Paste config")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { showingImport = false }
                }
            }
        }
    }
}
