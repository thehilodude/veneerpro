import AppKit
import ImageIO
import SceneKit
import UniformTypeIdentifiers

extension UTType {
    /// A Veneer Pro project (.vnr), declared in Info.plist.
    static let veneerProject = UTType(exportedAs: "com.thehilodude.veneerpro.project", conformingTo: .package)
}

/// A saved workspace: every open model with its edits, material graphs, mappings and colorways.
///
/// A `.vnr` is a package (a folder Finder shows as one file):
///
///     project.json         models, graphs, mappings, colorways, selection
///     Models/<n>.scn       each model's scene: hierarchy, names, visibility, transforms, unmapped geometry
///     Textures/<id>.<ext>  every image the graphs use, so the project doesn't depend on the original files
///     Swatches/<id>.png    colorway swatches
///
/// Scenes hold placeholder materials named "vnr:<index>"; project.json supplies each material's graph.
enum ProjectFile {
    static let fileExtension = "vnr"
    static let formatVersion = 1

    struct Contents {
        var documents: [ModelDocument]
        var selected: Int?
        var comparison: [Int]?
    }

    // MARK: Writing

    @MainActor
    static func write(documents: [ModelDocument], selected: UUID?, comparison: [UUID]?, to url: URL) throws {
        let fm = FileManager.default
        let staging = fm.temporaryDirectory.appendingPathComponent("VeneerPro-Save-\(UUID().uuidString).\(fileExtension)")
        try fm.createDirectory(at: staging.appendingPathComponent("Models"), withIntermediateDirectories: true)
        try fm.createDirectory(at: staging.appendingPathComponent("Textures"), withIntermediateDirectories: true)
        try fm.createDirectory(at: staging.appendingPathComponent("Swatches"), withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: staging) }

        var textures = TextureWriter(folder: staging.appendingPathComponent("Textures"))
        var models: [Manifest.Model] = []
        for (n, document) in documents.enumerated() {
            let scenePath = "Models/\(n).scn"
            try writeScene(of: document, to: staging.appendingPathComponent(scenePath))
            let index = Dictionary(uniqueKeysWithValues: document.materials.enumerated().map { ($1.id, $0) })
            let materials = try document.materials.map { entry in
                Manifest.Material(graph: try textures.encode(entry.graph.snapshot), mapping: .init(entry.mapping),
                                  reset: try textures.encode(entry.originalSnapshot))
            }
            let colorways = try document.colorways.map { colorway in
                var swatchFiles: [String] = []
                for (i, swatch) in colorway.swatches.enumerated() {
                    let path = "Swatches/\(colorway.id.uuidString)-\(i).png"
                    if let png = NSBitmapImageRep(cgImage: swatch).representation(using: .png, properties: [:]) {
                        try png.write(to: staging.appendingPathComponent(path))
                        swatchFiles.append(path)
                    }
                }
                var looks: [String: Manifest.Look] = [:]
                for (id, look) in colorway.looks {
                    guard let i = index[id] else { continue }
                    looks[String(i)] = Manifest.Look(graph: try textures.encode(look.graph), mapping: .init(look.mapping))
                }
                return Manifest.Colorway(name: colorway.name, looks: looks, swatches: swatchFiles)
            }
            models.append(Manifest.Model(
                name: document.name, source: document.sourceURL.path, scene: scenePath,
                metadata: .init(copyright: document.metadata.copyright, metersPerUnit: document.metadata.metersPerUnit,
                                upAxis: document.metadata.upAxis),
                materials: materials, colorways: colorways,
                activeColorway: document.colorways.firstIndex { $0.id == document.activeColorwayID },
                objects: objectStates(document.root),
                poses: poseRecords(document),
                activePose: document.poses.firstIndex { $0.id == document.activePoseID }))
        }
        let position = { (id: UUID) in documents.firstIndex { $0.id == id } }
        let manifest = Manifest(format: formatVersion, models: models, selected: selected.flatMap(position),
                                comparison: comparison.map { $0.compactMap(position) })
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(manifest).write(to: staging.appendingPathComponent("project.json"))

