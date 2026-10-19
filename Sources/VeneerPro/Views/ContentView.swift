import SceneKit
import SpatialPreview
import SwiftUI
import UniformTypeIdentifiers

enum SidebarTab: String, CaseIterable {
    case models = "Models"
    case scene = "Scene"
    case library = "Materials"

    var symbol: String {
        switch self {
        case .models: "cube.box"
        case .scene: "list.bullet.indent"
        case .library: "circle.hexagongrid"
        }
    }
}

struct ContentView: View {
    @Environment(AppModel.self) private var model
    @State private var frameRequest = 0
    @State private var sidebarTab: SidebarTab = .models
    @State private var viewportDropTarget = false
    @State private var showDevicePicker = false

    var body: some View {
        @Bindable var model = model
        NavigationSplitView {
            VStack(spacing: 0) {
                IconTabs(tabs: SidebarTab.allCases, selection: $sidebarTab, symbol: \.symbol, title: \.rawValue)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                switch sidebarTab {
                case .models: ModelList()
                case .scene: SceneOutline()
                case .library: MaterialLibraryView()
                }
            }
            .navigationSplitViewColumnWidth(min: 220, ideal: 300, max: 560)
        } detail: {
            detailContent
            .toolbar {
                ToolbarItemGroup(placement: .navigation) {
                    Button { model.history.undo() } label: { Label("Undo", systemImage: "arrow.uturn.backward") }
                        .help(model.history.undoName.map { "Undo \($0) (⌘Z)" } ?? "Nothing to undo")
                        .disabled(!model.history.canUndo)
                    Button { model.history.redo() } label: { Label("Redo", systemImage: "arrow.uturn.forward") }
                        .help(model.history.redoName.map { "Redo \($0) (⇧⌘Z)" } ?? "Nothing to redo")
                        .disabled(!model.history.canRedo)
                }
                ToolbarItemGroup(placement: .primaryAction) {
                    Button { model.presentImportPanel() } label: { Label("Import", systemImage: "square.and.arrow.down") }
                        .help("Import models")
                    Button { model.presentExportPanel() } label: { Label("Export", systemImage: "square.and.arrow.up") }
                        .help("Export the selected model as USDZ or FBX")
                    Button { toggleVisionPro() } label: {
                        Label(model.visionPro.isActive ? "Stop Vision Pro Preview" : "View on Apple Vision Pro",
                              systemImage: model.visionPro.isActive ? "visionpro.fill" : "visionpro")
                    }
                    .help(model.visionPro.isActive
                          ? "Stop the live preview on Apple Vision Pro"
                          : "Open this model on Apple Vision Pro; material and object edits update live")
                    .disabled((model.selectedDocument == nil && !model.visionPro.isActive) || model.isBusy)
                    Button { model.showShareSheet = true } label: {
                        Label("Share to iPhone or iPad", systemImage: model.share.isActive ? "qrcode.viewfinder" : "qrcode")
                    }
                    .help("Show a QR code that opens this model in AR on an iPhone or iPad on your Wi-Fi")
                    .disabled(model.selectedDocument == nil && !model.share.isActive)
                    Button { sidebarTab = sidebarTab == .library ? .models : .library } label: {
                        Label("Material Library", systemImage: "books.vertical")
                    }
                    .help("Show the material library")
                    Button { model.showInspector.toggle() } label: { Label("Inspector", systemImage: "sidebar.right") }
                        .help("Hide or show the inspectors (⌥⌘I)")
                }
            }
        }
        .navigationTitle(model.selectedDocument?.name ?? "Veneer Pro")
        .sheet(isPresented: $model.showShareSheet) {
            ShareSheet().environment(model)
        }
        .alert("Error", isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) {
            Button("OK") { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "")
        }
    }

