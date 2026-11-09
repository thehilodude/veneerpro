#if os(macOS)
import AppKit
#else
import UIKit
#endif
import SceneKit
import simd

/// Per-object pivot (the point objects rotate around, for the gumball and hinges), kept in the node's
/// own coordinates. SceneKit's `pivot` isn't used: it offsets the node after rotating rather than
/// rotating around a point, and every exporter would have to account for it.
extension SCNNode {
    private static let pivotKey = "veneerPivot"

    /// The custom pivot, or nil to use the center of the object's bounds.
    var customPivot: SIMD3<Float>? {
        get { (value(forKey: Self.pivotKey) as? [Float]).flatMap { $0.count == 3 ? SIMD3($0[0], $0[1], $0[2]) : nil } }
        set { setValue(newValue.map { [$0.x, $0.y, $0.z] }, forKey: Self.pivotKey) }
    }

    /// Where this object rotates around, in its own coordinates.
    var pivotPoint: SIMD3<Float> { customPivot ?? localBoundsCenter }

    var worldPivot: SIMD3<Float> { simdConvertPosition(pivotPoint, to: nil) }

    /// The center of this object and its children's geometry, in its own coordinates.
    var localBoundsCenter: SIMD3<Float> {
        guard let (lo, hi) = localBounds else { return .zero }
        return (lo + hi) / 2
    }

    /// The bounds of this object and its visible children, in its own coordinates.
    var localBounds: (SIMD3<Float>, SIMD3<Float>)? {
        var lo = SIMD3<Float>(repeating: .greatestFiniteMagnitude), hi = -lo
        enumerateHierarchy { child, _ in
            guard child.geometry != nil, !child.isHidden else { return }
            let (a, b) = child.boundingBox
            for corner in 0..<8 {
                let p = SCNVector3(corner & 1 == 0 ? a.x : b.x, corner & 2 == 0 ? a.y : b.y, corner & 4 == 0 ? a.z : b.z)
                let local = simdConvertPosition(SIMD3<Float>(child.convertPosition(p, to: nil)), from: nil)
                lo = simd_min(lo, local)
                hi = simd_max(hi, local)
            }
        }
        return lo.x <= hi.x ? (lo, hi) : nil
    }
}

/// How the gumball behaves (set from the viewer bar).
struct GumballSettings: Equatable {
    var visible = true
    /// Align the handles to the selected object's own axes rather than the world's.
    var local = false
    /// The arrows move the pivot instead of the object.
    var editPivot = false
}

/// A finished gumball drag, for undo.
enum GumballEdit {
    /// Each moved node's local transform before and after.
    case transform([(node: SCNNode, before: simd_float4x4, after: simd_float4x4)])
    case pivot(node: SCNNode, before: SIMD3<Float>?, after: SIMD3<Float>?)
}

/// Move arrows and rotation rings drawn over the selection. Dragging a handle moves or rotates the
/// selected objects around the primary object's pivot; ⇧ snaps rotation to 15°.
@MainActor
final class Gumball {
    let root = SCNNode()
    /// The selected object's hinge axis, drawn through its pivot at world scale.
    let hingeLine = SCNNode()
    private var targets: [SCNNode] = []
    private var settings = GumballSettings()
    /// The world-space frame the handles use: origin (the pivot) and unit axes.
    private var origin = SIMD3<Float>.zero
    private var axes = simd_float3x3(1)
    var onEdit: ((GumballEdit) -> Void)?
    /// The camera the handles keep a constant on-screen size for (read on SceneKit's render thread).
    let camera = CameraReference()

    final class CameraReference: @unchecked Sendable {
        weak var node: SCNNode?
    }

    private enum Handle: Equatable {
        case move(Int)
        case rotate(Int)
    }

    private struct Drag {
        let handle: Handle
        let startPoint: SIMD3<Float>
        let startParam: Float
        let origin: SIMD3<Float>
        let axis: SIMD3<Float>
        let starts: [(SCNNode, world: simd_float4x4, local: simd_float4x4)]
        let pivotBefore: SIMD3<Float>?
    }
    private var drag: Drag?
    private var handleNodes: [(Handle, SCNNode)] = []
    private static let colors: [NSColor] = [
        NSColor(srgbRed: 0.95, green: 0.32, blue: 0.32, alpha: 1),
        NSColor(srgbRed: 0.42, green: 0.85, blue: 0.3, alpha: 1),
        NSColor(srgbRed: 0.3, green: 0.55, blue: 1, alpha: 1),
    ]

