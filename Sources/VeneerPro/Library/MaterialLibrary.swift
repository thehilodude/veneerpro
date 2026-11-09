#if os(macOS)
import AppKit
#else
import UIKit
#endif
import ImageIO
import Observation

/// One or more material folders (e.g. a Visune Asset Library and KeyShot's own library),
/// browsed like KeyShot's material library.
@MainActor
@Observable
final class MaterialLibrary {
    enum TextureSize: Int, CaseIterable, Identifiable {
        case k1 = 1024, k2 = 2048, k4 = 4096, original = 0

        var id: Int { rawValue }
        var title: String {
            switch self {
            case .k1: "1K"
            case .k2: "2K"
            case .k4: "4K"
            case .original: "Original"
            }
        }
        var maxPixelSize: Int? { self == .original ? nil : rawValue }
    }

    /// Every library: the online CC0 libraries, then each folder the user added.
    private(set) var sources: [URL] = MaterialLibrary.fixedSources
    /// Why the selected online library couldn't load (e.g. offline).
    private(set) var loadError: String?

    private static let fixedSources = OnlineLibrary.Provider.available.map(\.source)

    private static func isFixed(_ url: URL) -> Bool { OnlineLibrary.isOnline(url) }
    /// The library being browsed.
    private(set) var root: URL?
    private(set) var materials: [LibraryMaterial] = []
    private(set) var isScanning = false
    /// The last failure while applying (e.g. a Substance archive with no renderer installed).
    var applyError: String?
    var searchText = ""
    /// Selected filter chips ("Category|Metal", "Subcategory|Metal/Brushed").
    var filters: Set<String> = [] {
        didSet {
            // Drop subcategories whose category was deselected.
            let tops = filters.filter { $0.hasPrefix("Category|") }.map { String($0.dropFirst(9)) + "/" }
            let orphaned = filters.filter { key in key.hasPrefix("Subcategory|") && !tops.contains { key.dropFirst(12).hasPrefix($0) } }
            if !orphaned.isEmpty { filters.subtract(orphaned) }
        }
    }
    var thumbnailSize: Double = 92
    var textureSize: TextureSize {
        didSet { UserDefaults.standard.set(textureSize.rawValue, forKey: Keys.textureSize) }
    }

    @ObservationIgnored private var scanned: [URL: [LibraryMaterial]] = [:]
    @ObservationIgnored private let thumbnailCache = NSCache<NSURL, CGImage>()
    @ObservationIgnored private let keyShotCache = NSCache<NSURL, KeyShotBox>()
    @ObservationIgnored private var textureIndexes: [URL: [String: URL]] = [:]

    private enum Keys {
        static let sources = "MaterialLibrarySources"
        static let selected = "MaterialLibrarySelected"
        static let legacyRoot = "MaterialLibraryRoot"
        static let textureSize = "MaterialLibraryTextureSize"
    }

    nonisolated static let dragPrefix = "rc2-library-material:"

    init() {
        let defaults = UserDefaults.standard
        let stored = defaults.object(forKey: Keys.textureSize) as? Int
        textureSize = stored.flatMap(TextureSize.init(rawValue:)) ?? .k2

        // Library folders often live in ~/Documents, which macOS may gate behind a permission prompt.
        // Never touch the file system on the main thread at launch, or a pending prompt freezes the app.
        Task { await loadSources() }
    }

    private func loadSources() async {
        let defaults = UserDefaults.standard
        var paths = defaults.stringArray(forKey: Keys.sources) ?? []
        if let legacy = defaults.string(forKey: Keys.legacyRoot), !paths.contains(legacy) { paths.insert(legacy, at: 0) }
        let known = Set(defaults.stringArray(forKey: Keys.sources + ".autoAdded") ?? [])
        let candidates = paths
        let (detected, existing) = await Task.detached(priority: .utility) { () -> ([URL], [URL]) in
            let detected = Self.detectedLibraries
            // Offer Visune and KeyShot automatically the first time each is found.
            var all = candidates
            for url in detected where !known.contains(url.path) && !all.contains(url.path) { all.append(url.path) }
            return (detected, all.map { URL(fileURLWithPath: $0) }.filter { FileManager.default.fileExists(atPath: $0.path) })
        }.value
        defaults.set(Array(known.union(detected.map(\.path))), forKey: Keys.sources + ".autoAdded")
        // Folders added while this was running stay in the list.
        sources = Self.fixedSources + existing + sources.filter { !existing.contains($0) && !Self.isFixed($0) }
        saveSources()
        let stored = defaults.string(forKey: Keys.selected)
        let selected = stored.flatMap { s in Self.fixedSources.first { $0.absoluteString == s } } ?? stored.map { URL(fileURLWithPath: $0) }
        if root == nil, let first = sources.first(where: { $0 == selected }) ?? sources.first {
            select(first)
        }
    }

