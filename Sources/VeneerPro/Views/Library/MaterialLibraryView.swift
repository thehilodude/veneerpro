import AppKit
import SwiftUI

/// KeyShot-style material browser: categories, search, a thumbnail grid, and drag-to-apply.
struct MaterialLibraryView: View {
    @Environment(AppModel.self) private var model
    @State private var selection: LibraryMaterial.ID?

    private var library: MaterialLibrary { model.library }

    var body: some View {
        @Bindable var library = model.library
        VStack(spacing: 0) {
            header
            if library.root != nil {
                searchField(text: $library.searchText)
                categoryChips
                Divider()
                grid
                Divider()
                footer
            } else {
                emptyLibrary
            }
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: library.root.map(Self.icon) ?? "books.vertical.fill")
                .foregroundStyle(.tint)
                .frame(width: 18)
            // The library switcher: every added folder, plus add/remove.
            Menu {
                ForEach(library.sources, id: \.self) { source in
                    Button {
                        model.library.select(source)
                    } label: {
                        if source == library.root {
                            Label(library.displayName(source), systemImage: "checkmark")
                        } else {
                            Text(library.displayName(source))
                        }
                    }
                }
                Divider()
                Button("Add Library Folder…") { model.library.addFolder() }
                if let root = library.root {
                    if !BuiltInMaterials.isBuiltIn(root) {
                    Button("Rescan “\(library.displayName(root))”") { model.library.rescan() }
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([root]) }
                    Divider()
                    Button("Remove “\(library.displayName(root))” from List", role: .destructive) {
                        model.library.remove(root)
                    }
                    }
                }
            } label: {
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 3) {
                        Text(library.root.map(library.displayName) ?? "Material Library")
                            .font(.headline)
                            .lineLimit(1)
                        Image(systemName: "chevron.down").font(.system(size: 9, weight: .bold)).foregroundStyle(.secondary)
                    }
                    Text(library.sources.count > 1 ? "\(library.sources.count) libraries · \(library.materials.count) materials"
                                                   : "\(library.materials.count) materials")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .fixedSize()
            .help(library.root?.path ?? "Choose a material library")
            Spacer(minLength: 4)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private static func icon(_ source: URL) -> String {
        if BuiltInMaterials.isBuiltIn(source) { return "sparkles" }
        return source.path.localizedCaseInsensitiveContains("keyshot") ? "k.circle.fill" : "books.vertical.fill"
    }