        // Swap the finished package in, so a failed save never leaves a half-written project.
        if fm.fileExists(atPath: url.path) {
            _ = try fm.replaceItemAt(url, withItemAt: staging)
        } else {
            try fm.moveItem(at: staging, to: url)
        }
    }

    /// Every node with a custom pivot or a hinge, by its path from the model's container.
    @MainActor
    private static func objectStates(_ root: SCNNode) -> [Manifest.Object] {
        var states: [Manifest.Object] = []
        func walk(_ node: SCNNode, _ path: [Int]) {
            if node.customPivot != nil || node.hinge != nil {
                states.append(Manifest.Object(path: path, pivot: node.customPivot.map { [$0.x, $0.y, $0.z] }, hinge: node.hinge))
            }
            for (i, child) in node.childNodes.enumerated() { walk(child, path + [i]) }
        }
        for (i, child) in root.childNodes.enumerated() { walk(child, [i]) }
        return states
    }

    @MainActor
    private static func poseRecords(_ document: ModelDocument) -> [Manifest.PoseRecord] {
        var paths: [ObjectIdentifier: [Int]] = [:]
        func walk(_ node: SCNNode, _ path: [Int]) {
            paths[ObjectIdentifier(node)] = path
            for (i, child) in node.childNodes.enumerated() { walk(child, path + [i]) }
        }
        for (i, child) in document.root.childNodes.enumerated() { walk(child, [i]) }
        return document.poses.map { pose in
            Manifest.PoseRecord(name: pose.name, states: pose.states.compactMap { state in
                paths[ObjectIdentifier(state.node)].map { path in
                    let m = state.transform
                    return Manifest.PoseState(path: path, transform: [m.columns.0, m.columns.1, m.columns.2, m.columns.3].flatMap { [$0.x, $0.y, $0.z, $0.w] },
                                              hidden: state.hidden, hinge: state.hinge)
                }
            })
        }
    }

    private static func node(at path: [Int], in root: SCNNode) -> SCNNode? {
        var node = root
        for i in path {
            guard node.childNodes.indices.contains(i) else { return nil }
            node = node.childNodes[i]
        }
        return node
    }

    /// Archives the model's nodes with unmapped geometry and placeholder materials.
    @MainActor
    private static func writeScene(of document: ModelDocument, to url: URL) throws {
        var placeholders: [ObjectIdentifier: SCNMaterial] = [:]
        for (i, entry) in document.materials.enumerated() {
            for material in entry.materials {
                // Keeps settings like double-sidedness; the graph supplies the look, so images are dropped.
                let placeholder = material.copy() as! SCNMaterial
                for property in [placeholder.diffuse, placeholder.metalness, placeholder.roughness, placeholder.normal,
                                 placeholder.emission, placeholder.transparent, placeholder.ambientOcclusion,
                                 placeholder.clearCoat, placeholder.clearCoatRoughness, placeholder.clearCoatNormal,
                                 placeholder.displacement, placeholder.specular, placeholder.reflective,
                                 placeholder.multiply, placeholder.selfIllumination, placeholder.ambient] {
                    property.contents = nil
                }
                placeholder.name = "vnr:\(i)"
                placeholders[ObjectIdentifier(material)] = placeholder
            }
        }
        let copy = document.root.clone()
        copy.transform = SCNMatrix4Identity
        func walk(_ live: SCNNode, _ saved: SCNNode) {
            if let geometry = live.geometry, let unmapped = document.mappingBaker.source(of: geometry).copy() as? SCNGeometry {
                unmapped.materials = geometry.materials.map { placeholders[ObjectIdentifier($0)] ?? SCNMaterial() }
                saved.geometry = unmapped
            }
            for (a, b) in zip(live.childNodes, saved.childNodes) { walk(a, b) }
        }
        walk(document.root, copy)
        let scene = SCNScene()
        scene.rootNode.addChildNode(copy)
        guard scene.write(to: url, options: nil, delegate: nil, progressHandler: nil) else {
            throw ProjectError.writeFailed(document.name)
        }
    }

    // MARK: Reading

    @MainActor
    static func read(_ url: URL) async throws -> Contents {
        let data = try Data(contentsOf: url.appendingPathComponent("project.json"))
        let manifest = try JSONDecoder().decode(Manifest.self, from: data)
        guard manifest.format <= formatVersion else { throw ProjectError.newerFormat }
        let textures = TextureReader(package: url)

        var documents: [ModelDocument] = []
        for model in manifest.models {
            let sceneURL = url.appendingPathComponent(model.scene)
            let scene = try await Task.detached(priority: .userInitiated) { try SCNScene(url: sceneURL) }.value
            let root = SCNNode()
            root.name = model.name
            // The scene holds the model's container node; its children become the new container's.
            for child in scene.rootNode.childNodes.first?.childNodes ?? [] {
                child.removeFromParentNode()
                root.addChildNode(child)
            }
            // Regroup the scene's materials by the entry each placeholder stands for.
            var groups = Array(repeating: [SCNMaterial](), count: model.materials.count)
            var seen: Set<ObjectIdentifier> = []
            root.enumerateHierarchy { node, _ in
                for material in node.geometry?.materials ?? [] where seen.insert(ObjectIdentifier(material)).inserted {
                    guard let i = material.name.flatMap({ Int($0.dropFirst(4)) }), groups.indices.contains(i) else { continue }
                    groups[i].append(material)
                }
            }
            guard !groups.contains(where: \.isEmpty) else { throw ProjectError.damaged(model.name) }
            let metadata = StageMetadata(copyright: model.metadata.copyright, metersPerUnit: model.metadata.metersPerUnit,
                                         upAxis: model.metadata.upAxis)
            let document = ModelDocument(url: URL(fileURLWithPath: model.source), root: root, metadata: metadata, groups: groups)
            document.name = model.name
            for (entry, saved) in zip(document.materials, model.materials) {
                entry.applyLook(Colorway.Look(graph: try textures.decode(saved.graph), mapping: saved.mapping.value))
                entry.resetGraph = try textures.decode(saved.reset)
            }
            document.colorways = try model.colorways.map { saved in
                var looks: [UUID: Colorway.Look] = [:]
                for (key, look) in saved.looks {
                    guard let i = Int(key), document.materials.indices.contains(i) else { continue }
                    looks[document.materials[i].id] = Colorway.Look(graph: try textures.decode(look.graph), mapping: look.mapping.value)
                }
                let swatches = saved.swatches.compactMap { path -> CGImage? in
                    guard let source = CGImageSourceCreateWithURL(url.appendingPathComponent(path) as CFURL, nil) else { return nil }
                    return CGImageSourceCreateImageAtIndex(source, 0, nil)
                }
                return Colorway(name: saved.name, looks: looks, swatches: swatches)
            }
            for object in model.objects ?? [] {
                guard let node = node(at: object.path, in: root) else { continue }
                node.customPivot = object.pivot.flatMap { $0.count == 3 ? SIMD3($0[0], $0[1], $0[2]) : nil }
                node.hinge = object.hinge
            }
            document.poses = (model.poses ?? []).map { record in
                Pose(name: record.name, states: record.states.compactMap { state in
                    guard let node = node(at: state.path, in: root), state.transform.count == 16 else { return nil }
                    let m = state.transform
                    let transform = simd_float4x4(columns: (SIMD4(m[0..<4]), SIMD4(m[4..<8]), SIMD4(m[8..<12]), SIMD4(m[12..<16])))
                    return Pose.State(node: node, transform: transform, hidden: state.hidden, hinge: state.hinge)
                })
            }
            document.activePoseID = model.activePose.flatMap { document.poses.indices.contains($0) ? document.poses[$0].id : nil }
            document.activeColorwayID = model.activeColorway.flatMap { document.colorways.indices.contains($0) ? document.colorways[$0].id : nil }
            document.applyMappingsNow()
            documents.append(document)
        }
        return Contents(documents: documents, selected: manifest.selected, comparison: manifest.comparison)
    }
}

