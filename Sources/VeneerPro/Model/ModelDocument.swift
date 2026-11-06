import AppKit
import Observation
import SceneKit

struct StageMetadata: Equatable {
    var copyright = ""
    var metersPerUnit: Double = 1
    var upAxis = "Y"
}

/// One material of an imported model, edited as a node graph.
@Observable
final class MaterialEntry: Identifiable {
    let id = UUID()
    /// The material the graph was built from.
    let material: SCNMaterial
    /// Every SceneKit material this entry drives. SceneKit gives each mesh its own copy of a
    /// shared USD material; identical copies are grouped so they're edited and exported once.
    let materials: [SCNMaterial]
    private let original: SCNMaterial
    private let fallbackName: String
    private(set) var graph: MaterialGraph
    /// Node previews drawn inside the node editor.
    private(set) var thumbnails: [UUID: CGImage] = [:]
    private(set) var swatch: CGImage?
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    /// The graph as of the last undo step; edits since then become the next step.
    @ObservationIgnored private var baseline: MaterialGraph.Snapshot
    /// How textures are projected onto the parts using this material.
    var mapping = TextureMapping() {
        didSet {
            guard mapping != oldValue else { return }
            onMappingChange?()
            if !quietMapping { mappingEdited(from: oldValue) }
        }
    }
    /// Set by the document to rebuild texture coordinates when the mapping changes.
    @ObservationIgnored var onMappingChange: (() -> Void)?
    @ObservationIgnored private var mappingBaseline: TextureMapping?
    @ObservationIgnored private var quietMapping = false

    /// Takes over another entry's graph and mapping without recording undo steps (used when duplicating a model).
    func copyState(from other: MaterialEntry) {
        applyLook(Colorway.Look(graph: other.graph.snapshot, mapping: other.mapping))
    }

    /// Puts a saved graph and mapping on this material without recording undo steps (colorways).
    func applyLook(_ look: Colorway.Look) {
        if graph.snapshot != look.graph { restoreSnapshot(look.graph) }
        quietMapping = true
        mapping = look.mapping
        quietMapping = false
    }

    init(materials: [SCNMaterial], fallbackName: String) {
        let material = materials[0]
        self.material = material
        self.materials = materials
        self.original = material.copy() as! SCNMaterial
        self.fallbackName = fallbackName
        let graph = MaterialGraph(material: material, fallbackName: fallbackName)
        self.graph = graph
        self.baseline = graph.snapshot
        attach()
    }

    /// A new entry for `materials` that starts as a copy of `source`'s graph (used to give one
    /// object its own material).
    convenience init(materials: [SCNMaterial], copying source: MaterialEntry, name: String) {
        self.init(materials: materials, fallbackName: name)
        var snapshot = source.graph.snapshot
        snapshot.name = name
        graph.restore(snapshot)
        baseline = graph.snapshot
        mapping = source.mapping
        materials.forEach { $0.name = name }
    }

    /// Mapping edits (slider drags included) become one undo step once editing pauses.
    private func mappingEdited(from old: TextureMapping) {
        MainActor.assumeIsolated {
            let history = EditHistory.shared
            guard !history.isReplaying else { return }
            if mappingBaseline == nil { mappingBaseline = old }
            history.beginGroup(MappingKey(entry: ObjectIdentifier(self))) { [weak self] in
                guard let self, let before = self.mappingBaseline else { return nil }
                let after = self.mapping
                self.mappingBaseline = nil
                guard before != after else { return nil }
                return EditHistory.Step(name: "Change Mapping of “\(self.name)”",
                                        undo: { [weak self] in self?.mapping = before },
                                        redo: { [weak self] in self?.mapping = after })
            }
        }
    }

    var name: String {
        get { graph.name }
        set {
            graph.name = newValue
            materials.forEach { $0.name = newValue }
            edited()
        }
    }

    /// The as-imported graph, for materials restored from a project (whose scene no longer holds the
    /// imported material).
    var resetGraph: MaterialGraph.Snapshot?

    /// What Reset Material goes back to.
    var originalSnapshot: MaterialGraph.Snapshot {
        resetGraph ?? MaterialGraph(material: original, fallbackName: fallbackName).snapshot
    }

