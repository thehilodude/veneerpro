import Foundation
import Observation
import SceneKit
import SpatialPreview
import System
import UniformTypeIdentifiers
import USDKit

/// Live preview on Apple Vision Pro via macOS 27's Spatial Preview framework.
///
/// The model opens in Quick Look on the headset (no visionOS app needed) and stays in sync without ever
/// being reopened. The scene is one ordinary USD layer held in a USDKit stage and shared with
/// `USDPreviewSession`; every edit is made to that same stage, which the session streams to the headset.
/// - Material value edits (colors, roughness, metallic, texture files…) become individual `setValue` calls.
/// - Structural edits (a different library material, connections added or removed, object edits) update
///   the same layer in place with `importContents`, which only touches what actually differs.
/// Only materials whose graph changed are re-evaluated, so edits stay quick. Undo/redo gestures in the
/// headset drive the app's undo history. If a live session can't be started, it falls back to sending a
/// USDZ and refreshing it on each change.
@MainActor
@Observable
final class VisionProPreview {
    enum Status: Equatable {
        case idle
        case connecting
        case live
        case updating
        case failed(String)

        var description: String {
            switch self {
            case .idle: ""
            case .connecting: "Opening on Apple Vision Pro…"
            case .live: "Live on Apple Vision Pro"
            case .updating: "Updating Apple Vision Pro…"
            case let .failed(message): "Vision Pro: \(message)"
            }
        }
    }

    private(set) var status: Status = .idle
    /// The document being previewed.
    private(set) weak var document: ModelDocument?
    /// Watches for an Apple Vision Pro connected through Mac Virtual Display.
    let connected = ConnectedSpatialEndpointObserver()

    var isActive: Bool { session != nil }

    @ObservationIgnored private var session: (any SpatialPreviewSession)?
    @ObservationIgnored private var usdSession: USDPreviewSession?
    @ObservationIgnored private var documentSession: DocumentPreviewSession?
    @ObservationIgnored private var stage: USDStage?
    @ObservationIgnored private var folder: URL?
    @ObservationIgnored private var revision = 0
    /// The material text the live stage currently matches, for diffing the next edit against.
    @ObservationIgnored private var liveMaterialText: String?
    @ObservationIgnored private var jobCache: [UUID: CachedJob] = [:]
    /// Each material's USD name, fixed when the session starts. Applying a library material renames the
    /// entry, but the headset keeps the same material prim, so meshes never need rebinding.
    @ObservationIgnored private var stableNames: [UUID: String] = [:]
    @ObservationIgnored private let bakeCache = USDWriter.BakeCache()
    @ObservationIgnored private var pendingMaterials = false
    @ObservationIgnored private var pendingScene = false
    @ObservationIgnored private var isPushing = false
    @ObservationIgnored private var updateTask: Task<Void, Never>?
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private weak var history: EditHistory?
    @ObservationIgnored private var undoBridge: UndoBridge?

    /// An evaluated material, reused until its graph changes.
    private struct CachedJob {
        let graph: ObjectIdentifier
        let revision: Int
        let job: USDWriter.MaterialJob
    }

    /// Texture bake size for live updates: smaller than export size so edits arrive quickly.
    private static let liveBakeCap = 1024

    // MARK: Session lifecycle

    /// Opens `document` on the headset at `endpoint` (the connected Vision Pro, or one picked in the device picker).
    func start(_ document: ModelDocument, endpoint: SpatialPreviewEndpoint, history: EditHistory) async {
        await stop()
        self.document = document
        self.history = history
        status = .connecting
        Self.log("start: \(document.name)")
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("VeneerPro-VisionPro-\(UUID().uuidString)")
        self.folder = folder
        do {
            try FileManager.default.createDirectory(at: folder.appendingPathComponent("textures"), withIntermediateDirectories: true)
            try await startLive(endpoint: endpoint)
        } catch {
            Self.log("live start failed: \(error)")
            // Fall back to a whole-file preview that's refreshed on every change.
            do {
                try await startDocument(endpoint: endpoint)
            } catch let fallbackError {
                Self.log("document start failed: \(fallbackError)")
                status = .failed(fallbackError.localizedDescription)
                await stop(keepStatus: true)
                return
            }
        }
        status = .live
        observeChanges()
    }

