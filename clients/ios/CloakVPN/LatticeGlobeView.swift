import SwiftUI
import MapKit
import QuartzCore

/// The panel under the region list on wide screens (the open iPhone Duo and iPad):
/// a globe that turns continuously, one dot per region, the exit in use lit, and a
/// strip of facts about the current session. It shows this device's own connection
/// only. Nothing about other customers is fetched or drawn.
struct LatticeGlobeView: View {
    let selectedRegionID: String?
    let isConnected: Bool
    let connectedSince: Date?
    let loadStats: () async -> CNSA2SessionStats?
    let onPick: (CloakRegion) -> Void

    @State private var stats: CNSA2SessionStats?
    @State private var latency: TimeInterval?
    @State private var latencySamples: [TimeInterval] = []
    /// The tile that is popped out, if any. Only one can be open at a time.
    @State private var open: Tile?

    enum Tile: String { case session, traffic, latency, keys }

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
        ZStack {
            GlobeMap(selectedRegionID: selectedRegionID, isConnected: isConnected, onPick: onPick)

            VStack(spacing: 8) {
                if open == nil {
                    HStack {
                        header
                        Spacer(minLength: 0)
                    }
                    .allowsHitTesting(false)
                    .transition(.opacity)
                }
                Spacer(minLength: 0)
                if let open {
                    detail(open)
                        .transition(.scale(scale: 0.88, anchor: .bottom).combined(with: .opacity))
                }
                facts
            }
            .padding(10)
            .animation(.spring(response: 0.32, dampingFraction: 0.84), value: open)
        }
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(LatticeTheme.border, lineWidth: 1))
        .task(id: isConnected) {
            // Ask the tunnel for its counters and time one echo to the exit, every few
            // seconds, for as long as this panel is on screen and the tunnel is up.
            stats = nil
            latency = nil
            latencySamples = []
            guard isConnected else { return }
            while !Task.isCancelled {
                stats = await loadStats()
                if let trip = await LatticePing.roundTrip(to: LatticePing.gatewayInTunnel) {
                    latency = trip
                    latencySamples.append(trip)
                    if latencySamples.count > 20 { latencySamples.removeFirst() }
                }
                try? await Task.sleep(nanoseconds: 3_000_000_000)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(liveRegion.map { "Globe. Connected through \($0.displayName)." } ?? "Globe of regions. Not connected.")
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Circle()
                    .fill(liveRegion == nil ? LatticeTheme.muted : LatticeTheme.mint)
                    .frame(width: 6, height: 6)
                Text(liveRegion == nil ? "REGIONS" : "LIVE CONNECTION")
                    .font(.system(size: 11, weight: .semibold))
                    .tracking(1.0)
                    .foregroundStyle(LatticeTheme.muted)
            }
            Text(liveRegion.map { "\($0.countryFlag)  \($0.displayName)" } ?? "Tap a dot to pick a region")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(liveRegion == nil ? LatticeTheme.text : LatticeTheme.mintText)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 10).fill(LatticeTheme.bg.opacity(0.80)))
    }

    /// Facts that are true of every session in this app, plus the session clock.
    private var facts: some View {
        HStack(spacing: 8) {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                fact(.session, "SESSION", sessionText(at: context.date), lit: liveRegion != nil)
            }
            fact(.traffic, "DOWN / UP", trafficText, lit: liveRegion != nil)
            fact(.latency, "LATENCY", latencyText, lit: liveRegion != nil)
            fact(.keys, "NEW KEYS", keysText, lit: liveRegion != nil)
        }
    }

    /// A tile. Tapping it pops its detail out; tapping it again, or the detail, puts it away.
    private func fact(_ tile: Tile, _ label: String, _ value: String, lit: Bool) -> some View {
        let isOpen = open == tile
        return Button {
            open = isOpen ? nil : tile
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                    .font(.system(size: 9, weight: .semibold))
                    .tracking(0.8)
                    .foregroundStyle(isOpen ? LatticeTheme.mint : LatticeTheme.muted)
                Text(value)
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .foregroundStyle(lit ? LatticeTheme.mintText : LatticeTheme.text)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 10).fill(LatticeTheme.bg.opacity(isOpen ? 0.94 : 0.80)))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(isOpen ? LatticeTheme.mint.opacity(0.7) : Color.clear, lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(label), \(value)")
        .accessibilityHint(isOpen ? "Closes the detail" : "Shows more detail")
    }

    // MARK: Popped-out detail

    private func detail(_ tile: Tile) -> some View {
        Button {
            open = nil
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(detailTitle(tile))
                        .font(.system(size: 11, weight: .semibold))
                        .tracking(1.0)
                        .foregroundStyle(LatticeTheme.mint)
                    Spacer()
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(LatticeTheme.muted)
                }
                switch tile {
                case .session:
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        big(sessionText(at: context.date))
                    }
                    if let region = liveRegion {
                        line("Exit", "\(region.countryFlag)  \(region.displayName)")
                        line("Exit address", region.endpointIP)
                        if let since = connectedSince {
                            line("Connected at", since.formatted(date: .omitted, time: .shortened))
                        }
                    } else {
                        note("Tap the power button, or a dot on the globe, to connect.")
                    }
                case .traffic:
                    if liveRegion != nil, let s = stats {
                        HStack(alignment: .firstTextBaseline, spacing: 18) {
                            pair("DOWN", Self.bytes.string(fromByteCount: Int64(clamping: s.received)))
                            pair("UP", Self.bytes.string(fromByteCount: Int64(clamping: s.sent)))
                            pair("TOTAL", Self.bytes.string(fromByteCount: Int64(clamping: s.received &+ s.sent)))
                        }
                    } else {
                        big("--")
                    }
                    note("Counted on this device for this session only. Not saved and not sent to Lattice.")
                case .latency:
                    big(latencyText)
                    if liveRegion != nil, !latencySamples.isEmpty {
                        let best = latencySamples.min() ?? 0
                        let average = latencySamples.reduce(0, +) / Double(latencySamples.count)
                        line("Best", "\(max(1, Int((best * 1000).rounded()))) ms")
                        line("Average", "\(max(1, Int((average * 1000).rounded()))) ms")
                    }
                    note(liveRegion.map { "Round trip from this device to \($0.displayName) and back, through the tunnel." }
                         ?? "Shown while connected.")
                case .keys:
                    big(liveRegion != nil ? "\(stats?.keyChanges ?? 0) so far" : "--")
                    line("Replaced", "Every 10 minutes")
                    line("Key exchange", "ML-KEM-1024")
                    line("Signatures", "ML-DSA-87")
                    line("Cipher", "AES-256-GCM")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .background(RoundedRectangle(cornerRadius: 14).fill(LatticeTheme.bg.opacity(0.94)))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(LatticeTheme.mint.opacity(0.45), lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityHint("Closes the detail")
    }

    private func detailTitle(_ tile: Tile) -> String {
        switch tile {
        case .session: return "THIS SESSION"
        case .traffic: return "DATA THIS SESSION"
        case .latency: return "LATENCY TO THE EXIT"
        case .keys: return "KEY CHANGES"
        }
    }

    private func big(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 26, weight: .bold, design: .monospaced))
            .foregroundStyle(liveRegion == nil ? LatticeTheme.text : LatticeTheme.mintText)
            .lineLimit(1)
            .minimumScaleFactor(0.6)
    }

    private func pair(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.system(size: 10, weight: .semibold))
                .tracking(0.8)
                .foregroundStyle(LatticeTheme.muted)
            Text(value)
                .font(.system(size: 19, weight: .bold, design: .monospaced))
                .foregroundStyle(LatticeTheme.mintText)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
        }
    }

    private func line(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .font(.system(size: 12))
                .foregroundStyle(LatticeTheme.muted)
            Spacer(minLength: 8)
            Text(value)
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                .foregroundStyle(LatticeTheme.text)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundStyle(LatticeTheme.muted)
            .fixedSize(horizontal: false, vertical: true)
    }

    private static let bytes: ByteCountFormatter = {
        let f = ByteCountFormatter()
        f.countStyle = .file
        f.allowedUnits = [.useKB, .useMB, .useGB]
        return f
    }()

    private var trafficText: String {
        guard liveRegion != nil, let s = stats else { return "--" }
        return "\(Self.bytes.string(fromByteCount: Int64(clamping: s.received))) / \(Self.bytes.string(fromByteCount: Int64(clamping: s.sent)))"
    }

    private var latencyText: String {
        guard liveRegion != nil, let l = latency else { return "--" }
        return "\(max(1, Int((l * 1000).rounded()))) ms"
    }

    /// The keys are replaced every 10 minutes; the count is how many times so far.
    private var keysText: String {
        guard liveRegion != nil, let s = stats else { return "Every 10 min" }
        return s.keyChanges == 0 ? "Every 10 min" : "\(s.keyChanges) so far"
    }

    private func sessionText(at now: Date) -> String {
        guard isConnected, let start = connectedSince else { return "Not connected" }
        let s = max(0, Int(now.timeIntervalSince(start)))
        return String(format: "%02d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60)
    }
}