    func reset() {
        let fresh: MaterialGraph
        if let resetGraph {
            fresh = MaterialGraph(name: resetGraph.name)
            fresh.restore(resetGraph)
        } else {
            fresh = MaterialGraph(material: original, fallbackName: fallbackName)
        }
        replace(with: fresh, stepName: "Reset “\(graph.name)”")
    }

    /// Swaps in a new graph (e.g. one built from a library material), keeping the bake size.
    func replaceGraph(_ newGraph: MaterialGraph) {
        let bakeSize = graph.node(graph.outputNodeID)?.option
        if let bakeSize { newGraph.update(newGraph.outputNodeID) { $0.option = bakeSize } }
        replace(with: newGraph, stepName: "Apply “\(newGraph.name)”")
    }

    /// Replaces the whole graph as one undoable step.
    private func replace(with newGraph: MaterialGraph, stepName: String) {
        MainActor.assumeIsolated { EditHistory.shared.flush() }
        let before = graph.snapshot
        graph = newGraph
        materials.forEach { $0.name = graph.name }
        attach()
        let after = graph.snapshot
        MainActor.assumeIsolated {
            EditHistory.shared.record(stepName,
                                      undo: { [weak self] in self?.restoreSnapshot(before) },
                                      redo: { [weak self] in self?.restoreSnapshot(after) })
        }
    }

    /// Puts the graph back to a recorded state (undo/redo).
    func restoreSnapshot(_ snapshot: MaterialGraph.Snapshot) {
        graph.restore(snapshot)
        materials.forEach { $0.name = snapshot.name }
        baseline = snapshot
    }

    /// Any edit to the graph: fold it into an undo step that closes when editing pauses.
    private func edited() {
        MainActor.assumeIsolated {
            let history = EditHistory.shared
            guard !history.isReplaying else { return }
            history.beginGroup(ObjectIdentifier(self)) { [weak self] in
                guard let self else { return nil }
                let before = self.baseline, after = self.graph.snapshot
                self.baseline = after
                guard before != after else { return nil }
                return EditHistory.Step(name: "Edit “\(after.name)”",
                                        undo: { [weak self] in self?.restoreSnapshot(before) },
                                        redo: { [weak self] in self?.restoreSnapshot(after) })
            }
        }
    }

    /// Image Texture nodes' shared tiling, or nil when they differ.
    var textureTiling: Float? {
        let values = Set(graph.nodes.filter { $0.kind == .imageTexture }.map { $0.value("Tiling").x })
        return values.count == 1 ? values.first : nil
    }

    /// Sets uniform U/V tiling on every Image Texture node at once.
    func setTextureTiling(_ tiling: Float) {
        for node in graph.nodes where node.kind == .imageTexture {
            graph.update(node.id) { $0.values["Tiling"] = SIMD4(tiling, tiling, 0, 0) }
        }
    }

    private func attach() {
        graph.onChange = { [weak self] in self?.scheduleRefresh() }
        graph.onEdit = { [weak self] in self?.edited() }
        baseline = graph.snapshot
        scheduleRefresh(debounce: false)
    }

    /// Waits for the latest refresh to reach the viewport material and swatch.
    func waitForRefresh() async { await refreshTask?.value }

    /// Re-evaluates the graph off the main thread and updates the viewport material and node previews.
    func scheduleRefresh(debounce: Bool = true) {
        NotificationCenter.default.post(name: .materialsDidChange, object: nil)
        refreshTask?.cancel()
        let previewSize = min(GraphEvaluator.bakeSize(for: graph), 512)
        let preview = GraphEvaluator(graph: graph, size: previewSize)
        let thumbs = GraphEvaluator(graph: graph, size: 72)
        let nodeIDs = graph.nodes.map(\.id)
        let materials = materials
        refreshTask = Task { [weak self] in
            if debounce { try? await Task.sleep(for: .milliseconds(40)) }
            guard !Task.isCancelled else { return }
            let (result, images, swatch) = await Task.detached(priority: .userInitiated) {
                let result = preview.evaluateMaterial()
                var images: [UUID: CGImage] = [:]
                for id in nodeIDs { images[id] = thumbs.thumbnail(of: id) }
                let swatch = thumbs.render(thumbs.evaluateMaterial()[.baseColor])
                return (result, images, swatch)
            }.value
            guard !Task.isCancelled, let self else { return }
            MaterialApplier.apply(result, to: materials, evaluator: preview)
            self.thumbnails = images
            self.swatch = swatch
        }
    }
}

