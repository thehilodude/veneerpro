#if os(macOS)
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
    @Environment(\.textScale) private var textScale
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
            .navigationSplitViewColumnWidth(min: 220 * textScale, ideal: 300 * textScale, max: 560)
        } detail: {
            detailContent
            // Customizable (each item has an ID) so the window's Icon and Text label style applies,
            // and right-clicking the toolbar offers Icon Only / Text Only and Customize Toolbar….
            .toolbar(id: "main") {
                ToolbarItem(id: "undo", placement: .navigation) {
                    Button { model.history.undo() } label: { Label("Undo", systemImage: "arrow.uturn.backward") }
                        .help(model.history.undoName.map { "Undo \($0) (⌘Z)" } ?? "Nothing to undo")
                        .disabled(!model.history.canUndo)
                }
                ToolbarItem(id: "redo", placement: .navigation) {
                    Button { model.history.redo() } label: { Label("Redo", systemImage: "arrow.uturn.forward") }
                        .help(model.history.redoName.map { "Redo \($0) (⇧⌘Z)" } ?? "Nothing to redo")
                        .disabled(!model.history.canRedo)
                }
                ToolbarItem(id: "import", placement: .primaryAction) {
                    Button { model.presentImportPanel() } label: { Label("Import", systemImage: "square.and.arrow.down") }
                        .help("Import models")
                }
                ToolbarItem(id: "export", placement: .primaryAction) {
                    Button { model.presentExportPanel() } label: { Label("Export", systemImage: "square.and.arrow.up") }
                        .help("Export the selected model as USDZ or FBX")
                }
                ToolbarItem(id: "visionPro", placement: .primaryAction) {
                    Button { toggleVisionPro() } label: {
                        Label(model.visionPro.isActive ? "Stop Vision Pro" : "Vision Pro",
                              systemImage: model.visionPro.isActive ? "visionpro.fill" : "visionpro")
                    }
                    .help(model.visionPro.isConnecting ? "Connecting to Apple Vision Pro…"
                          : model.visionPro.isActive ? "Stop the live preview on Apple Vision Pro"
                          : "Open this model on Apple Vision Pro; material and object edits update live")
                    // Disabled while connecting: a second press used to restart, and cancel, a slow start.
                    .disabled((model.selectedDocument == nil && !model.visionPro.isActive) || model.isBusy || model.visionPro.isConnecting)
                }
                ToolbarItem(id: "share", placement: .primaryAction) {
                    Button { model.showShareSheet = true } label: {
                        Label("iPhone & iPad", systemImage: model.share.isActive ? "qrcode.viewfinder" : "qrcode")
                    }
                    .help("Show a QR code that opens this model in AR on an iPhone or iPad on your Wi-Fi")
                    .disabled(model.selectedDocument == nil && !model.share.isActive)
                }
                ToolbarItem(id: "nodes", placement: .primaryAction) {
                    Button { model.showNodeEditor.toggle() } label: {
                        Label("Nodes", systemImage: "point.3.connected.trianglepath.dotted")
                    }
                    .help("Show or hide the node editor (⌥⌘N)")
                }
                ToolbarItem(id: "library", placement: .primaryAction) {
                    Button { sidebarTab = sidebarTab == .library ? .models : .library } label: {
                        Label("Library", systemImage: "books.vertical")
                    }
                    .help("Show the material library")
                }
                ToolbarItem(id: "inspector", placement: .primaryAction) {
                    Button { model.showInspector.toggle() } label: { Label("Inspector", systemImage: "sidebar.right") }
                        .help("Hide or show the inspectors (⌥⌘I)")
                }
            }
        }
        .navigationTitle(model.selectedDocument?.name ?? "Veneer Pro")
        .sheet(isPresented: $model.showShareSheet) {
            ShareSheet().environment(model)
        }
        .sheet(isPresented: $model.showSpecSheetPreview) {
            SpecSheetPreview().environment(model)
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
                    .padding(.bottom, model.showNodeEditor ? 0 : 4)
                if model.showNodeEditor {
                    editor
                        .canvasCard()
                        .padding([.horizontal, .bottom], 8)
                        .padding(.top, 4)
                        .frame(minHeight: 220, idealHeight: 420)
                }
            }
            .frame(minWidth: 360)
            .background(Theme.canvas)
            if model.showInspector {
                InspectorView()
                    .frame(minWidth: 260 * textScale, idealWidth: 300 * textScale, maxWidth: 420 * textScale)
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
                documents: model.displayedDocuments,
                settings: model.viewer,
                handle: model.viewport,
                frameRequest: frameRequest,
                selectedNode: model.selectedNode,
                selectedNodes: model.selectedNodes,
                isolatedNode: model.isolatedNode,
                sceneRevision: model.displayedDocuments.reduce(0) { $0 &+ $1.sceneRevision &* 31 },
                gumball: model.gumball,
                onGumballEdit: { model.applyGumballEdit($0) },
                onPick: { node, material, extend in
                    // Clicking a part selects its object and the material that was clicked. When comparing,
                    // it also switches the inspector and node editor to the model that was clicked.
                    if let node, let owner = model.document(containing: node), owner.id != model.selectedDocumentID {
                        model.selectedDocumentID = owner.id
                    }
                    if extend {
                        // ⌘/⇧-click adds or removes a part; clicking empty space keeps the selection.
                        if let node { model.select(node, extend: true) }
                        return
                    }
                    model.selectedNode = node
                    if let material, let entry = model.entry(for: material) {
                        model.selectedMaterialID = entry.id
                    }
                }
            )
            if model.showARMatch {
                ARMatchView(preview: model.arMatch, settings: model.viewer,
                            lighting: model.viewport.lightingImage, backdrop: model.viewport.backdropImage)
            }
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
                    .appFont(12)
                    .lineLimit(1)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(.regularMaterial, in: Capsule())
                    .padding(10)
                    // Below the AR Match badge, which sits in the same corner.
                    .padding(.top, model.showARMatch ? 34 : 0)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .allowsHitTesting(false)
            }
            if let document = model.selectedDocument {
                SizeReadout(document: document, node: model.selectedNode) {
                    model.inspectorTab = .properties
                    model.showInspector = true
                }
                .padding(12)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
            }
            if model.selectedDocument != nil {
                CanvasHUD {
                    if !model.showARMatch {
                        HUDButton(symbol: "viewfinder", title: "Frame", help: model.selectedNode == nil ? "Frame the model" : "Frame the selected object") {
                            frameRequest += 1
                        }
                        HUDButton(symbol: "grid", title: "Grid", help: "Show or hide the grid", isOn: model.viewer.showGrid) {
                            model.viewer.showGrid.toggle()
                        }
                    }
                    HUDButton(symbol: "photo", title: "Background", help: "Show the environment as the background", isOn: model.viewer.showEnvironment) {
                        model.viewer.showEnvironment.toggle()
                    }
                    if !model.showARMatch {
                        ScaleSceneMenu(scene: Binding(get: { model.viewer.scaleScene }, set: { model.viewer.scaleScene = $0 }))
                        CompareMenu()
                    }
                    ColorwayMenu()
                    if !model.showARMatch, !model.selectedNodes.isEmpty { GumballMenu() }
                    if model.selectedDocument?.poses.isEmpty == false { PoseMenu() }
                    HUDButton(symbol: "arkit", title: "AR Match",
                              help: "See the model in RealityKit exactly as exported for AR Quick Look and Vision Pro (view only)",
                              isOn: model.showARMatch) {
                        model.showARMatch.toggle()
                    }
                    if model.selectedDocument?.hasAnimations == true {
                        HUDButton(symbol: model.viewer.isPlaying ? "pause.fill" : "play.fill", title: model.viewer.isPlaying ? "Pause" : "Play", help: "Play or pause animation") {
                            model.viewer.isPlaying.toggle()
                        }
                    }
                    if model.isolatedNode != nil {
                        HUDButton(symbol: "eye.slash", title: "Show All", help: "Show all objects", isOn: true) { model.isolatedNode = nil }
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
        guard !preview.isConnecting else { return }
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

    /// The node editor pane. Its outer container never changes identity: the split view hosts each pane
    /// in its own view, and replacing a pane (as switching materials used to) makes the split view lay
    /// out again, briefly resizing the viewport — a split-second "zoom". Only the contents swap.
    private var editor: some View {
        ZStack {
            Color(white: 0.11)
            if let entry = model.selectedMaterial {
                NodeEditorView(entry: entry)
                    .id(entry.id)
                    .overlay(alignment: .topTrailing) {
                        Text(entry.name)
                            .appFont(12, weight: .semibold)
                            .padding(.horizontal, 10).padding(.vertical, 6)
                            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
                            .padding(10)
                            .environment(\.colorScheme, .dark)
                    }
            } else {
                Text(model.selectedDocument == nil ? "Import a model to edit its materials"
                                                   : "Select a material — or click a surface in the viewport")
                    .foregroundStyle(.secondary)
                    .environment(\.colorScheme, .dark)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// The viewer bar's compare button: compare with a copy (for material variations) or another open model
/// (for context), shown side by side in the same scene.
private struct CompareMenu: View {
    @Environment(AppModel.self) private var model
    @State private var hovering = false

    var body: some View {
        Menu {
            if model.isComparing {
                Button("Stop Comparing") { model.stopComparing() }
                Divider()
            }
            Button("Compare with a Copy") { model.compareWithCopy() }
                .disabled(model.selectedDocument == nil)
            let others = model.documents.filter { $0.id != model.selectedDocumentID }
            Menu("Compare With") {
                ForEach(others) { other in
                    Button(other.name) { model.compare(with: other) }
                }
            }
            .disabled(others.isEmpty || model.selectedDocument == nil)
            let colorways = model.selectedDocument?.colorways ?? []
            Menu("Compare Colorway") {
                ForEach(colorways) { colorway in
                    Button(colorway.name) { model.compareColorway(colorway) }
                }
            }
            .disabled(colorways.isEmpty)
        } label: {
            HUDLabel(symbol: "square.split.2x1", title: "Compare", isOn: model.isComparing, hovering: hovering, isMenu: true)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .onHover { hovering = $0 }
        .help(model.isComparing ? "Comparing two models side by side" : "Compare: a copy with different materials, or another model")
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
            Image(systemName: "cube.transparent").appFont(44, weight: .light)
            Text("Drop files here").appFont(15, weight: .semibold)
            Text("Drag in individual or multiple 3D models and folders\n(\(ModelDocument.importableExtensions.filter { !["usda", "usdc"].contains($0) }.map { $0.uppercased() }.joined(separator: ", ")))")
                .multilineTextAlignment(.center)
                .appFont(12)
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
            Section(model.projectName.map { "\($0)\(model.hasUnsavedChanges ? " — Edited" : "")" } ?? "Models") {
                ForEach(model.documents) { document in
                    HStack {
                        Image(systemName: document.exportedURL == nil ? "cube" : "cube.fill")
                            .foregroundStyle(.tint)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(document.name).lineLimit(1)
                            Text("\(document.materials.count) materials · .\(document.sourceURL.pathExtension.lowercased())")
                                .appFont(10).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 4)
                        if let side = model.displayedDocuments.count == 2
                            ? model.displayedDocuments.firstIndex(where: { $0.id == document.id }) : nil {
                            Text(side == 0 ? "A" : "B")
                                .appFont(10, weight: .bold)
                                .frame(width: 18, height: 18)
                                .background(Circle().fill(Color.accentColor.opacity(0.85)))
                                .foregroundStyle(.white)
                                .help(side == 0 ? "Compared: left" : "Compared: right")
                        }
                    }
                    .tag(document.id)
                    .contextMenu {
                        if let selected = model.selectedDocument, selected.id != document.id {
                            Button("Compare with “\(selected.name)”") {
                                model.selectedDocumentID = selected.id
                                model.compare(with: document)
                            }
                        }
                        if model.selectedDocumentID == document.id {
                            Button("Compare with a Copy") { model.compareWithCopy() }
                        }
                        Divider()
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

/// The viewer bar's colorway switcher: the saved colorways, plus saving the current look.
private struct ColorwayMenu: View {
    @Environment(AppModel.self) private var model
    @State private var hovering = false

    var body: some View {
        let document = model.selectedDocument
        let active = document?.activeColorway
        Menu {
            ForEach(document?.colorways ?? []) { colorway in
                Toggle(colorway.name, isOn: Binding(get: { colorway.id == active?.id },
                                                    set: { _ in model.applyColorway(colorway) }))
            }
            if document?.colorways.isEmpty == false { Divider() }
            Button("Save Current Look as Colorway") { model.saveColorway() }
            if let active, document?.colorwayIsModified == true {
                Button("Update “\(active.name)”") { model.updateColorway(active) }
            }
        } label: {
            HUDLabel(symbol: "swatchpalette", title: active.map { $0.name + (document?.colorwayIsModified == true ? " •" : "") } ?? "Colorways",
                     isOn: false, hovering: hovering, isMenu: true)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .onHover { hovering = $0 }
        .help("Colorways: saved material variants of this model")
    }
}

/// The viewer bar's gumball options, shown while objects are selected.
private struct GumballMenu: View {
    @Environment(AppModel.self) private var model
    @State private var hovering = false

    var body: some View {
        @Bindable var model = model
        Menu {
            Toggle("Show Gumball", isOn: $model.gumball.visible)
            Toggle("Local Axes", isOn: $model.gumball.local)
            Divider()
            Toggle("Edit Pivot", isOn: $model.gumball.editPivot)
            if let node = model.selectedNode {
                Button("Pivot to Center") { model.setPivot(node, to: nil) }
                Button("Pivot to Bottom") { model.setPivotToBottom(node) }
                Button("Pivot to Object Origin") { model.setPivot(node, to: .zero) }
            }
        } label: {
            HUDLabel(symbol: model.gumball.editPivot ? "scope" : "move.3d", title: model.gumball.editPivot ? "Pivot" : "Gumball",
                     isOn: model.gumball.visible, hovering: hovering, isMenu: true)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .onHover { hovering = $0 }
        .help("Move and rotate the selection with handles. ⇧ snaps rotation to 15°.")
    }
}

/// The viewer bar's pose switcher, shown once a model has poses.
private struct PoseMenu: View {
    @Environment(AppModel.self) private var model
    @State private var hovering = false

    var body: some View {
        let document = model.selectedDocument
        let active = document?.activePose
        let modified = document?.poseIsModified == true
        Menu {
            ForEach(document?.poses ?? []) { pose in
                Toggle(pose.name, isOn: Binding(get: { pose.id == active?.id }, set: { _ in model.applyPose(pose) }))
            }
            Divider()
            Button("Save Current Pose") { model.savePose() }
            if let active, modified { Button("Update “\(active.name)”") { model.updatePose(active) } }
        } label: {
            HUDLabel(symbol: "figure.stand.line.dotted.figure.stand", title: active.map { $0.name + (modified ? " •" : "") } ?? "Poses",
                     isOn: false, hovering: hovering, isMenu: true)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .onHover { hovering = $0 }
        .help("Poses: saved arrangements like Open and Closed")
    }
}
#endif