enum ProjectError: LocalizedError {
    case writeFailed(String)
    case damaged(String)
    case newerFormat

    var errorDescription: String? {
        switch self {
        case let .writeFailed(name): "“\(name)” couldn't be saved into the project."
        case let .damaged(name): "The project's copy of “\(name)” is damaged."
        case .newerFormat: "This project was saved by a newer version of Veneer Pro."
        }
    }
}

// MARK: - project.json

private struct Manifest: Codable {
    var format: Int
    var models: [Model]
    var selected: Int?
    var comparison: [Int]?

    struct Model: Codable {
        var name: String
        /// Where the model was originally imported from (the project doesn't need it to open).
        var source: String
        var scene: String
        var metadata: Metadata
        var materials: [Material]
        var colorways: [Colorway]
        var activeColorway: Int?
        /// Pivots and hinges, by node path (child indices from the model's container).
        var objects: [Object]?
        var poses: [PoseRecord]?
        var activePose: Int?
    }

    struct PoseRecord: Codable {
        var name: String
        var states: [PoseState]
    }

    struct PoseState: Codable {
        var path: [Int]
        var transform: [Float]
        var hidden: Bool
        var hinge: Hinge?
    }

    struct Object: Codable {
        var path: [Int]
        var pivot: [Float]?
        var hinge: Hinge?
    }