@Observable
final class ModelDocument: Identifiable {
    let id = UUID()
    let sourceURL: URL
    var name: String
    /// Container for the model's nodes; only its children are exported.
    let root: SCNNode
    private(set) var materials: [MaterialEntry]
    /// Bumped when the node hierarchy changes (delete, rename, visibility) so the outliner refreshes.
    private(set) var sceneRevision = 0
    var metadata: StageMetadata {
        didSet {
            applyUpAxis()
            // Mapping sizes are in meters, so a unit change rescales every projection.
            if metadata.metersPerUnit != oldValue.metersPerUnit { scheduleMapping(nil) }
        }
    }
    let hasAnimations: Bool
    /// Bakes material mappings into texture coordinates.
    @ObservationIgnored let mappingBaker = MappingBaker()
    @ObservationIgnored private var mappingTask: Task<Void, Never>?
    @ObservationIgnored private var pendingMappings: [MaterialEntry]? = []
    var exportedURL: URL?
    var issues: [String] = []
    /// Saved material variants (see Colorways.swift), and the one last applied or saved.
    var colorways: [Colorway] = []
    var activeColorwayID: UUID?
    /// Saved object arrangements (see Poses.swift), and the one last applied or saved.
    var poses: [Pose] = []
    var activePoseID: UUID?

    var meshCount: Int {
        var count = 0
        root.enumerateHierarchy { node, _ in if node.geometry != nil { count += 1 } }
        return count
    }

    /// An independent copy of this model, with its own geometry and materials (graphs and mappings
    /// included), for comparing material variations side by side.
    @MainActor
    func duplicate(named newName: String) -> ModelDocument {
        let rootCopy = root.clone()
        rootCopy.simdPosition = .zero
        rootCopy.simdScale = SIMD3(repeating: 1)
        var copies: [ObjectIdentifier: SCNMaterial] = [:]
        var originals: [ObjectIdentifier: SCNMaterial] = [:]   // copy → original
        var geometries: [(SCNGeometry, SCNGeometry)] = []
        // clone() shares geometry and materials; walk both trees in step and give the copy its own.
        var nodeMap: [ObjectIdentifier: SCNNode] = [:]   // original node → its copy
        func walk(_ a: SCNNode, _ b: SCNNode) {
            nodeMap[ObjectIdentifier(a)] = b
            b.customPivot = a.customPivot
            b.hinge = a.hinge
            if let geometry = a.geometry, let copy = geometry.copy() as? SCNGeometry {
                copy.materials = geometry.materials.map { material in
                    if let existing = copies[ObjectIdentifier(material)] { return existing }
                    let c = material.copy() as! SCNMaterial
                    copies[ObjectIdentifier(material)] = c
                    originals[ObjectIdentifier(c)] = material
                    return c
                }
                b.geometry = copy
                geometries.append((geometry, copy))
            }
            for (childA, childB) in zip(a.childNodes, b.childNodes) { walk(childA, childB) }
        }
        walk(root, rootCopy)

        let document = ModelDocument(url: sourceURL, root: rootCopy, metadata: metadata)
        document.name = newName
        for (original, copy) in geometries { document.mappingBaker.adopt(from: mappingBaker, original: original, copy: copy) }
        var ids: [UUID: UUID] = [:]   // this model's material IDs → the copy's
        for entry in document.materials {
            guard let original = originals[ObjectIdentifier(entry.material)],
                  let source = materials.first(where: { $0.materials.contains { $0 === original } }) else { continue }
            entry.copyState(from: source)
            entry.resetGraph = source.resetGraph
            ids[source.id] = entry.id
        }
        document.colorways = colorways(remapping: ids)
        document.poses = poses(remapping: nodeMap)
        document.activePoseID = activePoseID
        document.activeColorwayID = activeColorwayID
        return document
    }

