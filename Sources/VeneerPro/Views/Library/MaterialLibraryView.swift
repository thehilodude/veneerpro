#if os(macOS)
import AppKit
#else
import UIKit
#endif
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
                if let provider = library.root.flatMap(OnlineLibrary.Provider.init(source:)) {
                    // Required by Poly Haven's API terms; appreciated by ambientCG.
                    Link(destination: provider.website) {
                        HStack(spacing: 4) {
                            Image(systemName: "globe")
                            Text("\(provider.credit) · Free CC0 materials")
                        }
                        .appFont(10.5, weight: .medium)
                        .foregroundStyle(.secondary)
                    }
                    .padding(.bottom, 6)
                }
                searchField(text: $library.searchText)
                Divider()
                // Filters scroll with the grid: a long list of categories must never grow the sidebar
                // taller than the window (that pushes the whole window's layout around).
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
                    if let provider = OnlineLibrary.Provider(source: root) {
                    Button("Refresh \(provider.displayName)") { model.library.rescan() }
                    Button("Visit \(provider.displayName)") { PlatformActions.open(provider.website) }
                }
                if !OnlineLibrary.isOnline(root) {
                    Button("Rescan “\(library.displayName(root))”") { model.library.rescan() }
                    if PlatformActions.canRevealFiles {
                        Button("Show in Finder") { PlatformActions.reveal([root]) }
                    }
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
                            .appFont(13, weight: .semibold)
                            .lineLimit(1)
                        Image(systemName: "chevron.down").appFont(9, weight: .bold).foregroundStyle(.secondary)
                    }
                    Text(library.sources.count > 1 ? "\(library.sources.count) libraries · \(library.materials.count) materials"
                                                   : "\(library.materials.count) materials")
                        .appFont(10)
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
        if OnlineLibrary.isOnline(source) { return "globe" }
        if source.standardizedFileURL == OnlineLibrary.downloadsFolder.standardizedFileURL { return "arrow.down.circle.fill" }
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

    private var filterSection: some View {
        @Bindable var library = model.library
        return FilterPanel(groups: library.filterGroups, selection: $library.filters, storageKey: "Materials")
            .padding(.horizontal, 12)
            .padding(.bottom, 8)
    }

    // MARK: Grid

    @ViewBuilder
    private var grid: some View {
        let items = library.filtered
        if library.isScanning && library.materials.isEmpty {
            ProgressView(library.root.map(OnlineLibrary.isOnline) == true ? "Loading materials…" : "Scanning library…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let error = library.loadError, library.materials.isEmpty {
            VStack(spacing: 8) {
                Image(systemName: "wifi.exclamationmark").appFont(26).foregroundStyle(.tertiary)
                Text(error).foregroundStyle(.secondary).multilineTextAlignment(.center)
                Button("Retry") { model.library.rescan() }
            }
            .padding()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if library.materials.isEmpty {
            VStack(spacing: 6) {
                Image(systemName: "square.dashed").appFont(26).foregroundStyle(.tertiary)
                Text("No materials found in this folder")
                    .foregroundStyle(.secondary)
                if library.materials.isEmpty {
                    Text("Each material should be a folder of maps named like “Name_Diffuse.jpg”, “Name_Roughness.jpg”, “Name_NormalGL.jpg”.")
                        .appFont(10).foregroundStyle(.tertiary).multilineTextAlignment(.center)
                }
            }
            .padding()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                filterSection
                    .padding(.top, 10)
                if items.isEmpty {
                    Text("No matches").foregroundStyle(.secondary).padding(.vertical, 30)
                }
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
        if material.onlineAsset == nil, PlatformActions.canRevealFiles {
            Divider()
            Button("Show in Finder") { PlatformActions.reveal([material.location]) }
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
                Text(UIWords.isTouch ? "Double-tap to apply to the selected object (or material)." : "Double-click to apply to the selected object (or material), or drag onto a part in the viewport.")
                    .appFont(10)
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
        .appFont(10)
        .padding(12)
    }

    private var emptyLibrary: some View {
        VStack(spacing: 12) {
            Image(systemName: "folder.badge.plus").appFont(40, weight: .light).foregroundStyle(.tint)
            Text("Connect a Material Library").appFont(13, weight: .semibold)
            Text("Add the folder where your materials live — “Visune Asset Library”, KeyShot’s “Materials” folder, or any folder of PBR texture sets.")
                .appFont(12)
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
                if material.onlineAsset != nil {
                    Image(systemName: "icloud.and.arrow.down")
                        .appFont(9, weight: .bold)
                        .padding(4)
                        .background(.ultraThinMaterial, in: Circle())
                        .padding(4)
                        .help("Downloaded when applied")
                } else if material.isSubstanceArchive {
                    Text("S")
                        .appFont(9, weight: .heavy, design: .rounded)
                        .frame(width: 17, height: 17)
                        .background(.ultraThinMaterial, in: Circle())
                        .padding(4)
                        .help(SubstanceRenderer.isAvailable ? "Substance archive: rendered with Substance when applied"
                                                            : "Substance archive: needs Adobe Substance 3D Designer to render")
                } else if material.isProcedural {
                    Image(systemName: "function")
                        .appFont(9, weight: .bold)
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
                .appFont(10.5)
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
                Text(material.name).appFont(12, weight: .semibold).lineLimit(1)
                Spacer()
                if let keyShot {
                    Text(keyShot.shaderType.replacingOccurrences(of: "lux_", with: "").capitalized)
                        .appFont(10, weight: .medium)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Capsule().fill(.quaternary))
                        .help("KeyShot shader type")
                }
            }
            FlowLayout(spacing: 4) {
                ForEach(material.usableMaps, id: \.self) { kind in
                    Text(kind.rawValue)
                        .appFont(10)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Capsule().fill(kind.isUnsupported ? Color.secondary.opacity(0.12) : Color.accentColor.opacity(0.18)))
                        .foregroundStyle(kind.isUnsupported ? .secondary : .primary)
                        .strikethrough(kind.isUnsupported)
                        .help(kind.isUnsupported ? "\(kind.rawValue) maps aren't supported by USDZ and are skipped" : "")
                }
            }
            if let asset = material.onlineAsset {
                Text("Free CC0 material from \(asset.provider.displayName). Applying it downloads its maps at your Max Texture size, then it’s also available offline under Downloaded.")
                    .foregroundStyle(.secondary)
            } else if material.isSubstanceArchive {
                if SubstanceRenderer.isAvailable {
                    Text("Substance archive. Its maps are rendered with Substance when you apply it (cached after the first time).")
                        .foregroundStyle(.secondary)
                } else {
                    Text("Substance archive. Rendering it needs Adobe Substance 3D Designer installed. Or export its texture maps as PNG from a Substance app and add that folder to the library.")
                        .foregroundStyle(.orange)
                }
            } else if material.isKeyShotFile {
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
            .appFont(10)
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

