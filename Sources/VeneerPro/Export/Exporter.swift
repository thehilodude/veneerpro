import Foundation
import SceneKit

struct ExportOptions {
    /// Store the root layer as binary USDC (requires /usr/bin/usdcat), otherwise USDA.
    var binary = true
    var validate = true
    /// Caps texture size (for quick previews such as Vision Pro); nil keeps full resolution.
    var maxTextureSize: Int? = nil
    /// Include the model's colorways as a "Colorway" variant set (a picker in AR Quick Look). USDZ only.
    var colorwayVariants = true
    /// Writes hidden objects as visible, for a viewer that shows and hides them itself: RealityKit
    /// never draws a prim that was loaded invisible, even if its entity is enabled later.
    var hiddenAsVisible = false
}

enum Exporter {
    /// Bakes every material graph and writes `document` as USDZ, or FBX when `url` ends in .fbx.
    /// Returns validation issues.
    @MainActor
    static func export(_ document: ModelDocument, to url: URL, options: ExportOptions = ExportOptions()) async throws -> [String] {
        // Snapshot graphs on the main actor; the heavy work happens off it.
        let jobs: [([SCNMaterial], String, GraphEvaluator)] = document.materials.map { entry in
            (entry.materials, entry.name, GraphEvaluator(graph: entry.graph,
                                                          size: min(GraphEvaluator.bakeSize(for: entry.graph), options.maxTextureSize ?? .max)))
        }
        let root = document.root
        let metadata = document.metadata
        let name = document.name
        let variantJobs = options.colorwayVariants ? colorwayEvaluators(document, maxTextureSize: options.maxTextureSize) : []
        let (poseVariants, poseControlled) = options.colorwayVariants ? poseVariants(document) : ([], [])

        if url.pathExtension.lowercased() == "fbx" {
            return try await exportFBX(jobs: jobs, root: root, metadata: metadata, to: url, validate: options.validate)
        }

        return try await Task.detached(priority: .userInitiated) {
            let materials = jobs.map { sceneMaterials, name, evaluator in
                USDWriter.MaterialJob(materials: sceneMaterials, name: name, result: evaluator.evaluateMaterial(), evaluator: evaluator)
            }
            let writer = USDWriter(rootName: name)
            writer.maxTextureSize = options.maxTextureSize
            writer.writesVisibility = !options.hiddenAsVisible
            writer.poseVariants = poseVariants
            writer.poseControlled = poseControlled
            writer.colorwayVariants = variantJobs.map { variant in
                (variant.name, zip(jobs, variant.evaluators).map { job, evaluator in
                    USDWriter.MaterialJob(materials: job.0, name: job.1, result: evaluator.evaluateMaterial(), evaluator: evaluator)
                })
            }
            let usda = writer.write(root: root, materials: materials, metadata: metadata)

            let fm = FileManager.default
            let temp = fm.temporaryDirectory.appendingPathComponent("VeneerPro-\(UUID().uuidString)")
            try fm.createDirectory(at: temp, withIntermediateDirectories: true)
            defer { try? fm.removeItem(at: temp) }

            let layerBase = USDWriter.identifier(name, fallback: "model")
            let textURL = temp.appendingPathComponent("\(layerBase).usda")
            try usda.write(to: textURL, atomically: true, encoding: .utf8)

            var layer = USDZPackager.Entry(path: "\(layerBase).usda", data: Data(usda.utf8))
            if options.binary && USDTools.canConvertToBinary {
                let binaryURL = temp.appendingPathComponent("\(layerBase).usdc")
                try USDTools.convertToBinary(textURL, output: binaryURL)
                layer = USDZPackager.Entry(path: "\(layerBase).usdc", data: try Data(contentsOf: binaryURL))
            }

            try USDZPackager.write([layer] + writer.files, to: url)
            return options.validate ? USDTools.validate(url) : []
        }.value
    }

    /// The prims `exportLooks` writes are named this plus the look's index.
    static let lookPrefix = "VeneerLook"

    /// Writes just materials as a USDZ: one small plane per look, for loading materials without the
    /// model's geometry (the iPad's AR view swaps them to change colorways instantly).
    @MainActor
    static func exportLooks(_ looks: [Colorway.Look], metadata: StageMetadata, to url: URL) async throws {
        let root = SCNNode()
        let jobs: [(SCNMaterial, GraphEvaluator)] = looks.enumerated().map { i, look in
            let material = SCNMaterial()
            let plane = SCNPlane(width: 0.01, height: 0.01)
            plane.materials = [material]
            let node = SCNNode(geometry: plane)
            node.name = "\(lookPrefix)\(i)"
            root.addChildNode(node)
            let graph = MaterialGraph(name: look.graph.name)
            graph.restore(look.graph)
            return (material, GraphEvaluator(graph: graph, size: GraphEvaluator.bakeSize(for: graph)))
        }
        try await Task.detached(priority: .userInitiated) {
            let materials = jobs.enumerated().map { i, job in
                USDWriter.MaterialJob(materials: [job.0], name: "\(lookPrefix)Material\(i)", result: job.1.evaluateMaterial(), evaluator: job.1)
            }
            let writer = USDWriter(rootName: "Looks")
            let usda = writer.write(root: root, materials: materials, metadata: metadata)
            try USDZPackager.write([USDZPackager.Entry(path: "looks.usda", data: Data(usda.utf8))] + writer.files, to: url)
        }.value
    }