    init() {
        root.name = "__viewer_gumball"
        root.isHidden = true
        hingeLine.name = "__viewer_hinge"
        hingeLine.isHidden = true
        for axis in 0..<3 {
            handleNodes.append((.move(axis), Self.arrow(axis: axis)))
            handleNodes.append((.rotate(axis), Self.ring(axis: axis)))
        }
        for (_, node) in handleNodes { root.addChildNode(node) }
        let center = SCNNode(geometry: SCNSphere(radius: 0.045))
        center.geometry?.materials = [Self.material(.white)]
        root.addChildNode(center)
        // Constant size on screen: scale with the distance to the camera, every frame.
        let reference = camera
        root.constraints = [SCNTransformConstraint(inWorldSpace: true) { _, transform in
            guard let camera = reference.node else { return transform }
            var m = simd_float4x4(transform)
            let position = SIMD3(m.columns.3.x, m.columns.3.y, m.columns.3.z)
            let distance = simd_distance(position, camera.presentation.simdWorldPosition)
            let fov = Float(camera.camera?.fieldOfView ?? 40) * .pi / 180
            let scale = distance * tan(fov / 2) * 0.22
            for i in 0..<3 {
                let column = SIMD3(m[i].x, m[i].y, m[i].z)
                let length = max(simd_length(column), 1e-9)
                m[i] = SIMD4(column / length * scale, 0)
            }
            return SCNMatrix4(m)
        }]
    }

    // MARK: Placement

    func update(targets: [SCNNode], settings: GumballSettings) {
        self.targets = targets.filter { $0.parent != nil }
        self.settings = settings
        place()
    }

    private func place() {
        guard drag == nil else { return }
        placeHingeLine()
        guard settings.visible, let primary = targets.last else { root.isHidden = true; return }
        root.isHidden = false
        origin = primary.worldPivot
        if settings.local {
            let w = primary.simdWorldTransform
            axes = simd_float3x3(simd_normalize(SIMD3(w[0].x, w[0].y, w[0].z)),
                                 simd_normalize(SIMD3(w[1].x, w[1].y, w[1].z)),
                                 simd_normalize(SIMD3(w[2].x, w[2].y, w[2].z)))
        } else {
            axes = simd_float3x3(1)
        }
        var m = simd_float4x4(1)
        m[0] = SIMD4(axes[0], 0); m[1] = SIMD4(axes[1], 0); m[2] = SIMD4(axes[2], 0)
        m[3] = SIMD4(origin, 1)
        root.simdTransform = m
        // Rotation doesn't apply while editing the pivot.
        for (handle, node) in handleNodes {
            if case .rotate = handle { node.isHidden = settings.editPivot }
        }
        tint(nil)
    }

    private func placeHingeLine() {
        guard let primary = targets.last, let hinge = primary.hinge, let (lo, hi) = primary.localBounds else {
            hingeLine.isHidden = true
            return
        }
        let axis = simd_normalize(primary.simdConvertVector(hinge.axisVector, to: nil))
        let center = primary.worldPivot
        let a = primary.simdConvertPosition(lo, to: nil), b = primary.simdConvertPosition(hi, to: nil)
        let length = max(simd_distance(a, b) * 1.3, 1e-4)
        let cylinder = SCNCylinder(radius: CGFloat(length * 0.004), height: CGFloat(length))
        cylinder.materials = [Self.material(.systemOrange)]
        hingeLine.geometry = cylinder
        hingeLine.renderingOrder = 1980
        hingeLine.castsShadow = false
        // A cylinder runs along +Y; turn it onto the axis.
        hingeLine.simdOrientation = simd_quatf(from: SIMD3(0, 1, 0), to: axis)
        hingeLine.simdPosition = center
        hingeLine.isHidden = false
    }

    // MARK: Mouse

