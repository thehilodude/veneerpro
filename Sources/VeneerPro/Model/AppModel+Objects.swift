import SceneKit

/// Object (scene node) selection and editing, all undoable.
extension AppModel {
    var selectedNodeName: String { selectedNode.map(Self.displayName) ?? "" }

    static func displayName(_ node: SCNNode) -> String {
        if let name = node.name, !name.isEmpty { return name }
        return node.geometry != nil ? "Mesh" : "Group"
    }

    /// Selects an object; its first material becomes the material being edited. With `extend`
    /// (⌘- or ⇧-click), toggles the object in a multiple selection instead.
    func select(_ node: SCNNode?, extend: Bool = false, showInspector: Bool = false) {
        if extend, let node {
            if let i = selectedNodes.firstIndex(where: { $0 === node }) { selectedNodes.remove(at: i) } else { selectedNodes.append(node) }
        } else {
            selectedNode = node
        }
        guard let node = extend ? selectedNode : node else { return }
        if let entry = selectedDocument?.entries(for: node).first
            ?? ModelDocument.geometryNodes(in: node).lazy.compactMap({ self.selectedDocument?.entries(for: $0).first }).first {
            selectedMaterialID = entry.id
        }
        if showInspector, node != nil { inspectorTab = .object }
    }

    func toggleIsolation(_ node: SCNNode) {
        isolatedNode = isolatedNode === node ? nil : node
    }

    // MARK: Edits

    func setHidden(_ node: SCNNode, _ hidden: Bool) {
        guard node.isHidden != hidden else { return }
        let document = selectedDocument
        let apply: (Bool) -> Void = { value in
            node.isHidden = value
            document?.sceneChanged()
        }
        apply(hidden)
        history.record(hidden ? "Hide “\(Self.displayName(node))”" : "Show “\(Self.displayName(node))”",
                       undo: { apply(!hidden) }, redo: { apply(hidden) })
    }

    func rename(_ node: SCNNode, to name: String) {
        let old = node.name
        guard old != name else { return }
        let document = selectedDocument
        node.name = name
        document?.sceneChanged()
        history.beginGroup(RenameKey(node: ObjectIdentifier(node))) {
            let new = node.name
            return EditHistory.Step(name: "Rename “\(new ?? "")”",
                                    undo: { node.name = old; document?.sceneChanged() },
                                    redo: { node.name = new; document?.sceneChanged() })
        }
    }

    func delete(_ node: SCNNode) {
        guard let parent = node.parent, let index = parent.childNodes.firstIndex(of: node) else { return }
        let document = selectedDocument
        let remove = { [weak self] in
            node.removeFromParentNode()
            self?.selectedNodes.removeAll { $0 === node || $0.isDescendant(of: node) }
            if self?.isolatedNode.map({ $0 === node || $0.isDescendant(of: node) }) == true { self?.isolatedNode = nil }
            document?.sceneChanged()
        }
        let restore = {
            parent.insertChildNode(node, at: min(index, parent.childNodes.count))
            document?.sceneChanged()
        }
        remove()
        history.record("Delete “\(Self.displayName(node))”", undo: restore, redo: remove)
    }

    // MARK: Hierarchy

    /// Where a node sits: its parent, index among siblings and local transform.
    private struct Placement {
        let node: SCNNode
        let parent: SCNNode
        let index: Int
        let transform: simd_float4x4
    }

    private func placement(of node: SCNNode) -> Placement? {
        guard let parent = node.parent, let index = parent.childNodes.firstIndex(of: node) else { return nil }
        return Placement(node: node, parent: parent, index: index, transform: node.simdTransform)
    }

    /// Puts nodes back where they were (parents and order), lowest index first so indices hold.
    private func restore(_ placements: [Placement]) {
        for p in placements { p.node.removeFromParentNode() }
        for p in placements.sorted(by: { $0.index < $1.index }) {
            p.parent.insertChildNode(p.node, at: min(p.index, p.parent.childNodes.count))
            p.node.simdTransform = p.transform
        }
    }

    /// Moves `node` under `parent` at `index`, keeping where it is in the world.
    private static func reparent(_ node: SCNNode, to parent: SCNNode, at index: Int) {
        let world = node.simdWorldTransform
        node.removeFromParentNode()
        parent.insertChildNode(node, at: min(max(index, 0), parent.childNodes.count))
        node.simdWorldTransform = world
    }

