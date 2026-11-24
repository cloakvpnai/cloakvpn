//
//  ConnectionPopoverView.swift
//
//  The SwiftUI view that drops out of the menu bar status item. Three
//  stacked sections, top to bottom:
//
//    1. Status block       — big status pill, current public/tunnel IP,
//                            up/down byte counters when connected.
//    2. Region picker      — scroll list of regions with flag, name,
//                            and a checkmark on the active one.
//    3. Footer actions     — Preferences…, Quit.
//
//  Sized to fit the NSPopover (360 x 480 default). All styling uses
//  semantic Mac colors so the popover automatically adapts to
//  light/dark menu bars without us writing two themes.
//

import SwiftUI

struct ConnectionPopoverView: View {
    var showPreferences: () -> Void = {}
    /// True when hosted as the Connect tab of the Lattice window instead of
    /// the menu bar popover: the region list uses the available height and
    /// the Preferences/Quit footer is dropped.
    var inWindow = false
    @EnvironmentObject private var connection: ConnectionViewModel
    @State private var showingRegionPicker = false
    /// False while more regions are hidden below the visible part of the list.
    @State private var regionListAtBottom = true

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().padding(.horizontal, -16)
            statusBlock
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
            Divider().padding(.horizontal, -16)
            cnsa2Preview
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
            Divider().padding(.horizontal, -16)
            regionSection
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            if !inWindow {
                Spacer(minLength: 0)
                Divider().padding(.horizontal, -16)
                footer
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .padding(.bottom, 12)
        .background(inWindow ? Color.clear : Color(NSColor.windowBackgroundColor))
        .alert("Lattice VPN", isPresented: Binding(
            get: { connection.lastError != nil },
            set: { if !$0 { connection.clearError() } }
        )) {
            Button("OK") { connection.clearError() }
        } message: {
            Text(connection.lastError ?? "")
        }
    }

    // MARK: - Sections

