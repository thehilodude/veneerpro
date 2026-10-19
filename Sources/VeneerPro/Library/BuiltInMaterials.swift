import AppKit
import SceneKit
import simd

/// "Veneer Essentials": materials that ship with the app, so the library is useful before any folder
/// is linked. Each is a node graph: plain finishes are constants (tiny in USDZ), and textured ones
/// (wood, concrete, fabric, brushed metal) are built from procedural nodes and bake at export.
enum BuiltInMaterials {
    static let root = URL(string: "veneer-builtin://Essentials")!
    static let displayName = "Veneer Essentials"

    static func isBuiltIn(_ url: URL) -> Bool { url.scheme == root.scheme }

    struct Preset {
        let name: String
        let category: String
        let build: (MaterialGraph) -> Void
    }

    static var materials: [LibraryMaterial] {
        presets.map { preset in
            LibraryMaterial(location: url(for: preset), name: preset.name, category: preset.category, maps: [:], keyShotFile: nil)
        }
    }

    static func graph(for material: LibraryMaterial) -> MaterialGraph? {
        guard let preset = presets.first(where: { url(for: $0) == material.location }) else { return nil }
        return graph(for: preset)
    }

    static func graph(for preset: Preset) -> MaterialGraph {
        let graph = MaterialGraph(name: preset.name)
        preset.build(graph)
        return graph
    }

    /// Finds a preset by name, or "Category/Name" (for the command line).
    static func material(named query: String) -> LibraryMaterial? {
        materials.first { m in
            m.name.caseInsensitiveCompare(query) == .orderedSame
                || "\(m.category)/\(m.name)".caseInsensitiveCompare(query) == .orderedSame
        }
    }

    private static func url(for preset: Preset) -> URL {
        root.appendingPathComponent(preset.category).appendingPathComponent(preset.name)
    }

    // MARK: Presets