    /// Viewport and node editor, with the inspector as a plain trailing panel. (SwiftUI's `.inspector`
    /// gets its own toolbar section, and its safe-area updates fight the main toolbar's in a layout
    /// loop that crashes the window or freezes the viewport.)
    private var detailContent: some View {
        HSplitView {
            VSplitView {
                viewport
                    .canvasCard()
                    .padding([.horizontal, .top], 8)
                    .padding(.bottom, 4)
                    .frame(minHeight: 200, idealHeight: 380)
                editor
                    .canvasCard()
                    .padding([.horizontal, .bottom], 8)
                    .padding(.top, 4)
                    .frame(minHeight: 220, idealHeight: 420)
            }
            .frame(minWidth: 360)
            .background(Theme.canvas)
            if model.showInspector {
                InspectorView()
                    .frame(minWidth: 260, idealWidth: 300, maxWidth: 420)
            }
        }
    }

    private var statusText: String? {
        var text = model.status ?? model.visionPro.status.description
        if text.isEmpty, model.share.isActive { text = "Sharing to iPhone & iPad on Wi-Fi" }
        return text.isEmpty ? nil : text
    }

    private var viewport: some View {
        ZStack {
            ViewportView(
                document: model.selectedDocument,
                settings: model.viewer,
                handle: model.viewport,
                frameRequest: frameRequest,
                selectedNode: model.selectedNode,
                isolatedNode: model.isolatedNode,
                sceneRevision: model.selectedDocument?.sceneRevision ?? 0,
                onPick: { node, material in
                    // Clicking a part selects its object and the material that was clicked.
                    model.selectedNode = node
                    if let material, let entry = model.entry(for: material) {
                        model.selectedMaterialID = entry.id
                    }
                }
            )
            if viewportDropTarget {
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(Color.accentColor, lineWidth: 3)
                    .allowsHitTesting(false)
            }
            if model.documents.isEmpty {
                DropPrompt()
            }
            // Status lives here rather than in the window subtitle: changing title-bar text while the
            // toolbar is laying out can send SwiftUI into a layout loop that freezes the viewport.
            if let status = statusText, !model.isBusy {
                Text(status)
                    .font(.callout)
                    .lineLimit(1)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(.regularMaterial, in: Capsule())
                    .padding(10)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .allowsHitTesting(false)
            }
            if model.selectedDocument != nil {
                CanvasHUD {
                    HUDButton(symbol: "viewfinder", help: model.selectedNode == nil ? "Frame the model" : "Frame the selected object") {
                        frameRequest += 1
                    }
                    HUDButton(symbol: "grid", help: "Show or hide the grid", isOn: model.viewer.showGrid) {
                        model.viewer.showGrid.toggle()
                    }
                    HUDButton(symbol: "photo", help: "Show the environment as the background", isOn: model.viewer.showEnvironment) {
                        model.viewer.showEnvironment.toggle()
                    }
                    HUDButton(symbol: "sun.max", help: "Lighting") { model.inspectorTab = .environment; model.showInspector = true }
                    if model.selectedDocument?.hasAnimations == true {
                        HUDButton(symbol: model.viewer.isPlaying ? "pause.fill" : "play.fill", help: "Play or pause animation") {
                            model.viewer.isPlaying.toggle()
                        }
                    }
                    if model.isolatedNode != nil {
                        HUDButton(symbol: "eye.slash", help: "Show all objects", isOn: true) { model.isolatedNode = nil }
                    }
                }
                .padding(12)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            }
            if model.isBusy {
                ProgressView(model.status ?? "Working…")
                    .padding()
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
            }
        }
        .onDrop(of: [.fileURL, .plainText, .utf8PlainText], isTargeted: $viewportDropTarget) { providers, location in
            dropOnViewport(providers, at: location)
        }
        .background(
            // Apple's picker for nearby Apple Vision Pro devices, when none is connected via Mac Virtual Display.
            // Kept on the viewport: attached to the whole window it feeds a SwiftUI layout loop at launch.
            SpatialPreviewDevicePicker(isPresented: $showDevicePicker) { endpoint in
                guard let document = model.selectedDocument else { return }
                Task { await model.visionPro.start(document, endpoint: endpoint, history: model.history) }
            }
        )
    }

