import SwiftUI
import MapKit
import QuartzCore
#if os(macOS)
import AppKit
private typealias PlatformColor = NSColor
private typealias PlatformRepresentable = NSViewRepresentable
#else
import UIKit
private typealias PlatformColor = UIColor
private typealias PlatformRepresentable = UIViewRepresentable
#endif

private var reduceMotionOn: Bool {
    #if os(macOS)
    return NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    #else
    return UIAccessibility.isReduceMotionEnabled
    #endif
}

/// The panel beside the region list on wide screens (the open iPhone Duo, iPad and the Mac window):
/// a globe that turns continuously, one dot per region, the exit in use lit, and a
/// strip of facts about the current session. It shows this device's own connection
/// only. Nothing about other customers is fetched or drawn.
struct LatticeGlobeView: View {
    let selectedRegionID: String?
    let isConnected: Bool
    let connectedSince: Date?
    let loadStats: () async -> CNSA2SessionStats?
    let onPick: (CloakRegion) -> Void
    /// Text size multiplier. The Mac window uses larger text than the phone.
    var scale: CGFloat = 1

    private func f(_ size: CGFloat) -> CGFloat { size * scale }

    #if DEBUG
    /// Store preview capture (`-LatticeDemoStep <seconds>`): the globe and the session
    /// clock advance in fixed steps, so one still per step can be joined into a video.
    static let demoStepSeconds: Double = UserDefaults.standard.double(forKey: "LatticeDemoStep")
    static var demoStart = Date()
    static var demoStep: Int {
        demoStepSeconds > 0 ? max(0, Int(Date().timeIntervalSince(demoStart) / demoStepSeconds)) : 0
    }
    /// True for the first part of a step, while the clock may not have caught up yet.
    static var demoStepIsFresh: Bool {
        demoStepSeconds > 0 && Date().timeIntervalSince(demoStart).truncatingRemainder(dividingBy: demoStepSeconds) < 1.6
    }