    /// Starts a drag if `point` (view coordinates) is on a handle; returns whether it was.
    func mouseDown(at point: CGPoint, in view: SCNView) -> Bool {
        guard !root.isHidden, let primary = targets.last else { return false }
        let hits = view.hitTest(point, options: [.rootNode: root, .searchMode: SCNHitTestSearchMode.all.rawValue,
                                                 .ignoreHiddenNodes: true])
        guard let handle = hits.lazy.compactMap({ hit in self.handleNodes.first { $0.1 === hit.node || hit.node.isDescendant(of: $0.1) }?.0 }).first,
              let ray = Self.ray(at: point, in: view) else { return false }
        let axisIndex: Int
        switch handle { case let .move(i), let .rotate(i): axisIndex = i }
        let axis = axes[axisIndex]
        let starts = (settings.editPivot ? [primary] : targets).map { ($0, $0.simdWorldTransform, $0.simdTransform) }
        let startPoint: SIMD3<Float>
        var param: Float = 0
        if case .rotate = handle {
            guard let p = Self.intersect(ray, planeNormal: axis, through: origin) else { return false }
            startPoint = p
        } else {
            param = Self.closestParam(ray, origin: origin, axis: axis)
            startPoint = origin + axis * param
        }
        drag = Drag(handle: handle, startPoint: startPoint, startParam: param, origin: origin, axis: axis,
                    starts: starts, pivotBefore: primary.customPivot)
        tint(handle)
        return true
    }

    func mouseDragged(to point: CGPoint, in view: SCNView, snap: Bool) {
        guard let drag, let ray = Self.ray(at: point, in: view) else { return }
        switch drag.handle {
        case .move:
            let t = Self.closestParam(ray, origin: drag.origin, axis: drag.axis)
            let delta = drag.axis * (t - drag.startParam)
            if settings.editPivot, let (node, world, _) = drag.starts.first {
                let newPivot = drag.origin + delta
                node.customPivot = simd_mul(simd_inverse(world), SIMD4(newPivot, 1)).xyz
            } else {
                for (node, world, _) in drag.starts {
                    node.simdWorldTransform = Self.translation(delta) * world
                }
            }
            root.simdPosition = drag.origin + delta
        case .rotate:
            guard let p = Self.intersect(ray, planeNormal: drag.axis, through: drag.origin) else { return }
            let a = drag.startPoint - drag.origin, b = p - drag.origin
            var angle = atan2(simd_dot(drag.axis, simd_cross(a, b)), simd_dot(a, b))
            if snap { angle = (angle / (.pi / 12)).rounded() * (.pi / 12) }
            let rotation = Self.translation(drag.origin) * simd_float4x4(simd_quatf(angle: angle, axis: drag.axis))
                * Self.translation(-drag.origin)
            for (node, world, _) in drag.starts { node.simdWorldTransform = rotation * world }
            if settings.local, let primary = targets.last {
                let w = primary.simdWorldTransform
                var m = root.simdTransform
                for i in 0..<3 { m[i] = SIMD4(simd_normalize(SIMD3(w[i].x, w[i].y, w[i].z)), 0) }
                root.simdTransform = m
            }
        }
    }

    func mouseUp() {
        guard let drag else { return }
        self.drag = nil
        if settings.editPivot, let (node, _, _) = drag.starts.first {
            if node.customPivot != drag.pivotBefore { onEdit?(.pivot(node: node, before: drag.pivotBefore, after: node.customPivot)) }
        } else {
            let changes = drag.starts.map { (node: $0.0, before: $0.local, after: $0.0.simdTransform) }.filter { $0.before != $0.after }
            if !changes.isEmpty { onEdit?(.transform(changes)) }
        }
        place()
    }

    var isDragging: Bool { drag != nil }

    // MARK: Geometry

    private static func material(_ color: NSColor) -> SCNMaterial {
        let m = SCNMaterial()
        m.lightingModel = .constant
        m.diffuse.contents = color
        m.readsFromDepthBuffer = false
        m.writesToDepthBuffer = false
        return m
    }

    /// Invisible but hit-testable, to make thin handles easy to grab. (Hit tests skip fully
    /// transparent materials, so this one is opaque and just never writes any pixels.)
    private static func hitMaterial() -> SCNMaterial {
        let m = material(.white)
        m.colorBufferWriteMask = []
        m.setValue(true, forKey: "veneerHitOnly")
        return m
    }