    private func toggleVisionPro() {
        let preview = model.visionPro
        if preview.isActive {
            Task { await preview.stop() }
            return
        }
        guard let document = model.selectedDocument else { return }
        if preview.connected.isEndpointAvailable {
            // A headset connected via Mac Virtual Display: open there directly.
            Task {
                do {
                    let endpoint = try await preview.connected.endpoint
                    await preview.start(document, endpoint: endpoint, history: model.history)
                } catch {
                    showDevicePicker = true
                }
            }
        } else {
            showDevicePicker = true
        }
    }

    /// Model files are imported; a library material is applied to the part under the cursor.
    private func dropOnViewport(_ providers: [NSItemProvider], at location: CGPoint) -> Bool {
        let fileProviders = providers.filter { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }
        if !fileProviders.isEmpty {
            for provider in fileProviders {
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    guard let url else { return }
                    Task { @MainActor in model.importModels([url]) }
                }
            }
            return true
        }
        return model.libraryMaterial(fromDrop: providers) { material in
            if let hit = model.viewport.material(atTopLeft: location), let entry = model.entry(for: hit) {
                model.apply(material, to: entry)
            } else {
                model.apply(material)
            }
        }
    }

    @ViewBuilder
    private var editor: some View {
        if let entry = model.selectedMaterial {
            NodeEditorView(entry: entry)
                .id(entry.id)
                .overlay(alignment: .topTrailing) {
                    Text(entry.name)
                        .font(.system(size: 12, weight: .semibold))
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
                        .padding(10)
                        .environment(\.colorScheme, .dark)
                }
        } else {
            ZStack {
                Color(white: 0.11)
                Text(model.selectedDocument == nil ? "Import a model to edit its materials"
                                                   : "Select a material — or click a surface in the viewport")
                    .foregroundStyle(.secondary)
            }
            .environment(\.colorScheme, .dark)
        }
    }
}

private extension View {
    /// A canvas pane: rounded, with a hairline edge, recessed into the workspace.
    func canvasCard() -> some View {
        clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.white.opacity(0.07)))
    }
}

private struct DropPrompt: View {
    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "cube.transparent").font(.system(size: 44, weight: .light))
            Text("Drop files here").font(.title3.weight(.semibold))
            Text("Drag in individual or multiple 3D models and folders\n(USDZ, USD, FBX, OBJ, DAE, SCN, ABC, PLY, STL)")
                .multilineTextAlignment(.center)
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .foregroundStyle(.white.opacity(0.85))
        .padding(30)
        .background(RoundedRectangle(cornerRadius: 16).strokeBorder(style: StrokeStyle(lineWidth: 2, dash: [8, 6]))
            .foregroundStyle(.white.opacity(0.35)))
    }
}

private struct ModelList: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        List(selection: $model.selectedDocumentID) {
            Section("Models") {
                ForEach(model.documents) { document in
                    HStack {
                        Image(systemName: document.exportedURL == nil ? "cube" : "cube.fill")
                            .foregroundStyle(.tint)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(document.name).lineLimit(1)
                            Text("\(document.materials.count) materials · .\(document.sourceURL.pathExtension.lowercased())")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .tag(document.id)
                    .contextMenu {
                        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([document.sourceURL]) }
                        Divider()
                        Button("Remove Model", role: .destructive) { model.remove(document) }
                    }
                }
            }
        }
        .overlay {
            if model.documents.isEmpty {
                Text("Import models to start").foregroundStyle(.secondary)
            }
        }
        .safeAreaInset(edge: .bottom) {
            HStack {
                Button { model.presentImportPanel() } label: { Image(systemName: "plus") }
                    .help("Import models")
                Spacer()
                Button("Export All…") { model.presentExportAllPanel() }
                    .disabled(model.documents.isEmpty || model.isBusy)
            }
            .buttonStyle(.borderless)
            .padding(8)
        }
    }
}
