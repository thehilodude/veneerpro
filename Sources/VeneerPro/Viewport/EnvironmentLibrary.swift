import AppKit
import ImageIO
import Observation

/// Where the viewer's lighting comes from: a built-in procedural studio or an HDRI file.
enum EnvironmentSource: Hashable, Identifiable {
    case preset(EnvironmentPreset)
    case file(URL)

    var id: String {
        switch self {
        case let .preset(p): "preset:\(p.rawValue)"
        case let .file(url): "file:\(url.path)"
        }
    }

    var name: String {
        switch self {
        case let .preset(p): p.rawValue
        case let .file(url): url.deletingPathExtension().lastPathComponent
            .replacingOccurrences(of: " 4K", with: "").replacingOccurrences(of: "_", with: " ")
        }
    }

    /// Stored form for UserDefaults.
    var storageKey: String { id }

    init?(storageKey: String) {
        if storageKey.hasPrefix("preset:"), let p = EnvironmentPreset(rawValue: String(storageKey.dropFirst(7))) {
            self = .preset(p)
        } else if storageKey.hasPrefix("file:") {
            // Not checked for existence here (this runs at launch); a missing file just fails to load.
            self = .file(URL(fileURLWithPath: String(storageKey.dropFirst(5))))
        } else {
            return nil
        }
    }
}

/// Loads environments into linear HDR pixels for SceneKit's image-based lighting.
///
/// Supports `.hdr`/`.exr` (decoded as float by ImageIO), KeyShot's `.hdz` (a 64-byte header
/// followed by a standard Radiance RGBE image) and KeyShot `.klf` lighting files (rendered).
enum EnvironmentLoader {
    static let fileExtensions: Set<String> = ["hdr", "exr", "hdz", "klf", "pic"]
    /// Width of the lighting map. SceneKit prefilters it for reflections; 2K keeps backdrops sharp.
    static let workingWidth = 2048

    private static let cache = NSCache<NSString, PixelsBox>()

    static func load(_ source: EnvironmentSource) async -> HDRPixels? {
        if let cached = cache.object(forKey: source.id as NSString) { return cached.pixels }
        let pixels = await Task.detached(priority: .userInitiated) { () -> HDRPixels? in
            switch source {
            case let .preset(preset): preset.hdrPixels(width: workingWidth)
            case let .file(url): loadFile(url)
            }
        }.value
        if let pixels { cache.setObject(PixelsBox(pixels), forKey: source.id as NSString) }
        return pixels
    }

    private static func loadFile(_ url: URL) -> HDRPixels? {
        switch url.pathExtension.lowercased() {
        case "klf":
            return KeyShotLighting.parse(url).map { KeyShotLighting.render($0, width: workingWidth) }
        case "hdz":
            return imageSource(hdz: url).flatMap { decode($0) }
        default:
            return CGImageSourceCreateWithURL(url as CFURL, nil).flatMap { decode($0) }
        }
    }

    /// Downsamples to the working size while keeping float precision (highlights stay above 1.0).
    private static func decode(_ source: CGImageSource, maxPixelSize: Int = workingWidth) -> HDRPixels? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
            kCGImageSourceShouldAllowFloat: true,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return HDRPixels(image: image)
    }

    /// KeyShot `.hdz`: rebuild a Radiance header in front of its RGBE scanlines.
    static func imageSource(hdz url: URL) -> CGImageSource? {
        guard let data = try? Data(contentsOf: url), data.count > 64,
              data.starts(with: Array("hdzlux".utf8)) else { return nil }
        let width = data[16..<20].withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
        let height = data[20..<24].withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
        guard width > 0, height > 0 else { return nil }
        let header = Data("#?RADIANCE\nFORMAT=32-bit_rle_rgbe\n\n-Y \(height) +X \(width)\n".utf8)
        return CGImageSourceCreateWithData((header + data[64...]) as CFData, nil)
    }

    /// A small 8-bit preview for the environment picker.
    static func thumbnail(_ source: EnvironmentSource) -> CGImage? {
        switch source {
        case let .preset(preset):
            return preset.makeImage(width: 256)
        case let .file(url):
            switch url.pathExtension.lowercased() {
            case "klf":
                // KeyShot embeds a preview, stored without the sRGB curve; ours is closer to what you'll see.
                return KeyShotLighting.parse(url).flatMap { KeyShotLighting.render($0, width: 256).backdropImage() }
                    ?? KeyShotDocument.thumbnail(url, maxPixelSize: 256)
            case "hdz":
                return imageSource(hdz: url).flatMap { decode($0, maxPixelSize: 256)?.backdropImage() }
            default:
                return CGImageSourceCreateWithURL(url as CFURL, nil).flatMap { decode($0, maxPixelSize: 256)?.backdropImage() }
            }
        }
    }
}

private final class PixelsBox {
    let pixels: HDRPixels
    init(_ pixels: HDRPixels) { self.pixels = pixels }
}