    /// Only the outermost of the given nodes (a selected child moves with its selected parent).
    private static func outermost(_ nodes: [SCNNode]) -> [SCNNode] {
        nodes.filter { node in !nodes.contains { $0 !== node && node.isDescendant(of: $0) } }
    }

    /// Wraps the selected objects in a new group, placed where the first of them was.
    func groupSelection() {
        guard let document = selectedDocument else { return }
        let nodes = Self.outermost(selectedNodes).filter { $0.isDescendant(of: document.root) }
        guard let first = nodes.first, let firstPlace = placement(of: first) else { return }
        history.flush()
        let before = nodes.compactMap(placement(of:))
        var n = 1
        var names: Set<String> = []
        document.root.enumerateHierarchy { node, _ in if let name = node.name { names.insert(name) } }
        while names.contains("Group \(n)") { n += 1 }
        let group = SCNNode()
        group.name = "Group \(n)"
        let apply = { [weak self] in
            firstPlace.parent.insertChildNode(group, at: min(firstPlace.index, firstPlace.parent.childNodes.count))
            for (i, node) in nodes.enumerated() { Self.reparent(node, to: group, at: i) }
            self?.selectedNodes = [group]
            document.sceneChanged()
        }
        apply()
        history.record("Group \(nodes.count) Objects", undo: { [weak self] in
            self?.restore(before)
            group.removeFromParentNode()
            self?.selectedNodes = nodes
            document.sceneChanged()
        }, redo: apply)
    }

    /// Replaces a group with its contents, in its place.
    func ungroup(_ group: SCNNode) {
        guard let document = selectedDocument, group.geometry == nil, !group.childNodes.isEmpty,
              let place = placement(of: group) else { return }
        history.flush()
        let children = group.childNodes
        let before = children.compactMap(placement(of:))
        let apply = { [weak self] in
            for (i, child) in children.enumerated() { Self.reparent(child, to: place.parent, at: place.index + i) }
            group.removeFromParentNode()
            self?.selectedNodes = children
            document.sceneChanged()
        }
        apply()
        history.record("Ungroup “\(Self.displayName(group))”", undo: { [weak self] in
            self?.restore([place])
            self?.restore(before)
            self?.selectedNodes = [group]
            document.sceneChanged()
        }, redo: apply)
    }

    /// Moves objects into `parent` at `index` (drag and drop in the outline). Nodes can't move into
    /// themselves or their own children.
    func move(_ nodes: [SCNNode], into parent: SCNNode, at index: Int) {
        guard let document = selectedDocument else { return }
        let nodes = Self.outermost(nodes).filter { $0 !== parent && !parent.isDescendant(of: $0) }
        guard !nodes.isEmpty else { return }
        history.flush()
        let before = nodes.compactMap(placement(of:))
        // Indices shift as earlier siblings leave the parent.
        let adjusted = index - nodes.filter { $0.parent === parent && (parent.childNodes.firstIndex(of: $0) ?? .max) < index }.count
        let apply = { [weak self] in
            // An exploded view is re-planned for the new order and grouping.
            self?.withCollapsedExplode(document) {
                for (i, node) in nodes.enumerated() { Self.reparent(node, to: parent, at: adjusted + i) }
            }
            document.sceneChanged()
        }
        if document.explode.amount > 0 { document.explode.plan?.apply(0, root: document.root) }
        let collapsedBefore = nodes.compactMap(placement(of:))
        if document.explode.amount > 0 { document.explode.plan?.apply(document.explode.amount, root: document.root) }
        apply()
        history.record(nodes.count == 1 ? "Move “\(Self.displayName(nodes[0]))”" : "Move \(nodes.count) Objects", undo: { [weak self] in
            guard let self else { return }
            if document.explode.amount > 0 {
                self.withCollapsedExplode(document) { self.restore(collapsedBefore) }
            } else {
                self.restore(before)
            }
            document.sceneChanged()
        }, redo: apply)
    }

    /// Moves an object one place up or down among its siblings.
    func reorder(_ node: SCNNode, by offset: Int) {
        guard let parent = node.parent, let index = parent.childNodes.firstIndex(of: node) else { return }
        let target = index + offset
        guard parent.childNodes.indices.contains(target) else { return }
        move([node], into: parent, at: offset > 0 ? target + 1 : target)
    }