    struct Metadata: Codable {
        var copyright: String
        var metersPerUnit: Double
        var upAxis: String
    }

    struct Material: Codable {
        var graph: Graph
        var mapping: Mapping
        /// The as-imported graph, for Reset Material.
        var reset: Graph
    }

    struct Colorway: Codable {
        var name: String
        /// Keyed by material index.
        var looks: [String: Look]
        var swatches: [String]
    }

    struct Look: Codable {
        var graph: Graph
        var mapping: Mapping
    }

    struct Graph: Codable {
        var name: String
        var nodes: [Node]
        var links: [Link]
        var spec: Spec?
    }

    struct Spec: Codable {
        var colorCode: String?
        var colorName: String?
        var color: [Float]?
        var finish: String?
        var finishNodes: [UUID]?

        init(_ s: CMFSpec) {
            colorCode = s.colorCode
            colorName = s.colorName
            color = s.color.map { [$0.x, $0.y, $0.z] }
            finish = s.finishID
            finishNodes = s.finishNodes
        }

        var value: CMFSpec {
            CMFSpec(colorCode: colorCode, colorName: colorName,
                    color: color.flatMap { $0.count == 3 ? SIMD3($0[0], $0[1], $0[2]) : nil },
                    finishID: finish, finishNodes: finishNodes ?? [])
        }
    }

    struct Node: Codable {
        var id: UUID
        var kind: NodeKind
        var x: Double
        var y: Double
        var values: [String: [Float]]
        var option: String
        /// Path of the image in the package's Textures folder.
        var texture: String?
        var textureName: String?
    }

    struct Link: Codable {
        var id: UUID
        var fromNode: UUID
        var fromPort: Int
        var toNode: UUID
        var toPort: Int
    }

    struct Mapping: Codable {
        var kind: String
        var axis: String
        var size: Double
        var rotation: Double
        var offset: [Double]

        init(_ m: TextureMapping) {
            kind = m.kind.rawValue
            axis = m.axis.rawValue
            size = m.size
            rotation = m.rotation
            offset = [m.offset.x, m.offset.y]
        }

        var value: TextureMapping {
            var m = TextureMapping()
            m.kind = TextureMapping.Kind(rawValue: kind) ?? .uv
            m.axis = TextureMapping.Axis(rawValue: axis) ?? .z
            m.size = size
            m.rotation = rotation
            if offset.count == 2 { m.offset = SIMD2(offset[0], offset[1]) }
            return m
        }
    }
}

