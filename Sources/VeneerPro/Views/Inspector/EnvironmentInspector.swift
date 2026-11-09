#if os(macOS)
import AppKit
#else
import UIKit
#endif
import SwiftUI

/// Lighting for the viewer: Poly Haven and ambientCG HDRIs, KeyShot's environments, the user's own HDRIs,
/// and the offline Studio default.
struct EnvironmentInspector: View {
    @Environment(AppModel.self) private var model
    @State private var dropTargeted = false
    @AppStorage("HDRIBrowseSource") private var browseSource: HDRISource = Distribution.isAppStore ? .ambientCG : .polyHaven
    @AppStorage("HDRIDownloadSize") private var downloadSize = "2K"
    @State private var search = ""
    @State private var filters: Set<String> = []

    private var library: EnvironmentLibrary { model.environments }

    var body: some View {
        @Bindable var model = model
        VStack(alignment: .leading, spacing: 0) {
            InspectorSection(title: "Lighting") {
                CurrentEnvironment(source: model.viewer.environment)
                LabeledSlider(title: "Rotation", value: $model.viewer.environmentRotation, range: 0...360, defaultValue: 0,
                              format: { "\(Int($0))°" })
                LabeledSlider(title: "Brightness", value: $model.viewer.environmentIntensity, range: 0...3, defaultValue: 1,
                              format: { String(format: "%.1f×", $0) })
                LabeledSlider(title: "Exposure", value: $model.viewer.exposure, range: -3...3, defaultValue: 0,
                              format: { String(format: "%+.1f", $0) })
                Toggle("Show Environment as Background", isOn: $model.viewer.showEnvironment)
                Toggle("Show Grid", isOn: $model.viewer.showGrid)
            }

            InspectorSection(title: "Ground") {
                Toggle("Show Ground Plane", isOn: $model.viewer.showGround)
                if model.viewer.showGround {
                    Picker("Style", selection: $model.viewer.groundStyle) {
                        ForEach(GroundStyle.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    if model.viewer.groundStyle == .solid {
                        LabeledSlider(title: "Shade", value: $model.viewer.groundShade, range: 0.05...0.9, defaultValue: 0.42,
                                      format: { "\(Int(($0 * 100).rounded()))%" })
                    }
                }
                Text(model.viewer.scaleScene.kind == .none
                     ? "A floor under the model that catches its shadow. Shadow Only lets the background show through. View only, never exported."
                     : "Hidden while a scale scene is showing; it has its own floor.")
                    .appFont(10).foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            InspectorSection(title: "Scale Scene") {
                HStack(spacing: 5) {
                    ForEach(ScaleScene.Kind.allCases) { kind in
                        ToolTile(title: kind.rawValue, symbol: kind.symbol, isSelected: model.viewer.scaleScene.kind == kind) {
                            model.viewer.scaleScene.kind = kind
                        }
                    }
                }
                if model.viewer.scaleScene.kind != .none {
                    ScaleSceneToggles(scene: $model.viewer.scaleScene)
                        .toggleStyle(.switch)
                        .controlSize(.small)
                        .appFont(11.5)
                }
                Text("Clay reference scenes at real-world size. View only, never exported.")
                    .appFont(10).foregroundStyle(.tertiary)
            }

            InspectorSection(title: "HDRI Library") {
                Picker("Source", selection: $browseSource) {
                    ForEach(HDRISource.available.filter { $0 != .keyShot || library.keyShotRoot != nil }) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .controlSize(.small)
                switch browseSource {
                case .polyHaven: onlineBrowser(.polyHaven)
                case .ambientCG: onlineBrowser(.ambientCG)
                case .keyShot: keyShotBrowser
                case .mine: myHDRIs
                }
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            let added = library.add(urls)
            if let first = added.first {
                model.viewer.environment = first
                browseSource = .mine
            }
            return !added.isEmpty
        } isTargeted: { dropTargeted = $0 }
        .onAppear {
            if !HDRISource.available.contains(browseSource) { browseSource = .ambientCG }
            loadSelectedCatalog()
        }
        .onChange(of: browseSource) {
            filters = []
            search = ""
            loadSelectedCatalog()
        }
        .alert("Download Failed", isPresented: Binding(get: { library.downloadError != nil },
                                                      set: { if !$0 { library.downloadError = nil } })) {
            Button("OK") { library.downloadError = nil }
        } message: {
            Text(library.downloadError ?? "")
        }
    }

    private func loadSelectedCatalog() {
        switch browseSource {
        case .polyHaven: library.loadCatalog(.polyHaven)
        case .ambientCG: library.loadCatalog(.ambientCG)
        default: break
        }
    }

    // MARK: Online

    @ViewBuilder
    private func onlineBrowser(_ provider: OnlineLibrary.Provider) -> some View {
        let items = library.onlineCatalogs[provider] ?? []
        Link(destination: provider.website) {
            HStack(spacing: 4) {
                Image(systemName: "globe")
                Text("\(provider == .polyHaven ? "Powered by Poly Haven" : "HDRIs from ambientCG") · Free CC0")
            }
            .appFont(10.5, weight: .medium)
            .foregroundStyle(.secondary)
        }
        if let error = library.catalogErrors[provider], items.isEmpty {
            VStack(spacing: 8) {
                Image(systemName: "wifi.exclamationmark").appFont(17).foregroundStyle(.tertiary)
                Text(error).appFont(10).foregroundStyle(.secondary).multilineTextAlignment(.center)
                Button("Retry") { library.loadCatalog(provider, force: true) }
                Button("Use the Offline Studio") { model.viewer.environment = .preset(.studio) }
                    .linkButtonStyle().appFont(10)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
        } else if items.isEmpty {
            ProgressView("Loading HDRIs…").controlSize(.small).frame(maxWidth: .infinity).padding(.vertical, 16)
        } else {
            searchField
            let groups = OnlineLibrary.hdriGroups.map { group in
                FilterGroup(title: group.title,
                            options: FilterMatch.options(for: group.title, in: items.map(\.tags), labels: OnlineLibrary.hdriLabel,
                                                         order: group.values))
            }
            FilterPanel(groups: groups, selection: $filters, storageKey: "HDRIs")
            let shown = items.filter { item in
                FilterMatch.matches(item.tags, selection: filters)
                    && (search.isEmpty || item.name.localizedCaseInsensitiveContains(search))
            }
            HStack {
                Text("\(shown.count) HDRIs").appFont(10).foregroundStyle(.secondary)
                Spacer()
                Picker("Download Size", selection: $downloadSize) {
                    ForEach(["1K", "2K", "4K"], id: \.self) { Text($0).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .controlSize(.mini)
                .fixedSize()
                .help("Resolution to download. 2K lights the scene fully; 4K gives a sharper background.")
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 112), spacing: 8)], spacing: 10) {
                ForEach(shown) { item in
                    let local = library.localFile(item)
                    OnlineHDRICell(item: item, isSelected: local.map { model.viewer.environment == .file($0) } ?? false,
                                   isDownloaded: local != nil, isDownloading: library.downloading.contains(item.id))
                        .onTapGesture {
                            Task {
                                if let environment = await library.environment(for: item, resolution: downloadSize) {
                                    model.viewer.environment = environment
                                }
                            }
                        }
                        .contextMenu {
                            if let local {
                                if PlatformActions.canRevealFiles {
                                    Button("Show in Finder") { PlatformActions.reveal([local]) }
                                }
                                Button("Delete Download", role: .destructive) { deleteDownload(local) }
                            }
                        }
                }
            }
        }
    }

    // MARK: KeyShot

    @ViewBuilder
    private var keyShotBrowser: some View {
        let all = library.keyShotGroups.flatMap { group in group.sources.map { (source: $0, tags: Set(["Folder|" + group.title])) } }
        if library.keyShotGroups.isEmpty {
            ProgressView().controlSize(.small).frame(maxWidth: .infinity)
        } else {
            searchField
            FilterPanel(groups: [FilterGroup(title: "Folder",
                                             options: FilterMatch.options(for: "Folder", in: all.map(\.tags),
                                                                          order: library.keyShotGroups.map(\.title)))],
                        selection: $filters, storageKey: "KeyShotHDRIs")
            let shown = all.filter { FilterMatch.matches($0.tags, selection: filters)
                && (search.isEmpty || $0.source.name.localizedCaseInsensitiveContains(search)) }
            grid(shown.map(\.source), removable: false)
            Text("Studio and Sun & Sky lighting files are re-created from KeyShot's light setups; image environments load as-is.")
                .appFont(10).foregroundStyle(.tertiary)
        }
    }

    // MARK: Mine

    @ViewBuilder
    private var myHDRIs: some View {
        Text("OFFLINE DEFAULT").appFont(9.5, weight: .semibold).foregroundStyle(.tertiary)
        grid(library.builtIn, removable: false)
        if !library.downloaded.isEmpty {
            Text("DOWNLOADED").appFont(9.5, weight: .semibold).foregroundStyle(.tertiary).padding(.top, 4)
            grid(library.downloaded.map { .file($0) }, removable: false, downloaded: true)
        }
        Text("ADDED").appFont(9.5, weight: .semibold).foregroundStyle(.tertiary).padding(.top, 4)
        if library.custom.isEmpty {
            VStack(spacing: 6) {
                Image(systemName: "photo.on.rectangle.angled").appFont(17).foregroundStyle(.tertiary)
                Text("Drop .hdr, .exr or KeyShot .hdz/.klf files here")
                    .appFont(10).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(RoundedRectangle(cornerRadius: 8)
                .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [5, 4]))
                .foregroundStyle(dropTargeted ? Color.accentColor : Color.secondary.opacity(0.4)))
        } else {
            grid(library.custom.map { .file($0) }, removable: true)
        }
        Button {
            if let first = library.presentAddPanel().first { model.viewer.environment = first }
        } label: {
            Label("Add HDRI…", systemImage: "plus")
        }
    }

    // MARK: Shared

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Search", text: $search).textFieldStyle(.plain)
            if !search.isEmpty {
                Button { search = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary) }
                    .buttonStyle(.plain)
            }
        }
        .appFont(12)
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: Theme.corner).fill(Theme.control))
    }

    private func grid(_ sources: [EnvironmentSource], removable: Bool, downloaded: Bool = false) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 112), spacing: 8)], spacing: 10) {
            ForEach(sources) { source in
                EnvironmentCell(source: source, isSelected: model.viewer.environment == source)
                    .onTapGesture { model.viewer.environment = source }
                    .contextMenu {
                        if case let .file(url) = source {
                            if PlatformActions.canRevealFiles {
                                Button("Show in Finder") { PlatformActions.reveal([url]) }
                            }
                            if removable {
                                Button("Remove from My HDRIs", role: .destructive) {
                                    library.remove(url)
                                    if model.viewer.environment == source { model.viewer.environment = .preset(.studio) }
                                }
                            }
                            if downloaded {
                                Button("Delete Download", role: .destructive) { deleteDownload(url) }
                            }
                        }
                    }
            }
        }
    }

    private func deleteDownload(_ url: URL) {
        library.removeDownloaded(url)
        if model.viewer.environment == .file(url) { model.viewer.environment = .preset(.studio) }
    }
}

