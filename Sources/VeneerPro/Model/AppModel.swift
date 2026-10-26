import AppKit
import Observation
import SceneKit
import UniformTypeIdentifiers

@MainActor
@Observable
final class AppModel {
    var documents: [ModelDocument] = [] {
        didSet { if !suppressChangeTracking { structureChanged = true } }
    }

    // MARK: Project (see Project.swift)

    /// The open .vnr project, or nil for an untitled workspace.
    var projectURL: URL?
    /// Materials or objects edited since the last save or open.
    var contentChanged = false
    /// Models added or removed since the last save or open.
    var structureChanged = false
    /// Set while loading or exporting, whose material refreshes aren't edits.
    @ObservationIgnored var suppressChangeTracking = false
    @ObservationIgnored private var changeObservers: [NSObjectProtocol] = []

    init() {
        for name in [Notification.Name.materialsDidChange, .sceneDidChange] {
            changeObservers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, !self.suppressChangeTracking else { return }
                    self.contentChanged = true
                }
            })
        }
    }
    var selectedDocumentID: UUID? {
        didSet {
            // Picking a model outside the comparison ends it.
            if let pair = comparison, let id = selectedDocumentID, !pair.contains(id) { comparison = nil }
            if oldValue != selectedDocumentID {
                if showARMatch { if let document = selectedDocument { arMatch.start(document) } else { showARMatch = false } }
                selectedMaterialID = selectedDocument?.materials.first?.id
                selectedNode = nil
                isolatedNode = nil
            }
        }
    }
    var selectedMaterialID: UUID?
    /// The objects picked in the scene outline or viewport, in the order they were picked.
    var selectedNodes: [SCNNode] = []
    /// The most recently picked object: what the Object inspector and gumball act on first.
    var selectedNode: SCNNode? {
        get { selectedNodes.last }
        set { selectedNodes = newValue.map { [$0] } ?? [] }
    }
    /// The move/rotate handles over the selection (see Gumball.swift).
    var gumball = GumballSettings()
    /// When set, only this object (and its children) is shown in the viewer. View-only; not exported.
    var isolatedNode: SCNNode?
    var inspectorTab: InspectorTab = .materials
    var showInspector = true
    /// The node editor under the viewport; hidden until asked for (remembered between launches).
    var showNodeEditor = UserDefaults.standard.bool(forKey: "ShowNodeEditor") {
        didSet { UserDefaults.standard.set(showNodeEditor, forKey: "ShowNodeEditor") }
    }
    let history = EditHistory.shared
    var viewer = ViewerSettings.restored() {
        didSet { if viewer != oldValue { viewer.save() } }
    }
    var exportOptions = ExportOptions()
    var status: String?
    var isBusy = false
    var errorMessage: String?

    /// Recently imported model files, newest first (shown on the welcome screen).
    private(set) var recentModels: [URL] = (UserDefaults.standard.stringArray(forKey: "RecentModels") ?? [])
        .map { URL(fileURLWithPath: $0) }

    let library = MaterialLibrary()
    let environments = EnvironmentLibrary()
    let visionPro = VisionProPreview()
    let share = LocalShare()
    let arMatch = ARMatchPreview()
    /// Shows the selected model in RealityKit, exactly as exported for AR Quick Look (view only).
    var showARMatch = false {
        didSet {
            guard showARMatch != oldValue else { return }
            if showARMatch, let document = selectedDocument { arMatch.start(document) } else { arMatch.stop() }
        }
    }
    /// Opens the "Share to iPhone or iPad" sheet.
    var showShareSheet = false
    @ObservationIgnored let viewport = ViewportHandle()

    var selectedDocument: ModelDocument? { documents.first { $0.id == selectedDocumentID } }

    // MARK: Compare

    /// Two models shown side by side (left, right), or nil.
    private(set) var comparison: [UUID]?

    var isComparing: Bool { comparison != nil }

    /// What the viewport shows: the compared pair, or the selected model.
    var displayedDocuments: [ModelDocument] {
        if let pair = comparison {
            let shown = pair.compactMap { id in documents.first { $0.id == id } }
            if shown.count == 2 { return shown }
        }
        return selectedDocument.map { [$0] } ?? []
    }

    /// Duplicates the selected model (materials included) and shows the two side by side.
    func compareWithCopy(named preferred: String? = nil) {
        guard let document = selectedDocument else { return }
        let base = preferred ?? document.name + " B"
        var name = base
        var n = 2
        while documents.contains(where: { $0.name == name }) { name = base + " \(n)"; n += 1 }
        let copy = document.duplicate(named: name)
        let index = documents.firstIndex { $0.id == document.id }.map { $0 + 1 } ?? documents.endIndex
        documents.insert(copy, at: index)
        comparison = [document.id, copy.id]
    }

    /// Shows `other` beside the selected model.
    func compare(with other: ModelDocument) {
        guard let document = selectedDocument, document.id != other.id else { return }
        comparison = [document.id, other.id]
    }

    func stopComparing() { comparison = nil }

    /// The open model that `node` belongs to.
    func document(containing node: SCNNode) -> ModelDocument? {
        documents.first { node === $0.root || node.isDescendant(of: $0.root) }
    }

    /// Makes the model that owns `entry` the selected one (when comparing, it may be the other model).
    func select(_ entry: MaterialEntry) {
        if let owner = displayedDocuments.first(where: { doc in doc.materials.contains { $0 === entry } }),
           owner.id != selectedDocumentID {
            selectedDocumentID = owner.id
        }
        selectedMaterialID = entry.id
    }
    var selectedMaterial: MaterialEntry? { selectedDocument?.materials.first { $0.id == selectedMaterialID } }

    /// The material entry driving `material`, in any model on screen.
    func entry(for material: SCNMaterial) -> MaterialEntry? {
        for document in [selectedDocument].compactMap({ $0 }) + displayedDocuments {
            if let entry = document.materials.first(where: { $0.materials.contains { $0 === material } }) { return entry }
        }
        return nil
    }

    // MARK: Material library

    /// Applies a library material to `entry` (default: the selected material) and selects it.
    func apply(_ material: LibraryMaterial, to entry: MaterialEntry? = nil) {
        guard let entry = entry ?? selectedMaterial else { return }
        select(entry)
        Task {
            status = material.onlineAsset.map { "Downloading “\(material.name)” from \($0.provider.displayName)" }
                ?? (material.isSubstanceArchive ? "Rendering “\(material.name)” with Substance" : "Applying “\(material.name)”")
            await library.apply(material, to: entry)
            status = nil
            if let error = library.applyError {
                library.applyError = nil
                errorMessage = error
            }
        }
    }

    /// Resolves a drag payload from the library grid.
    func libraryMaterial(fromDrop providers: [NSItemProvider], completion: @escaping (LibraryMaterial) -> Void) -> Bool {
        guard let provider = providers.first(where: { $0.canLoadObject(ofClass: NSString.self) }) else { return false }
        _ = provider.loadObject(ofClass: NSString.self) { object, _ in
            guard let payload = object as? String else { return }
            Task { @MainActor in
                if let material = self.library.material(forDragPayload: payload) { completion(material) }
            }
        }
        return true
    }

    // MARK: Import

    /// Returns whether the user picked something.
    @discardableResult
    func presentImportPanel() -> Bool {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        panel.allowedContentTypes = ModelDocument.importableExtensions.compactMap { UTType(filenameExtension: $0) } + [.veneerProject]
        guard panel.runModal() == .OK else { return false }
        importModels(panel.urls)
        return true
    }

    func importModels(_ urls: [URL]) {
        // A project replaces the workspace rather than adding to it.
        if let project = urls.first(where: { $0.pathExtension.lowercased() == ProjectFile.fileExtension }) {
            openProject(project)
            return
        }
        let files = urls.flatMap { url -> [URL] in
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue else { return [url] }
            let contents = FileManager.default.enumerator(at: url, includingPropertiesForKeys: nil)?.allObjects as? [URL] ?? []
            return contents.filter { ModelDocument.importableExtensions.contains($0.pathExtension.lowercased()) }
        }
        Task {
            isBusy = true
            suppressChangeTracking = true
            defer { isBusy = false; status = nil; suppressChangeTracking = false; structureChanged = true }
            var failures: [String] = []
            for url in files {
                status = "Loading “\(url.lastPathComponent)”"
                do {
                    let document = try await ModelDocument.load(url: url)
                    documents.append(document)
                    selectedDocumentID = document.id
                    noteRecent(url)
                } catch {
                    failures.append("\(url.lastPathComponent): \(error.localizedDescription)")
                }
            }
            if !failures.isEmpty { errorMessage = failures.joined(separator: "\n") }
        }
    }

    func noteRecent(_ url: URL) {
        recentModels = Array(([url] + recentModels.filter { $0.standardizedFileURL != url.standardizedFileURL }).prefix(8))
        UserDefaults.standard.set(recentModels.map(\.path), forKey: "RecentModels")
    }

    func clearRecentModels() {
        recentModels = []
        UserDefaults.standard.removeObject(forKey: "RecentModels")
    }

    func remove(_ document: ModelDocument) {
        if comparison?.contains(document.id) == true { comparison = nil }
        documents.removeAll { $0.id == document.id }
        if selectedDocumentID == document.id { selectedDocumentID = documents.first?.id }
    }

    // MARK: Export

    /// The last export format ("usdz" or "fbx").
    private var exportFormat: String {
        get { UserDefaults.standard.string(forKey: "ExportFormat") ?? "usdz" }
        set { UserDefaults.standard.set(newValue, forKey: "ExportFormat") }
    }

    func presentExportPanel() {
        guard let document = selectedDocument else { return }
        let panel = NSSavePanel()
        let format = ExportFormatChooser(initial: exportFormat) { ext in
            panel.allowedContentTypes = [UTType(filenameExtension: ext)!]
            panel.nameFieldStringValue = (panel.nameFieldStringValue as NSString).deletingPathExtension + "." + ext
        }
        panel.accessoryView = format.view
        panel.allowedContentTypes = [UTType(filenameExtension: format.selected)!]
        panel.nameFieldStringValue = document.name + "." + format.selected
        panel.directoryURL = document.sourceURL.deletingLastPathComponent()
        guard panel.runModal() == .OK, let url = panel.url else { return }
        exportFormat = format.selected
        export([document], to: { _ in url })
    }

    func presentExportAllPanel() {
        guard !documents.isEmpty else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Export All"
        let format = ExportFormatChooser(initial: exportFormat) { _ in }
        panel.accessoryView = format.view
        panel.isAccessoryViewDisclosed = true
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        exportFormat = format.selected
        let ext = format.selected
        export(documents, to: { folder.appendingPathComponent($0.name + "." + ext) })
    }

    private func export(_ docs: [ModelDocument], to destination: @escaping (ModelDocument) -> URL) {
        Task {
            isBusy = true
            defer { isBusy = false; status = nil }
            for document in docs {
                status = "Exporting “\(document.name)”"
                let url = destination(document)
                do {
                    document.issues = try await Exporter.export(document, to: url, options: exportOptions)
                    document.exportedURL = url
                } catch {
                    errorMessage = error.localizedDescription
                }
            }
        }
    }
}