    func stop(keepStatus: Bool = false) async {
        updateTask?.cancel()
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        if let session { try? await session.close() }
        session = nil
        usdSession = nil
        documentSession = nil
        stage = nil
        undoBridge = nil
        liveMaterialText = nil
        jobCache = [:]
        stableNames = [:]
        if let folder { try? FileManager.default.removeItem(at: folder) }
        folder = nil
        document = nil
        pendingMaterials = false
        pendingScene = false
        if !keepStatus { status = .idle }
    }

    private func startLive(endpoint: SpatialPreviewEndpoint) async throws {
        guard let folder else { return }
        let jobs = await materialJobs()
        let scene = try await write(jobs, part: .all)
        let materials = try await write(jobs, part: .materials)
        let url = folder.appendingPathComponent("scene.usda")
        try scene.write(to: url, atomically: true, encoding: .utf8)

        let stage = try USDStage.open(FilePath(url.path))
        let session = USDPreviewSession(stage: stage)
        let bridge = UndoBridge(history: history)
        session.delegate = bridge
        // `.unmodified` is required for live edits: the default optimization can rebuild the scene on the
        // headset, and a rebuilt scene ignores later stage edits. Too-heavy scenes throw `assetUnshareable`.
        try await session.start(endpoint: endpoint, parameters: .unmodified, viewerOptions: [.annotations, .perObjectManipulation, .export])
        Self.log("live session started")
        self.stage = stage
        self.usdSession = session
        self.session = session
        self.undoBridge = bridge
        liveMaterialText = materials
        await syncUndoCounts()
    }

    private func startDocument(endpoint: SpatialPreviewEndpoint) async throws {
        guard let document, let folder else { return }
        let session = DocumentPreviewSession(name: document.name, contentType: .usdz)
        try await session.start(endpoint: endpoint)
        revision += 1
        let url = folder.appendingPathComponent("\(document.name)-\(revision).usdz")
        _ = try await Exporter.export(document, to: url, options: ExportOptions(binary: true, validate: false))
        try await session.updateContents(url: url)
        Self.log("document session started")
        self.documentSession = session
        self.session = session
    }

    // MARK: Live updates