    /// One evaluator per material for each colorway, read from the saved looks (the model isn't touched).
    /// The default comes first: the active colorway, or the current materials when they've been edited
    /// since (or none is active). Materials a colorway doesn't cover keep their current look.
    @MainActor
    private static func colorwayEvaluators(_ document: ModelDocument, maxTextureSize: Int?) -> [(name: String, evaluators: [GraphEvaluator])] {
        guard !document.colorways.isEmpty else { return [] }
        func evaluators(_ looks: [UUID: Colorway.Look]?) -> [GraphEvaluator] {
            document.materials.map { entry in
                var graph = entry.graph
                if let look = looks?[entry.id] {
                    graph = MaterialGraph(name: look.graph.name)
                    graph.restore(look.graph)
                }
                return GraphEvaluator(graph: graph, size: min(GraphEvaluator.bakeSize(for: graph), maxTextureSize ?? .max))
            }
        }
        var variants = document.colorways.map { ($0.name, evaluators($0.looks)) }
        if let active = document.colorways.firstIndex(where: { $0.id == document.activeColorwayID }), !document.colorwayIsModified {
            variants.insert(variants.remove(at: active), at: 0)
        } else {
            variants.insert(("Current", evaluators(nil)), at: 0)
        }
        return variants
    }

    /// Each pose's object states, default first (the active pose, or "Current" when objects have moved
    /// since), and the objects whose transform or visibility differs between them.
    @MainActor
    private static func poseVariants(_ document: ModelDocument)
        -> ([(name: String, states: [ObjectIdentifier: (transform: simd_float4x4, hidden: Bool)])], Set<ObjectIdentifier>) {
        guard !document.poses.isEmpty else { return ([], []) }
        typealias States = [ObjectIdentifier: (transform: simd_float4x4, hidden: Bool)]
        func states(_ list: [Pose.State]) -> States {
            var result: States = [:]
            for state in list where state.node.isDescendant(of: document.root) {
                result[ObjectIdentifier(state.node)] = (state.transform, state.hidden)
            }
            return result
        }
        let current = states(document.currentPoseStates)
        var variants: [(name: String, states: States)] = document.poses.map { ($0.name, states($0.states)) }
        if let active = document.poses.firstIndex(where: { $0.id == document.activePoseID }), !document.poseIsModified {
            variants.insert(variants.remove(at: active), at: 0)
        } else {
            variants.insert(("Current", current), at: 0)
        }
        var controlled: Set<ObjectIdentifier> = []
        for (id, now) in current {
            let differs = variants.contains { variant in
                guard let state = variant.states[id] else { return false }
                return state.hidden != now.hidden
                    || (0..<4).contains { simd_reduce_max(simd_abs(state.transform[$0] - now.transform[$0])) > 1e-6 }
            }
            if differs { controlled.insert(id) }
        }
        // Objects a pose doesn't mention (added later) stay as they are now in that pose.
        for i in variants.indices {
            for id in controlled where variants[i].states[id] == nil { variants[i].states[id] = current[id] }
        }
        return (variants, controlled)
    }

    /// Writes a binary FBX with embedded textures. When Reality Converter is installed, the file is
    /// read back with its Autodesk FBX SDK-based importer as a check.
    private static func exportFBX(jobs: [([SCNMaterial], String, GraphEvaluator)], root: SCNNode, metadata: StageMetadata,
                                  to url: URL, validate: Bool) async throws -> [String] {
        let data = await Task.detached(priority: .userInitiated) { () -> Data in
            let materials = jobs.map { sceneMaterials, name, evaluator in
                USDWriter.MaterialJob(materials: sceneMaterials, name: name, result: evaluator.evaluateMaterial(), evaluator: evaluator)
            }
            return FBXWriter(fileName: url.lastPathComponent).write(root: root, materials: materials, metadata: metadata)
        }.value
        try data.write(to: url, options: .atomic)

        guard validate, FBXImporter.isAvailable else { return [] }
        do {
            // Check a link in a temporary folder: the FBX SDK extracts embedded textures into a
            // ".fbm" folder beside the file it reads, which shouldn't appear next to the export.
            let check = FileManager.default.temporaryDirectory.appendingPathComponent("VeneerPro-FBXCheck-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: check, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: check) }
            let link = check.appendingPathComponent(url.lastPathComponent)
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: url)
            _ = try await FBXImporter.convert(link)
            return []
        } catch {
            return ["Error: Autodesk's FBX reader couldn't open the exported file: \(error.localizedDescription)"]
        }
    }
}
