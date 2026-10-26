import SwiftUI

enum InspectorTab: String, CaseIterable {
    case object = "Object"
    case materials = "Materials"
    case environment = "Environment"
    case properties = "Properties"

    var symbol: String {
        switch self {
        case .object: "cube"
        case .materials: "circle.lefthalf.filled"
        case .environment: "sun.max"
        case .properties: "info.circle"
        }
    }
}

struct InspectorView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        VStack(spacing: 0) {
            IconTabs(tabs: InspectorTab.allCases, selection: $model.inspectorTab,
                     symbol: \.symbol, title: \.rawValue)
                .padding(.horizontal, 12)
                .padding(.top, 10)
                .padding(.bottom, 4)
            ScrollView {
                Group {
                    switch model.inspectorTab {
                    case .object: ObjectInspector()
                    case .materials: MaterialsInspector()
                    case .environment: EnvironmentInspector()
                    case .properties: PropertiesInspector()
                    }
                }
                .padding(.horizontal, 14)
                .padding(.bottom, 14)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollIndicators(.automatic)
        }
        .background(Theme.panel)
    }
}

// MARK: - Materials

struct MaterialsInspector: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        if let document = model.selectedDocument {
            ColorwaysSection(document: document)
            InspectorSection(title: "Materials") {
                if document.materials.isEmpty {
                    Text("No materials").foregroundStyle(.secondary)
                }
                ForEach(document.materials) { entry in
                    MaterialRow(entry: entry, isSelected: entry.id == model.selectedMaterialID)
                        .onTapGesture { model.selectedMaterialID = entry.id }
                }
            }
            if let entry = model.selectedMaterial {
                CMFSection(entry: entry)
                InspectorSection(title: "Selected Material") {
                    @Bindable var entry = entry
                    TextField("Name", text: $entry.name)
                        .textFieldStyle(.roundedBorder)
                    ChannelSummary(graph: entry.graph)
                    if entry.graph.nodes.contains(where: { $0.kind == .imageTexture }) {
                        BarSlider(title: "Texture Tiling", value: Binding(
                            get: { Double(entry.textureTiling ?? 1) },
                            set: { entry.setTextureTiling(Float(($0 * 4).rounded() / 4)) }
                        ), range: 0.25...16, defaultValue: 1, curve: .logarithmic,
                                  format: { _ in entry.textureTiling.map { String(format: "%.2g×", $0) } ?? "mixed" })
                        .help("Repeats every image texture in this material. Tiling other than 1× bakes the maps on export.")
                    }
                    InspectorRow(title: "Bake Size") {
                    Picker("Bake Size", selection: Binding(
                        get: { entry.graph.node(entry.graph.outputNodeID)?.option ?? "1024" },
                        set: { value in entry.graph.update(entry.graph.outputNodeID) { $0.option = value } }
                    )) {
                        ForEach(["512", "1024", "2048", "4096"], id: \.self) { Text("\($0) px").tag($0) }
                    }
                    .labelsHidden()
                    .fixedSize()
                    }
                    Text("Textures are baked at this size when a channel's graph modifies an image. Unmodified textures are exported as-is.")
                        .font(.caption).foregroundStyle(.secondary)
                    HStack {
                        Button(model.showNodeEditor ? "Hide Nodes" : "Edit Nodes") { model.showNodeEditor.toggle() }
                        Spacer()
                        Button("Reset Material", role: .destructive) { entry.reset() }
                    }
                    .controlSize(.small)
                }
                MappingSection(entry: entry)
            }
        } else {
            Text("No Selection").foregroundStyle(.secondary)
        }
    }
}

private struct MaterialRow: View {
    let entry: MaterialEntry
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 8) {
            Group {
                if let swatch = entry.swatch {
                    Image(decorative: swatch, scale: 1).resizable()
                } else {
                    Color.gray
                }
            }
            .frame(width: 26, height: 26)
            .clipShape(Circle())
            .overlay(Circle().strokeBorder(.separator))
            Text(entry.name).lineLimit(1).font(.system(size: 12.5))
            Spacer()
            if entry.mapping.kind != .uv {
                Image(systemName: entry.mapping.kind.symbol)
                    .font(.system(size: 10))
                    .foregroundStyle(isSelected ? Color.white.opacity(0.8) : .secondary)
                    .help("\(entry.mapping.kind.rawValue) mapping")
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: Theme.corner).fill(isSelected ? Color.accentColor.opacity(0.85) : .clear))
        .foregroundStyle(isSelected ? Color.white : .primary)
        .contentShape(Rectangle())
    }
}

/// Which surface inputs are driven by nodes vs. constant values.
private struct ChannelSummary: View {
    let graph: MaterialGraph

    var body: some View {
        let output = graph.node(graph.outputNodeID)
        VStack(spacing: 1) {
            ForEach(MaterialGraph.Channel.allCases, id: \.rawValue) { channel in
                let link = graph.link(into: PortRef(node: graph.outputNodeID, port: channel.rawValue))
                HStack(spacing: 8) {
                    Text(channel.name).font(.system(size: 11.5)).foregroundStyle(.secondary)
                    Spacer()
                    if let link, let source = graph.node(link.from.node) {
                        Label(source.kind.title, systemImage: "arrow.left")
                            .labelStyle(.titleAndIcon)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(Color.accentColor)
                    } else if channel == .normal || channel == .occlusion {
                        Text("—").font(.system(size: 11)).foregroundStyle(.tertiary)
                    } else if let v = output?.value(channel.name) {
                        if channel.isColor {
                            RoundedRectangle(cornerRadius: 3)
                                .fill(Color(.sRGB, red: Double(v.x), green: Double(v.y), blue: Double(v.z)))
                                .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(Color.white.opacity(0.15)))
                                .frame(width: 28, height: 14)
                        } else {
                            Text(String(format: "%.2f", v.x)).font(.system(size: 11).monospacedDigit()).foregroundStyle(.secondary)
                        }
                    }
                }
                .frame(height: 19)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: Theme.corner).fill(Theme.control))
    }
}

