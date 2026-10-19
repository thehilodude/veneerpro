import SceneKit

/// Object (scene node) selection and editing, all undoable.
extension AppModel {
    var selectedNodeName: String { selectedNode.map(Self.displayName) ?? "" }

    static func displayName(_ node: SCNNode) -> String {
        if let name = node.name, !name.isEmpty { return name }
        return node.geometry != nil ? "Mesh" : "Group"
    }

    /// Selects an object; its first material becomes the material being edited.
    func select(_ node: SCNNode?, showInspector: Bool = false) {
        selectedNode = node
        if let node, let entry = selectedDocument?.entries(for: node).first
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
            if self?.selectedNode.map({ $0 === node || $0.isDescendant(of: node) }) == true { self?.selectedNode = nil }
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
