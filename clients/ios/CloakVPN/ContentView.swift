import SwiftUI

struct ContentView: View {
    @EnvironmentObject var tunnel: TunnelManager
    @State private var configText: String = ""
    @State private var showingImport = false
    @State private var errorMsg: String?

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                statusBadge
                bigConnectButton
                infoPanel

                Spacer()

                Button("Import config") { showingImport = true }
                    .buttonStyle(.bordered)
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