    /// `groups` lists the SceneKit materials of each material entry; by default identical copies are grouped.
    init(url: URL, root: SCNNode, metadata: StageMetadata, groups explicit: [[SCNMaterial]]? = nil) {
        sourceURL = url
        name = url.deletingPathExtension().lastPathComponent
        self.root = root
        self.metadata = metadata

        var seen: Set<ObjectIdentifier> = []
        var groups: [(key: String, materials: [SCNMaterial])] = []
        var animated = false
        root.enumerateHierarchy { node, _ in
            if !node.animationKeys.isEmpty || node.skinner != nil || node.morpher != nil { animated = true }
            guard explicit == nil else { return }
            for material in node.geometry?.materials ?? [] where seen.insert(ObjectIdentifier(material)).inserted {
                let key = Self.fingerprint(material)
                if let i = groups.firstIndex(where: { $0.key == key }) {
                    groups[i].materials.append(material)
                } else {
                    groups.append((key, [material]))
                }
            }
        }
        materials = (explicit ?? groups.map(\.materials)).enumerated().map { i, group in
            MaterialEntry(materials: group, fallbackName: "Material\(i + 1)")
        }
        hasAnimations = animated
        applyUpAxis()
        materials.forEach(observeMapping)
    }

    /// Rebuilds every mapping immediately (for headless conversion).
    @MainActor func applyMappingsNow() {
        mappingTask?.cancel()
        pendingMappings = []
        if mappingBaker.apply(root: root, entries: materials, metersPerUnit: metadata.metersPerUnit) { sceneChanged() }
    }

    private func observeMapping(_ entry: MaterialEntry) {
        entry.onMappingChange = { [weak self, weak entry] in
            guard let self, let entry else { return }
            self.scheduleMapping([entry])
        }
    }