/// Writes each distinct texture once and encodes graphs that refer to it by path.
private struct TextureWriter {
    let folder: URL
    private var paths: [ObjectIdentifier: String] = [:]

    init(folder: URL) { self.folder = folder }

    mutating func encode(_ snapshot: MaterialGraph.Snapshot) throws -> Manifest.Graph {
        let nodes = try snapshot.nodes.map { node in
            var path: String?
            if let texture = node.texture {
                if let existing = paths[ObjectIdentifier(texture)] {
                    path = existing
                } else {
                    let name = "Textures/\(texture.id.uuidString).\(texture.fileExtension.isEmpty ? "png" : texture.fileExtension)"
                    try texture.data.write(to: folder.deletingLastPathComponent().appendingPathComponent(name))
                    paths[ObjectIdentifier(texture)] = name
                    path = name
                }
            }
            return Manifest.Node(id: node.id, kind: node.kind, x: node.position.x, y: node.position.y,
                                 values: node.values.mapValues { [$0.x, $0.y, $0.z, $0.w] }, option: node.option,
                                 texture: path, textureName: node.texture?.name)
        }
        let links = snapshot.links.map {
            Manifest.Link(id: $0.id, fromNode: $0.from.node, fromPort: $0.from.port, toNode: $0.to.node, toPort: $0.to.port)
        }
        return Manifest.Graph(name: snapshot.name, nodes: nodes, links: links,
                              spec: snapshot.spec == CMFSpec() ? nil : Manifest.Spec(snapshot.spec))
    }
}

/// Loads each texture once, so graphs and colorways that shared an image share it again.
private final class TextureReader {
    let package: URL
    private var loaded: [String: TextureRef] = [:]

    init(package: URL) { self.package = package }

    func decode(_ graph: Manifest.Graph) throws -> MaterialGraph.Snapshot {
        let nodes = try graph.nodes.map { saved in
            var node = GraphNode(kind: saved.kind, position: CGPoint(x: saved.x, y: saved.y), texture: try saved.texture.map { try texture($0, name: saved.textureName) })
            node.id = saved.id
            node.values = saved.values.compactMapValues { $0.count == 4 ? SIMD4($0[0], $0[1], $0[2], $0[3]) : nil }
            node.option = saved.option
            return node
        }
        let links = graph.links.map {
            GraphLink(id: $0.id, from: PortRef(node: $0.fromNode, port: $0.fromPort), to: PortRef(node: $0.toNode, port: $0.toPort))
        }
        return MaterialGraph.Snapshot(name: graph.name, nodes: nodes, links: links, spec: graph.spec?.value ?? CMFSpec())
    }

    private func texture(_ path: String, name: String?) throws -> TextureRef {
        if let existing = loaded[path] { return existing }
        let url = package.appendingPathComponent(path)
        guard let data = try? Data(contentsOf: url),
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw ProjectError.damaged(name ?? url.lastPathComponent)
        }
        let texture = TextureRef(name: name ?? url.deletingPathExtension().lastPathComponent, cgImage: image, data: data,
                                 fileExtension: url.pathExtension.lowercased())
        loaded[path] = texture
        return texture
    }
}

// MARK: - Opening and saving

extension AppModel {
    var projectName: String? { projectURL?.deletingPathExtension().lastPathComponent }

    /// Whether quitting or opening another project would lose work. An untitled workspace that only
    /// has imported models (nothing edited) doesn't count.
    var hasUnsavedChanges: Bool {
        !documents.isEmpty && (contentChanged || (projectURL != nil && structureChanged))
    }

    /// Edits that don't touch materials or the scene (e.g. renaming a colorway).
    func noteProjectEdit() { if !suppressChangeTracking { contentChanged = true } }

    /// Saves to the open project, or asks where to save an untitled one. Returns whether it saved.
    @discardableResult
    func saveProject() -> Bool {
        guard let projectURL else { return saveProjectAs() }
        return write(to: projectURL)
    }

