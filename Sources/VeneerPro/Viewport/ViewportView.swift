import AppKit
import SceneKit
import SwiftUI

/// The 3D preview. Clicking a surface selects its object and material.
struct ViewportView: NSViewRepresentable {
    let document: ModelDocument?
    let settings: ViewerSettings
    let handle: ViewportHandle
    var frameRequest: Int
    var selectedNode: SCNNode?
    var isolatedNode: SCNNode?
    /// Changes when objects move, hide or get deleted, so the selection outline follows.
    var sceneRevision: Int
    var onPick: (_ node: SCNNode?, _ material: SCNMaterial?) -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> SCNView {
        let view = ViewportSCNView()
        view.scene = context.coordinator.scene
        view.pointOfView = context.coordinator.cameraNode
        view.allowsCameraControl = true
        view.antialiasingMode = .multisampling4X
        view.rendersContinuously = false
        view.backgroundColor = .black
        let click = NSClickGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.clicked(_:)))
        view.addGestureRecognizer(click)
        context.coordinator.view = view
        handle.view = view
        return view
    }

    func updateNSView(_ view: SCNView, context: Context) {
        let c = context.coordinator
        c.onPick = onPick
        handle.root = document?.root
        if c.currentRoot !== document?.root {
            c.show(document?.root)
        } else if c.lastFrameRequest != frameRequest {
            c.frameModel(focus: selectedNode)
        }
        c.lastFrameRequest = frameRequest
        c.apply(settings)
        c.applySelection(selected: selectedNode, isolated: isolatedNode, revision: sceneRevision)
    }

    final class Coordinator: NSObject {
        let scene = SCNScene()
        let cameraNode = SCNNode()
        private let gridNode = SCNNode()
        weak var view: SCNView?
        private(set) weak var currentRoot: SCNNode?
        var onPick: ((SCNNode?, SCNMaterial?) -> Void)?
        var lastFrameRequest = 0
        private let selectionOutline = SCNNode()
        private var shownSelection: (node: SCNNode?, isolated: SCNNode?, revision: Int)?
        /// Meshes faded out by isolation (restored when isolation ends).
        private var isolationFaded: [SCNNode] = []
        /// The requested environment, its loaded HDR pixels, and the rotation they were last built at.
        private var requestedEnvironment: EnvironmentSource?
        private var loadedPixels: HDRPixels?
        private var builtRotation: Double?
        private var wantedRotation: Double = 0
        private var buildGeneration = 0
        private var showEnvironment = true
        private var appliedBackdrop: CGImage?

        override init() {
            super.init()
            let camera = SCNCamera()
            camera.wantsHDR = true
            camera.wantsExposureAdaptation = false
            camera.fieldOfView = 40
            camera.bloomIntensity = 0
            cameraNode.camera = camera
            cameraNode.name = "__viewer_camera"
            scene.rootNode.addChildNode(cameraNode)
            gridNode.name = "__viewer_grid"
            scene.rootNode.addChildNode(gridNode)
            scene.lightingEnvironment.intensity = 1
        }

        func show(_ root: SCNNode?) {
            currentRoot?.removeFromParentNode()
            currentRoot = root
            guard let root else {
                gridNode.geometry = nil
                return
            }
            root.removeFromParentNode()
            scene.rootNode.addChildNode(root)
            frameModel()
        }

        private func worldBounds(of target: SCNNode? = nil) -> (min: SIMD3<Float>, max: SIMD3<Float>)? {
            guard let root = target ?? currentRoot else { return nil }
            var lo = SIMD3<Float>(repeating: .greatestFiniteMagnitude), hi = -lo
            root.enumerateHierarchy { node, _ in
                guard node.geometry != nil, !node.isHidden else { return }
                let (a, b) = node.boundingBox
                for corner in 0..<8 {
                    let p = SCNVector3(corner & 1 == 0 ? a.x : b.x, corner & 2 == 0 ? a.y : b.y, corner & 4 == 0 ? a.z : b.z)
                    let w = SIMD3<Float>(node.convertPosition(p, to: nil))
                    lo = simd_min(lo, w)
                    hi = simd_max(hi, w)
                }
            }
            return lo.x <= hi.x ? (lo, hi) : nil
        }

        /// Frames the whole model, or `focus` (the selected object) when given.
        func frameModel(focus: SCNNode? = nil) {
            guard let (lo, hi) = worldBounds(of: focus) ?? worldBounds() else { return }
            let center = (lo + hi) / 2
            let radius = max(simd_length(hi - lo) / 2, 0.001)
            let distance = radius / sin(Float(20 * Double.pi / 180)) * 1.1
            let direction = simd_normalize(SIMD3<Float>(0.6, 0.45, 1))
            cameraNode.simdPosition = center + direction * distance
            cameraNode.simdLook(at: center)
            cameraNode.camera?.zNear = Double(radius) * 0.01
            cameraNode.camera?.zFar = Double(radius) * 100
            view?.pointOfView = cameraNode
            view?.defaultCameraController.target = SCNVector3(center)
            if focus == nil { buildGrid(lo: lo, hi: hi, radius: radius) }
        }

        private func buildGrid(lo: SIMD3<Float>, hi: SIMD3<Float>, radius: Float) {
            // A grid sized to the model, one line per "nice" step.
            let extent = radius * 2.5
            let step = powf(10, (log10f(extent / 5)).rounded(.down))
            let lines = Int((extent / step).rounded(.up))
            var vertices: [SCNVector3] = []
            let cx = ((lo.x + hi.x) / 2 / step).rounded() * step, cz = ((lo.z + hi.z) / 2 / step).rounded() * step
            for i in -lines...lines {
                let o = Float(i) * step
                let span = Float(lines) * step
                vertices += [SCNVector3(cx + o, 0, cz - span), SCNVector3(cx + o, 0, cz + span),
                             SCNVector3(cx - span, 0, cz + o), SCNVector3(cx + span, 0, cz + o)]
            }
            let source = SCNGeometrySource(vertices: vertices)
            let element = SCNGeometryElement(indices: (0..<Int32(vertices.count)).map { $0 }, primitiveType: .line)
            let geometry = SCNGeometry(sources: [source], elements: [element])
            let material = SCNMaterial()
            material.lightingModel = .constant
            material.diffuse.contents = NSColor(white: 0.55, alpha: 0.35)
            material.blendMode = .alpha
            geometry.materials = [material]
            gridNode.geometry = geometry
            gridNode.simdPosition = SIMD3(0, lo.y, 0)
        }

        func apply(_ settings: ViewerSettings) {
            showEnvironment = settings.showEnvironment
            wantedRotation = settings.environmentRotation
            if requestedEnvironment != settings.environment {
                requestedEnvironment = settings.environment
                let source = settings.environment
                Task { @MainActor in
                    // Large HDRIs take a moment to decode; the previous lighting stays up meanwhile.
                    guard let pixels = await EnvironmentLoader.load(source), self.requestedEnvironment == source else { return }
                    self.loadedPixels = pixels
                    self.builtRotation = nil
                    self.rebuildEnvironment()
                }
            } else if builtRotation != wantedRotation {
                rebuildEnvironment()
            }
            scene.lightingEnvironment.intensity = CGFloat(settings.environmentIntensity)
            updateBackground()
            cameraNode.camera?.exposureOffset = settings.exposure
            gridNode.isHidden = !settings.showGrid
            scene.isPaused = !settings.isPlaying
            view?.isPlaying = settings.isPlaying
        }

        /// Builds the lighting and backdrop images for the current rotation, off the main thread.
        private func rebuildEnvironment() {
            guard let pixels = loadedPixels else { return }
            let rotation = wantedRotation
            builtRotation = rotation
            buildGeneration += 1
            let generation = buildGeneration
            Task { @MainActor in
                let images = await Task.detached(priority: .userInitiated) { () -> (CGImage?, CGImage?) in
                    let rotated = pixels.rotated(degrees: rotation)
                    return (rotated.cgImage(), rotated.backdropImage())
                }.value
                guard generation == self.buildGeneration else { return }
                self.scene.lightingEnvironment.contents = images.0
                self.appliedBackdrop = images.1
                self.updateBackground()
            }
        }

        private func updateBackground() {
            scene.background.contents = showEnvironment ? appliedBackdrop as Any? : NSColor(white: 0.18, alpha: 1)
        }

        @objc func clicked(_ gesture: NSClickGestureRecognizer) {
            guard let view, let root = currentRoot else { return }
            let point = gesture.location(in: view)
            // Gesture actions are delivered on the main thread.
            MainActor.assumeIsolated {
                let hit = ViewportHandle.hit(in: view, root: root, at: point)
                onPick?(hit?.node, hit?.material)
            }
        }

        // MARK: Selection & isolation

        func applySelection(selected: SCNNode?, isolated: SCNNode?, revision: Int) {
            if let shown = shownSelection, shown.node === selected, shown.isolated === isolated, shown.revision == revision { return }
            shownSelection = (selected, isolated, revision)

            // Isolation fades every other mesh out completely (view-only: opacity isn't exported).
            for node in isolationFaded { node.opacity = 1 }
            isolationFaded = []
            if let isolated, let root = currentRoot {
                root.enumerateHierarchy { node, _ in
                    guard node.geometry != nil, node !== isolated, !node.isDescendant(of: isolated) else { return }
                    node.opacity = 0
                    isolationFaded.append(node)
                }
            }

            selectionOutline.geometry = nil
            guard let selected, selected.parent != nil, let (lo, hi) = worldBounds(of: selected) else { return }
            if selectionOutline.parent == nil { scene.rootNode.addChildNode(selectionOutline) }
            selectionOutline.geometry = Self.boxOutline(lo: lo, hi: hi)
            selectionOutline.renderingOrder = 1000
        }

        /// A bounding-box wireframe drawn on top of everything, in the accent color.
        private static func boxOutline(lo: SIMD3<Float>, hi: SIMD3<Float>) -> SCNGeometry {
            let pad = simd_length(hi - lo) * 0.01
            let a = lo - pad, b = hi + pad
            let corners = (0..<8).map { i in SCNVector3(i & 1 == 0 ? a.x : b.x, i & 2 == 0 ? a.y : b.y, i & 4 == 0 ? a.z : b.z) }
            let edges: [Int32] = [0, 1, 2, 3, 4, 5, 6, 7, 0, 2, 1, 3, 4, 6, 5, 7, 0, 4, 1, 5, 2, 6, 3, 7]
            let geometry = SCNGeometry(sources: [SCNGeometrySource(vertices: corners)],
                                       elements: [SCNGeometryElement(indices: edges, primitiveType: .line)])
            let material = SCNMaterial()
            material.lightingModel = .constant
            material.diffuse.contents = NSColor.controlAccentColor
            material.readsFromDepthBuffer = false
            geometry.materials = [material]
            return geometry
        }
    }
}

