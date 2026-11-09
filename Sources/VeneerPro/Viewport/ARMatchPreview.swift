#if os(macOS)
import AppKit
import Observation
import RealityKit
import SwiftUI

/// "AR Match": the model as AR Quick Look and Vision Pro will show it. It renders the exact USDZ that
/// Share to iPhone sends, in RealityKit (the renderer behind Quick Look), re-exported after each edit.
/// View only; editing happens in the regular viewer.
@MainActor
@Observable
final class ARMatchPreview {
    enum State: Equatable {
        case idle
        case exporting
        case ready
        case failed(String)
    }

    private(set) var state: State = .idle
    /// The latest exported file; bumped URL per export so the view reloads.
    private(set) var fileURL: URL?
    @ObservationIgnored private weak var document: ModelDocument?
    @ObservationIgnored private var folder: URL?
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var exportTask: Task<Void, Never>?
    @ObservationIgnored private var isExporting = false
    @ObservationIgnored private var pendingExport = false
    @ObservationIgnored private var version = 0

    var isActive: Bool { document != nil }

    func start(_ document: ModelDocument) {
        guard document !== self.document else { return }
        stop()
        self.document = document
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("VeneerPro-ARMatch-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        self.folder = folder
        for name in [Notification.Name.materialsDidChange, .sceneDidChange] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    if name == .sceneDidChange, (note.object as AnyObject?) !== self.document { return }
                    self.scheduleExport(delay: 0.8)
                }
            })
        }
        scheduleExport(delay: 0)
    }

    func stop() {
        exportTask?.cancel()
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        if let folder { try? FileManager.default.removeItem(at: folder) }
        folder = nil
        fileURL = nil
        document = nil
        state = .idle
    }

    private func scheduleExport(delay: Double) {
        if isExporting {
            pendingExport = true
            return
        }
        exportTask?.cancel()
        exportTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, let self else { return }
            await self.export()
        }
    }

    private func export() async {
        guard let document, let folder else { return }
        isExporting = true
        state = .exporting
        version += 1
        let url = folder.appendingPathComponent("preview-\(version).usdz")
        do {
            // The same options as Share to iPhone, so this is the file Quick Look would open.
            _ = try await Exporter.export(document, to: url, options: ExportOptions(binary: true, validate: false))
            if let old = fileURL, old != url { try? FileManager.default.removeItem(at: old) }
            fileURL = url
            state = .ready
        } catch {
            state = .failed(error.localizedDescription)
        }
        isExporting = false
        if pendingExport {
            pendingExport = false
            scheduleExport(delay: 0.3)
        }
    }
}

/// RealityKit view of the AR Match file, lit by the viewer's HDRI, with Quick Look's grounding shadow.
struct ARMatchView: View {
    let preview: ARMatchPreview
    let settings: ViewerSettings
    /// The viewer's current lighting and backdrop images (equirectangular).
    let lighting: CGImage?
    let backdrop: CGImage?

    @State private var root = Entity()
    @State private var lightEntity = Entity()
    @State private var cameraEntity = PerspectiveCamera()
    /// Kept apart from `root` so the camera orbits the model, not the floor.
    @State private var groundEntity = Entity()
    /// Orbit camera: yaw/pitch in radians around `center`, at `distance`. Only the user moves it.
    @State private var orbit = Orbit()
    @State private var dragStart: Orbit?
    @State private var zoomStart: Float?
    @State private var environment: EnvironmentResource?
    @State private var skybox: EnvironmentResource?
    @State private var loadedURL: URL?
    @State private var loadError: String?

    var body: some View {
        RealityView { content in
            content.camera = .virtual
            content.add(root)
            content.add(lightEntity)
            content.add(cameraEntity)
            content.add(groundEntity)
        } update: { content in
            orbit.apply(to: cameraEntity)
            if settings.showEnvironment, let skybox {
                content.environment = .skybox(skybox)
            } else {
                content.environment = .default
            }
        }
        .gesture(DragGesture(minimumDistance: 1)
            .onChanged { value in
                let start = dragStart ?? orbit
                dragStart = start
                orbit.yaw = start.yaw - Float(value.translation.width) * 0.008
                orbit.pitch = min(max(start.pitch + Float(value.translation.height) * 0.008, -1.45), 1.45)
            }
            .onEnded { _ in dragStart = nil })
        .simultaneousGesture(MagnifyGesture()
            .onChanged { value in
                let start = zoomStart ?? orbit.distance
                zoomStart = start
                orbit.distance = start / Float(max(value.magnification, 0.05))
            }
            .onEnded { _ in zoomStart = nil })
        .onTapGesture(count: 2) { if let model = root.children.first { frame(model) } }
        .background(ScrollZoom { delta in orbit.distance *= exp(-Float(delta) * 0.01) })
        .background(Color(white: 0.18))
        .task(id: preview.fileURL) { await load(preview.fileURL) }
        .task(id: lightingKey) { await buildEnvironment() }
        .overlay(alignment: .topLeading) { badge }
    }

    /// Rebuild lighting when the HDRI, its rotation or brightness change.
    private var lightingKey: String {
        "\(lighting.map { ObjectIdentifier($0).hashValue } ?? 0)-\(settings.environmentIntensity)-\(settings.exposure)-\(settings.showEnvironment)"
    }

    private var badge: some View {
        HStack(spacing: 6) {
            Image(systemName: "arkit")
            switch preview.state {
            case .exporting: Text("AR Match · Updating…")
            case let .failed(message): Text("AR Match · \(message)").lineLimit(1)
            default: Text(loadError.map { "AR Match · \($0)" } ?? "AR Match · RealityKit, as in AR Quick Look")
            }
        }
        .font(.callout)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(.regularMaterial, in: Capsule())
        .padding(10)
    }