/// Where the HDRI browser is looking.
enum HDRISource: String, CaseIterable, Identifiable {
    case polyHaven, ambientCG, keyShot, mine
    var id: String { rawValue }
    /// The App Store edition leaves out Poly Haven (commercial API license) and KeyShot's folder (sandbox).
    static var available: [HDRISource] { Distribution.isAppStore ? [.ambientCG, .mine] : allCases }
    var title: String {
        switch self {
        case .polyHaven: "Poly Haven"
        case .ambientCG: "ambientCG"
        case .keyShot: "KeyShot"
        case .mine: "Mine"
        }
    }
}

/// An online HDRI: its preview, with a download badge or progress.
private struct OnlineHDRICell: View {
    @Environment(AppModel.self) private var model
    let item: OnlineHDRI
    let isSelected: Bool
    let isDownloaded: Bool
    let isDownloading: Bool
    @State private var image: CGImage?

    var body: some View {
        VStack(spacing: 3) {
            Rectangle().fill(.quaternary)
                .aspectRatio(2, contentMode: .fit)
                .overlay {
                    if let image {
                        Image(decorative: image, scale: 1).resizable().scaledToFill()
                    } else {
                        ProgressView().controlSize(.mini)
                    }
                }
                .overlay {
                    if isDownloading {
                        ZStack {
                            Color.black.opacity(0.45)
                            ProgressView().controlSize(.small)
                        }
                    }
                }
                .overlay(alignment: .topTrailing) {
                    if !isDownloaded && !isDownloading {
                        Image(systemName: "icloud.and.arrow.down")
                            .appFont(8.5, weight: .bold)
                            .padding(3.5)
                            .background(.ultraThinMaterial, in: Circle())
                            .padding(3)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(isSelected ? Color.accentColor : .clear, lineWidth: 2.5))
            Text(item.name)
                .appFont(10)
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundStyle(isSelected ? .primary : .secondary)
        }
        .contentShape(Rectangle())
        .help(isDownloaded ? item.name : "\(item.name) — click to download and use")
        .task(id: item.id) {
            image = model.environments.cachedThumbnail(item)
            if image == nil { image = await model.environments.thumbnail(item) }
        }
    }
}

/// The selected environment, shown large.
private struct CurrentEnvironment: View {
    @Environment(AppModel.self) private var model
    let source: EnvironmentSource
    @State private var image: CGImage?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Rectangle().fill(.quaternary)
                .aspectRatio(2, contentMode: .fit)
                .overlay { if let image { Image(decorative: image, scale: 1).resizable() } }
                .clipShape(RoundedRectangle(cornerRadius: 8))
            Text(source.name).appFont(12, weight: .medium).lineLimit(1)
        }
        .task(id: source.id) {
            image = model.environments.cachedThumbnail(source)
            if image == nil { image = await model.environments.thumbnail(source) }
        }
    }
}

private struct EnvironmentCell: View {
    @Environment(AppModel.self) private var model
    let source: EnvironmentSource
    let isSelected: Bool
    @State private var image: CGImage?

    var body: some View {
        VStack(spacing: 3) {
            Rectangle().fill(.quaternary)
                .aspectRatio(2, contentMode: .fit)
                .overlay {
                    if let image {
                        Image(decorative: image, scale: 1).resizable()
                    } else {
                        ProgressView().controlSize(.mini)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(isSelected ? Color.accentColor : .clear, lineWidth: 2.5))
            Text(source.name)
                .appFont(10)
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundStyle(isSelected ? .primary : .secondary)
        }
        .contentShape(Rectangle())
        .help(source.name)
        .task(id: source.id) {
            image = model.environments.cachedThumbnail(source)
            if image == nil { image = await model.environments.thumbnail(source) }
        }
    }
}

private struct LabeledSlider: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    var defaultValue: Double? = nil
    let format: (Double) -> String

    var body: some View {
        BarSlider(title: title, value: $value, range: range, defaultValue: defaultValue, format: format)
    }
}