    /// Libraries installed by Visune and KeyShot, if present.
    nonisolated static var detectedLibraries: [URL] {
        // The sandboxed App Store edition can only open folders the user picks.
        if Distribution.isAppStore { return [] }
        #if os(iOS)
        return []
        #else
        let fm = FileManager.default
        var candidates = [fm.homeDirectoryForCurrentUser.appendingPathComponent("Documents/Visune Asset Library/Materials")]
        // KeyShot Studio / KeyShot 2023+ / older "KeyShot 11" resource folders.
        for base in [URL(fileURLWithPath: "/Library/Application Support"), fm.homeDirectoryForCurrentUser.appendingPathComponent("Documents")] {
            let names = (try? fm.contentsOfDirectory(atPath: base.path)) ?? []
            for name in names.sorted() where name.hasPrefix("KeyShot") && !name.contains("Viewer") {
                candidates.append(base.appendingPathComponent(name).appendingPathComponent("Materials"))
            }
        }
        // Adobe Substance apps keep their libraries and downloads under ~/Documents/Adobe.
        let adobe = fm.homeDirectoryForCurrentUser.appendingPathComponent("Documents/Adobe")
        for name in ((try? fm.contentsOfDirectory(atPath: adobe.path)) ?? []).sorted() where name.localizedCaseInsensitiveContains("Substance") {
            candidates.append(adobe.appendingPathComponent(name))
        }
        return candidates.filter { fm.fileExists(atPath: $0.path) }
        #endif
    }

    // MARK: Sources

    func displayName(_ source: URL) -> String {
        if let provider = OnlineLibrary.Provider(source: source) { return provider.displayName }
        if source.standardizedFileURL == OnlineLibrary.downloadsFolder.standardizedFileURL { return "Downloaded" }
        if source.path.contains("/Adobe/"), source.lastPathComponent.localizedCaseInsensitiveContains("Substance") {
            return source.lastPathComponent.replacingOccurrences(of: "Adobe ", with: "")
        }
        // ".../KeyShot Studio/Materials" → "KeyShot Studio"; ".../Visune Asset Library/Materials" → "Visune Asset Library".
        return source.lastPathComponent == "Materials" ? source.deletingLastPathComponent().lastPathComponent : source.lastPathComponent
    }

