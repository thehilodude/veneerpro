import Foundation

/// A texture map role, detected from a file name suffix such as `Oak Wood 001_Roughness.jpg`.
enum MapKind: String, CaseIterable, Comparable {
    case baseColor = "Base Color"
    case roughness = "Roughness"
    case glossiness = "Glossiness"
    case metallic = "Metallic"
    case normalGL = "Normal (GL)"
    case normalDX = "Normal (DX)"
    case occlusion = "Occlusion"
    case opacity = "Opacity"
    case emissive = "Emissive"
    case height = "Height"
    case specular = "Specular"
    case preview = "Preview"

    static func < (a: MapKind, b: MapKind) -> Bool {
        allCases.firstIndex(of: a)! < allCases.firstIndex(of: b)!
    }

    /// Maps that UsdPreviewSurface (and so USDZ) can't use.
    var isUnsupported: Bool { self == .height || self == .specular }

    private static let keywords: [(MapKind, [String])] = [
        (.preview, ["sphere", "preview", "thumb", "thumbnail", "render", "swatch"]),
        (.normalDX, ["normaldx", "nrmdx", "normal-dx", "dx"]),
        (.normalGL, ["normalgl", "nrmgl", "normal-gl", "gl", "normal", "normals", "nrm", "nor", "norm"]),
        (.baseColor, ["diffuse", "albedo", "basecolor", "base-color", "color", "colour", "col", "diff", "base"]),
        (.roughness, ["roughness", "rough", "rgh"]),
        (.glossiness, ["glossiness", "gloss"]),
        (.metallic, ["metallic", "metalness", "metal", "mtl"]),
        (.occlusion, ["ao", "ambientocclusion", "occlusion", "occ"]),
        (.opacity, ["opacity", "alpha", "mask", "transparency", "cutout"]),
        (.emissive, ["emissive", "emission", "emit", "glow"]),
        (.height, ["height", "displacement", "disp", "bump"]),
        (.specular, ["specular", "spec", "reflection", "refl"]),
    ]

    /// Classifies `Name_Suffix.ext` by its last `_`-separated token.
    static func classify(_ url: URL) -> MapKind? {
        let stem = url.deletingPathExtension().lastPathComponent.trimmingCharacters(in: .whitespaces)
        let tokens = stem.split(whereSeparator: { $0 == "_" || $0 == "." })
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
        // Check the last few tokens so "Wood_Color_2K" still resolves to Color.
        for token in tokens.reversed().prefix(3) {
            let compact = token.replacingOccurrences(of: " ", with: "")
            for (kind, words) in keywords where words.contains(compact) { return kind }
        }
        return nil
    }
}

/// One material in the library: either a folder of texture maps (Visune, Poliigon, ambientCG...)
/// with an optional KeyShot `.mtl`, or a single KeyShot `.mtl` file (KeyShot's own library).
struct LibraryMaterial: Identifiable, Hashable {
    var id: URL { location }
    /// The material folder, or the `.mtl` file for KeyShot materials.
    let location: URL
    let name: String
    /// Folder path relative to the library root, e.g. "Wood" or "Metal/Anodized/Brushed".
    let category: String
    let maps: [MapKind: URL]
    let keyShotFile: URL?

    /// A standalone KeyShot material (no texture-map folder); its thumbnail is embedded in the file.
    var isKeyShotFile: Bool { location == keyShotFile }

    var preview: URL? { maps[.preview] ?? maps[.baseColor] }

    /// A map folder with no texture maps: the look comes only from KeyShot parameters (procedurals, glass...).
    var isProcedural: Bool { !isKeyShotFile && maps.keys.allSatisfy { $0 == .preview } }

    var usableMaps: [MapKind] { maps.keys.filter { $0 != .preview }.sorted() }

    static let imageExtensions: Set<String> = ["jpg", "jpeg", "png", "tif", "tiff", "exr", "webp", "tga", "bmp"]

    /// Materials found in one folder: the folder itself if it holds texture maps,
    /// otherwise each KeyShot `.mtl` file in it.
    static func materials(inFolder folder: URL, files: [URL], root: URL) -> [LibraryMaterial] {
        var maps: [MapKind: URL] = [:]
        var keyShotFiles: [URL] = []
        for file in files {
            let ext = file.pathExtension.lowercased()
            if ext == "mtl", KeyShotDocument.isKeyShotFile(file) {
                keyShotFiles.append(file)
            } else if imageExtensions.contains(ext), let kind = MapKind.classify(file) {
                // Prefer PNG/JPEG over formats USDZ can't hold.
                if let existing = maps[kind], ["png", "jpg", "jpeg"].contains(existing.pathExtension.lowercased()) { continue }
                maps[kind] = file
            }
        }
        let hasMaps = maps.keys.contains { $0 != .preview && !$0.isUnsupported }

        if hasMaps || (keyShotFiles.count == 1 && maps[.preview] != nil) {
            // A map folder (Visune style): one material named after the folder.
            return [LibraryMaterial(location: folder, name: folder.lastPathComponent,
                                    category: relativePath(folder.deletingLastPathComponent(), root: root),
                                    maps: maps, keyShotFile: keyShotFiles.first)]
        }
        // A KeyShot category folder: one material per .mtl file.
        let category = relativePath(folder, root: root)
        return keyShotFiles.map { file in
            LibraryMaterial(location: file, name: file.deletingPathExtension().lastPathComponent,
                            category: category, maps: [:], keyShotFile: file)
        }
    }

    /// A material from an explicit folder or `.mtl` path (used by the command line).
    static func from(path: URL) -> LibraryMaterial? {
        if path.pathExtension.lowercased() == "mtl" {
            return materials(inFolder: path.deletingLastPathComponent(), files: [path],
                             root: path.deletingLastPathComponent()).first
        }
        let files = (try? FileManager.default.contentsOfDirectory(at: path, includingPropertiesForKeys: nil)) ?? []
        return materials(inFolder: path, files: files, root: path.deletingLastPathComponent()).first
    }

    private static func relativePath(_ folder: URL, root: URL) -> String {
        let rootComponents = root.standardizedFileURL.pathComponents
        let components = folder.standardizedFileURL.pathComponents
        return components.count > rootComponents.count
            ? components[rootComponents.count...].joined(separator: "/")
            : ""
    }

    /// Walks `root` and returns every material, sorted by category then name.
    static func scan(root: URL) -> [LibraryMaterial] {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey],
                                             options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return [] }
        var filesByFolder: [URL: [URL]] = [:]
        for case let url as URL in enumerator {
            guard (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == false else { continue }
            filesByFolder[url.deletingLastPathComponent(), default: []].append(url)
        }
        return filesByFolder
            .flatMap { materials(inFolder: $0.key, files: $0.value, root: root) }
            .sorted { ($0.category, $0.name.localizedLowercase) < ($1.category, $1.name.localizedLowercase) }
    }
}