// MARK: - The map itself

/// MKMapView driven by a display link, so the turn is one continuous motion and not
/// a chain of short animations.
private struct GlobeMap: UIViewRepresentable {
    let selectedRegionID: String?
    let isConnected: Bool
    let onPick: (CloakRegion) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onPick: onPick) }

    func makeUIView(context: Context) -> MKMapView {
        let map = MKMapView(frame: .zero)
        map.preferredConfiguration = MKImageryMapConfiguration(elevationStyle: .realistic)
        map.showsCompass = false
        map.showsScale = false
        map.isPitchEnabled = false
        map.showsUserLocation = false
        map.delegate = context.coordinator
        map.register(RegionDotView.self, forAnnotationViewWithReuseIdentifier: RegionDotView.reuseID)
        map.camera = MKMapCamera(lookingAtCenter: CLLocationCoordinate2D(latitude: 18, longitude: -100),
                                 fromDistance: Coordinator.altitude, pitch: 0, heading: 0)
        for region in CloakRegion.all {
            guard let c = LatticeGlobeView.coordinates[region.id] else { continue }
            map.addAnnotation(RegionAnnotation(region: region, coordinate: c))
        }
        for recognizer in [UIPanGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.touched)),
                           UIPinchGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.touched)),
                           UIRotationGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.touched))] as [UIGestureRecognizer] {
            recognizer.delegate = context.coordinator
            recognizer.cancelsTouchesInView = false
            map.addGestureRecognizer(recognizer)
        }
        context.coordinator.attach(map)
        context.coordinator.apply(selectedRegionID: selectedRegionID, isConnected: isConnected, animated: false)
        return map
    }

    func updateUIView(_ map: MKMapView, context: Context) {
        context.coordinator.onPick = onPick
        context.coordinator.apply(selectedRegionID: selectedRegionID, isConnected: isConnected, animated: true)
    }

    static func dismantleUIView(_ map: MKMapView, coordinator: Coordinator) {
        coordinator.detach()
    }

    final class Coordinator: NSObject, MKMapViewDelegate, UIGestureRecognizerDelegate {
        static let altitude: CLLocationDistance = 24_000_000
        /// One full turn in about two minutes.
        private static let degreesPerSecond = 3.0
        private static let restAfterTouch: CFTimeInterval = 5

        var onPick: (CloakRegion) -> Void
        private weak var map: MKMapView?
        private var link: CADisplayLink?
        private var lastFrame: CFTimeInterval = 0
        private var holdUntil: CFTimeInterval = 0
        private var selectedRegionID: String?
        private var isConnected = false
        private var applied = false

        init(onPick: @escaping (CloakRegion) -> Void) { self.onPick = onPick }

        func attach(_ map: MKMapView) {
            self.map = map
            let link = CADisplayLink(target: self, selector: #selector(frame(_:)))
            link.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 60, preferred: 60)
            link.add(to: .main, forMode: .common)
            self.link = link
        }

        func detach() {
            link?.invalidate()
            link = nil
        }

        @objc private func frame(_ link: CADisplayLink) {
            defer { lastFrame = link.timestamp }
            guard let map, lastFrame > 0, link.timestamp >= holdUntil, map.window != nil else { return }
            if UIAccessibility.isReduceMotionEnabled { return }
            let dt = min(link.timestamp - lastFrame, 0.1)
            guard let camera = map.camera.copy() as? MKMapCamera else { return }
            var c = camera.centerCoordinate
            c.longitude += Self.degreesPerSecond * dt
            if c.longitude > 180 { c.longitude -= 360 }
            // Drift back toward a latitude that keeps most regions in view.
            c.latitude += (18 - c.latitude) * min(1, dt * 0.4)
            camera.centerCoordinate = c
            camera.heading = 0
            map.camera = camera
        }

        @objc func touched() {
            holdUntil = CACurrentMediaTime() + Self.restAfterTouch
        }

        func gestureRecognizer(_ g: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }

        func apply(selectedRegionID: String?, isConnected: Bool, animated: Bool) {
            let changed = !applied || selectedRegionID != self.selectedRegionID || isConnected != self.isConnected
            self.selectedRegionID = selectedRegionID
            self.isConnected = isConnected
            applied = true
            guard changed, let map else { return }
            for annotation in map.annotations {
                guard let a = annotation as? RegionAnnotation, let view = map.view(for: a) as? RegionDotView else { continue }
                view.show(live: isConnected && a.region.id == selectedRegionID, selected: a.region.id == selectedRegionID)
            }
            // Swing to the exit when a connection comes up, rest on it, then carry on turning.
            if isConnected, let id = selectedRegionID, let c = LatticeGlobeView.coordinates[id] {
                let distance = map.camera.centerCoordinateDistance
                map.setCamera(MKMapCamera(lookingAtCenter: c, fromDistance: distance, pitch: 0, heading: 0), animated: animated)
                holdUntil = CACurrentMediaTime() + 6
            }
        }

        func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
            guard let a = annotation as? RegionAnnotation else { return nil }
            let view = mapView.dequeueReusableAnnotationView(withIdentifier: RegionDotView.reuseID, for: a) as? RegionDotView
            view?.show(live: isConnected && a.region.id == selectedRegionID, selected: a.region.id == selectedRegionID)
            return view
        }

        func mapView(_ mapView: MKMapView, didSelect annotation: MKAnnotation) {
            mapView.deselectAnnotation(annotation, animated: false)
            guard let a = annotation as? RegionAnnotation else { return }
            touched()
            onPick(a.region)
        }
    }
}

