#if os(macOS)
import AppKit
#else
import UIKit
#endif
import SceneKit
import SwiftUI

/// The 3D preview. Clicking a surface selects its object and material. In Compare mode it shows two
/// models side by side, in the same lighting and at true relative scale.
struct ViewportView: PlatformViewRepresentable {
    /// The models shown, in a fixed left-to-right order (one, or two when comparing).
    let documents: [ModelDocument]
    let settings: ViewerSettings
    let handle: ViewportHandle
    var frameRequest: Int
    var selectedNode: SCNNode?
    /// Every selected object (outlined); `selectedNode` is the most recent.
    var selectedNodes: [SCNNode] = []
    var isolatedNode: SCNNode?
    /// Changes when objects move, hide or get deleted, so the selection outline follows.
    var sceneRevision: Int
    var gumball = GumballSettings()
    /// A finished gumball drag (move, rotate or pivot), for undo.
    var onGumballEdit: (GumballEdit) -> Void = { _ in }
    /// `extend` is true for ⌘- or ⇧-clicks, which add to (or remove from) the selection.
    var onPick: (_ node: SCNNode?, _ material: SCNMaterial?, _ extend: Bool) -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    #if os(macOS)
    func makeNSView(context: Context) -> SCNView { makeView(context: context) }
    func updateNSView(_ view: SCNView, context: Context) { updateView(view, context: context) }
    #else
    func makeUIView(context: Context) -> SCNView { makeView(context: context) }
    func updateUIView(_ view: SCNView, context: Context) { updateView(view, context: context) }
    #endif