    /// Colors are sRGB, like everywhere in the graph.
    static let presets: [Preset] = [
        // Metal
        Preset(name: "Polished Chrome", category: "Metal") { surface($0, color: rgb(0.80, 0.81, 0.83), metallic: 1, roughness: 0.04) },
        Preset(name: "Brushed Aluminum", category: "Metal") { g in
            surface(g, color: rgb(0.90, 0.91, 0.92), metallic: 1)
            brushedRoughness(g, low: 0.22, high: 0.42)
        },
        Preset(name: "Stainless Steel", category: "Metal") { surface($0, color: rgb(0.77, 0.77, 0.76), metallic: 1, roughness: 0.22) },
        Preset(name: "Space Grey Anodized", category: "Metal") { surface($0, color: rgb(0.36, 0.37, 0.39), metallic: 1, roughness: 0.38) },
        Preset(name: "Gold", category: "Metal") { surface($0, color: rgb(1.0, 0.80, 0.42), metallic: 1, roughness: 0.15) },
        Preset(name: "Copper", category: "Metal") { surface($0, color: rgb(0.96, 0.64, 0.54), metallic: 1, roughness: 0.22) },

        // Plastic
        Preset(name: "Glossy White ABS", category: "Plastic") { surface($0, color: rgb(0.93, 0.93, 0.92), roughness: 0.14) },
        Preset(name: "Matte Black", category: "Plastic") { surface($0, color: rgb(0.05, 0.05, 0.055), roughness: 0.72) },
        Preset(name: "Soft-Touch Grey", category: "Plastic") { surface($0, color: rgb(0.34, 0.35, 0.36), roughness: 0.88) },
        Preset(name: "Glossy Red", category: "Plastic") { surface($0, color: rgb(0.78, 0.06, 0.06), roughness: 0.1) },
        Preset(name: "Frosted Translucent", category: "Plastic") { surface($0, color: rgb(0.92, 0.93, 0.95), roughness: 0.55, opacity: 0.6) },

        // Paint
        Preset(name: "Gloss Red Car Paint", category: "Paint") {
            surface($0, color: rgb(0.62, 0.02, 0.03), metallic: 0.3, roughness: 0.4, clearcoat: 1, clearcoatRoughness: 0.03)
        },
        Preset(name: "Metallic Blue", category: "Paint") {
            surface($0, color: rgb(0.06, 0.22, 0.58), metallic: 0.6, roughness: 0.35, clearcoat: 1, clearcoatRoughness: 0.04)
        },
        Preset(name: "Satin White", category: "Paint") { surface($0, color: rgb(0.90, 0.90, 0.88), roughness: 0.4, clearcoat: 0.3, clearcoatRoughness: 0.3) },
        Preset(name: "Matte Olive", category: "Paint") { surface($0, color: rgb(0.33, 0.36, 0.22), roughness: 0.82) },

        // Glass
        Preset(name: "Clear Glass", category: "Glass") { surface($0, color: rgb(0.96, 0.97, 0.98), roughness: 0.02, opacity: 0.15) },
        Preset(name: "Frosted Glass", category: "Glass") { surface($0, color: rgb(0.92, 0.94, 0.95), roughness: 0.5, opacity: 0.45) },
        Preset(name: "Smoked Glass", category: "Glass") { surface($0, color: rgb(0.16, 0.16, 0.17), roughness: 0.03, opacity: 0.5) },

        // Rubber & silicone
        Preset(name: "Black Rubber", category: "Rubber") { surface($0, color: rgb(0.035, 0.035, 0.035), roughness: 0.9) },
        Preset(name: "Grey Silicone", category: "Rubber") { surface($0, color: rgb(0.46, 0.47, 0.48), roughness: 0.6) },
        Preset(name: "Orange Silicone", category: "Rubber") { surface($0, color: rgb(0.95, 0.42, 0.08), roughness: 0.55) },

        // Wood
        Preset(name: "Light Oak", category: "Wood") { g in
            woodGrain(g, dark: rgb(0.62, 0.44, 0.26), light: rgb(0.84, 0.68, 0.48), seed: 3)
            surface(g, roughness: 0.55)
        },
        Preset(name: "Walnut", category: "Wood") { g in
            woodGrain(g, dark: rgb(0.20, 0.11, 0.06), light: rgb(0.42, 0.26, 0.15), seed: 11)
            surface(g, roughness: 0.45)
        },
        Preset(name: "Lacquered Maple", category: "Wood") { g in
            woodGrain(g, dark: rgb(0.78, 0.60, 0.38), light: rgb(0.93, 0.82, 0.64), seed: 21)
            surface(g, roughness: 0.25, clearcoat: 0.8, clearcoatRoughness: 0.05)
        },

        // Fabric & leather
        Preset(name: "Grey Felt", category: "Fabric") { g in
            mottled(g, a: rgb(0.40, 0.41, 0.42), b: rgb(0.50, 0.51, 0.52), scale: 96, stretch: 1, seed: 5)
            surface(g, roughness: 0.95)
        },
        Preset(name: "Navy Canvas", category: "Fabric") { g in
            weave(g, a: rgb(0.10, 0.14, 0.26), b: rgb(0.15, 0.20, 0.34))
            surface(g, roughness: 0.9)
        },
        Preset(name: "Black Leather", category: "Fabric") { g in
            mottled(g, a: rgb(0.05, 0.05, 0.05), b: rgb(0.09, 0.085, 0.08), scale: 64, stretch: 1, seed: 8)
            surface(g, roughness: 0.55)
        },
        Preset(name: "Tan Leather", category: "Fabric") { g in
            mottled(g, a: rgb(0.55, 0.36, 0.20), b: rgb(0.66, 0.45, 0.27), scale: 64, stretch: 1, seed: 9)
            surface(g, roughness: 0.5)
        },

        // Ceramic & stone
        Preset(name: "Glazed White Ceramic", category: "Ceramic & Stone") {
            surface($0, color: rgb(0.94, 0.94, 0.92), roughness: 0.08, clearcoat: 1, clearcoatRoughness: 0.02)
        },
        Preset(name: "Terracotta", category: "Ceramic & Stone") { g in
            mottled(g, a: rgb(0.66, 0.32, 0.19), b: rgb(0.74, 0.40, 0.25), scale: 48, stretch: 1, seed: 14)
            surface(g, roughness: 0.92)
        },
        Preset(name: "Concrete", category: "Ceramic & Stone") { g in
            mottled(g, a: rgb(0.50, 0.50, 0.49), b: rgb(0.64, 0.64, 0.62), scale: 24, stretch: 1, seed: 2, detail: true)
            surface(g, roughness: 0.95)
        },
        Preset(name: "White Marble", category: "Ceramic & Stone") { g in
            mottled(g, a: rgb(0.80, 0.80, 0.79), b: rgb(0.95, 0.95, 0.94), scale: 6, stretch: 3, seed: 31, detail: true)
            surface(g, roughness: 0.12, clearcoat: 0.6, clearcoatRoughness: 0.04)
        },

        // Light
        Preset(name: "White LED", category: "Light") { surface($0, color: rgb(1, 1, 1), roughness: 0.3, emissive: rgb(1, 1, 1)) },
        Preset(name: "Warm LED", category: "Light") { surface($0, color: rgb(1, 0.85, 0.65), roughness: 0.3, emissive: rgb(1, 0.78, 0.52)) },
        Preset(name: "Indicator Green", category: "Light") { surface($0, color: rgb(0.2, 0.9, 0.35), roughness: 0.2, emissive: rgb(0.15, 0.85, 0.3)) },
    ]

