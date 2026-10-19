import AppKit
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

    /// Every library: the built-in Veneer Essentials first, then each folder the user has added.
    private(set) var sources: [URL] = [BuiltInMaterials.root]
    /// The library being browsed.
    private(set) var root: URL?
    private(set) var materials: [LibraryMaterial] = []
    private(set) var isScanning = false
    var searchText = ""
    var category: String?
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
        sources = [BuiltInMaterials.root] + existing + sources.filter { !existing.contains($0) && !BuiltInMaterials.isBuiltIn($0) }
        saveSources()
        let stored = defaults.string(forKey: Keys.selected)
        let selected = stored == BuiltInMaterials.root.absoluteString ? BuiltInMaterials.root : stored.map { URL(fileURLWithPath: $0) }
        if root == nil || root == BuiltInMaterials.root, let first = sources.first(where: { $0 == selected }) ?? sources.first {
            select(first)
        }
    }

    /// Libraries installed by Visune and KeyShot, if present.
    nonisolated static var detectedLibraries: [URL] {
        let fm = FileManager.default
        var candidates = [fm.homeDirectoryForCurrentUser.appendingPathComponent("Documents/Visune Asset Library/Materials")]
        // KeyShot Studio / KeyShot 2023+ / older "KeyShot 11" resource folders.
        for base in [URL(fileURLWithPath: "/Library/Application Support"), fm.homeDirectoryForCurrentUser.appendingPathComponent("Documents")] {
            let names = (try? fm.contentsOfDirectory(atPath: base.path)) ?? []
            for name in names.sorted() where name.hasPrefix("KeyShot") && !name.contains("Viewer") {
                candidates.append(base.appendingPathComponent(name).appendingPathComponent("Materials"))
            }
        }
        return candidates.filter { fm.fileExists(atPath: $0.path) }
    }

    // MARK: Sources

    func displayName(_ source: URL) -> String {
        if BuiltInMaterials.isBuiltIn(source) { return BuiltInMaterials.displayName }
        // ".../KeyShot Studio/Materials" → "KeyShot Studio"; ".../Visune Asset Library/Materials" → "Visune Asset Library".
        return source.lastPathComponent == "Materials" ? source.deletingLastPathComponent().lastPathComponent : source.lastPathComponent
    }

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

    func add(_ url: URL) {
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
        guard !BuiltInMaterials.isBuiltIn(source) else { return }
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
        category = nil
        UserDefaults.standard.set(BuiltInMaterials.isBuiltIn(source) ? source.absoluteString : source.path, forKey: Keys.selected)
        if BuiltInMaterials.isBuiltIn(source) {
            materials = BuiltInMaterials.materials
            isScanning = false
        } else if let cached = scanned[source] {
            materials = cached
        } else {
            materials = []
            rescan()
        }
    }

    func rescan() {
        guard let root, !BuiltInMaterials.isBuiltIn(root) else { return }
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
        UserDefaults.standard.set(sources.filter { !BuiltInMaterials.isBuiltIn($0) }.map(\.path), forKey: Keys.sources)
    }

    // MARK: Browsing

    /// Top-level categories ("Metal") with counts.
    var categories: [(name: String, count: Int)] {
        counts(materials.map { $0.category.split(separator: "/").first.map(String.init) ?? "" })
    }

    /// Second-level categories under the selected top-level one ("Metal/Anodized"), with counts.
    var subcategories: [(name: String, count: Int)] {
        guard let top = topCategory else { return [] }
        let names = materials.compactMap { m -> String? in
            guard m.category.hasPrefix(top + "/") else { return nil }
            return m.category.split(separator: "/").prefix(2).joined(separator: "/")
        }
        return counts(names)
    }

    /// The top-level part of the selected category.
    var topCategory: String? { category?.split(separator: "/").first.map(String.init) }

    private func counts(_ names: [String]) -> [(name: String, count: Int)] {
        var counts: [String: Int] = [:]
        for name in names { counts[name, default: 0] += 1 }
        return counts.sorted { $0.key.localizedLowercase < $1.key.localizedLowercase }.map { ($0.key, $0.value) }
    }

    var filtered: [LibraryMaterial] {
        let query = searchText.trimmingCharacters(in: .whitespaces)
        return materials.filter { m in
            (category == nil || m.category == category || m.category.hasPrefix(category! + "/"))
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
        if BuiltInMaterials.isBuiltIn(material.location) { return material.location }
        return material.preview ?? (material.isKeyShotFile ? material.location : nil)
    }

    /// Lighting for built-in material thumbnails (the Studio environment), loaded once.
    @ObservationIgnored private var thumbnailEnvironment: CGImage??

    private func builtInThumbnail(_ material: LibraryMaterial) async -> CGImage? {
        if thumbnailEnvironment == nil {
            let pixels = await EnvironmentLoader.load(.preset(.studio))
            thumbnailEnvironment = .some(pixels?.cgImage())
        }
        let environment = thumbnailEnvironment ?? nil
        return await Task.detached(priority: .utility) { BuiltInMaterials.thumbnail(for: material, environment: environment) }.value
    }

    func cachedThumbnail(for material: LibraryMaterial) -> CGImage? {
        thumbnailKey(material).flatMap { thumbnailCache.object(forKey: $0 as NSURL) }
    }

    func thumbnail(for material: LibraryMaterial) async -> CGImage? {
        guard let key = thumbnailKey(material) else { return nil }
        if let cached = thumbnailCache.object(forKey: key as NSURL) { return cached }
        if BuiltInMaterials.isBuiltIn(material.location) {
            let image = await builtInThumbnail(material)
            if let image { thumbnailCache.setObject(image, forKey: key as NSURL) }
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
        if BuiltInMaterials.isBuiltIn(material.location) {
            if let graph = BuiltInMaterials.graph(for: material) { entry.replaceGraph(graph) }
            return
        }
        let maxSize = (textureSize ?? self.textureSize).maxPixelSize
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