    private func makeView(context: Context) -> SCNView {
        let view = ViewportSCNView()
        view.coordinator = context.coordinator
        view.scene = context.coordinator.scene
        view.pointOfView = context.coordinator.cameraNode
        view.allowsCameraControl = true
        view.antialiasingMode = .multisampling4X
        view.rendersContinuously = false
        view.backgroundColor = .black
        let click = PlatformTapGesture(target: context.coordinator, action: #selector(Coordinator.clicked(_:)))
        view.addGestureRecognizer(click)
        context.coordinator.view = view
        handle.view = view
        handle.coordinator = context.coordinator
        context.coordinator.handle = handle
        return view
    }

    private func updateView(_ view: SCNView, context: Context) {
        let c = context.coordinator
        c.onPick = onPick
        let roots = documents.map(\.root)
        handle.roots = roots
        // The first model's units are the scene's; others are scaled so sizes compare truthfully.
        let unit = documents.first?.metadata.metersPerUnit ?? 1
        let scales = documents.map { Float($0.metadata.metersPerUnit / unit) }
        if !c.isShowing(roots, scales: scales) {
            c.show(roots, scales: scales)
        } else if c.lastFrameRequest != frameRequest {
            c.frameModel(focus: selectedNode)
        }
        c.lastFrameRequest = frameRequest
        c.setMetersPerUnit(unit)
        c.apply(settings)
        c.applySelection(selected: selectedNodes, isolated: isolatedNode, revision: sceneRevision)
        c.gumball.onEdit = onGumballEdit
        c.gumball.camera.node = view.pointOfView
        c.gumball.update(targets: selectedNodes, settings: gumball)
    }

    @MainActor
    final class Coordinator: NSObject {
        let gumball = Gumball()
        /// Set when a mouse-down landed on the gumball, so the click recognizer doesn't also pick.
        var gumballTookClick = false
        let scene = SCNScene()
        let cameraNode = SCNNode()
        private let gridNode = SCNNode()
        weak var view: SCNView?
        weak var handle: ViewportHandle?
        /// The models in the scene, left to right.
        private(set) var roots: [SCNNode] = []
        private var rootScales: [Float] = []
        var currentRoot: SCNNode? { roots.first }
        var onPick: ((SCNNode?, SCNMaterial?, Bool) -> Void)?
        var lastFrameRequest = 0
        private let selectionOutline = SCNNode()
        private var shownSelection: (nodes: [ObjectIdentifier], isolated: SCNNode?, revision: Int)?
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
        /// The true-scale clay scene: scaled into the model's units and positioned under it.
        private let scaleRoot = SCNNode()
        private let sun = SCNNode()
        private var builtScene: ScaleScene?
        private var sceneAnchor: SIMD3<Float> = .zero
        private var sceneFrame: (lo: SIMD3<Float>, hi: SIMD3<Float>)?
        private var metersPerUnit: Double = 1
        private var placedRevision: Int?
        /// The studio ground under the model, and a light that only lights the ground so the model
        /// casts a shadow on it without its own lighting changing.
        private let groundNode = SCNNode()
        private let groundLight = SCNNode()
        private static let groundCategory = 1 << 3
        private var builtGround: (show: Bool, style: GroundStyle, shade: Double)?

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
            scaleRoot.name = "__scale_scene"
            scene.rootNode.addChildNode(scaleRoot)
            // A soft key light so the model grounds itself with contact shadows in scale scenes.
            let light = SCNLight()
            light.type = .directional
            light.intensity = 650
            light.castsShadow = true
            light.automaticallyAdjustsShadowProjection = true
            light.shadowMapSize = CGSize(width: 4096, height: 4096)
            light.shadowSampleCount = 16
            light.shadowRadius = 6
            light.shadowColor = NSColor(white: 0, alpha: 0.5)
            sun.light = light
            scene.lightingEnvironment.intensity = 1

            let floor = SCNFloor()
            floor.reflectivity = 0
            groundNode.geometry = floor
            groundNode.name = "__viewer_ground"
            groundNode.categoryBitMask = Self.groundCategory
            groundNode.castsShadow = false
            groundNode.renderingOrder = -1
            scene.rootNode.addChildNode(groundNode)
            let shadowLight = SCNLight()
            shadowLight.type = .directional
            shadowLight.intensity = 900
            shadowLight.categoryBitMask = Self.groundCategory
            shadowLight.castsShadow = true
            shadowLight.automaticallyAdjustsShadowProjection = false
            shadowLight.shadowMapSize = CGSize(width: 4096, height: 4096)
            shadowLight.shadowSampleCount = 24
            shadowLight.shadowRadius = 10
            shadowLight.shadowColor = NSColor(white: 0, alpha: 0.55)
            groundLight.light = shadowLight
            groundLight.name = "__viewer_ground_light"
            scene.rootNode.addChildNode(groundLight)
            scene.rootNode.addChildNode(gumball.root)
            scene.rootNode.addChildNode(gumball.hingeLine)
        }

        func isShowing(_ roots: [SCNNode], scales: [Float]) -> Bool {
            self.roots.count == roots.count && zip(self.roots, roots).allSatisfy { $0 === $1 } && rootScales == scales
        }

        /// Single-model convenience (offscreen renders).
        func show(_ root: SCNNode?) { show(root.map { [$0] } ?? [], scales: [1]) }

        func show(_ newRoots: [SCNNode], scales: [Float]) {
            for root in roots where !newRoots.contains(where: { $0 === root }) { root.removeFromParentNode() }
            roots = newRoots
            rootScales = scales
            guard !newRoots.isEmpty else {
                gridNode.geometry = nil
                return
            }
            for root in newRoots where root.parent !== scene.rootNode {
                root.removeFromParentNode()
                scene.rootNode.addChildNode(root)
            }
            layoutRoots()
            placeScaleScene()
            frameModel()
        }

        /// Puts the models side by side: the first at the origin, each next one to its right with a gap,
        /// bottoms level and centered in depth. Only the container nodes move, which are never exported.
        private func layoutRoots() {
            for (i, root) in roots.enumerated() {
                root.simdPosition = .zero
                root.simdScale = SIMD3(repeating: i < rootScales.count ? rootScales[i] : 1)
            }
            guard roots.count > 1, var previous = worldBounds(of: roots[0]) else { return }
            for root in roots.dropFirst() {
                guard let bounds = worldBounds(of: root) else { continue }
                let gap = max(previous.max.x - previous.min.x, bounds.max.x - bounds.min.x) * 0.25
                let offset = SIMD3<Float>(previous.max.x + gap - bounds.min.x,
                                          previous.min.y - bounds.min.y,
                                          (previous.min.z + previous.max.z) / 2 - (bounds.min.z + bounds.max.z) / 2)
                root.simdPosition = offset
                previous = (bounds.min + offset, bounds.max + offset)
            }
        }

        private func worldBounds(of target: SCNNode? = nil) -> (min: SIMD3<Float>, max: SIMD3<Float>)? {
            let targets = target.map { [$0] } ?? roots
            guard !targets.isEmpty else { return nil }
            var lo = SIMD3<Float>(repeating: .greatestFiniteMagnitude), hi = -lo
            for root in targets { root.enumerateHierarchy { node, _ in
                guard node.geometry != nil, !node.isHidden else { return }
                let (a, b) = node.boundingBox
                for corner in 0..<8 {
                    let p = SCNVector3(corner & 1 == 0 ? a.x : b.x, corner & 2 == 0 ? a.y : b.y, corner & 4 == 0 ? a.z : b.z)
                    let w = SIMD3<Float>(node.convertPosition(p, to: nil))
                    lo = simd_min(lo, w)
                    hi = simd_max(hi, w)
                }
            } }
            return lo.x <= hi.x ? (lo, hi) : nil
        }

        /// Frames the whole model, or `focus` (the selected object) when given.
        func frameModel(focus: SCNNode? = nil) {
            guard var (lo, hi) = worldBounds(of: focus) ?? worldBounds() else { return }
            // In a scale scene, take in the surroundings too.
            if focus == nil, let region = sceneFrameInWorld() {
                lo = simd_min(lo, region.lo)
                hi = simd_max(hi, region.hi)
            }
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
            applyScaleScene(settings.scaleScene)
            gridNode.isHidden = !settings.showGrid || settings.scaleScene.kind != .none
            applyGround(show: settings.showGround && settings.scaleScene.kind == .none, style: settings.groundStyle,
                        shade: settings.groundShade)
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
                self.handle?.environmentChanged(lighting: images.0, backdrop: images.1)
                self.updateBackground()
            }
        }