struct ViewerSettings: Equatable {
    var environment: EnvironmentSource = .preset(.studio)
    /// Spin of the environment about the vertical axis, in degrees.
    var environmentRotation: Double = 0
    /// Multiplier on image-based lighting.
    var environmentIntensity: Double = 1
    var showEnvironment = true
    var showGrid = true
    /// A studio floor under the model (hidden in true-scale scenes, which have their own).
    var showGround = true
    var groundStyle: GroundStyle = .solid
    /// Brightness of the solid ground.
    var groundShade: Double = 0.42
    var exposure: Double = 0
    var isPlaying = true
    /// A true-scale clay setting around the model (view-only).
    var scaleScene = ScaleScene()

    private enum Keys {
        static let environment = "ViewerEnvironment", rotation = "ViewerEnvironmentRotation"
        static let intensity = "ViewerEnvironmentIntensity", exposure = "ViewerExposure"
        static let scaleScene = "ViewerScaleScene"
        static let showGround = "ViewerShowGround", groundStyle = "ViewerGroundStyle", groundShade = "ViewerGroundShade"
    }

    /// The last-used lighting setup, so a chosen HDRI sticks between launches.
    static func restored() -> ViewerSettings {
        var settings = ViewerSettings()
        let defaults = UserDefaults.standard
        if let key = defaults.string(forKey: Keys.environment), let source = EnvironmentSource(storageKey: key) {
            settings.environment = source
        }
        settings.environmentRotation = defaults.double(forKey: Keys.rotation)
        if defaults.object(forKey: Keys.intensity) != nil { settings.environmentIntensity = defaults.double(forKey: Keys.intensity) }
        settings.exposure = defaults.double(forKey: Keys.exposure)
        if defaults.object(forKey: Keys.showGround) != nil { settings.showGround = defaults.bool(forKey: Keys.showGround) }
        if let style = defaults.string(forKey: Keys.groundStyle).flatMap(GroundStyle.init) { settings.groundStyle = style }
        if defaults.object(forKey: Keys.groundShade) != nil { settings.groundShade = defaults.double(forKey: Keys.groundShade) }
        if let data = defaults.data(forKey: Keys.scaleScene), let scene = try? JSONDecoder().decode(ScaleScene.self, from: data) {
            settings.scaleScene = scene
        }
        return settings
    }

