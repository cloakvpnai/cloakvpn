import SwiftUI
import RosenpassFFI

struct ContentView: View {
    @EnvironmentObject var tunnel: TunnelManager
    @State private var configText: String = ""
    @State private var showingImport = false
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

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                statusBadge
                bigConnectButton
                infoPanel

                Spacer()

                Button("Import config") { showingImport = true }
                    .buttonStyle(.bordered)

                pqcSmokeTestPanel
            }
            .padding()
            .navigationTitle("Cloak VPN")
            .alert("Error", isPresented: .constant(errorMsg != nil), actions: {
                Button("OK") { errorMsg = nil }
            }, message: { Text(errorMsg ?? "") })
            .sheet(isPresented: $showingImport) {
                importSheet
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
            } else {
                Text("No config imported.").font(.footnote).foregroundStyle(.secondary)
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