    /// The step number as a row of squares a script can read back from a still.
    private var demoMarker: some View {
        TimelineView(.periodic(from: .now, by: 0.2)) { _ in
            let n = Self.demoStep
            HStack(spacing: 0) {
                Rectangle().fill(Color(red: 1, green: 0, blue: 0)).frame(width: 8, height: 8)
                ForEach(0..<7, id: \.self) { bit in
                    Rectangle().fill((n >> bit) & 1 == 1 ? Color.white : Color(white: 0.3)).frame(width: 8, height: 8)
                }
                Rectangle().fill(Self.demoStepIsFresh ? Color.white : Color(white: 0.3)).frame(width: 8, height: 8)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
            .padding(.top, 16)
            .padding(.trailing, 16)
            .allowsHitTesting(false)
        }
    }
    #endif

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

    #if os(macOS)
    private static let pickHint = "Click a dot to pick a region"
    private static let connectHint = "Click Connect, or a dot on the globe, to connect."
    #else
    private static let pickHint = "Tap a dot to pick a region"
    private static let connectHint = "Tap the power button, or a dot on the globe, to connect."
    #endif

    private var liveRegion: CloakRegion? {
        guard isConnected, let id = selectedRegionID else { return nil }
        return CloakRegion.byID(id)
    }

    var body: some View {
        ZStack {
            GlobeMap(selectedRegionID: selectedRegionID, isConnected: isConnected, onPick: onPick)
            #if DEBUG
            if Self.demoStepSeconds > 0, isConnected { demoMarker }
            #endif

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
            // Ask the tunnel for its counters and its latency to the exit, every few
            // seconds, for as long as this panel is on screen and the tunnel is up.
            stats = nil
            latency = nil
            latencySamples = []
            guard isConnected else { return }
            #if DEBUG
            Self.demoStart = Date()
            #endif
            while !Task.isCancelled {
                stats = await loadStats()
                if let trip = stats?.latency {
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
                    .font(.system(size: f(11), weight: .semibold))
                    .tracking(1.0)
                    .foregroundStyle(LatticeTheme.muted)
            }
            Text(liveRegion.map { "\($0.countryFlag)  \($0.displayName)" } ?? Self.pickHint)
                .font(.system(size: f(14), weight: .semibold))
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
                    .font(.system(size: f(9), weight: .semibold))
                    .tracking(0.8)
                    .foregroundStyle(isOpen ? LatticeTheme.mint : LatticeTheme.muted)
                Text(value)
                    .font(.system(size: f(12), weight: .semibold, design: .monospaced))
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
                        .font(.system(size: f(11), weight: .semibold))
                        .tracking(1.0)
                        .foregroundStyle(LatticeTheme.mint)
                    Spacer()
                    Image(systemName: "xmark")
                        .font(.system(size: f(11), weight: .bold))
                        .foregroundStyle(LatticeTheme.muted)
                }
                switch tile {
                case .session:
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        big(sessionText(at: context.date))
                    }
                    if let region = liveRegion {
                        line("Exit", "\(region.countryFlag)  \(region.displayName)")
                        line("Exit address", shownExitAddress(region))
                        if let since = connectedSince {
                            line("Connected at", since.formatted(date: .omitted, time: .shortened))
                        }
                    } else {
                        note(Self.connectHint)
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

    /// The exit's address. Debug builds started with `-LatticeDemoIP` show an example
    /// address instead, so store screenshots and previews carry no real server address.
    private func shownExitAddress(_ region: CloakRegion) -> String {
        #if DEBUG
        if UserDefaults.standard.string(forKey: "LatticeDemoIP") != nil {
            return UserDefaults.standard.string(forKey: "LatticeDemoExitIP") ?? "198.51.100.77"
        }
        #endif
        return region.endpointIP
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
            .font(.system(size: f(26), weight: .bold, design: .monospaced))
            .foregroundStyle(liveRegion == nil ? LatticeTheme.text : LatticeTheme.mintText)
            .lineLimit(1)
            .minimumScaleFactor(0.6)
    }

    private func pair(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.system(size: f(10), weight: .semibold))
                .tracking(0.8)
                .foregroundStyle(LatticeTheme.muted)
            Text(value)
                .font(.system(size: f(19), weight: .bold, design: .monospaced))
                .foregroundStyle(LatticeTheme.mintText)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
        }
    }

    private func line(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .font(.system(size: f(12)))
                .foregroundStyle(LatticeTheme.muted)
            Spacer(minLength: 8)
            Text(value)
                .font(.system(size: f(12), weight: .semibold, design: .monospaced))
                .foregroundStyle(LatticeTheme.text)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .font(.system(size: f(11)))
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
        #if DEBUG
        if Self.demoStepSeconds > 0 { return String(format: "00:00:%02d", 12 + Self.demoStep / 2) }
        #endif
        let s = max(0, Int(now.timeIntervalSince(start)))
        return String(format: "%02d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60)
    }
}

// MARK: - The map itself

/// MKMapView driven by a display link, so the turn is one continuous motion and not
/// a chain of short animations.
private struct GlobeMap: PlatformRepresentable {
    let selectedRegionID: String?
    let isConnected: Bool
    let onPick: (CloakRegion) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onPick: onPick) }

    private func build(_ context: Context) -> MKMapView {
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
        #if !os(macOS)
        for recognizer in [UIPanGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.touched)),
                           UIPinchGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.touched)),
                           UIRotationGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.touched))] as [UIGestureRecognizer] {
            recognizer.delegate = context.coordinator
            recognizer.cancelsTouchesInView = false
            map.addGestureRecognizer(recognizer)
        }
        #endif
        context.coordinator.attach(map)
        context.coordinator.apply(selectedRegionID: selectedRegionID, isConnected: isConnected, animated: false)
        return map
    }

    private func refresh(_ map: MKMapView, _ context: Context) {
        context.coordinator.onPick = onPick
        context.coordinator.apply(selectedRegionID: selectedRegionID, isConnected: isConnected, animated: true)
    }

    #if os(macOS)
    func makeNSView(context: Context) -> MKMapView { build(context) }
    func updateNSView(_ map: MKMapView, context: Context) { refresh(map, context) }
    static func dismantleNSView(_ map: MKMapView, coordinator: Coordinator) { coordinator.detach() }
    #else
    func makeUIView(context: Context) -> MKMapView { build(context) }
    func updateUIView(_ map: MKMapView, context: Context) { refresh(map, context) }
    static func dismantleUIView(_ map: MKMapView, coordinator: Coordinator) { coordinator.detach() }
    #endif

    final class Coordinator: NSObject, MKMapViewDelegate {
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
        #if os(macOS)
        private var monitor: Any?
        #endif
        #if DEBUG
        private var demoAppliedStep = -1
        #endif

        init(onPick: @escaping (CloakRegion) -> Void) { self.onPick = onPick }

        func attach(_ map: MKMapView) {
            self.map = map
            #if os(macOS)
            let link = map.displayLink(target: self, selector: #selector(frame(_:)))
            // The Mac has no touch recognizers to hang on the map. Watch for the mouse
            // working inside it, and let the event carry on untouched.
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseDragged, .scrollWheel, .magnify, .rotate]) { [weak self] event in
                if let map = self?.map, event.window === map.window,
                   map.bounds.contains(map.convert(event.locationInWindow, from: nil)) {
                    self?.touched()
                }
                return event
            }
            #else
            let link = CADisplayLink(target: self, selector: #selector(frame(_:)))
            #endif
            link.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 60, preferred: 60)
            link.add(to: .main, forMode: .common)
            self.link = link
        }

        func detach() {
            link?.invalidate()
            link = nil
            #if os(macOS)
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
            #endif
        }

        @objc private func frame(_ link: CADisplayLink) {
            defer { lastFrame = link.timestamp }
            #if DEBUG
            if LatticeGlobeView.demoStepSeconds > 0 {
                // Capture mode: rest on the exit for two seconds of video, then turn at the
                // usual three degrees per second, half a second of video per step.
                guard let map, isConnected, let id = selectedRegionID, let exit = LatticeGlobeView.coordinates[id],
                      let camera = map.camera.copy() as? MKMapCamera else { return }
                // Move only when the step changes. Setting the camera on every frame keeps
                // the map from ever finishing its drawing.
                let step = LatticeGlobeView.demoStep
                guard step != demoAppliedStep else { return }
                demoAppliedStep = step
                let tau = max(0, Double(step) * 0.5 - 2)
                var longitude = exit.longitude + Self.degreesPerSecond * tau
                if longitude > 180 { longitude -= 360 }
                let latitude = 18 + (exit.latitude - 18) * exp(-0.4 * tau)
                camera.centerCoordinate = CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
                camera.heading = 0
                map.camera = camera
                return
            }
            #endif
            guard let map, lastFrame > 0, link.timestamp >= holdUntil, map.window != nil else { return }
            if reduceMotionOn { return }
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

        func mapView(_ mapView: MKMapView, didSelect view: MKAnnotationView) {
            guard let a = view.annotation as? RegionAnnotation else { return }
            mapView.deselectAnnotation(a, animated: false)
            touched()
            onPick(a.region)
        }
    }
}