    #if os(iOS)
    /// iPad: asks the UI to show a folder picker (which calls `add(_:)`).
    var wantsFolderPicker = false
    func addFolder() { wantsFolderPicker = true }
    #else
    func addFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.message = "Choose a folder of materials — e.g. “Visune Asset Library”, or KeyShot’s “Materials” folder."
        panel.prompt = "Add Library"
        panel.directoryURL = root
        guard panel.runModal() == .OK, let url = panel.url else { return }
        add(url)
    }
    #endif

    func add(_ url: URL) {
        FileAccess.remember(url)
        // Picking a whole asset library? Narrow to its Materials folder.
        let materials = url.appendingPathComponent("Materials", isDirectory: true)
        var isDir: ObjCBool = false
        let resolved = FileManager.default.fileExists(atPath: materials.path, isDirectory: &isDir) && isDir.boolValue
            ? materials : url
        if !sources.contains(resolved) { sources.append(resolved) }
        saveSources()
        select(resolved)
    }

    func remove(_ source: URL) {
        guard !Self.isFixed(source) else { return }
        sources.removeAll { $0 == source }
        scanned[source] = nil
        saveSources()
        if root == source {
            root = nil
            materials = []
            if let first = sources.first { select(first) }
        }
    }

    func select(_ source: URL) {
        root = source
        filters = []
        UserDefaults.standard.set(Self.isFixed(source) ? source.absoluteString : source.path, forKey: Keys.selected)
        loadError = nil
        if let cached = scanned[source] {
            materials = cached
        } else {
            materials = []
            rescan()
        }
    }

    func rescan() {
        guard let root else { return }
        if let provider = OnlineLibrary.Provider(source: root) {
            isScanning = true
            Task {
                do {
                    let found = try await OnlineLibrary.catalog(provider)
                    scanned[root] = found
                    if root == self.root { materials = found }
                } catch {
                    if root == self.root { loadError = "Couldn’t reach \(provider.displayName). Check your internet connection." }
                }
                if root == self.root { isScanning = false }
            }
            return
        }
        isScanning = true
        Task {
            let found = await Task.detached(priority: .userInitiated) { LibraryMaterial.scan(root: root) }.value
            scanned[root] = found
            textureIndexes[root] = nil
            guard root == self.root else { return }
            materials = found
            isScanning = false
        }
    }

    private func saveSources() {
        UserDefaults.standard.set(sources.filter { !Self.isFixed($0) }.map(\.path), forKey: Keys.sources)
    }

    // MARK: Browsing
    /// Filter tags for a material: its top-level category and, below that, its subcategory.
    private static func tags(_ m: LibraryMaterial) -> Set<String> {
        let parts = m.category.split(separator: "/").map(String.init)
        var tags: Set<String> = ["Category|" + (parts.first ?? "")]
        if parts.count > 1 { tags.insert("Subcategory|" + parts[0] + "/" + parts[1]) }
        return tags
    }

    /// The filter chips: categories, and the subcategories of whichever categories are selected.
    var filterGroups: [FilterGroup] {
        let all = materials.map(Self.tags)
        let categories = FilterMatch.options(for: "Category", in: all, labels: { $0.isEmpty ? "Uncategorized" : $0 },
                                             order: Set(all.flatMap { $0 }.filter { $0.hasPrefix("Category|") }
                                                 .map { String($0.dropFirst(9)) }).sorted { $0.localizedLowercase < $1.localizedLowercase })
        let selectedTops = filters.filter { $0.hasPrefix("Category|") }.map { String($0.dropFirst(9)) }
        var groups = [FilterGroup(title: "Category", options: categories)]
        if !selectedTops.isEmpty {
            let inSelected = all.filter { tags in selectedTops.contains { tags.contains("Category|" + $0) } }
            let subs = FilterMatch.options(for: "Subcategory", in: inSelected,
                                           labels: { String($0.split(separator: "/").last ?? "") })
            if subs.count > 1 { groups.append(FilterGroup(title: "Subcategory", options: subs)) }
        }
        return groups
    }

    var filtered: [LibraryMaterial] {
        let query = searchText.trimmingCharacters(in: .whitespaces)
        return materials.filter { m in
            FilterMatch.matches(Self.tags(m), selection: filters)
                && (query.isEmpty || m.name.localizedCaseInsensitiveContains(query)
                    || m.category.localizedCaseInsensitiveContains(query))
        }
    }

    func material(forDragPayload payload: String) -> LibraryMaterial? {
        guard payload.hasPrefix(Self.dragPrefix) else { return nil }
        let path = String(payload.dropFirst(Self.dragPrefix.count))
        return materials.first { $0.location.path == path }
    }

    nonisolated static func dragPayload(_ material: LibraryMaterial) -> String { dragPrefix + material.location.path }

    // MARK: Thumbnails & KeyShot data

    private func thumbnailKey(_ material: LibraryMaterial) -> URL? {
        if material.isSubstanceArchive || material.onlineAsset != nil {
            return material.location
        }
        return material.preview ?? (material.isKeyShotFile ? material.location : nil)
    }

    func cachedThumbnail(for material: LibraryMaterial) -> CGImage? {
        thumbnailKey(material).flatMap { thumbnailCache.object(forKey: $0 as NSURL) }
    }

    func thumbnail(for material: LibraryMaterial) async -> CGImage? {
        guard let key = thumbnailKey(material) else { return nil }
        if let cached = thumbnailCache.object(forKey: key as NSURL) { return cached }
        if let asset = material.onlineAsset {
            guard let url = asset.thumbnail, let data = await OnlineLibrary.thumbnailData(url),
                  let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
            let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                            kCGImageSourceThumbnailMaxPixelSize: 320]
            guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
            thumbnailCache.setObject(image, forKey: key as NSURL)
            return image
        }
        if let archive = material.substanceArchive {
            // A small render of the base color, when Substance's renderer is installed.
            guard SubstanceRenderer.isAvailable,
                  let files = try? await SubstanceRenderer.render(archive, sizeLog2: 8),
                  let color = files.first(where: { MapKind.classify($0) == .baseColor }) ?? files.first,
                  let source = CGImageSourceCreateWithURL(color as CFURL, nil),
                  let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
            thumbnailCache.setObject(image, forKey: key as NSURL)
            return image
        }
        let preview = material.preview
        let image = await Task.detached(priority: .utility) { () -> CGImage? in
            guard let preview else {
                // KeyShot embeds its preview render in the .mtl file.
                return KeyShotDocument.thumbnail(key)
            }
            guard let source = CGImageSourceCreateWithURL(preview as CFURL, nil) else { return nil }
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: 320,
                kCGImageSourceCreateThumbnailWithTransform: true,
            ]
            return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
        }.value
        if let image { thumbnailCache.setObject(image, forKey: key as NSURL) }
        return image
    }

    func keyShot(for material: LibraryMaterial) -> KeyShotMaterial? {
        guard let url = material.keyShotFile else { return nil }
        if let cached = keyShotCache.object(forKey: url as NSURL) { return cached.value }
        let parsed = KeyShotMaterial.load(url)
        keyShotCache.setObject(KeyShotBox(parsed), forKey: url as NSURL)
        return parsed
    }

    /// Lowercased file name → URL for every image under the library's `Textures` folder
    /// (KeyShot keeps materials and textures side by side), built on first use.
    private func textureIndex(for source: URL?) -> [String: URL] {
        guard let source else { return [:] }
        if let cached = textureIndexes[source] { return cached }
        var index: [String: URL] = [:]
        let texturesRoot = source.deletingLastPathComponent().appendingPathComponent("Textures")
        if let enumerator = FileManager.default.enumerator(at: texturesRoot, includingPropertiesForKeys: nil,
                                                          options: [.skipsHiddenFiles, .skipsPackageDescendants]) {
            for case let url as URL in enumerator where LibraryMaterial.imageExtensions.contains(url.pathExtension.lowercased()) {
                index[url.lastPathComponent.lowercased()] = index[url.lastPathComponent.lowercased()] ?? url
            }
        }
        textureIndexes[source] = index
        return index
    }

    // MARK: Applying

    /// Loads the material's textures (off the main thread) and replaces `entry`'s node graph with one built from them.
    func apply(_ material: LibraryMaterial, to entry: MaterialEntry, textureSize: TextureSize? = nil) async {
        let maxSize = (textureSize ?? self.textureSize).maxPixelSize
        if material.onlineAsset != nil {
            await applyOnline(material, to: entry, textureSize: textureSize ?? self.textureSize)
            return
        }
        if let archive = material.substanceArchive {
            await applySubstance(archive, material: material, to: entry, textureSize: textureSize ?? self.textureSize)
            return
        }
        let thumbnail = await thumbnail(for: material)

        if material.isKeyShotFile {
            await applyKeyShot(material, to: entry, maxSize: maxSize, thumbnail: thumbnail)
            return
        }
        let maps = material.maps.filter { $0.key != .preview && !$0.key.isUnsupported }
        let keyShot = keyShot(for: material)
        let (textures, previewColor) = await Task.detached(priority: .userInitiated) { () -> ([MapKind: TextureRef], SIMD3<Float>?) in
            var result: [MapKind: TextureRef] = [:]
            for (kind, url) in maps {
                guard let texture = TextureRef.load(url: url, maxPixelSize: maxSize)?.compactedForAR() else { continue }
                _ = texture.pixels // decode now rather than on the first preview
                result[kind] = texture
            }
            return (result, thumbnail?.dominantColor())
        }.value
        entry.replaceGraph(MaterialGraph(library: material, textures: textures, keyShot: keyShot, previewColor: previewColor))
    }

    /// Downloads an online material's maps (once), lists the Downloaded folder, then applies it locally.
    private func applyOnline(_ material: LibraryMaterial, to entry: MaterialEntry, textureSize: TextureSize) async {
        // 8K scans are far too heavy for AR; Original means the largest sensible size.
        let resolution = switch textureSize { case .k1: "1K"; case .k2: "2K"; case .k4, .original: "4K" }
        do {
            let folder = try await OnlineLibrary.download(material, resolution: resolution)
            let downloads = OnlineLibrary.downloadsFolder
            if !sources.contains(where: { $0.standardizedFileURL == downloads.standardizedFileURL }) {
                sources.append(downloads)
                saveSources()
            }
            scanned[downloads] = nil
            guard let local = LibraryMaterial.from(path: folder) else { throw URLError(.cannotParseResponse) }
            await apply(local, to: entry, textureSize: textureSize)
        } catch {
            applyError = "Couldn’t download “\(material.name)” from \(material.onlineAsset?.provider.displayName ?? "the library"). \(error.localizedDescription)"
        }
    }

    /// Renders the archive's outputs with Substance, then builds the graph from them like a map folder.
    private func applySubstance(_ archive: URL, material: LibraryMaterial, to entry: MaterialEntry, textureSize: TextureSize) async {
        // Substance's default engine renders up to 2048 px.
        let sizeLog2 = textureSize == .k1 ? 10 : 11
        do {
            let files = try await SubstanceRenderer.render(archive, sizeLog2: sizeLog2)
            var maps: [MapKind: URL] = [:]
            for file in files {
                if let kind = MapKind.classify(file), kind != .preview, !kind.isUnsupported, maps[kind] == nil { maps[kind] = file }
            }
            let textures = await Task.detached(priority: .userInitiated) { () -> [MapKind: TextureRef] in
                var result: [MapKind: TextureRef] = [:]
                for (kind, url) in maps {
                    guard let texture = TextureRef.load(url: url, maxPixelSize: textureSize.maxPixelSize)?.compactedForAR() else { continue }
                    _ = texture.pixels
                    result[kind] = texture
                }
                return result
            }.value
            entry.replaceGraph(MaterialGraph(library: material, textures: textures, keyShot: nil))
        } catch {
            applyError = error.localizedDescription
        }
    }

    private func applyKeyShot(_ material: LibraryMaterial, to entry: MaterialEntry, maxSize: Int?, thumbnail: CGImage?) async {
        let file = material.location
        let index = textureIndex(for: sources.first { file.path.hasPrefix($0.path + "/") } ?? root)
        let folder = file.deletingLastPathComponent()

        if KeyShotDocument.isBinaryFormat(file) {
            // Undocumented binary graph: rebuild from its texture maps, classified by file name.
            let built = await Task.detached(priority: .userInitiated) { () -> ([MapKind: TextureRef], SIMD3<Float>?) in
                var textures: [MapKind: TextureRef] = [:]
                for name in KeyShotDocument.binaryTextureNames(file) {
                    guard let kind = MapKind.classify(URL(fileURLWithPath: name)), kind != .preview, !kind.isUnsupported,
                          textures[kind] == nil else { continue }
                    let local = folder.appendingPathComponent(name)
                    let url = FileManager.default.fileExists(atPath: local.path) ? local : index[name.lowercased()]
                    guard let url, let texture = TextureRef.load(url: url, maxPixelSize: maxSize)?.compactedForAR() else { continue }
                    _ = texture.pixels
                    textures[kind] = texture
                }
                return (textures, thumbnail?.dominantColor())
            }.value
            entry.replaceGraph(MaterialGraph(library: material, textures: built.0, keyShot: nil, previewColor: built.1))
            return
        }

        let loaded = await Task.detached(priority: .userInitiated) { () -> (KeyShotDocument, [String: TextureRef], SIMD3<Float>?)? in
            guard let doc = KeyShotDocument.load(file) else { return nil }
            var textures: [String: TextureRef] = [:]
            for name in Set(doc.textureFileNames) {
                // Next to the .mtl first, then anywhere in the library's Textures folder.
                let local = folder.appendingPathComponent(name)
                let url = FileManager.default.fileExists(atPath: local.path) ? local
                    : index[(name as NSString).lastPathComponent.lowercased()]
                guard let url, let texture = TextureRef.load(url: url, maxPixelSize: maxSize)?.compactedForAR() else { continue }
                _ = texture.pixels
                textures[name.lowercased()] = texture
            }
            return (doc, textures, thumbnail?.dominantColor())
        }.value
        guard let (doc, textures, previewColor) = loaded, let ks = KeyShotMaterial(document: doc) else {
            // Unknown surface type: still give the user the right look from the preview.
            let graph = MaterialGraph(name: material.name)
            if let color = loaded?.2 ?? thumbnail?.dominantColor() {
                graph.update(graph.outputNodeID) { $0.values["Base Color"] = SIMD4(color, 1) }
            }
            entry.replaceGraph(graph)
            return
        }
        entry.replaceGraph(MaterialGraph(keyShot: ks, document: doc, name: material.name,
                                         textures: textures, previewColor: previewColor))
    }
}

private final class KeyShotBox {
    let value: KeyShotMaterial?
    init(_ value: KeyShotMaterial?) { self.value = value }
}