    /// What protects the connection. The CNSA 2.0 suite is the only mode; there is no switch.
    private var cnsa2Preview: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("CNSA 2.0")
                        .font(.system(size: inWindow ? 13 : 11, weight: .semibold))
                    Text("ML-KEM-1024, ML-DSA-87 and AES-256 over TLS 1.3, through the selected region.")
                        .font(.system(size: inWindow ? 12 : 10))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
            }
            if let message = connection.cnsa2Message {
                Text(message)
                    .font(.system(size: inWindow ? 12 : 10))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "shield.lefthalf.filled")
                .resizable()
                .renderingMode(.template)
                .foregroundStyle(.tint)
                .frame(width: 22, height: 22)
            VStack(alignment: .leading, spacing: 0) {
                Text("Lattice VPN")
                    .font(.system(size: 14, weight: .semibold))
                Text("CNSA 2.0")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button(action: { Task { await connection.refreshPublicIP() } }) {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 11, weight: .medium))
            }
            .buttonStyle(.borderless)
            .help("Refresh status")
        }
        .padding(.bottom, 12)
    }

    private var statusBlock: some View {
        VStack(spacing: 12) {
            statusPill
            HStack(spacing: 16) {
                ipColumn(label: "Your IP",  value: connection.publicIP ?? "—")
                Divider().frame(height: 28)
                ipColumn(label: "Exit IP",  value: connection.tunnelIP ?? "—")
            }
            primaryActionButton
        }
    }

    private var statusPill: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(pillTintColor)
                .frame(width: 8, height: 8)
                .overlay(
                    Circle()
                        .stroke(pillTintColor.opacity(0.4), lineWidth: 4)
                        .scaleEffect(connection.status.isBusy ? 1.4 : 1)
                        .opacity(connection.status.isBusy ? 0 : 1)
                        .animation(
                            connection.status.isBusy
                                ? .easeOut(duration: 1.0).repeatForever(autoreverses: false)
                                : .default,
                            value: connection.status.isBusy
                        )
                )
            Text(connection.status.menuTitle)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(pillTextColor)
            Spacer()
            if connection.status == .connected, let region = connection.selectedRegion {
                Text("\(region.countryFlag) \(region.id)")
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(pillBackgroundColor)
        )
    }

    private func ipColumn(label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label.uppercased())
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.secondary)
                .tracking(0.6)
            Text(value)
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .foregroundStyle(.primary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var primaryActionButton: some View {
        Button {
            Task {
                if connection.status.isConnected {
                    await connection.disconnect()
                } else {
                    // In CNSA 2.0 mode the main button stays in that mode.
                    if connection.isCNSA2Mode { await connection.connectCNSA2(); return }
                    await connection.connect()
                }
            }
        } label: {
            HStack(spacing: 6) {
                if connection.status.isBusy { ProgressView().controlSize(.small) }
                Text(primaryActionLabel)
                    .font(.system(size: 13, weight: .semibold))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 7)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.regular)
        .tint(connection.status.isConnected ? .red : .accentColor)
        .disabled(connection.status.isBusy)
    }

    private var regionSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("REGION")
                    .font(.system(size: inWindow ? 12 : 9, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .tracking(0.6)
                Spacer()
                Text("\(connection.availableRegions.count) available")
                    .font(.system(size: inWindow ? 12 : 10))
                    .foregroundStyle(.secondary)
            }
            ScrollView {
                VStack(spacing: 6) {
                    ForEach(connection.availableRegions) { region in
                        regionRow(region)
                    }
                }
            }
            .scrollIndicators(.visible)
            .onScrollGeometryChange(for: Bool.self) { geometry in
                geometry.contentOffset.y + geometry.containerSize.height >= geometry.contentSize.height - 4
            } action: { _, atBottom in
                regionListAtBottom = atBottom
            }
            .overlay(alignment: .bottom) {
                // Tells people the list continues; goes away at the end of the list.
                if !regionListAtBottom {
                    HStack(spacing: 5) {
                        Image(systemName: "chevron.down")
                        Text("More regions below")
                    }
                    .font(.system(size: inWindow ? 12 : 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 5)
                    .background(.regularMaterial, in: Capsule())
                    .overlay(Capsule().stroke(Color.primary.opacity(0.12), lineWidth: 1))
                    .padding(.bottom, 6)
                    .allowsHitTesting(false)
                    .transition(.opacity)
                }
            }
            .animation(.easeInOut(duration: 0.2), value: regionListAtBottom)
            .frame(maxHeight: inWindow ? .infinity : 170)
        }
    }

    private func regionRow(_ region: RegionSummary) -> some View {
        let isSelected = (connection.selectedRegion?.id == region.id)
        return Button {
            Task { await connection.connect(to: region) }
        } label: {
            HStack(spacing: inWindow ? 14 : 10) {
                Text(region.countryFlag).font(.system(size: inWindow ? 32 : 20))
                Text(region.displayName)
                    .font(.system(size: inWindow ? 17 : 13, weight: .medium))
                    .foregroundStyle(.primary)
                Spacer()
                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.tint)
                        .font(.system(size: inWindow ? 18 : 13, weight: .semibold))
                }
            }
            .padding(.horizontal, inWindow ? 14 : 10)
            .padding(.vertical, inWindow ? 10 : 7)
            .background(
                RoundedRectangle(cornerRadius: inWindow ? 10 : 6, style: .continuous)
                    .fill(isSelected ? Color.accentColor.opacity(0.10) : Color.clear)
            )
        }
        .buttonStyle(.plain)
        .contentShape(Rectangle())
    }

    private var footer: some View {
        HStack {
            Button("Preferences…") { openPreferences() }
                .buttonStyle(.borderless)
                .font(.system(size: 11))
            Spacer()
            Button("Quit") { NSApp.terminate(nil) }
                .buttonStyle(.borderless)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        .padding(.top, 8)
    }

    // MARK: - Helpers

    private var primaryActionLabel: String {
        switch connection.status {
        case .disconnected:   return "Connect"
        case .connecting:     return "Connecting…"
        case .connected:      return "Disconnect"
        case .reconnecting:   return "Reconnecting…"
        case .error:          return "Retry"
        }
    }

    private var pillTintColor: Color {
        switch connection.status {
        case .connected:                      return .green
        case .connecting, .reconnecting:      return .yellow
        case .error:                          return .red
        case .disconnected:                   return .secondary
        }
    }

    private var pillTextColor: Color {
        connection.status == .disconnected ? .secondary : .primary
    }

    private var pillBackgroundColor: Color {
        switch connection.status {
        case .connected:                      return .green.opacity(0.08)
        case .connecting, .reconnecting:      return .yellow.opacity(0.10)
        case .error:                          return .red.opacity(0.10)
        case .disconnected:                   return Color(NSColor.controlBackgroundColor)
        }
    }

    private func openPreferences() {
        showPreferences()
        NSApp.activate(ignoringOtherApps: true)
    }
}

#Preview {
    ConnectionPopoverView()
        .environmentObject(ConnectionViewModel())
        .frame(width: 360, height: 480)
}