    /// Moves an object out of its group, just after the group.
    func moveOutOfGroup(_ node: SCNNode) {
        guard let document = selectedDocument, let parent = node.parent, parent !== document.root,
              let grand = parent.parent, let index = grand.childNodes.firstIndex(of: parent) else { return }
        move([node], into: grand, at: index + 1)
    }

    func deleteSelection() {
        let nodes = Self.outermost(selectedNodes)
        guard !nodes.isEmpty else { return }
        if nodes.count == 1 { delete(nodes[0]); return }
        guard let document = selectedDocument else { return }
        history.flush()
        let before = nodes.compactMap(placement(of:))
        let apply = { [weak self] in
            for node in nodes { node.removeFromParentNode() }
            self?.selectedNodes = []
            if let isolated = self?.isolatedNode, nodes.contains(where: { isolated === $0 || isolated.isDescendant(of: $0) }) {
                self?.isolatedNode = nil
            }
            document.sceneChanged()
        }
        apply()
        history.record("Delete \(nodes.count) Objects", undo: { [weak self] in
            self?.restore(before)
            document.sceneChanged()
        }, redo: apply)
    }

    // MARK: Gumball & pivots

    /// Records a finished gumball drag as one undo step.
    func applyGumballEdit(_ edit: GumballEdit) {
        let document = selectedDocument
        switch edit {
        case let .transform(changes):
            // A hinged object keeps its angle; the move becomes the hinge's new frame.
            let hingesBefore = changes.map { $0.node.hinge }
            for change in changes { rebaseHinge(of: change.node) }
            let hingesAfter = changes.map { $0.node.hinge }
            let set = { (after: Bool) in
                for (i, change) in changes.enumerated() {
                    change.node.simdTransform = after ? change.after : change.before
                    change.node.hinge = after ? hingesAfter[i] : hingesBefore[i]
                }
                document?.sceneChanged()
            }
            document?.sceneChanged()
            let name = changes.count == 1 ? "“\(Self.displayName(changes[0].node))”" : "\(changes.count) Objects"
            history.record("Transform \(name)", undo: { set(false) }, redo: { set(true) })
        case let .pivot(node, before, after):
            setPivot(node, from: before, to: after)
        }
    }

    /// Sets an object's pivot (nil: the center of its bounds), as an undo step.
    func setPivot(_ node: SCNNode, to pivot: SIMD3<Float>?) {
        setPivot(node, from: node.customPivot, to: pivot)
    }

    private func setPivot(_ node: SCNNode, from before: SIMD3<Float>?, to after: SIMD3<Float>?) {
        let document = selectedDocument
        let hingeBefore = node.hinge
        node.customPivot = after
        // Swinging around the new pivot should start from where the object is now.
        rebaseHinge(of: node)
        let hingeAfter = node.hinge
        document?.sceneChanged()
        history.record("Move Pivot of “\(Self.displayName(node))”",
                       undo: { node.customPivot = before; node.hinge = hingeBefore; document?.sceneChanged() },
                       redo: { node.customPivot = after; node.hinge = hingeAfter; document?.sceneChanged() })
    }

    /// Pivot presets: the bottom center of the object's bounds, or its own origin.
    func setPivotToBottom(_ node: SCNNode) {
        guard let (lo, hi) = node.localBounds else { return }
        setPivot(node, to: SIMD3((lo.x + hi.x) / 2, lo.y, (lo.z + hi.z) / 2))
    }

    /// Sets position / rotation (degrees) / scale; continuous edits coalesce into one step.
    func setTransform(_ node: SCNNode, position: SIMD3<Float>? = nil, rotationDegrees: SIMD3<Float>? = nil,
                      scale: SIMD3<Float>? = nil) {
        let document = selectedDocument
        let before = node.simdTransform
        if let position { node.simdPosition = position }
        if let rotationDegrees { node.simdEulerAngles = rotationDegrees * (.pi / 180) }
        if let scale { node.simdScale = scale }
        document?.sceneChanged()
        history.beginGroup(TransformKey(node: ObjectIdentifier(node))) { [before] in
            let after = node.simdTransform
            guard after != before else { return nil }
            return EditHistory.Step(name: "Move “\(Self.displayName(node))”",
                                    undo: { node.simdTransform = before; document?.sceneChanged() },
                                    redo: { node.simdTransform = after; document?.sceneChanged() })
        }
    }