/// The environments offered in the viewer: built-ins, the user's own HDRIs, and KeyShot's library.
@MainActor
@Observable
final class EnvironmentLibrary {
    struct Group: Identifiable {
        var id: String { title }
        let title: String
        let sources: [EnvironmentSource]
    }

    private(set) var custom: [URL] = []
    private(set) var keyShotGroups: [Group] = []
    private(set) var keyShotRoot: URL?
    @ObservationIgnored private let thumbnails = NSCache<NSString, CGImage>()

    private static let customKey = "CustomEnvironments"

    init() {
        let stored = (UserDefaults.standard.stringArray(forKey: Self.customKey) ?? []).map { URL(fileURLWithPath: $0) }
        custom = stored
        // File checks can hit macOS permission prompts (e.g. HDRIs in ~/Documents); keep them off the main thread.
        Task {
            let (existing, root) = await Task.detached(priority: .utility) {
                (stored.filter { FileManager.default.fileExists(atPath: $0.path) }, Self.detectKeyShotEnvironments())
            }.value
            custom = existing + custom.filter { !stored.contains($0) }
            keyShotRoot = root
            scanKeyShot()
        }
    }

    var builtIn: [EnvironmentSource] { EnvironmentPreset.allCases.map { .preset($0) } }

    /// `…/KeyShot Studio/Environments` (or an older KeyShot version's), if installed.
    nonisolated static func detectKeyShotEnvironments() -> URL? {
        let fm = FileManager.default
        for base in [URL(fileURLWithPath: "/Library/Application Support"), fm.homeDirectoryForCurrentUser.appendingPathComponent("Documents")] {
            let names = ((try? fm.contentsOfDirectory(atPath: base.path)) ?? []).sorted().reversed()
            for name in names where name.hasPrefix("KeyShot") && !name.contains("Viewer") {
                let url = base.appendingPathComponent(name).appendingPathComponent("Environments")
                if fm.fileExists(atPath: url.path) { return url }
            }
        }
        return nil
    }

    private func scanKeyShot() {
        guard let root = keyShotRoot else { return }
        Task {
            let groups = await Task.detached(priority: .utility) { () -> [Group] in
                var byFolder: [String: [URL]] = [:]
                let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil,
                                                                options: [.skipsHiddenFiles, .skipsPackageDescendants])
                while let url = enumerator?.nextObject() as? URL {
                    guard EnvironmentLoader.fileExtensions.contains(url.pathExtension.lowercased()) else { continue }
                    let relative = url.deletingLastPathComponent().pathComponents.dropFirst(root.pathComponents.count)
                    byFolder[relative.joined(separator: " › "), default: []].append(url)
                }
                return byFolder.sorted { $0.key.localizedLowercase < $1.key.localizedLowercase }.map { folder, urls in
                    Group(title: folder.isEmpty ? "KeyShot" : folder,
                          sources: urls.sorted { $0.lastPathComponent.localizedLowercase < $1.lastPathComponent.localizedLowercase }
                              .map { .file($0) })
                }
            }.value
            keyShotGroups = groups
        }
    }

    // MARK: Custom HDRIs

    func presentAddPanel() -> [EnvironmentSource] {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        panel.message = "Choose HDRI files (.hdr, .exr, KeyShot .hdz/.klf) or folders of them."
        panel.prompt = "Add"
        guard panel.runModal() == .OK else { return [] }
        return add(panel.urls)
    }

    /// Adds files (or every HDRI inside dropped folders). Returns the sources that were added.
    @discardableResult
    func add(_ urls: [URL]) -> [EnvironmentSource] {
        var added: [URL] = []
        for url in urls {
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else { continue }
            if isDir.boolValue {
                let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
                while let file = enumerator?.nextObject() as? URL {
                    if EnvironmentLoader.fileExtensions.contains(file.pathExtension.lowercased()) { added.append(file) }
                }
            } else if EnvironmentLoader.fileExtensions.contains(url.pathExtension.lowercased()) {
                added.append(url)
            }
        }
        for url in added where !custom.contains(url) { custom.append(url) }
        save()
        return added.map { .file($0) }
    }

    func remove(_ url: URL) {
        custom.removeAll { $0 == url }
        save()
    }

    private func save() {
        UserDefaults.standard.set(custom.map(\.path), forKey: Self.customKey)
    }

    // MARK: Thumbnails

    func cachedThumbnail(_ source: EnvironmentSource) -> CGImage? {
        thumbnails.object(forKey: source.id as NSString)
    }

    func thumbnail(_ source: EnvironmentSource) async -> CGImage? {
        if let cached = cachedThumbnail(source) { return cached }
        let image = await Task.detached(priority: .utility) { EnvironmentLoader.thumbnail(source) }.value
        if let image { thumbnails.setObject(image, forKey: source.id as NSString) }
        return image
    }
}