        private func updateBackground() {
            scene.background.contents = showEnvironment ? appliedBackdrop as Any? : NSColor(white: 0.18, alpha: 1)
        }

        @objc func clicked(_ gesture: PlatformTapGesture) {
            if gumballTookClick { gumballTookClick = false; return }
            guard let view, !roots.isEmpty else { return }
            let point = gesture.location(in: view)
            let roots = roots
            // Gesture actions are delivered on the main thread.
            MainActor.assumeIsolated {
                let hit = ViewportHandle.hit(in: view, roots: roots, at: point)
                #if os(macOS)
                let flags = NSApp.currentEvent?.modifierFlags ?? []
                let extend = flags.contains(.command) || flags.contains(.shift)
                #else
                let extend = false
                #endif
                onPick?(hit?.node, hit?.material, extend)
            }
        }

        // MARK: Selection & isolation

        // MARK: Scale scenes

        func setMetersPerUnit(_ value: Double) {
            guard value != metersPerUnit else { return }
            metersPerUnit = value
            placeScaleScene()
        }

        private func applyScaleScene(_ setup: ScaleScene) {
            guard setup != builtScene else { return }
            let reframe = builtScene?.kind != setup.kind || builtScene?.effectiveSurface != setup.effectiveSurface
            builtScene = setup
            scaleRoot.childNodes.forEach { $0.removeFromParentNode() }
            sun.removeFromParentNode()
            sceneFrame = nil
            if let built = ScaleSceneBuilder.build(setup) {
                scaleRoot.addChildNode(built.node)
                // The sun lives outside the scaled container: a scaled light node breaks shadow projection.
                if sun.parent == nil { scene.rootNode.addChildNode(sun) }
                sceneAnchor = built.anchor
                sceneFrame = built.frame
            }
            placeScaleScene()
            if reframe, currentRoot != nil { frameModel() }
        }