    private func load(_ url: URL?) async {
        guard let url, url != loadedURL else { return }
        do {
            let entity = try await Entity(contentsOf: url)
            // Quick Look gives every model a soft contact shadow on the surface it sits on.
            func shadow(_ e: Entity) {
                if e.components.has(ModelComponent.self) { e.components.set(GroundingShadowComponent(castsShadow: true)) }
                e.children.forEach(shadow)
            }
            shadow(entity)
            // Same parts as on screen: update them in place, so the camera and view don't jump.
            if let current = root.children.first, Self.sameStructure(current, entity) {
                Self.transfer(from: entity, to: current)
                applyLighting()
                loadedURL = url
                loadError = nil
                return
            }
            let firstLoad = root.children.isEmpty
            root.children.removeAll()
            root.addChild(entity)
            groundEntity.children.removeAll()
            if settings.showGround, settings.groundStyle == .solid { addGround(under: entity) }
            applyLighting()
            if firstLoad { frame(entity) }
            loadedURL = url
            loadError = nil
        } catch {
            loadError = error.localizedDescription
        }
    }

    private static func sameStructure(_ a: Entity, _ b: Entity) -> Bool {
        a.name == b.name && a.children.count == b.children.count
            && a.components.has(ModelComponent.self) == b.components.has(ModelComponent.self)
            && zip(a.children, b.children).allSatisfy { sameStructure($0, $1) }
    }

    /// Copies meshes, materials and transforms from a fresh load onto the entities being shown.
    private static func transfer(from source: Entity, to target: Entity) {
        target.transform = source.transform
        target.isEnabled = source.isEnabled
        if let model = source.components[ModelComponent.self] { target.components.set(model) }
        for (a, b) in zip(source.children, target.children) { transfer(from: a, to: b) }
    }

    /// Points the camera at the whole model from the front-right, like the regular viewer's framing.
    private func frame(_ entity: Entity) {
        let bounds = entity.visualBounds(relativeTo: nil)
        let radius = max(simd_length(bounds.extents) / 2, 0.001)
        cameraEntity.camera.fieldOfViewInDegrees = 40
        cameraEntity.camera.near = radius * 0.01
        cameraEntity.camera.far = radius * 100
        orbit = Orbit(center: bounds.center, yaw: atan2(0.6, 1), pitch: 0.38, distance: radius / sin(20 * .pi / 180) * 1.1)
        orbit.apply(to: cameraEntity)
    }

    /// A floor at the model's base to catch the grounding shadow, matching the viewer's solid ground.
    private func addGround(under entity: Entity) {
        let bounds = entity.visualBounds(relativeTo: nil)
        let size = max(bounds.extents.x, bounds.extents.z, bounds.extents.y) * 60
        var material = PhysicallyBasedMaterial()
        material.baseColor = .init(tint: NSColor(white: settings.groundShade, alpha: 1))
        material.roughness = 0.85
        let ground = ModelEntity(mesh: .generatePlane(width: size, depth: size), materials: [material])
        ground.position = SIMD3(bounds.center.x, bounds.min.y - bounds.extents.y * 0.0005, bounds.center.z)
        groundEntity.addChild(ground)
    }

    private func buildEnvironment() async {
        if let lighting { environment = try? await EnvironmentResource(equirectangular: lighting) }
        if let backdrop { skybox = try? await EnvironmentResource(equirectangular: backdrop) }
        applyLighting()
    }

    /// Image-based lighting from the viewer's HDRI on everything in the model.
    private func applyLighting() {
        guard let environment else { return }
        let exponent = Float(log2(max(settings.environmentIntensity, 0.01)) + settings.exposure)
        lightEntity.components.set(ImageBasedLightComponent(source: .single(environment), intensityExponent: exponent))
        func receive(_ e: Entity) {
            e.components.set(ImageBasedLightReceiverComponent(imageBasedLight: lightEntity))
            e.children.forEach(receive)
        }
        receive(root)
        receive(groundEntity)
    }
}

/// The AR Match camera's position on a sphere around the model.
struct Orbit: Equatable {
    var center = SIMD3<Float>(0, 0, 0)
    var yaw: Float = 0.54
    var pitch: Float = 0.38
    var distance: Float = 1

    @MainActor func apply(to camera: Entity) {
        let direction = SIMD3(sin(yaw) * cos(pitch), sin(pitch), cos(yaw) * cos(pitch))
        camera.look(at: center, from: center + direction * max(distance, 1e-4), relativeTo: nil)
    }
}

/// Two-finger scroll (trackpad or mouse wheel) over the view, reported as a zoom delta.
private struct ScrollZoom: NSViewRepresentable {
    let onScroll: (CGFloat) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = ScrollView()
        view.onScroll = onScroll
        return view
    }

    func updateNSView(_ view: NSView, context: Context) { (view as? ScrollView)?.onScroll = onScroll }

    final class ScrollView: NSView {
        var onScroll: ((CGFloat) -> Void)?
        private var monitor: Any?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
            guard window != nil else { return }
            // The RealityView above takes the events; watch scrolls that land inside this view's frame.
            monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                guard let self, let window = self.window, event.window === window,
                      self.bounds.contains(self.convert(event.locationInWindow, from: nil)) else { return event }
                self.onScroll?(event.scrollingDeltaY * (event.hasPreciseScrollingDeltas ? 1 : 8))
                return event
            }
        }

        deinit { if let monitor { NSEvent.removeMonitor(monitor) } }
    }
}
#endif