    // MARK: Graph helpers

    private static func rgb(_ r: Float, _ g: Float, _ b: Float) -> SIMD4<Float> { SIMD4(r, g, b, 1) }

    /// Sets the Surface Output's constant inputs (nil leaves an input as is).
    private static func surface(_ g: MaterialGraph, color: SIMD4<Float>? = nil, metallic: Float? = nil, roughness: Float? = nil,
                                clearcoat: Float? = nil, clearcoatRoughness: Float? = nil, opacity: Float? = nil,
                                emissive: SIMD4<Float>? = nil) {
        g.update(g.outputNodeID) { out in
            if let color { out.values["Base Color"] = color }
            if let metallic { out.values["Metallic"] = NodeKind.gray(metallic) }
            if let roughness { out.values["Roughness"] = NodeKind.gray(roughness) }
            if let clearcoat { out.values["Clearcoat"] = NodeKind.gray(clearcoat) }
            if let clearcoatRoughness { out.values["Clearcoat Roughness"] = NodeKind.gray(clearcoatRoughness) }
            if let opacity { out.values["Opacity"] = NodeKind.gray(opacity) }
            if let emissive { out.values["Emissive"] = emissive }
        }
    }

    private static func noise(_ g: MaterialGraph, at p: CGPoint, scale: Float, stretch: Float, seed: Float) -> UUID {
        let id = g.addNode(.noise, at: p)
        g.update(id) {
            $0.values["Scale"] = NodeKind.gray(scale)
            $0.values["Stretch"] = NodeKind.gray(stretch)
            $0.values["Seed"] = NodeKind.gray(seed)
        }
        return id
    }

    /// Two colors blended by noise into Base Color; with `detail`, a finer noise layered on top.
    private static func mottled(_ g: MaterialGraph, a: SIMD4<Float>, b: SIMD4<Float>, scale: Float, stretch: Float, seed: Float,
                                detail: Bool = false) {
        let out = g.outputNodeID
        let n = noise(g, at: CGPoint(x: 40, y: 40), scale: scale, stretch: stretch, seed: seed)
        let mix = g.addNode(.mix, at: CGPoint(x: 330, y: 40))
        g.update(mix) { $0.values["A"] = a; $0.values["B"] = b }
        var factor = PortRef(node: n, port: 0)
        if detail {
            let fine = noise(g, at: CGPoint(x: 40, y: 260), scale: scale * 6, stretch: stretch, seed: seed + 50)
            let overlay = g.addNode(.mix, at: CGPoint(x: 330, y: 260))
            g.update(overlay) { $0.option = "Overlay"; $0.values["Factor"] = NodeKind.gray(0.45) }
            g.connect(PortRef(node: n, port: 0), PortRef(node: overlay, port: 0))
            g.connect(PortRef(node: fine, port: 0), PortRef(node: overlay, port: 1))
            factor = PortRef(node: overlay, port: 0)
        }
        g.connect(factor, PortRef(node: mix, port: 2))
        g.connect(PortRef(node: mix, port: 0), PortRef(node: out, port: MaterialGraph.Channel.baseColor.rawValue))
        g.update(out) { $0.position = CGPoint(x: 620, y: 40) }
    }