    private func observeChanges() {
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: .materialsDidChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.schedule(materials: true) }
        })
        observers.append(center.addObserver(forName: .sceneDidChange, object: nil, queue: .main) { [weak self] note in
            MainActor.assumeIsolated {
                guard let self, (note.object as AnyObject?) === self.document else { return }
                self.schedule(scene: true)
            }
        })
    }

    /// Coalesces bursts of edits (slider drags) into one update shortly after they pause.
    private func schedule(materials: Bool = false, scene: Bool = false) {
        guard session != nil else { return }
        pendingMaterials = pendingMaterials || materials
        pendingScene = pendingScene || scene
        guard !isPushing else { return }  // picked up when the running update finishes
        updateTask?.cancel()
        updateTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled, let self else { return }
            await self.pushUpdates()
        }
    }

    /// Sends pending edits, one update at a time, until none are left.
    private func pushUpdates() async {
        isPushing = true
        defer { isPushing = false }
        while (pendingMaterials || pendingScene), session != nil {
            let scene = pendingScene
            pendingMaterials = false
            pendingScene = false
            status = .updating
            do {
                if usdSession != nil {
                    try await updateLive(scene: scene)
                } else if let documentSession, let document, let folder {
                    revision += 1
                    let url = folder.appendingPathComponent("\(document.name)-\(revision).usdz")
                    _ = try await Exporter.export(document, to: url, options: ExportOptions(binary: true, validate: false))
                    try await documentSession.updateContents(url: url)
                }
                await syncUndoCounts()
                status = session?.state.isInvalidated == true ? .failed("The headset closed the preview.") : .live
            } catch {
                Self.log("update failed: \(error)")
                status = .failed(error.localizedDescription)
            }
        }
    }

    /// Applies the document's current state to the live stage, always editing the same scene.
    private func updateLive(scene: Bool) async throws {
        guard let stage else { return }
        // Object edits can change which SceneKit materials each entry covers.
        if scene { jobCache = [:] }
        let jobs = await materialJobs()
        let materials = try await write(jobs, part: .materials)
        if !scene, let old = liveMaterialText, let edits = Self.valueEdits(from: old, to: materials) {
            if edits.allSatisfy({ $0.apply(to: stage) }) {
                Self.log("value edits: " + (edits.isEmpty ? "none" : edits.map { "\($0.path)=\($0.value)" }.joined(separator: ", ")))
                liveMaterialText = materials
                return
            }
            Self.log("a value edit failed; updating contents in place")
        }
        Self.log(scene ? "scene change: updating contents in place" : "material structure change: updating contents in place")
        try stage.rootLayer.importContents(from: try await write(jobs, part: .all))
        liveMaterialText = materials
    }

    func syncUndoCounts() async {
        guard let usdSession, let history else { return }
        try? await usdSession.updateUndoRedoCounts(undo: UInt(history.undoStack.count), redo: UInt(history.redoStack.count))
    }

    // MARK: Writing

    /// Evaluated materials for the current document, re-evaluating only graphs that changed.
    private func materialJobs() async -> [USDWriter.MaterialJob] {
        guard let document else { return [] }
        let entries = document.materials
        var jobs: [USDWriter.MaterialJob?] = Array(repeating: nil, count: entries.count)
        var pending: [(index: Int, id: UUID, graph: ObjectIdentifier, revision: Int, materials: [SCNMaterial], name: String, evaluator: GraphEvaluator)] = []
        for (i, entry) in entries.enumerated() {
            let key = ObjectIdentifier(entry.graph), revision = entry.graph.revision
            let name = stableNames[entry.id] ?? entry.name
            stableNames[entry.id] = name
            if let cached = jobCache[entry.id], cached.graph == key, cached.revision == revision {
                jobs[i] = cached.job
            } else {
                let size = min(GraphEvaluator.bakeSize(for: entry.graph), Self.liveBakeCap)
                pending.append((i, entry.id, key, revision, entry.materials, name, GraphEvaluator(graph: entry.graph, size: size)))
            }
        }
        let built = await Task.detached(priority: .userInitiated) {
            pending.map { p in USDWriter.MaterialJob(materials: p.materials, name: p.name, result: p.evaluator.evaluateMaterial(), evaluator: p.evaluator) }
        }.value
        for (p, job) in zip(pending, built) {
            jobCache[p.id] = CachedJob(graph: p.graph, revision: p.revision, job: job)
            jobs[p.index] = job
        }
        return jobs.compactMap { $0 }
    }

    /// Writes the scene (or just its materials) as USDA text and saves any new texture files next to it.
    private func write(_ jobs: [USDWriter.MaterialJob], part: USDWriter.Part) async throws -> String {
        guard let document, let folder else { return "" }
        let name = document.name, root = document.root, metadata = document.metadata, cache = bakeCache
        let (text, files) = await Task.detached(priority: .userInitiated) {
            let writer = USDWriter(rootName: name)
            writer.part = part
            writer.contentHashedTextures = true
            writer.bakeCache = cache
            return (writer.write(root: root, materials: jobs, metadata: metadata), writer.files)
        }.value
        for file in files {
            let url = folder.appendingPathComponent(file.path)
            if !FileManager.default.fileExists(atPath: url.path) { try file.data.write(to: url) }
        }
        return text
    }

    // MARK: Diagnostics

    /// ~/Library/Logs/Veneer Pro/VisionPro.log — what each update did, for diagnosing headset issues.
    nonisolated static let logURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/Veneer Pro/VisionPro.log")

    nonisolated static func log(_ message: String) {
        let line = "\(Date().formatted(.iso8601)) \(message)\n"
        let url = logURL
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(Data(line.utf8))
            try? handle.close()
        } else {
            try? Data(line.utf8).write(to: url)
        }
    }

    // MARK: Value diffs

    /// One changed attribute value, e.g. a material's `inputs:diffuseColor` or a texture's `inputs:file`.
    struct ValueEdit: Equatable {
        let path: String
        let type: String
        let value: String

        /// Sets the value on the stage through USDKit, which the preview session replicates.
        func apply(to stage: USDStage) -> Bool {
            let attribute = stage.attribute(at: USDLayer.Path(path))
            if type == "asset" {
                return attribute.setValue(USDLayer.AssetPath(value.trimmingCharacters(in: CharacterSet(charactersIn: "@"))))
            }
            let numbers = value.trimmingCharacters(in: CharacterSet(charactersIn: "()"))
                .split(separator: ",").compactMap { Float($0.trimmingCharacters(in: .whitespaces)) }
            switch (type, numbers.count) {
            case ("float", 1): return attribute.setValue(numbers[0])
            case ("int", 1): return attribute.setValue(Int32(numbers[0]))
            case ("color3f", 3), ("normal3f", 3), ("float3", 3), ("vector3f", 3):
                return attribute.setValue(USDValue.Vec3f(SIMD3(numbers[0], numbers[1], numbers[2])))
            case ("float4", 4):
                return attribute.setValue(USDValue.Vec4f(SIMD4(numbers[0], numbers[1], numbers[2], numbers[3])))
            default: return false
            }
        }
    }

    /// The attribute values that differ between two material texts written by `USDWriter`, or nil when
    /// anything else changed (prims or connections added or removed).
    nonisolated static func valueEdits(from old: String, to new: String) -> [ValueEdit]? {
        let oldLines = old.components(separatedBy: "\n"), newLines = new.components(separatedBy: "\n")
        guard oldLines.count == newLines.count else { return nil }
        let pattern = #/^\s*(float|int|color3f|normal3f|float3|vector3f|float4|asset) (inputs:\w+) = (.+)$/#
        var edits: [ValueEdit] = []
        var stack: [String] = []
        var pendingPrim: String?
        for (a, b) in zip(oldLines, newLines) {
            let line = b.trimmingCharacters(in: .whitespaces)
            if let match = line.firstMatch(of: #/^def \w+ "([^"]+)"/#) {
                pendingPrim = String(match.1)
            } else if line == "{" {
                stack.append(pendingPrim ?? "")
                pendingPrim = nil
            } else if line.hasSuffix("{") {
                stack.append("")  // a metadata dictionary, not a prim
            } else if line == "}" {
                _ = stack.popLast()
            }
            guard a != b else { continue }
            guard let was = a.firstMatch(of: pattern), let now = b.firstMatch(of: pattern),
                  was.1 == now.1, was.2 == now.2 else { return nil }
            let prim = "/" + stack.filter { !$0.isEmpty }.joined(separator: "/")
            edits.append(ValueEdit(path: "\(prim).\(now.2)", type: String(now.1), value: String(now.3)))
        }
        return edits
    }
}

/// Routes undo/redo gestures from the headset into the app's undo history.
@MainActor
private final class UndoBridge: USDPreviewSession.ChangeListDelegate {
    weak var history: EditHistory?

    init(history: EditHistory?) { self.history = history }

    func willApplyChanges(instanceIdentifier: String, operationIdentifier: UInt) {}
    func didApplyChanges(instanceIdentifier: String, operationIdentifier: UInt) {}
    func onUndoRequest() { history?.undo() }
    func onRedoRequest() { history?.redo() }
}