// MARK: - Mapping

/// How the material's textures are projected: KeyShot-style mapping types, baked into UVs.
private struct MappingSection: View {
    @Bindable var entry: MaterialEntry

    var body: some View {
        InspectorSection(title: "Mapping") {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 5), count: 5), spacing: 5) {
                ForEach(TextureMapping.Kind.allCases) { kind in
                    ToolTile(title: kind.rawValue, symbol: kind.symbol, isSelected: entry.mapping.kind == kind) {
                        entry.mapping.kind = kind
                    }
                }
            }
            if entry.mapping.kind == .uv {
                Text("Uses the model's own texture coordinates.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                if entry.mapping.kind.hasAxis {
                    InspectorRow(title: "Axis") {
                        Picker("Axis", selection: $entry.mapping.axis) {
                            ForEach(TextureMapping.Axis.allCases) { Text($0.rawValue).tag($0) }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .frame(width: 120)
                    }
                }
                BarSlider(title: "Size", value: Binding(get: { entry.mapping.size * 100 }, set: { entry.mapping.size = $0 / 100 }),
                          range: 0.2...500, defaultValue: 10, curve: .logarithmic,
                          format: { $0 < 10 ? String(format: "%.1f cm", $0) : String(format: "%.0f cm", $0) })
                    .help("Width of one texture tile in the real world")
                BarSlider(title: "Rotation", value: $entry.mapping.rotation, range: 0...360, defaultValue: 0,
                          format: { "\(Int($0.rounded()))°" })
                BarSlider(title: "Offset U", value: $entry.mapping.offset.x, range: -1...1, defaultValue: 0,
                          format: { String(format: "%+.2f", $0) })
                BarSlider(title: "Offset V", value: $entry.mapping.offset.y, range: -1...1, defaultValue: 0,
                          format: { String(format: "%+.2f", $0) })
                Text("Projected in real-world units and baked into the model's UVs, so it carries into USDZ, FBX and Vision Pro.")
                    .font(.caption2).foregroundStyle(.tertiary)
            }
        } accessory: {
            if entry.mapping != TextureMapping() {
                Button("Reset") { entry.mapping = TextureMapping() }
                    .buttonStyle(.plain).font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - Properties

struct PropertiesInspector: View {
    @Environment(AppModel.self) private var model

    private static let units: [(String, Double)] = [
        ("Millimeters", 0.001), ("Centimeters", 0.01), ("Meters", 1), ("Inches", 0.0254), ("Feet", 0.3048),
    ]

    var body: some View {
        @Bindable var model = model
        if let document = model.selectedDocument {
            @Bindable var document = document
            InspectorSection(title: "Model") {
                TextField("Name", text: $document.name).textFieldStyle(.roundedBorder)
                LabeledContent("Source", value: document.sourceURL.lastPathComponent)
                LabeledContent("Meshes", value: "\(document.meshCount)")
                LabeledContent("Materials", value: "\(document.materials.count)")
                if document.hasAnimations {
                    Label("This model is animated. Animation and skinning aren't exported; the bind pose is.",
                          systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(.orange)
                }
            }
            InspectorSection(title: "Metadata") {
                TextField("Copyright", text: $document.metadata.copyright, prompt: Text("No copyright"))
                    .textFieldStyle(.roundedBorder)
                Picker("Base Units", selection: $document.metadata.metersPerUnit) {
                    ForEach(Self.units, id: \.1) { Text($0.0).tag($0.1) }
                    if !Self.units.contains(where: { $0.1 == document.metadata.metersPerUnit }) {
                        Text("Custom").tag(document.metadata.metersPerUnit)
                    }
                }
                HStack {
                    Text("Meters per Unit")
                    Spacer()
                    TextField("", value: $document.metadata.metersPerUnit, format: .number)
                        .textFieldStyle(.roundedBorder).frame(width: 90)
                }
                Picker("Up Axis", selection: $document.metadata.upAxis) {
                    Text("Y").tag("Y")
                    Text("Z").tag("Z")
                }
                .pickerStyle(.segmented)
            }
            InspectorSection(title: "Export") {
                Toggle("Binary layer (smaller, faster)", isOn: $model.exportOptions.binary)
                    .disabled(!USDTools.canConvertToBinary)
                Toggle("Validate (usdchecker / FBX read-back)", isOn: $model.exportOptions.validate)
                    .disabled(!USDTools.canValidate)
                HStack {
                    Button("Export…") { model.presentExportPanel() }
                        .keyboardShortcut("e")
                    Button("Spec Sheet…") { model.presentSpecSheetPanel() }
                        .help("A PDF with renders, dimensions, and each material's color code and finish")
                }
                if let url = document.exportedURL {
                    HStack {
                        Label(url.lastPathComponent, systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green).lineLimit(1)
                        Spacer()
                        Button("Show") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                            .controlSize(.small)
                    }
                }
            }
            if document.exportedURL != nil {
                InspectorSection(title: "Issues") {
                    if document.issues.isEmpty {
                        Label("No issues", systemImage: "checkmark.seal").foregroundStyle(.secondary)
                    }
                    ForEach(document.issues, id: \.self) { issue in
                        Text(issue).font(.caption).textSelection(.enabled)
                            .foregroundStyle(issue.hasPrefix("Error") ? .red : .orange)
                    }
                }
            }
        } else {
            Text("No Selection").foregroundStyle(.secondary)
        }
    }
}