/// Lets SwiftUI code hit-test the viewport, e.g. to find the surface under a dropped library material.
@MainActor
final class ViewportHandle {
    weak var view: SCNView?
    weak var root: SCNNode?

    /// `point` is in SwiftUI's top-left-origin coordinates of the viewport.
    func material(atTopLeft point: CGPoint) -> SCNMaterial? {
        guard let view, let root else { return nil }
        return Self.material(in: view, root: root, at: CGPoint(x: point.x, y: view.bounds.height - point.y))
    }

    /// `point` is in the SCNView's own (bottom-left-origin) coordinates.
    static func material(in view: SCNView, root: SCNNode, at point: CGPoint) -> SCNMaterial? {
        hit(in: view, root: root, at: point)?.material
    }

    /// The visible object and material under `point` (isolated-away objects are skipped).
    static func hit(in view: SCNView, root: SCNNode, at point: CGPoint) -> (node: SCNNode, material: SCNMaterial?)? {
        let hits = view.hitTest(point, options: [.rootNode: root, .searchMode: SCNHitTestSearchMode.all.rawValue,
                                                 .ignoreHiddenNodes: true])
        guard let hit = hits.first(where: { $0.node.opacity > 0 }) else { return nil }
        let materials = hit.node.geometry?.materials ?? []
        return (hit.node, materials.isEmpty ? nil : materials[hit.geometryIndex % materials.count])
    }
}

/// SCNView whose camera controller ignores double-clicks. SceneKit's built-in double-click
/// "frames" the whole scene (grid included), which reads as a brief zoom-out glitch when
/// double-clicking a part to select it.
final class ViewportSCNView: SCNView {
    override func mouseDown(with event: NSEvent) {
        guard event.clickCount < 2 else { return }
        super.mouseDown(with: event)
    }

    override func mouseUp(with event: NSEvent) {
        guard event.clickCount < 2 else { return }
        super.mouseUp(with: event)
    }
}