private final class RegionAnnotation: NSObject, MKAnnotation {
    let region: CloakRegion
    let coordinate: CLLocationCoordinate2D
    var title: String? { region.displayName }
    init(region: CloakRegion, coordinate: CLLocationCoordinate2D) {
        self.region = region
        self.coordinate = coordinate
    }
}

/// A dot for one region. The region in use is larger, mint, and sends out a ring.
private final class RegionDotView: MKAnnotationView {
    static let reuseID = "lattice.region.dot"
    private let dot = CAShapeLayer()
    private let ring = CAShapeLayer()

    override init(annotation: MKAnnotation?, reuseIdentifier: String?) {
        super.init(annotation: annotation, reuseIdentifier: reuseIdentifier)
        frame = CGRect(x: 0, y: 0, width: 44, height: 44)
        centerOffset = .zero
        canShowCallout = false
        displayPriority = .required
        collisionMode = .none
        backgroundColor = .clear
        ring.fillColor = UIColor.clear.cgColor
        ring.lineWidth = 2
        ring.frame = bounds
        ring.path = UIBezierPath(ovalIn: bounds.insetBy(dx: 5, dy: 5)).cgPath
        ring.opacity = 0
        layer.addSublayer(ring)
        dot.strokeColor = UIColor.black.withAlphaComponent(0.55).cgColor
        dot.lineWidth = 1.5
        dot.frame = bounds
        layer.addSublayer(dot)
        isAccessibilityElement = true
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func show(live: Bool, selected: Bool) {
        let mint = UIColor(LatticeTheme.mint)
        let size: CGFloat = live ? 15 : 10
        let rect = CGRect(x: (bounds.width - size) / 2, y: (bounds.height - size) / 2, width: size, height: size)
        dot.path = UIBezierPath(ovalIn: rect).cgPath
        dot.fillColor = (live ? mint : (selected ? UIColor(LatticeTheme.mintText) : UIColor.white.withAlphaComponent(0.88))).cgColor
        ring.strokeColor = mint.cgColor
        ring.removeAllAnimations()
        ring.opacity = 0
        if live && !UIAccessibility.isReduceMotionEnabled {
            let scale = CABasicAnimation(keyPath: "transform.scale")
            scale.fromValue = 0.4
            scale.toValue = 1.0
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 0.9
            fade.toValue = 0.0
            let group = CAAnimationGroup()
            group.animations = [scale, fade]
            group.duration = 1.8
            group.repeatCount = .infinity
            group.timingFunction = CAMediaTimingFunction(name: .easeOut)
            group.isRemovedOnCompletion = false
            ring.add(group, forKey: "pulse")
        }
        if let a = annotation as? RegionAnnotation {
            accessibilityLabel = live ? "\(a.region.displayName), connected" : a.region.displayName
        }
    }
}

// MARK: - The power button's pulse

/// Rings that travel outward from the power button while the tunnel is protecting traffic.
struct OrbPulse: View {
    let color: Color
    let diameter: CGFloat
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var out = false

    var body: some View {
        ZStack {
            ring(delay: 0)
            ring(delay: 1.1)
        }
        .onAppear { out = true }
        .allowsHitTesting(false)
    }

    private func ring(delay: Double) -> some View {
        Circle()
            .stroke(color, lineWidth: 2)
            .frame(width: diameter, height: diameter)
            .scaleEffect(reduceMotion ? 1 : (out ? 1.30 : 1.0))
            .opacity(reduceMotion ? 0 : (out ? 0 : 0.75))
            .animation(.easeOut(duration: 2.2).repeatForever(autoreverses: false).delay(delay), value: out)
    }
}