        /// Puts the scene's anchor (e.g. the desktop) under the model's bottom center, at the model's scale.
        private func placeScaleScene() {
            placeGround()
            guard sceneFrame != nil else { return }
            let mpu = Float(max(metersPerUnit, 1e-9))
            scaleRoot.simdScale = SIMD3(repeating: 1 / mpu)
            let bounds = worldBounds() ?? (.zero, .zero)
            let bottom = SIMD3((bounds.min.x + bounds.max.x) / 2, bounds.min.y, (bounds.min.z + bounds.max.z) / 2)
            scaleRoot.simdPosition = bottom - sceneAnchor / mpu
            // Aim the sun at the model from above, front-left.
            sun.simdPosition = bottom + SIMD3<Float>(-1.2, 3, 1.6) / mpu
            sun.simdLook(at: bottom)
            // Shadow ranges are in scene units; express them in meters so millimeter models get shadows too.
            sun.light?.maximumShadowDistance = CGFloat(12 / mpu)
            sun.light?.zNear = CGFloat(0.01 / mpu)
            sun.light?.zFar = CGFloat(40 / mpu)
            sun.light?.orthographicScale = CGFloat(4 / mpu)
        }

        // MARK: Ground

        private func applyGround(show: Bool, style: GroundStyle, shade: Double) {
            if let built = builtGround, built.show == show, built.style == style, built.shade == shade { return }
            builtGround = (show, style, shade)
            groundNode.isHidden = !show
            groundLight.isHidden = !show
            let material = SCNMaterial()
            switch style {
            case .solid:
                material.lightingModel = .physicallyBased
                material.diffuse.contents = NSColor(white: shade, alpha: 1)
                material.roughness.contents = 0.85
                material.metalness.contents = 0
            case .shadowOnly:
                // Transparent except for the shadow, so the environment backdrop shows through.
                material.lightingModel = .shadowOnly
            }
            material.writesToDepthBuffer = true
            groundNode.geometry?.materials = [material]
            placeGround()
        }

        /// Keeps the ground at the models' lowest point and fits the shadow to them.
        private func placeGround(around bounds: (min: SIMD3<Float>, max: SIMD3<Float>)? = nil) {
            guard let (lo, hi) = bounds ?? worldBounds() else { return }
            let center = (lo + hi) / 2
            let radius = max(simd_length(hi - lo) / 2, 0.001)
            // A hair below the bottom so the grid and the model's base don't flicker against it.
            groundNode.simdPosition = SIMD3(center.x, lo.y - radius * 0.0005, center.z)
            // Mostly overhead, slightly from the front-left, like a softbox above the set.
            groundLight.simdPosition = SIMD3(center.x, lo.y, center.z) + SIMD3<Float>(-0.35, 1, 0.45) * radius * 4
            groundLight.simdLook(at: SIMD3(center.x, lo.y, center.z))
            groundLight.light?.orthographicScale = CGFloat(radius * 2.2)
            groundLight.light?.zNear = CGFloat(radius * 0.1)
            groundLight.light?.zFar = CGFloat(radius * 12)
        }

        private func sceneFrameInWorld() -> (lo: SIMD3<Float>, hi: SIMD3<Float>)? {
            guard let frame = sceneFrame else { return nil }
            let a = scaleRoot.simdConvertPosition(frame.lo, to: nil), b = scaleRoot.simdConvertPosition(frame.hi, to: nil)
            return (simd_min(a, b), simd_max(a, b))
        }

