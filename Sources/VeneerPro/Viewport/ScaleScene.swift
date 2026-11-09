#if os(macOS)
import AppKit
#else
import UIKit
#endif
import SceneKit
import simd

/// A true-scale reference setting for the viewer — a desk or a bedroom built from untextured clay
/// shapes at real-world sizes, so a product can be judged next to familiar objects. View-only: scale
/// scenes are never exported.
struct ScaleScene: Codable, Equatable {
    enum Kind: String, Codable, CaseIterable, Identifiable {
        case none = "Studio"
        case desk = "Desk"
        case bedroom = "Bedroom"

        var id: String { rawValue }

        var symbol: String {
            switch self {
            case .none: "circle.dashed"
            case .desk: "table.furniture"
            case .bedroom: "bed.double"
            }
        }
    }

    /// Where the model sits in the scene.
    enum Surface: String, Codable, CaseIterable, Identifiable {
        case desk = "Desk"
        case floor = "Floor"
        case nightstand = "Nightstand"
        case bed = "Bed"

        var id: String { rawValue }
    }

    var kind: Kind = .none
    /// Desk: monitor, laptop, phone and mug.
    var props = true
    /// Bedroom: bed and nightstands.
    var furniture = true
    /// A 175 cm figure.
    var person = false
    var surface: Surface?

    /// Surfaces the model can be placed on in the current setup.
    var surfaces: [Surface] {
        switch kind {
        case .none: []
        case .desk: [.desk, .floor]
        case .bedroom: furniture ? [.floor, .nightstand, .bed] : [.floor]
        }
    }

    /// The chosen surface, or the scene's natural one.
    var effectiveSurface: Surface? {
        if let surface, surfaces.contains(surface) { return surface }
        return surfaces.first
    }
}

/// Builds scale scenes in meters (Y up, floor at 0).
enum ScaleSceneBuilder {
    struct Built {
        let node: SCNNode
        /// Where the model's bottom center goes, in meters.
        let anchor: SIMD3<Float>
        /// The region worth framing around the model, in meters.
        let frame: (lo: SIMD3<Float>, hi: SIMD3<Float>)
    }

    static func build(_ scene: ScaleScene) -> Built? {
        switch scene.kind {
        case .none: nil
        case .desk: desk(scene)
        case .bedroom: bedroom(scene)
        }
    }

    // MARK: Desk

    private static func desk(_ s: ScaleScene) -> Built {
        let root = SCNNode()
        root.addChildNode(floor())
        add(root, box(4.2, 2.6, 0.08), at: [0, 1.3, -0.62], material: wall)          // wall behind the desk

        // 120 × 60 cm desk, top at 74 cm, panel legs.
        let deskTop: Float = 0.74
        add(root, box(1.2, 0.03, 0.6, chamfer: 0.004), at: [0, deskTop - 0.015, 0])
        for x: Float in [-0.57, 0.57] {
            add(root, box(0.03, deskTop - 0.03, 0.56), at: [x, (deskTop - 0.03) / 2, 0])
        }

        if s.props {
            // 27" monitor: 61.4 × 36.8 cm panel on a stand.
            let monitor = SCNNode()
            monitor.addChildNode(node(box(0.22, 0.012, 0.18, chamfer: 0.004), at: [0, 0.006, 0]))
            monitor.addChildNode(node(box(0.05, 0.16, 0.025), at: [0, 0.09, -0.05]))
            monitor.addChildNode(node(box(0.614, 0.368, 0.025, chamfer: 0.006), at: [0, 0.12 + 0.184, -0.05]))
            monitor.addChildNode(node(box(0.59, 0.335, 0.004), at: [0, 0.12 + 0.19, -0.036], material: screen))
            monitor.position = SCNVector3(0.22, deskTop, -0.16)
            root.addChildNode(monitor)

            // 14" laptop, open: 31.3 × 22.1 cm.
            let laptop = SCNNode()
            laptop.addChildNode(node(box(0.313, 0.012, 0.221, chamfer: 0.004), at: [0, 0.006, 0]))
            let lid = SCNNode()
            lid.addChildNode(node(box(0.313, 0.21, 0.006, chamfer: 0.003), at: [0, 0.105, 0]))
            lid.addChildNode(node(box(0.29, 0.185, 0.002), at: [0, 0.108, 0.0035], material: screen))
            lid.position = SCNVector3(0, 0.012, -0.11)
            lid.eulerAngles.x = -0.32
            laptop.addChildNode(lid)
            laptop.position = SCNVector3(0.2, deskTop, 0.12)
            laptop.eulerAngles.y = -0.12
            root.addChildNode(laptop)

            // Phone: 14.7 × 7.1 cm, lying flat.
            add(root, box(0.071, 0.0083, 0.147, chamfer: 0.008), at: [-0.02, deskTop + 0.0042, 0.17], rotationY: 0.35)

            // Mug: 8.2 cm across, 9.5 cm tall.
            let mug = SCNNode()
            mug.addChildNode(node(SCNTube(innerRadius: 0.036, outerRadius: 0.041, height: 0.095), at: [0, 0.0475, 0]))
            mug.addChildNode(node(SCNCylinder(radius: 0.038, height: 0.006), at: [0, 0.003, 0]))
            let handle = node(SCNTorus(ringRadius: 0.026, pipeRadius: 0.0065), at: [0.045, 0.05, 0])
            handle.eulerAngles.x = .pi / 2
            mug.addChildNode(handle)
            mug.position = SCNVector3(0.5, deskTop, 0.1)
            root.addChildNode(mug)
        }
        if s.person { root.addChildNode(person(at: [-1.6, 0, 0.3], facing: 0.4)) }

        let onDesk = s.effectiveSurface != .floor
        let anchor: SIMD3<Float> = onDesk ? [-0.28, deskTop, 0.02] : [-0.95, 0, 0.75]
        let frame: (SIMD3<Float>, SIMD3<Float>) = onDesk
            ? ([-0.62, deskTop, -0.35], [0.62, deskTop + 0.5, 0.32])
            : ([-1.9, 0, -0.6], [0.7, 1.2, 1.1])
        return Built(node: root, anchor: anchor, frame: frame)
    }