    func save() {
        let defaults = UserDefaults.standard
        defaults.set(environment.storageKey, forKey: Keys.environment)
        defaults.set(environmentRotation, forKey: Keys.rotation)
        defaults.set(environmentIntensity, forKey: Keys.intensity)
        defaults.set(exposure, forKey: Keys.exposure)
        defaults.set(showGround, forKey: Keys.showGround)
        defaults.set(groundStyle.rawValue, forKey: Keys.groundStyle)
        defaults.set(groundShade, forKey: Keys.groundShade)
        defaults.set(try? JSONEncoder().encode(scaleScene), forKey: Keys.scaleScene)
    }
}

enum GroundStyle: String, CaseIterable {
    case solid = "Solid"
    case shadowOnly = "Shadow Only"
}

/// The "Format: USDZ / FBX" pop-up shown in export panels.
final class ExportFormatChooser: NSObject {
    static let formats = [("USDZ (AR Quick Look, Reality Composer)", "usdz"), ("FBX (Blender, Unity, Maya, KeyShot)", "fbx")]
    let view: NSView
    private let popup: NSPopUpButton
    private let onChange: (String) -> Void

    var selected: String { Self.formats[max(0, popup.indexOfSelectedItem)].1 }

    init(initial: String, onChange: @escaping (String) -> Void) {
        self.onChange = onChange
        popup = NSPopUpButton(frame: .zero, pullsDown: false)
        popup.addItems(withTitles: Self.formats.map(\.0))
        popup.selectItem(at: Self.formats.firstIndex { $0.1 == initial } ?? 0)
        let label = NSTextField(labelWithString: "Format:")
        let stack = NSStackView(views: [label, popup])
        stack.edgeInsets = NSEdgeInsets(top: 10, left: 16, bottom: 10, right: 16)
        view = stack
        super.init()
        popup.target = self
        popup.action = #selector(changed)
    }

    @objc private func changed() { onChange(selected) }
}