    /// Gives `node` (and its child meshes) their own copies of their materials, so editing them or
    /// applying a library material changes only this object. Returns the object's material entries.
    @discardableResult
    func makeMaterialsUnique(for node: SCNNode) -> [MaterialEntry] {
        guard let document = selectedDocument else { return [] }
        let meshes = ModelDocument.geometryNodes(in: node)
        // Already unique when no other mesh shares this object's geometry, materials, or material
        // entries. (SceneKit gives every mesh its own copy of a shared material, and those copies are
        // grouped into one entry, so sharing has to be checked at the entry level too.)
        let otherMeshes = ModelDocument.geometryNodes(in: document.root).filter { !meshes.contains($0) }
        let ours = Set(meshes.flatMap { $0.geometry?.materials ?? [] }.map(ObjectIdentifier.init))
        let theirs = Set(otherMeshes.flatMap { $0.geometry?.materials ?? [] }.map(ObjectIdentifier.init))
        let sharedGeometry = meshes.contains { mesh in otherMeshes.contains { $0.geometry === mesh.geometry } }
        let sharedEntry = document.materials.contains { entry in
            entry.materials.contains { ours.contains(ObjectIdentifier($0)) } && entry.materials.contains { theirs.contains(ObjectIdentifier($0)) }
        }
        let shared = sharedGeometry || sharedEntry || !ours.isDisjoint(with: theirs)
        guard shared else { return meshes.flatMap { document.entries(for: $0) }.uniqued() }

        history.flush()
        var oldGeometries: [(SCNNode, SCNGeometry)] = []
        var newGeometries: [(SCNNode, SCNGeometry)] = []
        var created: [MaterialEntry] = []
        var copies: [ObjectIdentifier: SCNMaterial] = [:]   // one copy per source material
        let objectName = Self.displayName(node)
        for mesh in meshes {
            guard let geometry = mesh.geometry, let copy = geometry.copy() as? SCNGeometry else { continue }
            copy.materials = geometry.materials.map { source in
                if let existing = copies[ObjectIdentifier(source)] { return existing }
                let material = source.copy() as! SCNMaterial
                copies[ObjectIdentifier(source)] = material
                if let entry = document.materials.first(where: { $0.materials.contains { $0 === source } }) {
                    created.append(MaterialEntry(materials: [material], copying: entry, name: "\(entry.name) – \(objectName)"))
                }
                return material
            }
            document.mappingBaker.inherit(from: geometry, to: copy)
            oldGeometries.append((mesh, geometry))
            newGeometries.append((mesh, copy))
        }
        let apply = { (geometries: [(SCNNode, SCNGeometry)], add: Bool) in
            for (mesh, geometry) in geometries { mesh.geometry = geometry }
            if add { document.addMaterials(created) } else { document.removeMaterials(created) }
            document.sceneChanged()
        }
        apply(newGeometries, true)
        history.record("Separate Materials of “\(objectName)”",
                       undo: { apply(oldGeometries, false) },
                       redo: { apply(newGeometries, true) })
        if let first = created.first { selectedMaterialID = first.id }
        return created
    }

    /// Applies a library material to just the selected object (its materials are separated first).
    func applyToSelectedObject(_ material: LibraryMaterial) {
        guard let node = selectedNode else { return }
        for entry in makeMaterialsUnique(for: node) { apply(material, to: entry) }
    }
}

private struct RenameKey: Hashable { let node: ObjectIdentifier }
private struct TransformKey: Hashable { let node: ObjectIdentifier }

private extension Array where Element == MaterialEntry {
    func uniqued() -> [MaterialEntry] {
        var seen: Set<ObjectIdentifier> = []
        return filter { seen.insert(ObjectIdentifier($0)).inserted }
    }
}

extension SCNNode {
    /// True if `ancestor` is somewhere above this node.
    func isDescendant(of ancestor: SCNNode) -> Bool {
        var current = parent
        while let node = current {
            if node === ancestor { return true }
            current = node.parent
        }
        return false
    }
}