    // MARK: Bedroom

    private static func bedroom(_ s: ScaleScene) -> Built {
        let root = SCNNode()
        let width: Float = 3.5, depth: Float = 3.0, height: Float = 2.4
        // Floor slab, and the back and left walls only, so the camera can look in.
        add(root, box(width, 0.04, depth), at: [0, -0.02, 0], material: floorClay)
        add(root, box(width, height, 0.1), at: [0, height / 2, -depth / 2 - 0.05], material: wall)
        add(root, box(0.1, height, depth + 0.1), at: [-width / 2 - 0.05, height / 2, -0.05], material: wall)
        // Skirting.
        add(root, box(width, 0.08, 0.015), at: [0, 0.04, -depth / 2 + 0.0075])
        add(root, box(0.015, 0.08, depth), at: [-width / 2 + 0.0075, 0.04, 0])

        // Door (82 × 203 cm) on the left wall, as a slightly proud panel with a frame and handle.
        let doorZ: Float = 0.75
        add(root, box(0.05, 2.1, 0.94), at: [-width / 2 + 0.01, 1.05, doorZ])
        add(root, box(0.06, 2.03, 0.82), at: [-width / 2 + 0.02, 1.015, doorZ], material: wall)
        add(root, SCNSphere(radius: 0.025), at: [-width / 2 + 0.07, 1.0, doorZ + 0.33])

        // Window (120 × 120 cm, sill at 90 cm) on the back wall: frame bars around a darker pane.
        let wx: Float = 0.85, wy: Float = 0.9 + 0.6, wz = -depth / 2 + 0.005
        add(root, box(1.16, 1.16, 0.01), at: [wx, wy, wz], material: screen)
        for (dx, dy, w, h) in [(Float(0), Float(0.6), Float(1.24), Float(0.06)), (0, -0.6, 1.24, 0.06),
                               (-0.6, 0, 0.06, 1.24), (0.6, 0, 0.06, 1.24), (0, 0, 1.2, 0.04), (0, 0, 0.04, 1.2)] {
            add(root, box(w, h, 0.06), at: [wx + dx, wy + dy, wz + 0.02])
        }
        add(root, box(1.3, 0.03, 0.18), at: [wx, 0.9 - 0.015, wz + 0.09])    // sill

        let bedX: Float = -0.45, nightstandTop: Float = 0.6, mattressTop: Float = 0.6
        let rightStandX = bedX + 0.8 + 0.08 + 0.25
        if s.furniture {
            // Queen bed: 152 × 203 cm mattress, top at 60 cm, headboard against the back wall.
            let bedZ = -depth / 2 + 0.05 + 1.05
            add(root, box(1.6, 0.35, 2.1, chamfer: 0.01), at: [bedX, 0.175, bedZ])
            add(root, box(1.52, 0.25, 2.03, chamfer: 0.04), at: [bedX, mattressTop - 0.125, bedZ + 0.02])
            add(root, box(1.6, 1.1, 0.08, chamfer: 0.01), at: [bedX, 0.55, -depth / 2 + 0.04])
            for dx: Float in [-0.36, 0.36] {
                add(root, box(0.62, 0.13, 0.4, chamfer: 0.05), at: [bedX + dx, mattressTop + 0.06, -depth / 2 + 0.35])
            }
            add(root, box(1.56, 0.06, 1.2, chamfer: 0.025), at: [bedX, mattressTop + 0.02, bedZ + 0.4])   // duvet
            // Nightstands: 50 × 40 cm, 60 cm tall, either side.
            for x in [bedX - 0.8 - 0.08 - 0.25, rightStandX] {
                add(root, box(0.5, nightstandTop, 0.4, chamfer: 0.006), at: [x, nightstandTop / 2, -depth / 2 + 0.25])
                add(root, box(0.44, 0.005, 0.005), at: [x, nightstandTop - 0.14, -depth / 2 + 0.452])
            }
        }
        if s.person { root.addChildNode(person(at: [1.35, 0, 0.9], facing: -0.5)) }

        let anchor: SIMD3<Float>
        let frame: (SIMD3<Float>, SIMD3<Float>)
        switch s.effectiveSurface {
        case .nightstand:
            anchor = [rightStandX, nightstandTop, -depth / 2 + 0.25]
            frame = ([bedX - 0.3, 0, -depth / 2], [rightStandX + 0.6, 1.4, -0.4])
        case .bed:
            anchor = [bedX, mattressTop + 0.05, -0.1]
            frame = ([bedX - 1.0, 0, -depth / 2], [bedX + 1.0, 1.3, 0.8])
        default:
            anchor = [0.85, 0, 0.55]
            frame = ([-width / 2, 0, -depth / 2], [width / 2, height, depth / 2])
        }
        return Built(node: root, anchor: anchor, frame: frame)
    }

