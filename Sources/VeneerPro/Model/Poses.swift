import SceneKit
import simd

/// A saved arrangement of a model's objects (e.g. "Closed" and "Open"): every object's local
/// transform, visibility and hinge.
struct Pose: Identifiable {
    struct State {
        let node: SCNNode
        var transform: simd_float4x4
        var hidden: Bool
        var hinge: Hinge?
    }

    var id = UUID()
    var name: String
    var states: [State]
}

extension ModelDocument {
    /// The state of every object under the model's container.
    var currentPoseStates: [Pose.State] {
        var states: [Pose.State] = []
        root.enumerateHierarchy { node, _ in
            guard node !== root else { return }
            states.append(Pose.State(node: node, transform: node.simdTransform, hidden: node.isHidden, hinge: node.hinge))
        }
        return states
    }

    var activePose: Pose? { poses.first { $0.id == activePoseID } }

    /// True when objects have moved, hidden or swung since the active pose was applied or saved.
    var poseIsModified: Bool {
        guard let active = activePose else { return false }
        return active.states.contains { state in
            state.node.isDescendant(of: root) && !Self.matches(state, state.node)
        }
    }

    static func matches(_ state: Pose.State, _ node: SCNNode) -> Bool {
        node.isHidden == state.hidden && node.hinge == state.hinge
            && (0..<4).allSatisfy { simd_reduce_max(simd_abs(node.simdTransform[$0] - state.transform[$0])) < 1e-5 }
    }

    /// Puts objects in `states` (ones since deleted are skipped).
    func applyPoseStates(_ states: [Pose.State]) {
        for state in states where state.node.isDescendant(of: root) {
            state.node.simdTransform = state.transform
            state.node.isHidden = state.hidden
            state.node.hinge = state.hinge
        }
        sceneChanged()
    }

    /// The poses re-pointed at a duplicate's nodes (`map`: original → copy).
    func poses(remapping map: [ObjectIdentifier: SCNNode]) -> [Pose] {
        poses.map { pose in
            var copy = pose
            copy.states = pose.states.compactMap { state in
                map[ObjectIdentifier(state.node)].map { Pose.State(node: $0, transform: state.transform, hidden: state.hidden, hinge: state.hinge) }
            }
            return copy
        }
    }
}

extension AppModel {
    // MARK: Poses

    func savePose() {
        guard let document = selectedDocument else { return }
        history.flush()
        var n = document.poses.count + 1
        while document.poses.contains(where: { $0.name == "Pose \(n)" }) { n += 1 }
        let pose = Pose(name: "Pose \(n)", states: document.currentPoseStates)
        let previous = document.activePoseID
        noteProjectEdit()
        document.poses.append(pose)
        document.activePoseID = pose.id
        history.record("Save “\(pose.name)”", undo: { [weak document] in
            document?.poses.removeAll { $0.id == pose.id }
            document?.activePoseID = previous
        }, redo: { [weak document] in
            document?.poses.append(pose)
            document?.activePoseID = pose.id
        })
    }

    func applyPose(_ pose: Pose) {
        guard let document = selectedDocument else { return }
        history.flush()
        let before = document.currentPoseStates, previous = document.activePoseID
        document.applyPoseStates(pose.states)
        document.activePoseID = pose.id
        history.record("Apply “\(pose.name)”", undo: { [weak document] in
            document?.applyPoseStates(before)
            document?.activePoseID = previous
        }, redo: { [weak document] in
            document?.applyPoseStates(pose.states)
            document?.activePoseID = pose.id
        })
    }

    func updatePose(_ pose: Pose) {
        guard let document = selectedDocument, let i = document.poses.firstIndex(where: { $0.id == pose.id }) else { return }
        history.flush()
        let old = document.poses[i]
        var updated = old
        updated.states = document.currentPoseStates
        document.poses[i] = updated
        document.activePoseID = pose.id
        noteProjectEdit()
        history.record("Update “\(pose.name)”", undo: { [weak document] in
            if let i = document?.poses.firstIndex(where: { $0.id == old.id }) { document?.poses[i] = old }
        }, redo: { [weak document] in
            if let i = document?.poses.firstIndex(where: { $0.id == updated.id }) { document?.poses[i] = updated }
        })
    }

    func renamePose(_ pose: Pose, to name: String) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, let document = selectedDocument, let i = document.poses.firstIndex(where: { $0.id == pose.id }) else { return }
        document.poses[i].name = name
        noteProjectEdit()
    }

    func deletePose(_ pose: Pose) {
        guard let document = selectedDocument, let i = document.poses.firstIndex(where: { $0.id == pose.id }) else { return }
        let wasActive = document.activePoseID == pose.id
        document.poses.remove(at: i)
        if wasActive { document.activePoseID = nil }
        noteProjectEdit()
        history.record("Delete “\(pose.name)”", undo: { [weak document] in
            document?.poses.insert(pose, at: min(i, document?.poses.count ?? 0))
            if wasActive { document?.activePoseID = pose.id }
        }, redo: { [weak document] in
            document?.poses.removeAll { $0.id == pose.id }
            if wasActive { document?.activePoseID = nil }
        })
    }
}
