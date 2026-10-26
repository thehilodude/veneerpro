import AppKit
import SwiftUI

@main
struct VeneerProApp: App {
    @NSApplicationDelegateAdaptor private var appDelegate: AppDelegate
    @State private var model: AppModel = {
        // Must run before AppModel reads its settings.
        VeneerProApp.migrateSettings()
        // Toolbar buttons show their names by default (NSToolbarDisplayMode.iconAndLabel). The toolbar
        // autosaves its own configuration, so a choice from its right-click menu replaces this.
        UserDefaults.standard.register(defaults: ["NSToolbar Configuration main": ["TB Display Mode": 1]])
        return AppModel()
    }()

    init() {
        // When launched as the FBX conversion helper, convert and exit before any UI exists.
        FBXImporter.runHelperIfRequested()
    }

    var body: some Scene {
        Window("Veneer Pro", id: "main") {
            MainWindowRoot(model: model, appDelegate: appDelegate)
        }
        // Open the window even when launched to open files (Finder double-click), not just on a plain launch.
        .defaultLaunchBehavior(.presented)
        .defaultSize(width: 1440, height: 900)
        .commands {
            WelcomeCommands()
            CommandGroup(replacing: .undoRedo) {
                Button(model.history.undoName.map { "Undo \($0)" } ?? "Undo") { Self.undo(model) }
                    .keyboardShortcut("z")
                Button(model.history.redoName.map { "Redo \($0)" } ?? "Redo") { Self.redo(model) }
                    .keyboardShortcut("z", modifiers: [.command, .shift])
            }
            CommandGroup(after: .sidebar) {
                Button(model.showInspector ? "Hide Inspector" : "Show Inspector") { model.showInspector.toggle() }
                    .keyboardShortcut("i", modifiers: [.command, .option])
                Button(model.showNodeEditor ? "Hide Node Editor" : "Show Node Editor") { model.showNodeEditor.toggle() }
                    .keyboardShortcut("n", modifiers: [.command, .option])
            }
            CommandGroup(replacing: .newItem) {
                Button("New Project") { model.newProject() }
                    .keyboardShortcut("n")
                Button("Open…") { model.presentImportPanel() }
                    .keyboardShortcut("o")
            }
            CommandMenu("Object") {
                Button("Group") { model.groupSelection() }
                    .keyboardShortcut("g")
                    .disabled(model.selectedNodes.isEmpty)
                Button("Ungroup") { if let node = model.selectedNode { model.ungroup(node) } }
                    .keyboardShortcut("g", modifiers: [.command, .shift])
                    .disabled(model.selectedNode.map { $0.geometry != nil || $0.childNodes.isEmpty } ?? true)
                Divider()
                Button("Select Parent Group") {
                    if let parent = model.selectedNode?.parent, parent !== model.selectedDocument?.root { model.select(parent, showInspector: true) }
                }
                .keyboardShortcut(.upArrow, modifiers: .command)
                .disabled(model.selectedNode?.parent == nil || model.selectedNode?.parent === model.selectedDocument?.root)
                Button("Deselect All") { model.selectedNodes = [] }
                    .keyboardShortcut("a", modifiers: [.command, .shift])
                    .disabled(model.selectedNodes.isEmpty)
            }
            CommandGroup(replacing: .saveItem) {
                Button("Save Project") { model.saveProject() }
                    .keyboardShortcut("s")
                    .disabled(model.documents.isEmpty)
                Button("Save Project As…") { model.saveProjectAs() }
                    .keyboardShortcut("s", modifiers: [.command, .shift])
                    .disabled(model.documents.isEmpty)
            }
            CommandGroup(after: .newItem) {
                Divider()
                Button("Export…") { model.presentExportPanel() }
                    .keyboardShortcut("e")
                    .disabled(model.selectedDocument == nil)
                Button("Share to iPhone or iPad…") { model.showShareSheet = true }
                    .keyboardShortcut("s", modifiers: [.command, .option])
                    .disabled(model.selectedDocument == nil && !model.share.isActive)
                Button("Export Spec Sheet…") { model.presentSpecSheetPanel() }
                    .keyboardShortcut("p", modifiers: [.command, .option])
                    .disabled(model.selectedDocument == nil)
                Button("Export Colorways…") { model.presentExportColorwaysPanel() }
                    .disabled(model.selectedDocument?.colorways.isEmpty != false)
                Button("Export All…") { model.presentExportAllPanel() }
                    .keyboardShortcut("e", modifiers: [.command, .shift])
                    .disabled(model.documents.isEmpty)
            }
        }

        Window("Welcome to Veneer Pro", id: WelcomeView.windowID) {
            WelcomeView()
                .environment(model)
                .preferredColorScheme(.dark)
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
        .defaultLaunchBehavior(.suppressed)
        .restorationBehavior(.disabled)
        .defaultWindowPlacement { _, context in
            WindowPlacement(.center)
        }
    }
}

/// The main window's content; on first appearance it hands the model to the app delegate and shows
/// the welcome window (unless files were opened at launch, or the user turned it off).
private struct MainWindowRoot: View {
    let model: AppModel
    let appDelegate: AppDelegate
    @Environment(\.openWindow) private var openWindow
    @AppStorage(WelcomeView.showAtLaunchKey) private var showWelcome = true
    @State private var didLaunch = false

