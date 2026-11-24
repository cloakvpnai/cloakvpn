import SwiftUI
import MapKit
import Combine

/// A slowly turning globe with one dot per region, shown on wide screens (the open
/// iPhone Duo and iPad). The dot for the region in use is lit; tapping a dot picks
/// that region. It shows this device's own connection only. Nothing about other
/// customers is fetched or drawn.
struct LatticeGlobeView: View {
    let selectedRegionID: String?
    let isConnected: Bool
    let onPick: (CloakRegion) -> Void

    @State private var position: MapCameraPosition = .camera(
        MapCamera(centerCoordinate: CLLocationCoordinate2D(latitude: 18, longitude: -100), distance: LatticeGlobeView.altitude))
    @State private var center = CLLocationCoordinate2D(latitude: 18, longitude: -100)
    @State private var lastTouch = Date.distantPast
    @State private var pulse = false

    private static let altitude: CLLocationDistance = 24_000_000
    private let turn = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    /// Where each region's servers are, to the nearest city.
    static let coordinates: [String: CLLocationCoordinate2D] = [
        "us-west-1": .init(latitude: 45.52, longitude: -122.99),
        "us-east-1": .init(latitude: 39.04, longitude: -77.49),
        "us-central-1": .init(latitude: 32.78, longitude: -96.80),
        "de1": .init(latitude: 50.48, longitude: 12.37),
        "fi1": .init(latitude: 60.17, longitude: 24.94),
        "es1": .init(latitude: 40.42, longitude: -3.70),
        "mx1": .init(latitude: 19.43, longitude: -99.13),
        "za1": .init(latitude: -26.20, longitude: 28.05),
        "in1": .init(latitude: 19.08, longitude: 72.88),
        "jp1": .init(latitude: 35.68, longitude: 139.69),
    ]

    private var liveRegion: CloakRegion? {
        guard isConnected, let id = selectedRegionID else { return nil }
        return CloakRegion.byID(id)
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            Map(position: $position, interactionModes: [.pan, .zoom, .rotate]) {
                ForEach(CloakRegion.all) { region in
                    if let c = Self.coordinates[region.id] {
                        Annotation(region.shortLabel, coordinate: c, anchor: .center) {
                            dot(for: region)
                        }
                        .annotationTitles(.hidden)
                    }
                }
            }
            .mapStyle(.imagery(elevation: .realistic))
            .mapControlVisibility(.hidden)
            .onMapCameraChange(frequency: .onEnd) { context in
                center = context.camera.centerCoordinate
            }
            .simultaneousGesture(DragGesture(minimumDistance: 2).onChanged { _ in lastTouch = Date() })

            VStack(alignment: .leading, spacing: 2) {
                Text("LIVE CONNECTION")
                    .font(.system(size: 11, weight: .semibold))
                    .tracking(1.0)
                    .foregroundStyle(LatticeTheme.muted)
                Text(liveRegion.map { "Exit: \($0.displayName)" } ?? "Not connected. Tap a dot to pick a region.")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(liveRegion == nil ? LatticeTheme.text : LatticeTheme.mintText)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 10).fill(LatticeTheme.bg.opacity(0.78)))
            .padding(10)
        }
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(LatticeTheme.border, lineWidth: 1))
        .onAppear {
            pulse = true
            focusOnLiveRegion(animated: false)
        }
        .onChange(of: selectedRegionID) { _, _ in focusOnLiveRegion(animated: true) }
        .onChange(of: isConnected) { _, _ in focusOnLiveRegion(animated: true) }
        .onReceive(turn) { _ in
            // Turns slowly whenever it is left alone, connected or not. It pauses for a few
            // seconds after the customer moves it, and after it swings to a new exit region.
            guard Date().timeIntervalSince(lastTouch) > 6 else { return }
            var longitude = center.longitude + 6
            if longitude > 180 { longitude -= 360 }
            let next = CLLocationCoordinate2D(latitude: 18, longitude: longitude)
            center = next
            withAnimation(.linear(duration: 2)) {
                position = .camera(MapCamera(centerCoordinate: next, distance: Self.altitude))
            }
        }
        .accessibilityLabel(liveRegion.map { "Globe. Connected through \($0.displayName)." } ?? "Globe of regions. Not connected.")
    }

    private func focusOnLiveRegion(animated: Bool) {
        guard let region = liveRegion, let c = Self.coordinates[region.id] else { return }
        lastTouch = Date()
        center = c
        let camera = MapCameraPosition.camera(MapCamera(centerCoordinate: c, distance: Self.altitude))
        if animated { withAnimation(.easeInOut(duration: 1.6)) { position = camera } } else { position = camera }
    }

    private func dot(for region: CloakRegion) -> some View {
        let isLive = liveRegion?.id == region.id
        let isSelected = selectedRegionID == region.id
        return Button {
            lastTouch = Date()
            onPick(region)
        } label: {
            ZStack {
                if isLive {
                    Circle()
                        .stroke(LatticeTheme.mint.opacity(0.7), lineWidth: 2)
                        .frame(width: 34, height: 34)
                        .scaleEffect(pulse ? 1.0 : 0.45)
                        .opacity(pulse ? 0.0 : 0.9)
                        .animation(.easeOut(duration: 1.6).repeatForever(autoreverses: false), value: pulse)
                }
                Circle()
                    .fill(isLive ? LatticeTheme.mint : (isSelected ? LatticeTheme.mintText : Color.white.opacity(0.85)))
                    .frame(width: isLive ? 14 : 10, height: isLive ? 14 : 10)
                    .overlay(Circle().stroke(Color.black.opacity(0.55), lineWidth: 1.5))
            }
            .frame(width: 44, height: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isLive ? "\(region.displayName), connected" : region.displayName)
    }
}
