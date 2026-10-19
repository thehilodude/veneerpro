import AppKit
import CoreImage
import ImageIO
import ModelIO
import UniformTypeIdentifiers

/// An image used by an Image Texture node. Keeps the original encoded bytes so an
/// unmodified texture can be written into the USDZ untouched.
final class TextureRef: Identifiable, Hashable {
    let id = UUID()
    let name: String
    let cgImage: CGImage
    /// Original file bytes (PNG/JPEG) if available, otherwise a PNG encoding.
    let data: Data
    let fileExtension: String

    var size: CGSize { CGSize(width: cgImage.width, height: cgImage.height) }

    private let lock = NSLock()
    private var decoded: TexturePixels?

    /// Decoded pixels for the CPU node evaluator, created on first use.
    var pixels: TexturePixels {
        lock.lock()
        defer { lock.unlock() }
        if let decoded { return decoded }
        let result = TexturePixels(cgImage)
        decoded = result
        return result
    }

    init(name: String, cgImage: CGImage, data: Data, fileExtension: String) {
        self.name = name
        self.cgImage = cgImage
        self.data = data
        self.fileExtension = fileExtension
    }

    static func == (lhs: TextureRef, rhs: TextureRef) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }

    static func load(url: URL) -> TextureRef? {
        // Textures inside a .usdz arrive as `package.usdz?offset=…&size=…`.
        let packaged = PackagedFile(url)
        let fileURL = packaged?.entryName.map { URL(fileURLWithPath: $0) } ?? url
        guard let data = packaged?.read() ?? (packaged == nil ? try? Data(contentsOf: url) : nil),
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        let name = packaged != nil && packaged?.entryName == nil
            ? "texture_\(packaged!.offset)"
            : fileURL.deletingPathExtension().lastPathComponent
        var ext = fileURL.pathExtension.lowercased()
        if packaged != nil, packaged?.entryName == nil {
            // No directory entry: sniff the format from the bytes.
            ext = data.starts(with: [0x89, 0x50, 0x4E, 0x47]) ? "png" : data.starts(with: [0xFF, 0xD8]) ? "jpg" : ""
        }
        // USDZ only allows PNG and JPEG; re-encode anything else.
        if ext == "png" || ext == "jpg" || ext == "jpeg" {
            return TextureRef(name: name, cgImage: image, data: data, fileExtension: ext == "jpeg" ? "jpg" : ext)
        }
        return from(cgImage: image, name: name)
    }

    /// Loads an image, downsampling it so its longest side is at most `maxPixelSize`.
    /// Images already within the limit are kept byte-for-byte.
    static func load(url: URL, maxPixelSize: Int?) -> TextureRef? {
        guard let maxPixelSize,
              let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = props[kCGImagePropertyPixelWidth] as? Int,
              let height = props[kCGImagePropertyPixelHeight] as? Int,
              max(width, height) > maxPixelSize else { return load8Bit(url: url) }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
            kCGImageSourceCreateThumbnailWithTransform: false,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        let name = url.deletingPathExtension().lastPathComponent
        let isJPEG = ["jpg", "jpeg"].contains(url.pathExtension.lowercased())
        if isJPEG, let jpeg = image.jpegData() {
            return TextureRef(name: name, cgImage: image, data: jpeg, fileExtension: "jpg")
        }
        return from(cgImage: image, name: name)
    }

    /// Large opaque PNGs (photographic color, roughness and normal maps) re-encoded as high-quality
    /// JPEG — typically 4–6× smaller in the USDZ. Small or transparent images are returned unchanged.
    func compactedForAR(threshold: Int = 1_500_000) -> TextureRef {
        let opaque = [.none, .noneSkipFirst, .noneSkipLast].contains(cgImage.alphaInfo)
        guard fileExtension == "png", data.count > threshold, opaque, let jpeg = cgImage.jpegData(quality: 0.92),
              jpeg.count < data.count else { return self }
        return TextureRef(name: name, cgImage: cgImage, data: jpeg, fileExtension: "jpg")
    }

    /// Loads an image, converting 16/32-bit sources to 8 bits per channel. High bit-depth maps
    /// (common for normal maps) are several times larger in a USDZ with no visible benefit in AR.
    private static func load8Bit(url: URL) -> TextureRef? {
        guard let texture = load(url: url) else { return nil }
        let image = texture.cgImage
        guard image.bitsPerComponent > 8 else { return texture }
        let hasAlpha = ![.none, .noneSkipFirst, .noneSkipLast].contains(image.alphaInfo)
        guard let ctx = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: image.colorSpace?.model == .rgb ? image.colorSpace! : CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: (hasAlpha ? CGImageAlphaInfo.premultipliedLast : .noneSkipLast).rawValue) else { return texture }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        guard let converted = ctx.makeImage() else { return texture }
        return from(cgImage: converted, name: texture.name) ?? texture
    }

    static func from(cgImage: CGImage, name: String) -> TextureRef? {
        guard let png = cgImage.pngData() else { return nil }
        return TextureRef(name: name, cgImage: cgImage, data: png, fileExtension: "png")
    }

    private static let sharedLock = NSLock()
    private static let shared = NSMapTable<NSString, TextureRef>.strongToWeakObjects()

    /// Loads `url` once and hands out the same TextureRef while it's in use, so a file referenced
    /// by several materials is decoded once and exported once.
    static func loadShared(url: URL) -> TextureRef? {
        let key = url.absoluteString as NSString
        sharedLock.lock()
        defer { sharedLock.unlock() }
        if let existing = shared.object(forKey: key) { return existing }
        guard let texture = load(url: url) else { return nil }
        shared.setObject(texture, forKey: key)
        return texture
    }

    /// Builds a texture from whatever SceneKit put into `SCNMaterialProperty.contents`.
    static func from(contents: Any?, fallbackName: String) -> TextureRef? {
        switch contents {
        case let url as URL:
            return loadShared(url: url)
        case let path as String:
            let url = path.hasPrefix("file:") ? URL(string: path) : URL(fileURLWithPath: path)
            return url.flatMap(loadShared(url:))
        case let image as NSImage:
            guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
            return from(cgImage: cg, name: image.name() ?? fallbackName)
        case let mdl as MDLTexture:
            guard let cg = mdl.imageFromTexture()?.takeUnretainedValue() else { return nil }
            return from(cgImage: cg, name: mdl.name.isEmpty ? fallbackName : mdl.name)
        default:
            if let contents, CFGetTypeID(contents as CFTypeRef) == CGImage.typeID {
                return from(cgImage: contents as! CGImage, name: fallbackName)
            }
            return nil
        }
    }
}

extension CGImage {
    func pngData() -> Data? { encoded(as: .png, options: [:]) }

    func jpegData(quality: Double = 0.92) -> Data? {
        encoded(as: .jpeg, options: [kCGImageDestinationLossyCompressionQuality: quality])
    }

    private func encoded(as type: UTType, options: [CFString: Any]) -> Data? {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, self, options as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return data as Data
    }
}