    /// Rebuilds texture coordinates for `entries` (nil: all) shortly after edits pause, so dragging
    /// a mapping slider doesn't rebuild meshes on every tick.
    private func scheduleMapping(_ entries: [MaterialEntry]?) {
        if let entries, let pending = pendingMappings {
            pendingMappings = pending + entries.filter { e in !pending.contains { $0 === e } }
        } else {
            pendingMappings = nil
        }
        mappingTask?.cancel()
        mappingTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(30))
            guard let self, !Task.isCancelled else { return }
            let only = self.pendingMappings
            self.pendingMappings = []
            if self.mappingBaker.apply(root: self.root, entries: self.materials, only: only, metersPerUnit: self.metadata.metersPerUnit) {
                self.sceneChanged()
            }
        }
    }

    func sceneChanged() {
        sceneRevision &+= 1
        NotificationCenter.default.post(name: .sceneDidChange, object: self)
    }

    /// Real-world size (meters) of the visible geometry under `node` (default: the whole model), as
    /// width (X), height (Y, up) and depth (Z) in the viewer's upright frame.
    func size(of node: SCNNode? = nil) -> SIMD3<Float>? {
        let target = node ?? root
        var lo = SIMD3<Float>(repeating: .greatestFiniteMagnitude), hi = -lo
        target.enumerateHierarchy { child, _ in
            guard child.geometry != nil, !child.isHidden else { return }
            let (a, b) = child.boundingBox
            for corner in 0..<8 {
                let p = SCNVector3(corner & 1 == 0 ? a.x : b.x, corner & 2 == 0 ? a.y : b.y, corner & 4 == 0 ? a.z : b.z)
                let w = SIMD3<Float>(child.convertPosition(p, to: nil))
                lo = simd_min(lo, w)
                hi = simd_max(hi, w)
            }
        }
        guard lo.x <= hi.x else { return nil }
        // Undo the container's scale (a compared model is scaled into the other model's units).
        return (hi - lo) * Float(metadata.metersPerUnit) / max(root.simdScale.x, 1e-9)
    }

    /// The material entries used by a node's own geometry.
    func entries(for node: SCNNode) -> [MaterialEntry] {
        let used = node.geometry?.materials ?? []
        return materials.filter { entry in entry.materials.contains { m in used.contains { $0 === m } } }
    }

    /// Every geometry node at or under `node`.
    static func geometryNodes(in node: SCNNode) -> [SCNNode] {
        var nodes: [SCNNode] = []
        node.enumerateHierarchy { child, _ in if child.geometry != nil { nodes.append(child) } }
        return nodes
    }

    func addMaterials(_ entries: [MaterialEntry]) {
        materials += entries
        entries.forEach(observeMapping)
        NotificationCenter.default.post(name: .materialsDidChange, object: nil)
    }

    func removeMaterials(_ entries: [MaterialEntry]) {
        materials.removeAll { entry in entries.contains { $0 === entry } }
    }

    /// Identifies copies of the same source material: same name and same property contents.
    /// Unnamed materials are never merged.
    private static func fingerprint(_ m: SCNMaterial) -> String {
        guard let name = m.name, !name.isEmpty else { return UUID().uuidString }
        let properties = [m.diffuse, m.metalness, m.roughness, m.normal, m.emission, m.transparent,
                          m.ambientOcclusion, m.clearCoat, m.clearCoatRoughness]
        let contents = properties.map { p -> String in
            switch p.contents {
            case nil: "-"
            case let url as URL: url.absoluteString
            case let value as NSNumber: value.stringValue
            case let color as NSColor: color.description
            case let other?: "\(ObjectIdentifier(other as AnyObject))"
            }
        }
        return ([name, "\(m.lightingModel.rawValue)", "\(m.isDoubleSided)", "\(m.transparency)"] + contents)
            .joined(separator: "|")
    }

    /// Shows Z-up models upright in the Y-up viewport without changing exported transforms.
    private func applyUpAxis() {
        root.eulerAngles = metadata.upAxis == "Z" ? SCNVector3(-Double.pi / 2, 0, 0) : SCNVector3Zero
    }

    /// FBX import goes through Reality Converter's plugin, which the App Store edition can't load.
    static let importableExtensions = ["usdz", "usd", "usda", "usdc", "fbx", "obj", "dae", "scn", "abc", "ply", "stl"]
        .filter { !Distribution.isAppStore || $0 != "fbx" }

    static func load(url: URL) async throws -> ModelDocument {
        let ext = url.pathExtension.lowercased()
        guard importableExtensions.contains(ext) else {
            throw ConverterError.unsupportedFormat(ext)
        }
        // FBX goes through Apple's FBX → USD converter first; everything after works on the USD.
        let sceneURL = ext == "fbx" ? try await FBXImporter.convert(url) : url
        let (scene, metadata) = try await Task.detached(priority: .userInitiated) {
            let scene = try SCNScene(url: sceneURL, options: [.checkConsistency: true])
            var metadata = USDTools.readMetadata(url: sceneURL) ?? StageMetadata()
            if ext == "fbx", metadata.copyright.hasPrefix("Reality Converter") {
                metadata.copyright = "" // placeholder written by Apple's FBX converter, not the model's
            }
            if !["usdz", "usd", "usda", "usdc", "fbx"].contains(ext) {
                // Non-USD formats arrive Y-up and are usually authored in meters (OBJ/STL: unitless).
                metadata.upAxis = "Y"
            }
            return (scene, metadata)
        }.value

        // SceneKit returns an empty scene rather than throwing for some unreadable files.
        guard !scene.rootNode.childNodes(passingTest: { node, _ in node.geometry != nil }).isEmpty else {
            throw ConverterError.loadFailed(url.lastPathComponent)
        }

        let root = SCNNode()
        root.name = url.deletingPathExtension().lastPathComponent
        for child in scene.rootNode.childNodes {
            child.removeFromParentNode()
            root.addChildNode(child)
        }
        // Lights and cameras from the file would fight the viewer's environment lighting.
        root.enumerateHierarchy { node, _ in
            node.light = nil
            node.camera = nil
        }
        return ModelDocument(url: url, root: root, metadata: metadata)
    }
}

enum ConverterError: LocalizedError {
    case unsupportedFormat(String)
    case exportFailed(String)
    case loadFailed(String)
    case fbxUnavailable
    case fbxFailed(String)

    var errorDescription: String? {
        switch self {
        case .fbxUnavailable:
            "FBX import uses Apple's FBX converter, which comes with Reality Converter. Install Reality Converter (free from developer.apple.com/augmented-reality/tools) and try again."
        case let .fbxFailed(reason):
            "The FBX file couldn't be converted: \(reason)"
        case let .loadFailed(name):
            "“\(name)” couldn't be read, or contains no geometry."
        case let .unsupportedFormat(ext):
            "“.\(ext)” files aren't supported. Supported formats: \(ModelDocument.importableExtensions.joined(separator: ", "))."
        case let .exportFailed(reason):
            "Export failed: \(reason)"
        }
    }
}

extension Notification.Name {
    /// Any material graph changed (posted on every re-evaluation).
    static let materialsDidChange = Notification.Name("RC2MaterialsDidChange")
    /// A document's object hierarchy changed (rename, visibility, transform, delete…).
    static let sceneDidChange = Notification.Name("RC2SceneDidChange")
}
private struct MappingKey: Hashable { let entry: ObjectIdentifier }