    /// Orients a handle built along +Y to point along `axis`.
    private static func orient(_ node: SCNNode, axis: Int) {
        if axis == 0 { node.simdEulerAngles = SIMD3(0, 0, -.pi / 2) }
        if axis == 2 { node.simdEulerAngles = SIMD3(.pi / 2, 0, 0) }
    }

    private static func arrow(axis: Int) -> SCNNode {
        let node = SCNNode()
        let shaft = SCNNode(geometry: SCNCylinder(radius: 0.014, height: 1.0))
        shaft.simdPosition = SIMD3(0, 0.65, 0)
        let tip = SCNNode(geometry: SCNCone(topRadius: 0, bottomRadius: 0.06, height: 0.2))
        tip.simdPosition = SIMD3(0, 1.25, 0)
        let hit = SCNNode(geometry: SCNCylinder(radius: 0.08, height: 1.25))
        hit.simdPosition = SIMD3(0, 0.75, 0)
        hit.geometry?.materials = [hitMaterial()]
        for part in [shaft, tip] { part.geometry?.materials = [material(colors[axis])] }
        [shaft, tip, hit].forEach(node.addChildNode)
        orient(node, axis: axis)
        node.renderingOrder = 2000
        node.enumerateHierarchy { n, _ in n.renderingOrder = 2000; n.castsShadow = false }
        return node
    }

    private static func ring(axis: Int) -> SCNNode {
        let node = SCNNode()
        let ring = SCNNode(geometry: SCNTorus(ringRadius: 0.95, pipeRadius: 0.012))
        ring.geometry?.materials = [material(colors[axis].withAlphaComponent(0.9))]
        let hit = SCNNode(geometry: SCNTorus(ringRadius: 0.95, pipeRadius: 0.06))
        hit.geometry?.materials = [hitMaterial()]
        [ring, hit].forEach(node.addChildNode)
        // A torus lies around +Y; orient it around the axis it rotates about.
        orient(node, axis: axis)
        node.enumerateHierarchy { n, _ in n.renderingOrder = 1990; n.castsShadow = false }
        return node
    }

    /// Highlights the handle being dragged.
    private func tint(_ active: Handle?) {
        for (handle, node) in handleNodes {
            let axis: Int
            switch handle { case let .move(i), let .rotate(i): axis = i }
            let color = handle == active ? NSColor.systemYellow : (settings.editPivot ? NSColor.systemOrange : Self.colors[axis])
            for child in node.childNodes where child.geometry?.firstMaterial?.value(forKey: "veneerHitOnly") == nil {
                child.geometry?.firstMaterial?.diffuse.contents = color
            }
        }
    }

    // MARK: Math

    private struct Ray { let origin: SIMD3<Float>; let direction: SIMD3<Float> }

    private static func ray(at point: CGPoint, in view: SCNView) -> Ray? {
        let near = SIMD3<Float>(view.unprojectPoint(SCNVector3(point.x, point.y, 0)))
        let far = SIMD3<Float>(view.unprojectPoint(SCNVector3(point.x, point.y, 1)))
        let d = far - near
        guard simd_length(d) > 0 else { return nil }
        return Ray(origin: near, direction: simd_normalize(d))
    }

    /// The parameter along the axis line closest to the ray.
    private static func closestParam(_ ray: Ray, origin: SIMD3<Float>, axis: SIMD3<Float>) -> Float {
        let w = origin - ray.origin
        let b = simd_dot(axis, ray.direction), d = simd_dot(axis, w), e = simd_dot(ray.direction, w)
        let denominator = 1 - b * b
        guard abs(denominator) > 1e-6 else { return 0 }
        return (b * e - d) / denominator
    }

    private static func intersect(_ ray: Ray, planeNormal n: SIMD3<Float>, through p: SIMD3<Float>) -> SIMD3<Float>? {
        let denominator = simd_dot(ray.direction, n)
        guard abs(denominator) > 1e-6 else { return nil }
        let s = simd_dot(p - ray.origin, n) / denominator
        return ray.origin + ray.direction * s
    }

    nonisolated static func translation(_ v: SIMD3<Float>) -> simd_float4x4 {
        var m = simd_float4x4(1)
        m[3] = SIMD4(v, 1)
        return m
    }
}

private extension SIMD4 where Scalar == Float {
    var xyz: SIMD3<Float> { SIMD3(x, y, z) }
}
