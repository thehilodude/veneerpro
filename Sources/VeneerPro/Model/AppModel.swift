import AppKit
import Observation
import SceneKit
import UniformTypeIdentifiers

@MainActor
@Observable
final class AppModel {
    var documents: [ModelDocument] = []
    var selectedDocumentID: UUID? {
        didSet {
            if oldValue != selectedDocumentID {
                selectedMaterialID = selectedDocument?.materials.first?.id
                selectedNode = nil
                isolatedNode = nil
            }
        }
    }
    var selectedMaterialID: UUID?
    /// The object picked in the scene outline or viewport.
    var selectedNode: SCNNode?
    /// When set, only this object (and its children) is shown in the viewer. View-only; not exported.
    var isolatedNode: SCNNode?
    var inspectorTab: InspectorTab = .materials
    var showInspector = true
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
    /// Opens the "Share to iPhone or iPad" sheet.
    var showShareSheet = false
    @ObservationIgnored let viewport = ViewportHandle()

    var selectedDocument: ModelDocument? { documents.first { $0.id == selectedDocumentID } }
    var selectedMaterial: MaterialEntry? { selectedDocument?.materials.first { $0.id == selectedMaterialID } }

    func entry(for material: SCNMaterial) -> MaterialEntry? {
        selectedDocument?.materials.first { $0.materials.contains { $0 === material } }
    }

    // MARK: Material library

    /// Applies a library material to `entry` (default: the selected material) and selects it.
    func apply(_ material: LibraryMaterial, to entry: MaterialEntry? = nil) {
        guard let entry = entry ?? selectedMaterial else { return }
        selectedMaterialID = entry.id
        Task {
            status = "Applying “\(material.name)”"
            await library.apply(material, to: entry)
            status = nil
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
        panel.allowedContentTypes = ModelDocument.importableExtensions.compactMap { UTType(filenameExtension: $0) }
        guard panel.runModal() == .OK else { return false }
        importModels(panel.urls)
        return true
    }

    func importModels(_ urls: [URL]) {
        let files = urls.flatMap { url -> [URL] in
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue else { return [url] }
            let contents = FileManager.default.enumerator(at: url, includingPropertiesForKeys: nil)?.allObjects as? [URL] ?? []
            return contents.filter { ModelDocument.importableExtensions.contains($0.pathExtension.lowercased()) }
        }
        Task {
            isBusy = true
            defer { isBusy = false; status = nil }
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

    private func noteRecent(_ url: URL) {
        recentModels = Array(([url] + recentModels.filter { $0.standardizedFileURL != url.standardizedFileURL }).prefix(8))
        UserDefaults.standard.set(recentModels.map(\.path), forKey: "RecentModels")
    }

    func clearRecentModels() {
        recentModels = []
        UserDefaults.standard.removeObject(forKey: "RecentModels")
    }

    func remove(_ document: ModelDocument) {
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
    var exposure: Double = 0
    var isPlaying = true

    private enum Keys {
        static let environment = "ViewerEnvironment", rotation = "ViewerEnvironmentRotation"
        static let intensity = "ViewerEnvironmentIntensity", exposure = "ViewerExposure"
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
        return settings
    }

    func save() {
        let defaults = UserDefaults.standard
        defaults.set(environment.storageKey, forKey: Keys.environment)
        defaults.set(environmentRotation, forKey: Keys.rotation)
        defaults.set(environmentIntensity, forKey: Keys.intensity)
        defaults.set(exposure, forKey: Keys.exposure)
    }
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