    private func searchField(text: Binding<String>) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Search \(library.materials.count) materials", text: text)
                .textFieldStyle(.plain)
            if !text.wrappedValue.isEmpty {
                Button { text.wrappedValue = "" } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 7))
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
    }

    private var categoryChips: some View {
        VStack(alignment: .leading, spacing: 6) {
            chipRow {
                chip("All", count: library.materials.count, selected: library.category == nil) {
                    model.library.category = nil
                }
                ForEach(library.categories, id: \.name) { category in
                    chip(category.name.isEmpty ? "Uncategorized" : category.name, count: category.count,
                         selected: library.topCategory == category.name) {
                        model.library.category = category.name
                    }
                }
            }
            // Second level for nested libraries (KeyShot: Metal › Anodized, Paint › Metallic...).
            if let top = library.topCategory, !library.subcategories.isEmpty {
                chipRow {
                    Image(systemName: "arrow.turn.down.right").font(.caption).foregroundStyle(.tertiary)
                    chip("All \(top)", count: library.categories.first { $0.name == top }?.count ?? 0,
                         selected: library.category == top, small: true) {
                        model.library.category = top
                    }
                    ForEach(library.subcategories, id: \.name) { sub in
                        chip(String(sub.name.split(separator: "/").last ?? ""), count: sub.count,
                             selected: library.category == sub.name, small: true) {
                            model.library.category = sub.name
                        }
                    }
                }
            }
        }
        .padding(.bottom, 8)
    }

    private func chipRow<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6, content: content).padding(.horizontal, 12)
        }
    }

    private func chip(_ title: String, count: Int, selected: Bool, small: Bool = false,
                      action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Text(title)
                Text("\(count)").foregroundStyle(selected ? .white.opacity(0.75) : .secondary)
            }
            .font(.system(size: small ? 10 : 11, weight: .medium))
            .padding(.horizontal, small ? 7 : 9)
            .padding(.vertical, small ? 3 : 4)
            .background(Capsule().fill(selected ? Color.accentColor : Color.secondary.opacity(0.15)))
            .foregroundStyle(selected ? .white : .primary)
        }
        .buttonStyle(.plain)
    }

    // MARK: Grid

    @ViewBuilder
    private var grid: some View {
        let items = library.filtered
        if library.isScanning && library.materials.isEmpty {
            ProgressView("Scanning library…").frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if items.isEmpty {
            VStack(spacing: 6) {
                Image(systemName: "square.dashed").font(.largeTitle).foregroundStyle(.tertiary)
                Text(library.materials.isEmpty ? "No materials found in this folder" : "No matches")
                    .foregroundStyle(.secondary)
                if library.materials.isEmpty {
                    Text("Each material should be a folder of maps named like “Name_Diffuse.jpg”, “Name_Roughness.jpg”, “Name_NormalGL.jpg”.")
                        .font(.caption).foregroundStyle(.tertiary).multilineTextAlignment(.center)
                }
            }
            .padding()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: library.thumbnailSize, maximum: library.thumbnailSize * 1.4), spacing: 10)],
                          spacing: 12) {
                    ForEach(items) { material in
                        MaterialTile(material: material, isSelected: selection == material.id)
                            .onTapGesture(count: 2) {
                                selection = material.id
                                // With an object selected, only that object changes.
                                if model.selectedNode != nil { model.applyToSelectedObject(material) } else { model.apply(material) }
                            }
                            .onTapGesture { selection = material.id }
                            .draggable(MaterialLibrary.dragPayload(material)) {
                                MaterialTile(material: material, isSelected: false)
                                    .frame(width: 90)
                            }
                            .contextMenu { tileMenu(material) }
                    }
                }
                .padding(12)
            }
        }
    }

    @ViewBuilder
    private func tileMenu(_ material: LibraryMaterial) -> some View {
        if model.selectedNode != nil {
            Button("Apply to Object “\(model.selectedNodeName)” Only") { model.applyToSelectedObject(material) }
        }
        Button("Apply to Material “\(model.selectedMaterial?.name ?? "Selected Material")”") { model.apply(material) }
            .disabled(model.selectedMaterial == nil)
        if let document = model.selectedDocument, document.materials.count > 1 {
            Button("Apply to All \(document.materials.count) Materials") {
                for entry in document.materials { model.apply(material, to: entry) }
            }
        }
        if !BuiltInMaterials.isBuiltIn(material.location) {
            Divider()
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([material.location]) }
        }
    }

    // MARK: Footer

    private var footer: some View {
        @Bindable var library = model.library
        return VStack(alignment: .leading, spacing: 8) {
            if let material = library.materials.first(where: { $0.id == selection }) {
                MaterialDetail(material: material, keyShot: library.keyShot(for: material))
                if model.selectedNode != nil {
                    Button {
                        model.applyToSelectedObject(material)
                    } label: {
                        Label("Apply to Object “\(model.selectedNodeName)”", systemImage: "cube.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .help("Gives this object its own material, so other parts sharing the material are unchanged.")
                }
                Button {
                    model.apply(material)
                } label: {
                    Label(model.selectedMaterial.map { "Apply to Material “\($0.name)”" } ?? "Select a material on the model first",
                          systemImage: "paintbrush.pointed.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .help("Changes every part that uses this material.")
                .disabled(model.selectedMaterial == nil)
                Divider()
            } else {
                Text("Double-click to apply to the selected object (or material), or drag onto a part in the viewport.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            HStack {
                Image(systemName: "square.grid.3x3").foregroundStyle(.secondary)
                Slider(value: $library.thumbnailSize, in: 64...180)
                    .controlSize(.mini)
                Image(systemName: "square.grid.2x2").foregroundStyle(.secondary)
            }
            HStack {
                Text("Max Texture").foregroundStyle(.secondary).fixedSize()
                Picker("Max Texture Size", selection: $library.textureSize) {
                    ForEach(MaterialLibrary.TextureSize.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
            .help("Maps larger than this are downsampled when applied, keeping exported USDZ files small.")
        }
        .font(.caption)
        .padding(12)
    }

    private var emptyLibrary: some View {
        VStack(spacing: 12) {
            Image(systemName: "folder.badge.plus").font(.system(size: 40, weight: .light)).foregroundStyle(.tint)
            Text("Connect a Material Library").font(.headline)
            Text("Add the folder where your materials live — “Visune Asset Library”, KeyShot’s “Materials” folder, or any folder of PBR texture sets.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Add Library Folder…") { model.library.addFolder() }
                .buttonStyle(.borderedProminent)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Tile

private struct MaterialTile: View {
    @Environment(AppModel.self) private var model
    let material: LibraryMaterial
    let isSelected: Bool
    @State private var image: CGImage?
    @State private var hovering = false

    var body: some View {
        VStack(spacing: 5) {
            ZStack(alignment: .topTrailing) {
                // A square base with the preview cropped into it (Visune spheres are 4:3).
                Rectangle()
                    .fill(.quaternary)
                    .aspectRatio(1, contentMode: .fit)
                    .overlay {
                        if let image {
                            Image(decorative: image, scale: 1)
                                .resizable()
                                .scaledToFill()
                        } else {
                            Image(systemName: "circle.dotted").foregroundStyle(.tertiary)
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                if material.isProcedural {
                    Image(systemName: "function")
                        .font(.system(size: 9, weight: .bold))
                        .padding(4)
                        .background(.ultraThinMaterial, in: Circle())
                        .padding(4)
                        .help("Procedural in KeyShot: base values are approximated")
                }
            }
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(isSelected ? Color.accentColor : hovering ? Color.secondary.opacity(0.5) : .clear,
                                  lineWidth: isSelected ? 2.5 : 1)
            )
            .shadow(color: .black.opacity(hovering ? 0.25 : 0.12), radius: hovering ? 5 : 2, y: 1)

            Text(material.name)
                .font(.system(size: 10.5))
                .lineLimit(2, reservesSpace: true)
                .multilineTextAlignment(.center)
                .foregroundStyle(isSelected ? .primary : .secondary)
        }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .help("\(material.category.isEmpty ? "" : material.category + " › ")\(material.name)")
        .task(id: material.id) {
            image = model.library.cachedThumbnail(for: material)
            if image == nil { image = await model.library.thumbnail(for: material) }
        }
    }
}

// MARK: - Detail

private struct MaterialDetail: View {
    let material: LibraryMaterial
    let keyShot: KeyShotMaterial?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(material.name).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                Spacer()
                if let keyShot {
                    Text(keyShot.shaderType.replacingOccurrences(of: "lux_", with: "").capitalized)
                        .font(.system(size: 10, weight: .medium))
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Capsule().fill(.quaternary))
                        .help("KeyShot shader type")
                }
            }
            FlowLayout(spacing: 4) {
                ForEach(material.usableMaps, id: \.self) { kind in
                    Text(kind.rawValue)
                        .font(.system(size: 10))
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Capsule().fill(kind.isUnsupported ? Color.secondary.opacity(0.12) : Color.accentColor.opacity(0.18)))
                        .foregroundStyle(kind.isUnsupported ? .secondary : .primary)
                        .strikethrough(kind.isUnsupported)
                        .help(kind.isUnsupported ? "\(kind.rawValue) maps aren't supported by USDZ and are skipped" : "")
                }
            }
            if material.isKeyShotFile {
                keyShotSummary
            } else if material.isProcedural {
                Text("No texture maps. Color, roughness and metalness come from the KeyShot material, so procedural patterns aren't reproduced.")
                    .foregroundStyle(.orange)
            }
        }
    }
}

private extension MaterialDetail {
    @ViewBuilder
    var keyShotSummary: some View {
        if let ks = keyShot {
            let textured = [ks.colorLink, ks.roughnessLink, ks.opacityLink, ks.normalMapLink].compactMap { $0 }.count
            FlowLayout(spacing: 4) {
                tag(familyName(ks.family))
                if ks.metallic > 0 { tag("Metallic \(Int(ks.metallic * 100))%") }
                if let r = ks.roughness { tag("Roughness \(String(format: "%.2f", r))") }
                if ks.clearcoat > 0 { tag("Clearcoat") }
                if ks.opacity < 1 { tag("Opacity \(Int(ks.opacity * 100))%") }
                if textured > 0 { tag("\(textured) textured input\(textured == 1 ? "" : "s")") }
            }
            if ks.color == nil && ks.colorLink == nil {
                Text("KeyShot doesn't expose this color (e.g. licensed paint), so it's sampled from the preview render.")
                    .foregroundStyle(.orange)
            } else if ks.colorIsApproximate {
                Text("Procedural pattern in KeyShot: flattened to its average color.")
                    .foregroundStyle(.orange)
            }
        } else {
            Text("Unrecognized KeyShot shader: the color is sampled from the preview render.")
                .foregroundStyle(.orange)
        }
    }

    func tag(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10))
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(Capsule().fill(Color.accentColor.opacity(0.18)))
    }

    func familyName(_ family: KeyShotMaterial.Family) -> String {
        switch family {
        case .metal: "Metal"
        case .glass: "Glass / Transparent"
        case .paint: "Paint"
        case .plastic: "Plastic"
        case .cloth: "Cloth"
        case .emissive: "Light"
        case .other: "Surface"
        }
    }
}

/// Wraps children onto multiple lines.
private struct FlowLayout: Layout {
    var spacing: CGFloat = 4

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrange(proposal.width ?? .infinity, subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for (subview, origin) in zip(subviews, arrange(bounds.width, subviews).origins) {
            subview.place(at: CGPoint(x: bounds.minX + origin.x, y: bounds.minY + origin.y), proposal: .unspecified)
        }
    }

    private func arrange(_ width: CGFloat, _ subviews: Subviews) -> (origins: [CGPoint], size: CGSize) {
        var origins: [CGPoint] = []
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, maxX: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            origins.append(CGPoint(x: x, y: y))
            x += size.width + spacing
            maxX = max(maxX, x - spacing)
            rowHeight = max(rowHeight, size.height)
        }
        return (origins, CGSize(width: maxX, height: y + rowHeight))
    }
}