#if !os(macOS)
extension GlobeMap.Coordinator: UIGestureRecognizerDelegate {
    func gestureRecognizer(_ g: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }
}
#endif

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
        #if os(macOS)
        wantsLayer = true
        let host: CALayer? = layer
        setAccessibilityElement(true)
        #else
        backgroundColor = .clear
        let host: CALayer? = layer
        isAccessibilityElement = true
        #endif
        ring.fillColor = PlatformColor.clear.cgColor
        ring.lineWidth = 2
        ring.frame = bounds
        ring.path = CGPath(ellipseIn: bounds.insetBy(dx: 5, dy: 5), transform: nil)
        ring.opacity = 0
        host?.addSublayer(ring)
        dot.strokeColor = PlatformColor.black.withAlphaComponent(0.55).cgColor
        dot.lineWidth = 1.5
        dot.frame = bounds
        host?.addSublayer(dot)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func show(live: Bool, selected: Bool) {
        let mint = PlatformColor(LatticeTheme.mint)
        let size: CGFloat = live ? 15 : 10
        let rect = CGRect(x: (bounds.width - size) / 2, y: (bounds.height - size) / 2, width: size, height: size)
        dot.path = CGPath(ellipseIn: rect, transform: nil)
        dot.fillColor = (live ? mint : (selected ? PlatformColor(LatticeTheme.mintText) : PlatformColor.white.withAlphaComponent(0.88))).cgColor
        ring.strokeColor = mint.cgColor
        ring.removeAllAnimations()
        ring.opacity = 0
        var still = reduceMotionOn
        #if DEBUG
        if LatticeGlobeView.demoStepSeconds > 0 {
            still = true
            if live { ring.opacity = 0.6 }
        }
        #endif
        if live && !still {
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
            let label = live ? "\(a.region.displayName), connected" : a.region.displayName
            #if os(macOS)
            setAccessibilityLabel(label)
            #else
            accessibilityLabel = label
            #endif
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