    // MARK: Person

    /// A simple 175 cm mannequin.
    private static func person(at p: SIMD3<Float>, facing angle: Float) -> SCNNode {
        let figure = SCNNode()
        for x: Float in [-0.09, 0.09] {
            figure.addChildNode(node(SCNCapsule(capRadius: 0.065, height: 0.86), at: [x, 0.43, 0]))
        }
        figure.addChildNode(node(box(0.36, 0.56, 0.2, chamfer: 0.08), at: [0, 1.16, 0]))
        for x: Float in [-0.235, 0.235] {
            let arm = node(SCNCapsule(capRadius: 0.045, height: 0.66), at: [x, 1.1, 0])
            arm.eulerAngles.z = x < 0 ? -0.06 : 0.06
            figure.addChildNode(arm)
        }
        figure.addChildNode(node(SCNCylinder(radius: 0.05, height: 0.1), at: [0, 1.48, 0]))
        figure.addChildNode(node(SCNSphere(radius: 0.11), at: [0, 1.64, 0]))
        figure.simdPosition = p
        figure.eulerAngles.y = SCNFloat(angle)
        return figure
    }

    // MARK: Building blocks

    /// Matte, untextured clay.
    private static func clay(_ white: CGFloat, roughness: CGFloat = 0.9) -> SCNMaterial {
        let m = SCNMaterial()
        m.lightingModel = .physicallyBased
        m.diffuse.contents = NSColor(white: white, alpha: 1)
        m.roughness.contents = roughness
        m.metalness.contents = 0
        return m
    }

    private static let surface = clay(0.6)
    private static let wall = clay(0.66)
    private static let floorClay = clay(0.5)
    /// Screens and the window pane: the same clay, just darker and smoother.
    private static let screen = clay(0.1, roughness: 0.35)

    private static func floor() -> SCNNode {
        let floor = SCNFloor()
        floor.reflectivity = 0
        floor.materials = [floorClay]
        return SCNNode(geometry: floor)
    }

    private static func box(_ w: Float, _ h: Float, _ d: Float, chamfer: Float = 0.002) -> SCNBox {
        SCNBox(width: CGFloat(w), height: CGFloat(h), length: CGFloat(d), chamferRadius: CGFloat(min(chamfer, min(w, h, d) / 2)))
    }

    private static func node(_ geometry: SCNGeometry, at p: SIMD3<Float>, material: SCNMaterial? = nil) -> SCNNode {
        geometry.materials = [material ?? surface]
        let n = SCNNode(geometry: geometry)
        n.simdPosition = p
        n.castsShadow = true
        return n
    }

    private static func add(_ parent: SCNNode, _ geometry: SCNGeometry, at p: SIMD3<Float>, material: SCNMaterial? = nil,
                            rotationY: Float = 0) {
        let n = node(geometry, at: p, material: material)
        n.eulerAngles.y = SCNFloat(rotationY)
        parent.addChildNode(n)
    }
}
