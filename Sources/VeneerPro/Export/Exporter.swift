import Foundation
import SceneKit

struct ExportOptions {
    /// Store the root layer as binary USDC (requires /usr/bin/usdcat), otherwise USDA.
    var binary = true
    var validate = true
    /// Caps texture size (for quick previews such as Vision Pro); nil keeps full resolution.
    var maxTextureSize: Int? = nil
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

        if url.pathExtension.lowercased() == "fbx" {
            return try await exportFBX(jobs: jobs, root: root, metadata: metadata, to: url, validate: options.validate)
        }

        return try await Task.detached(priority: .userInitiated) {
            let materials = jobs.map { sceneMaterials, name, evaluator in
                USDWriter.MaterialJob(materials: sceneMaterials, name: name, result: evaluator.evaluateMaterial(), evaluator: evaluator)
            }
            let writer = USDWriter(rootName: name)
            writer.maxTextureSize = options.maxTextureSize
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