    var body: some View {
        ContentView()
            .environment(model)
            .frame(minWidth: 960, minHeight: 640)
            .preferredColorScheme(.dark)
            .onAppear {
                let openedFiles = appDelegate.attach(model)
                guard !didLaunch else { return }
                didLaunch = true
                if showWelcome, !openedFiles, model.documents.isEmpty { openWindow(id: WelcomeView.windowID) }
            }
    }
}

private struct WelcomeCommands: Commands {
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(after: .help) {
            Button("Welcome to Veneer Pro") { openWindow(id: WelcomeView.windowID) }
                .keyboardShortcut("1", modifiers: [.command, .shift])
        }
    }
}

extension VeneerProApp {
    /// Carries settings (library folders, HDRIs, viewer setup) over from the app's previous name,
    /// Reality Converter 2, once. Existing Veneer Pro settings are never overwritten.
    /// Copies settings from the app's earlier bundle IDs (Reality Converter 2, then local.veneerpro)
    /// the first time this ID runs. Keys already set here win.
    static func migrateSettings() {
        let defaults = UserDefaults.standard
        for (domain, flag) in [("local.veneerpro", "MigratedFromLocalVeneerPro"), ("local.realityconverter2", "MigratedFromRealityConverter2")] {
            guard !defaults.bool(forKey: flag) else { continue }
            for (key, value) in defaults.persistentDomain(forName: domain) ?? [:] where defaults.object(forKey: key) == nil {
                defaults.set(value, forKey: key)
            }
            defaults.set(true, forKey: flag)
        }
    }

    /// While typing in a text field, ⌘Z undoes the typing; otherwise it undoes the last edit.
    @MainActor static func undo(_ model: AppModel) {
        if let text = NSApp.keyWindow?.firstResponder as? NSTextView, text.undoManager?.canUndo == true {
            text.undoManager?.undo()
        } else {
            model.history.undo()
        }
    }