        func applySelection(selected: [SCNNode], isolated: SCNNode?, revision: Int) {
            // Object edits can change the model's footprint: keep it standing on the scene's surface.
            if placedRevision != revision {
                placedRevision = revision
                layoutRoots()
                placeScaleScene()
            }
            let ids = selected.map(ObjectIdentifier.init)
            if let shown = shownSelection, shown.nodes == ids, shown.isolated === isolated, shown.revision == revision { return }
            shownSelection = (ids, isolated, revision)

            // Isolation fades every other mesh out completely (view-only: opacity isn't exported).
            for node in isolationFaded { node.opacity = 1 }
            isolationFaded = []
            if let isolated {
                for root in roots {
                    root.enumerateHierarchy { node, _ in
                        guard node.geometry != nil, node !== isolated, !node.isDescendant(of: isolated) else { return }
                        node.opacity = 0
                        isolationFaded.append(node)
                    }
                }
            }

            selectionOutline.childNodes.forEach { $0.removeFromParentNode() }
            if selectionOutline.parent == nil { scene.rootNode.addChildNode(selectionOutline) }
            for node in selected where node.parent != nil {
                guard let (lo, hi) = worldBounds(of: node) else { continue }
                let box = SCNNode(geometry: Self.boxOutline(lo: lo, hi: hi))
                box.renderingOrder = 1000
                selectionOutline.addChildNode(box)
            }
        }

        // MARK: Stills (spec sheets)

        enum StillAngle { case hero, front, side, top }