    /// Long, streaky noise for grain, with fine rings layered over it.
    private static func woodGrain(_ g: MaterialGraph, dark: SIMD4<Float>, light: SIMD4<Float>, seed: Float) {
        mottled(g, a: dark, b: light, scale: 24, stretch: 16, seed: seed, detail: true)
    }

    /// A fine checker softened with noise, for woven fabric.
    private static func weave(_ g: MaterialGraph, a: SIMD4<Float>, b: SIMD4<Float>) {
        let out = g.outputNodeID
        let checker = g.addNode(.checker, at: CGPoint(x: 40, y: 40))
        g.update(checker) { $0.values["Color 1"] = a; $0.values["Color 2"] = b; $0.values["Scale"] = NodeKind.gray(64) }
        let n = noise(g, at: CGPoint(x: 40, y: 260), scale: 128, stretch: 1, seed: 4)
        let mix = g.addNode(.mix, at: CGPoint(x: 330, y: 40))
        g.update(mix) { $0.option = "Overlay"; $0.values["Factor"] = NodeKind.gray(0.35) }
        g.connect(PortRef(node: checker, port: 0), PortRef(node: mix, port: 0))
        g.connect(PortRef(node: n, port: 0), PortRef(node: mix, port: 1))
        g.connect(PortRef(node: mix, port: 0), PortRef(node: out, port: MaterialGraph.Channel.baseColor.rawValue))
        g.update(out) { $0.position = CGPoint(x: 620, y: 40) }
    }

    /// Roughness streaks for a brushed finish.
    private static func brushedRoughness(_ g: MaterialGraph, low: Float, high: Float) {
        let out = g.outputNodeID
        let n = noise(g, at: CGPoint(x: 40, y: 40), scale: 128, stretch: 48, seed: 7)
        let range = g.addNode(.mapRange, at: CGPoint(x: 330, y: 40))
        g.update(range) { $0.values["To Min"] = NodeKind.gray(low); $0.values["To Max"] = NodeKind.gray(high) }
        g.connect(PortRef(node: n, port: 0), PortRef(node: range, port: 0))
        g.connect(PortRef(node: range, port: 0), PortRef(node: out, port: MaterialGraph.Channel.roughness.rawValue))
        g.update(out) { $0.position = CGPoint(x: 620, y: 40) }
    }

    // MARK: Thumbnails

    /// A lit sphere wearing the preset, rendered offscreen.
    static func thumbnail(for material: LibraryMaterial, environment: CGImage?, size: Int = 220) -> CGImage? {
        guard let graph = graph(for: material) else { return nil }
        let evaluator = GraphEvaluator(graph: graph, size: 256)
        let result = evaluator.evaluateMaterial()

        let scene = SCNScene()
        let sphere = SCNSphere(radius: 1)
        sphere.segmentCount = 72
        let surface = SCNMaterial()
        surface.lightingModel = .physicallyBased
        MaterialApplier.apply(result, to: surface, evaluator: evaluator)
        sphere.materials = [surface]
        let node = SCNNode(geometry: sphere)
        node.eulerAngles = SCNVector3(0.35, -0.6, 0)
        scene.rootNode.addChildNode(node)
        scene.lightingEnvironment.contents = environment
        scene.lightingEnvironment.intensity = 1
        scene.background.contents = NSColor(white: 0.16, alpha: 1)

        let camera = SCNNode()
        camera.camera = SCNCamera()
        camera.camera?.fieldOfView = 30
        camera.camera?.wantsHDR = true
        // Keep whites and glass reflections out of clipping so light finishes still read.
        camera.camera?.exposureOffset = -1.1
        camera.camera?.wantsExposureAdaptation = false
        camera.position = SCNVector3(0, 0, 4.1)
        scene.rootNode.addChildNode(camera)

        let renderer = SCNRenderer(device: MTLCreateSystemDefaultDevice(), options: nil)
        renderer.scene = scene
        renderer.pointOfView = camera
        if environment == nil { renderer.autoenablesDefaultLighting = true }
        let image = renderer.snapshot(atTime: 0, with: CGSize(width: size, height: size), antialiasingMode: .multisampling4X)
        return image.cgImage(forProposedRect: nil, context: nil, hints: nil)
    }
}