    @MainActor static func redo(_ model: AppModel) {
        if let text = NSApp.keyWindow?.firstResponder as? NSTextView, text.undoManager?.canRedo == true {
            text.undoManager?.redo()
        } else {
            model.history.redo()
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private(set) var model: AppModel?
    /// Files opened before the window (and its model) exist, imported once it appears.
    private var pendingURLs: [URL] = []

    /// Returns whether files opened at launch were handed over.
    @MainActor @discardableResult
    func attach(_ model: AppModel) -> Bool {
        self.model = model
        guard !pendingURLs.isEmpty else { return false }
        model.importModels(pendingURLs)
        pendingURLs = []
        return true
    }

    func applicationWillFinishLaunching(_ notification: Notification) {
        // Headless conversion:
        //   VeneerPro --convert <input> <output.usdz> [--material <folder | .mtl | .sbsar | polyhaven:<id> | ambientcg:<id>>] [--texture-size 2048] [--max-texture 2048]
        //            [--mapping uv|planar|box|cylindrical|spherical] [--mapping-size meters] [--mapping-axis X|Y|Z]
        //   VeneerPro --scan-library <folder>   (lists detected materials and maps)
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--scan-library"), args.count > i + 1 {
            let materials = LibraryMaterial.scan(root: URL(fileURLWithPath: args[i + 1]))
            for m in materials {
                let ks = m.keyShotFile.flatMap(KeyShotMaterial.load)
                let maps = m.usableMaps.map(\.rawValue).joined(separator: ", ")
                func f(_ v: Float?) -> String { v.map { String(format: "%.2f", $0) } ?? "-" }
                let color = ks?.color.map { String(format: "(%.2f %.2f %.2f)%@", $0.x, $0.y, $0.z, ks!.colorIsApproximate ? "~" : "") } ?? "-"
                let links = [("color", ks?.colorLink), ("rough", ks?.roughnessLink), ("opacity", ks?.opacityLink), ("normal", ks?.normalMapLink)]
                    .compactMap { $0.1 == nil ? nil : $0.0 }.joined(separator: "+")
                print("[\(m.category)] \(m.name): \(maps.isEmpty ? "(no maps)" : maps)"
                      + (ks.map { " | \($0.shaderType) color=\(color) rough=\(f($0.roughness)) metal=\(f($0.metallic)) opacity=\(f($0.opacity)) coat=\(f($0.clearcoat))\(links.isEmpty ? "" : " linked=" + links)" } ?? (m.keyShotFile.map { KeyShotDocument.isBinaryFormat($0) ? " | KeyShot binary: " + KeyShotDocument.binaryTextureNames($0).compactMap { MapKind.classify(URL(fileURLWithPath: $0))?.rawValue }.joined(separator: ", ") : " | KeyShot: unrecognized surface" } ?? "")))
            }
            print("\(materials.count) materials")
            exit(0)
        }
        guard let i = args.firstIndex(of: "--convert"), args.count > i + 2 else { return }
        let input = URL(fileURLWithPath: args[i + 1]), output = URL(fileURLWithPath: args[i + 2])
        func option(_ name: String) -> String? {
            args.firstIndex(of: name).flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil }
        }
        Task { @MainActor in
            do {
                let document = try await ModelDocument.load(url: input)
                if let path = option("--material") {
                    // Apply one library material (a map folder or a KeyShot .mtl) to every material.
                    let location = URL(fileURLWithPath: path)
                    // "polyhaven:<id>" / "ambientcg:<id>" download from those CC0 libraries.
                    let online = path.split(separator: ":", maxSplits: 1).count == 2
                        ? OnlineLibrary.Provider(rawValue: String(path.split(separator: ":")[0]).lowercased()).map { provider -> LibraryMaterial in
                            let id = String(path.split(separator: ":", maxSplits: 1)[1])
                            return LibraryMaterial(location: URL(string: "veneer-online://\(provider.rawValue)/\(id)")!, name: id,
                                                   category: "Command Line", maps: [:], keyShotFile: nil,
                                                   onlineAsset: OnlineAsset(provider: provider, id: id, thumbnail: nil))
                        } : nil
                    guard let material = online ?? LibraryMaterial.from(path: location) else {
                        throw ConverterError.loadFailed(location.lastPathComponent)
                    }
                    let size = option("--texture-size").flatMap(Int.init).flatMap(MaterialLibrary.TextureSize.init) ?? .k2
                    let library = MaterialLibrary()
                    for entry in document.materials { await library.apply(material, to: entry, textureSize: size) }
                    if let error = library.applyError {
                        FileHandle.standardError.write(Data((error + "\n").utf8))
                        exit(1)
                    }
                }
                if let kind = option("--mapping").flatMap({ k in TextureMapping.Kind.allCases.first { $0.rawValue.lowercased() == k.lowercased() } }) {
                    // Project every material's textures, e.g. --mapping box --mapping-size 0.05 (meters per tile).
                    var mapping = TextureMapping(kind: kind)
                    if let size = option("--mapping-size").flatMap(Double.init) { mapping.size = size }
                    if let axis = option("--mapping-axis").flatMap({ TextureMapping.Axis(rawValue: $0.uppercased()) }) { mapping.axis = axis }
                    for entry in document.materials { entry.mapping = mapping }
                    document.applyMappingsNow()
                }
                var exportOptions = ExportOptions()
                // --max-texture 2048: downscale larger textures (a lighter file for AR); exports keep full size otherwise.
                if let cap = option("--max-texture").flatMap(Int.init) { exportOptions.maxTextureSize = cap }
                let issues = try await Exporter.export(document, to: output, options: exportOptions)
                print("Exported \(output.path) (\(document.materials.count) materials)")
                issues.forEach { print($0) }
                exit(0)
            } catch {
                FileHandle.standardError.write(Data("\(error.localizedDescription)\n".utf8))
                exit(1)
            }
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard !CommandLine.arguments.contains("--convert") else { return }
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    @MainActor
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model else { return .terminateNow }
        return model.confirmDiscardingChanges("quitting") ? .terminateNow : .terminateCancel
    }

    @MainActor
    func application(_ application: NSApplication, open urls: [URL]) {
        if let model { model.importModels(urls) } else { pendingURLs += urls }
    }
}