        /// Renders `root` alone from each angle on a transparent background, with a shadow on the
        /// ground and no grid, outlines or scale scene. The viewport's own state is put back after.
        func renderStills(of root: SCNNode, angles: [StillAngle], size: CGSize) -> [CGImage] {
            guard let (lo, hi) = worldBounds(of: root), let device = MTLCreateSystemDefaultDevice() else { return [] }
            // Hide everything that isn't the model and its shadow.
            let background = scene.background.contents
            let ground = builtGround
            var hidden: [(SCNNode, Bool)] = []
            for node in [gridNode, selectionOutline, scaleRoot, sun, gumball.root, gumball.hingeLine] + roots.filter({ $0 !== root }) {
                hidden.append((node, node.isHidden))
                node.isHidden = true
            }
            let faded = isolationFaded
            faded.forEach { $0.opacity = 1 }
            scene.background.contents = NSColor.clear
            builtGround = nil
            applyGround(show: true, style: .shadowOnly, shade: 0)
            let shadowColor = groundLight.light?.shadowColor, shadowRadius = groundLight.light?.shadowRadius
            groundLight.light?.shadowColor = NSColor(white: 0, alpha: 0.32)
            groundLight.light?.shadowRadius = 16
            defer {
                groundLight.light?.shadowColor = shadowColor
                groundLight.light?.shadowRadius = shadowRadius ?? 10
                scene.background.contents = background
                for (node, wasHidden) in hidden { node.isHidden = wasHidden }
                faded.forEach { $0.opacity = 0 }
                builtGround = nil
                if let ground { applyGround(show: ground.show, style: ground.style, shade: ground.shade) }
                placeGround()
            }
            placeGround(around: (lo, hi))

            let renderer = SCNRenderer(device: device, options: nil)
            renderer.scene = scene
            let center = (lo + hi) / 2
            let extent = hi - lo
            let radius = max(simd_length(extent) / 2, 0.001)
            let aspect = Float(size.width / size.height)
            return angles.compactMap { angle in
                let camera = SCNCamera()
                camera.wantsHDR = true
                camera.wantsExposureAdaptation = false
                camera.exposureOffset = cameraNode.camera?.exposureOffset ?? 0
                camera.bloomIntensity = 0
                camera.zNear = Double(radius) * 0.01
                camera.zFar = Double(radius) * 100
                let node = SCNNode()
                node.camera = camera
                // Orthographic views fit the model's face toward the camera with a 10% margin.
                func ortho(width: Float, height: Float) {
                    camera.usesOrthographicProjection = true
                    camera.orthographicScale = Double(max(height, width / aspect) / 2 * 1.12)
                }
                switch angle {
                case .hero:
                    camera.fieldOfView = 30
                    let direction = simd_normalize(SIMD3<Float>(0.62, 0.42, 1))
                    node.simdPosition = center + direction * (radius / sin(Float(15 * Double.pi / 180)) * 1.02)
                    node.simdLook(at: center)
                case .front:
                    ortho(width: extent.x, height: extent.y)
                    node.simdPosition = center + SIMD3(0, 0, radius * 4)
                    node.simdLook(at: center)
                case .side:
                    ortho(width: extent.z, height: extent.y)
                    node.simdPosition = center + SIMD3(radius * 4, 0, 0)
                    node.simdLook(at: center)
                case .top:
                    ortho(width: extent.x, height: extent.z)
                    node.simdPosition = center + SIMD3(0, radius * 4, 0)
                    node.simdLook(at: center, up: SIMD3(0, 0, -1), localFront: SIMD3(0, 0, -1))
                }
                scene.rootNode.addChildNode(node)
                // Seen from above, the shadow would only cover the plan view.
                groundNode.isHidden = angle == .top
                defer { node.removeFromParentNode(); groundNode.isHidden = false }
                renderer.pointOfView = node
                let image = renderer.snapshot(atTime: 0, with: size, antialiasingMode: .multisampling4X)
                return image.cgImage(forProposedRect: nil, context: nil, hints: nil)
            }
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
@Observable
final class ViewportHandle {
    @ObservationIgnored weak var view: SCNView?
    @ObservationIgnored weak var coordinator: ViewportView.Coordinator?
    /// The viewer's current lighting and backdrop images, for the AR Match view.
    private(set) var lightingImage: CGImage?
    private(set) var backdropImage: CGImage?

    func environmentChanged(lighting: CGImage?, backdrop: CGImage?) {
        lightingImage = lighting
        backdropImage = backdrop
    }
    /// The models in the viewport (two when comparing).
    @ObservationIgnored var roots: [SCNNode] = []
    /// The first model, for code that only needs one.
    var root: SCNNode? { roots.first }

    /// `point` is in SwiftUI's top-left-origin coordinates of the viewport.
    func material(atTopLeft point: CGPoint) -> SCNMaterial? {
        guard let view, !roots.isEmpty else { return nil }
        return Self.hit(in: view, roots: roots, at: CGPoint(x: point.x, y: view.bounds.height - point.y))?.material
    }

    /// The visible object and material under `point` (isolated-away objects, the grid and scale-scene
    /// props are skipped).
    static func hit(in view: SCNView, roots: [SCNNode], at point: CGPoint) -> (node: SCNNode, material: SCNMaterial?)? {
        let hits = view.hitTest(point, options: [.searchMode: SCNHitTestSearchMode.all.rawValue, .ignoreHiddenNodes: true])
        guard let hit = hits.first(where: { hit in
            hit.node.opacity > 0 && roots.contains { hit.node === $0 || hit.node.isDescendant(of: $0) }
        }) else { return nil }
        let materials = hit.node.geometry?.materials ?? []
        return (hit.node, materials.isEmpty ? nil : materials[hit.geometryIndex % materials.count])
    }
}

/// SCNView whose camera controller ignores double-clicks. SceneKit's built-in double-click
/// "frames" the whole scene (grid included), which reads as a brief zoom-out glitch when
/// double-clicking a part to select it.
final class ViewportSCNView: SCNView {
    weak var coordinator: ViewportView.Coordinator?
    #if os(macOS)

    override func mouseDown(with event: NSEvent) {
        // Gumball handles take the drag (and the click) before the camera does.
        let point = convert(event.locationInWindow, from: nil)
        if let coordinator, coordinator.gumball.mouseDown(at: point, in: self) {
            coordinator.gumballTookClick = true
            return
        }
        guard event.clickCount < 2 else { return }
        super.mouseDown(with: event)
    }

    override func mouseDragged(with event: NSEvent) {
        if let gumball = coordinator?.gumball, gumball.isDragging {
            gumball.mouseDragged(to: convert(event.locationInWindow, from: nil), in: self,
                                 snap: event.modifierFlags.contains(.shift))
            return
        }
        super.mouseDragged(with: event)
    }

    override func mouseUp(with event: NSEvent) {
        if let gumball = coordinator?.gumball, gumball.isDragging {
            gumball.mouseUp()
            return
        }
        guard event.clickCount < 2 else { return }
        super.mouseUp(with: event)
    }
    #endif
}
