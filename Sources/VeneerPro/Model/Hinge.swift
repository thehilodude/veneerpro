import SceneKit
import simd

/// Rotates an object around its pivot along one axis, between limits, like a lid or a door.
/// At 0° the object sits at `rest` (its local transform when the hinge was added).
struct Hinge: Codable, Equatable {
    /// The rotation axis in the object's own coordinates.
    var axis: [Float]
    var minAngle: Double = 0
    var maxAngle: Double = 110
    var angle: Double = 0
    /// The object's local transform at 0°, column-major.
    var rest: [Float]

    var axisVector: SIMD3<Float> { simd_normalize(SIMD3(axis[0], axis[1], axis[2])) }

    var restTransform: simd_float4x4 {
        get { simd_float4x4(columns: (SIMD4(rest[0..<4]), SIMD4(rest[4..<8]), SIMD4(rest[8..<12]), SIMD4(rest[12..<16]))) }
        set { rest = [newValue.columns.0, newValue.columns.1, newValue.columns.2, newValue.columns.3].flatMap { [$0.x, $0.y, $0.z, $0.w] } }
    }

    /// The rotation at `angle` around `pivot` (local coordinates), applied before the rest transform.
    func swing(pivot: SIMD3<Float>, angle: Double? = nil) -> simd_float4x4 {
        let radians = Float((angle ?? self.angle) * .pi / 180)
        return Gumball.translation(pivot) * simd_float4x4(simd_quatf(angle: radians, axis: axisVector)) * Gumball.translation(-pivot)
    }

    /// The object's local transform at the current angle.
    func transform(pivot: SIMD3<Float>) -> simd_float4x4 { restTransform * swing(pivot: pivot) }
}

extension SCNNode {
    private static let hingeKey = "veneerHinge"

    var hinge: Hinge? {
        get { (value(forKey: Self.hingeKey) as? Data).flatMap { try? JSONDecoder().decode(Hinge.self, from: $0) } }
        set { setValue(newValue.flatMap { try? JSONEncoder().encode($0) }, forKey: Self.hingeKey) }
    }
}

extension AppModel {
    /// Adds a hinge along a world axis (0 = X, 1 = Y, 2 = Z) through the object's pivot.
    func addHinge(to node: SCNNode, worldAxis: Int) {
        var world = SIMD3<Float>(0, 0, 0)
        world[worldAxis] = 1
        let local = simd_normalize(node.simdConvertVector(world, from: nil))
        var hinge = Hinge(axis: [local.x, local.y, local.z], rest: [])
        hinge.restTransform = node.simdTransform
        setHinge(node, hinge, name: "Add Hinge to “\(Self.displayName(node))”")
    }

    func removeHinge(from node: SCNNode) {
        guard let hinge = node.hinge else { return }
        let document = selectedDocument
        let before = node.simdTransform
        node.hinge = nil
        node.simdTransform = hinge.restTransform
        document?.sceneChanged()
        history.record("Remove Hinge from “\(Self.displayName(node))”", undo: {
            node.hinge = hinge
            node.simdTransform = before
            document?.sceneChanged()
        }, redo: {
            node.hinge = nil
            node.simdTransform = hinge.restTransform
            document?.sceneChanged()
        })
    }

    /// Changes a hinge (angle, limits, axis) and moves the object to match; slider drags coalesce.
    func setHinge(_ node: SCNNode, _ hinge: Hinge, name: String? = nil) {
        let document = selectedDocument
        let beforeHinge = node.hinge, beforeTransform = node.simdTransform
        var hinge = hinge
        hinge.angle = min(max(hinge.angle, hinge.minAngle), hinge.maxAngle)
        node.hinge = hinge
        node.simdTransform = hinge.transform(pivot: node.pivotPoint)
        document?.sceneChanged()
        let apply = { (h: Hinge?, t: simd_float4x4) in node.hinge = h; node.simdTransform = t; document?.sceneChanged() }
        if let name {
            let after = node.simdTransform
            history.flush()
            history.record(name, undo: { apply(beforeHinge, beforeTransform) }, redo: { apply(hinge, after) })
            return
        }
        history.beginGroup(HingeKey(node: ObjectIdentifier(node))) { [beforeHinge, beforeTransform] in
            let afterHinge = node.hinge, after = node.simdTransform
            guard afterHinge != beforeHinge else { return nil }
            return EditHistory.Step(name: "Swing “\(Self.displayName(node))”",
                                    undo: { apply(beforeHinge, beforeTransform) },
                                    redo: { apply(afterHinge, after) })
        }
    }

    /// After the gumball moves a hinged object, its new position becomes the hinge's frame (keeping the angle).
    func rebaseHinge(of node: SCNNode) {
        guard var hinge = node.hinge else { return }
        hinge.restTransform = node.simdTransform * simd_inverse(hinge.swing(pivot: node.pivotPoint))
        node.hinge = hinge
    }
}

private struct HingeKey: Hashable { let node: ObjectIdentifier }