    @discardableResult
    func saveProjectAs() -> Bool {
        guard !documents.isEmpty else { return false }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.veneerProject]
        panel.nameFieldStringValue = (projectName ?? selectedDocument?.name ?? documents[0].name) + "." + ProjectFile.fileExtension
        panel.directoryURL = projectURL?.deletingLastPathComponent() ?? documents[0].sourceURL.deletingLastPathComponent()
        panel.message = "A project keeps your models, materials, mappings and colorways together in one file."
        guard panel.runModal() == .OK, let url = panel.url else { return false }
        return write(to: url)
    }

    private func write(to url: URL) -> Bool {
        EditHistory.shared.flush()
        do {
            try ProjectFile.write(documents: documents, selected: selectedDocumentID, comparison: comparison, to: url)
            projectURL = url
            contentChanged = false
            structureChanged = false
            noteRecent(url)
            return true
        } catch {
            errorMessage = "The project couldn't be saved. \(error.localizedDescription)"
            return false
        }
    }

    /// Offers to save unsaved work. Returns false if the user cancelled.
    func confirmDiscardingChanges(_ action: String) -> Bool {
        guard hasUnsavedChanges else { return true }
        let alert = NSAlert()
        alert.messageText = projectName.map { "Save changes to “\($0)” before \(action)?" } ?? "Save this workspace as a project before \(action)?"
        alert.informativeText = "Your edits will be lost if you don't save them."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Don't Save")
        alert.buttons[2].hasDestructiveAction = true
        switch alert.runModal() {
        case .alertFirstButtonReturn: return saveProject()
        case .alertThirdButtonReturn: return true
        default: return false
        }
    }

    /// Clears the workspace.
    func newProject() {
        guard confirmDiscardingChanges("starting a new project") else { return }
        replaceWorkspace(with: [], selected: nil, comparison: nil)
        projectURL = nil
    }

    func openProject(_ url: URL) {
        guard url.standardizedFileURL != projectURL?.standardizedFileURL || hasUnsavedChanges else { return }
        guard confirmDiscardingChanges("opening “\(url.deletingPathExtension().lastPathComponent)”") else { return }
        Task {
            isBusy = true
            status = "Opening “\(url.deletingPathExtension().lastPathComponent)”"
            suppressChangeTracking = true
            defer { isBusy = false; status = nil; suppressChangeTracking = false }
            do {
                let contents = try await ProjectFile.read(url)
                let ids = contents.documents.map(\.id)
                replaceWorkspace(with: contents.documents,
                                 selected: contents.selected.flatMap { ids.indices.contains($0) ? ids[$0] : nil } ?? ids.first,
                                 comparison: contents.comparison.flatMap { pair in
                                     pair.count == 2 && pair.allSatisfy(ids.indices.contains) ? pair.map { ids[$0] } : nil
                                 })
                projectURL = url
                noteRecent(url)
                // Let the materials' first refresh pass before edits count.
                try? await Task.sleep(for: .milliseconds(200))
                contentChanged = false
                structureChanged = false
            } catch {
                errorMessage = "“\(url.lastPathComponent)” couldn't be opened. \(error.localizedDescription)"
            }
        }
    }

    private func replaceWorkspace(with documents: [ModelDocument], selected: UUID?, comparison pair: [UUID]?) {
        if visionPro.isActive { Task { await visionPro.stop() } }
        if share.isActive { share.stop() }
        EditHistory.shared.clear()
        stopComparing()
        let tracking = suppressChangeTracking
        suppressChangeTracking = true
        self.documents = documents
        suppressChangeTracking = tracking
        selectedDocumentID = selected
        if let pair, pair.count == 2, let other = documents.first(where: { $0.id == pair[1] }) {
            selectedDocumentID = pair[0]
            compare(with: other)
        }
        contentChanged = false
        structureChanged = false
    }
}
