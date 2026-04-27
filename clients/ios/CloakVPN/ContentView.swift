import SwiftUI
import UniformTypeIdentifiers

// Note on RosenpassFFI: the Swift bindings (rosenpassffi.swift) are
// compiled directly into the CloakVPN app target alongside this file,
// so types like `generateStaticKeypair()` and `StaticKeypair` are
// already in scope — no `import` needed. The bindings themselves
// `import rosenpassffiFFI` (the C module from the xcframework) under
// the hood; that's the only module name in this build.

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

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                statusBadge
                bigConnectButton
                infoPanel
                pqcIdentityPanel

                Spacer()

                // Two import paths:
                //   - "Import from file" → UIDocumentPickerViewController
                //     (via SwiftUI .fileImporter). Required for PQC configs
                //     since they're ~1.4 MB of base64 McEliece keys —
                //     too big to paste sanely.
                //   - "Paste config" → TextEditor sheet. Fine for the
                //     small classical-only configs (~400 bytes).
                HStack(spacing: 12) {
                    Button("Import from file…") { showingFileImporter = true }
                        .buttonStyle(.borderedProminent)
                    Button("Paste config") { showingImport = true }
                        .buttonStyle(.bordered)
                }

                pqcSmokeTestPanel
                troubleshootingPanel
            }
            .padding()
            .navigationTitle("Cloak VPN")
            .alert("Error", isPresented: .constant(errorMsg != nil), actions: {
                Button("OK") { errorMsg = nil }
            }, message: { Text(errorMsg ?? "") })
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
            Text(tunnel.status.description).font(.headline)
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
                .font(.title2).bold()
                .frame(maxWidth: .infinity)
                .padding(.vertical, 18)
                .background(tunnel.status == .connected ? Color.red : Color.blue)
                .foregroundStyle(.white)
                .clipShape(RoundedRectangle(cornerRadius: 14))
        }
        .disabled(tunnel.config == nil)
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
