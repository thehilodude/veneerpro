import CoreGraphics
import Foundation
import ImageIO
import simd

/// One `#define shader N type { ... }` block of a KeyShot `.mtl` file.
struct KeyShotShader {
    let id: Int
    let type: String
    /// Constant parameter values, split on spaces (`"color" 0.2 0.3 0.4`).
    var values: [String: [String]] = [:]
    /// Quoted string parameters (`"texture" "walnut.jpg"`).
    var strings: [String: String] = [:]
    /// Parameters driven by another shader (`"roughness" ! 5`).
    var links: [String: Int] = [:]
    /// Shader-id lists (`"shaders" [ ... ]`, used by composites).
    var lists: [String: [Int]] = [:]

    func number(_ key: String) -> Float? { values[key]?.first.flatMap(Float.init) }

    /// A reference to another shader. Some nodes write these as links (`"color" ! 3`), wrappers
    /// like `lux_bumpmap` as plain integers (`"shader" 5`).
    func ref(_ key: String) -> Int? { links[key] ?? values[key]?.first.flatMap { Int($0) } }

    func color(_ key: String) -> SIMD3<Float>? {
        guard let t = values[key], t.count >= 3, let r = Float(t[0]), let g = Float(t[1]), let b = Float(t[2]) else { return nil }
        return SIMD3(r, g, b)
    }
}

/// A parsed KeyShot material file (`//--lux:mat` text format).
struct KeyShotDocument {
    var name: String
    var shaders: [Int: KeyShotShader]
    var surfaceID: Int?

    static func isKeyShotFile(_ url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        let head = (try? handle.read(upToCount: 32)) ?? Data()
        return String(decoding: head, as: UTF8.self).hasPrefix("//--lux:mat")
    }

    static func load(_ url: URL) -> KeyShotDocument? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return parse(data, fallbackName: url.deletingPathExtension().lastPathComponent)
    }

    static func parse(_ data: Data, fallbackName: String) -> KeyShotDocument? {
        // Latin-1 maps every byte to one character, so embedded binary lists survive intact.
        let text = String(data: data, encoding: .isoLatin1) ?? ""
        var doc = KeyShotDocument(name: fallbackName, shaders: [:], surfaceID: nil)
        var current: KeyShotShader?
        var inMaterial = false

        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("#define shader") {
                let parts = line.split(separator: " ")
                current = KeyShotShader(id: parts.count >= 3 ? Int(parts[2]) ?? -1 : -1,
                                        type: parts.count >= 4 ? String(parts[3]) : "")
            } else if line.hasPrefix("#define material") {
                inMaterial = true
                if let open = line.firstIndex(of: "\""), let close = line[line.index(after: open)...].firstIndex(of: "\"") {
                    doc.name = Self.utf8(String(line[line.index(after: open)..<close]))
                }
            } else if line.hasPrefix("}") {
                if let c = current { doc.shaders[c.id] = c }
                current = nil
                inMaterial = false
            } else if inMaterial, line.hasPrefix("surface ") {
                doc.surfaceID = Int(line.dropFirst(8).trimmingCharacters(in: .whitespaces))
            } else if current != nil, line.hasPrefix("\"") {
                guard let close = line.dropFirst().firstIndex(of: "\"") else { continue }
                let key = String(line[line.index(after: line.startIndex)..<close])
                let rest = line[line.index(after: close)...].trimmingCharacters(in: CharacterSet(charactersIn: " ,"))
                if rest.hasPrefix("[") {
                    continue // binary id list: decoded from raw bytes below
                } else if rest.hasPrefix("!") {
                    current?.links[key] = Int(rest.dropFirst().trimmingCharacters(in: .whitespaces))
                } else if rest.hasPrefix("\"") {
                    current?.strings[key] = Self.utf8(rest.trimmingCharacters(in: CharacterSet(charactersIn: "\"")))
                } else {
                    current?.values[key] = rest.split(separator: " ").map(String.init)
                }
            }
        }
        decodeLists(in: [UInt8](data), into: &doc)
        return doc.shaders.isEmpty ? nil : doc
    }

    /// KeyShot writes id lists (`"shaders" [ … ]`) in binary: a few marker bytes, `i`, then
    /// little-endian int32s — a count followed by the ids. The payload can contain newline
    /// bytes, so it's read from the raw file rather than line by line.
    private static func decodeLists(in bytes: [UInt8], into doc: inout KeyShotDocument) {
        let defineShader = Array("#define shader ".utf8)
        var owner: Int?
        var p = 0
        while p < bytes.count {
            if bytes[p] == UInt8(ascii: "#"), bytes[p...].starts(with: defineShader) {
                var q = p + defineShader.count, id = 0
                while q < bytes.count, (48...57).contains(bytes[q]) { id = id * 10 + Int(bytes[q] - 48); q += 1 }
                owner = id
                p = q
                continue
            }
            // `"key" [` → read the list that follows.
            if bytes[p] == UInt8(ascii: "\""), let owner, let close = bytes[(p + 1)...].prefix(64).firstIndex(of: UInt8(ascii: "\"")),
               close + 2 < bytes.count, bytes[close + 1] == UInt8(ascii: " "), bytes[close + 2] == UInt8(ascii: "[") {
                let key = String(decoding: bytes[(p + 1)..<close], as: UTF8.self)
                if let i = bytes[(close + 3)...].prefix(8).firstIndex(of: UInt8(ascii: "i")) {
                    func int32(_ at: Int) -> Int? {
                        guard at + 4 <= bytes.count else { return nil }
                        return Int(UInt32(bytes[at]) | UInt32(bytes[at + 1]) << 8 | UInt32(bytes[at + 2]) << 16 | UInt32(bytes[at + 3]) << 24)
                    }
                    if let count = int32(i + 1), count > 0, count < 64 {
                        let ids = (0..<count).compactMap { int32(i + 5 + $0 * 4) }
                        doc.shaders[owner]?.lists[key] = ids
                    }
                }
                p = close + 1
                continue
            }
            p += 1
        }
    }

    /// Re-decodes a Latin-1 string as UTF-8 (for names and file paths with non-ASCII characters).
    private static func utf8(_ s: String) -> String {
        let bytes = s.unicodeScalars.map { UInt8(truncatingIfNeeded: $0.value) }
        return String(bytes: bytes, encoding: .utf8) ?? s
    }

    // MARK: Structure

    private static let wrapperLinks = ["shader", "base", "surface"]

    /// The surface shader, found by following wrappers (bump maps, composites) from `surface N`.
    /// Also returns the bump-map shader, if any.
    var surface: (bsdf: KeyShotShader, bump: KeyShotShader?)? {
        var bump: KeyShotShader?
        func resolve(_ id: Int?, depth: Int) -> KeyShotShader? {
            guard depth < 10, let id, let shader = shaders[id] else { return nil }
            switch shader.type {
            case "lux_bumpmap", "lux_bumpmap_add":
                if bump == nil { bump = shader }
                return resolve(shader.ref("shader"), depth: depth + 1)
            case "lux_composite":
                // Layers (labels, decals) come first; take the first layer that is a real surface.
                for layer in shader.lists["shaders"] ?? [] {
                    if let surface = resolve(layer, depth: depth + 1) { return surface }
                }
                return nil
            default:
                if KeyShotMaterial.mapping(for: shader.type) != nil { return shader }
                return Self.wrapperLinks.lazy.compactMap { resolve(shader.ref($0), depth: depth + 1) }.first
            }
        }
        if let bsdf = resolve(surfaceID ?? shaders.keys.max(), depth: 0) { return (bsdf, bump) }
        // No usable chain: fall back to the first shader that looks like a surface.
        if let bsdf = shaders.values.sorted(by: { $0.id < $1.id }).first(where: { KeyShotMaterial.mapping(for: $0.type) != nil }) {
            return (bsdf, bump)
        }
        return nil
    }

    /// Every texture file name referenced by the material.
    var textureFileNames: [String] {
        shaders.values.compactMap { $0.strings["texture"] }.filter { !$0.isEmpty }
    }

    /// Whether a shader chain reads an image texture.
    func containsTexture(_ id: Int, depth: Int = 0) -> Bool {
        guard depth < 8, let shader = shaders[id] else { return false }
        if shader.strings["texture"] != nil { return true }
        return shader.links.values.contains { containsTexture($0, depth: depth + 1) }
    }

    /// Average linear color of a shader's color parameters, following links a few levels deep.
    /// Used to flatten procedurals (wood, noise, brushed metal...) into one representative color.
    func averageColor(of id: Int, depth: Int = 0) -> SIMD3<Float>? {
        guard depth < 4, let shader = shaders[id] else { return nil }
        // Prefer a procedural's main colors (wood seasons, the two pattern colors) over accents
        // like knot or outline colors; fall back to any color-like parameter.
        let groups: [[String]] = [
            ["winter", "spring", "summer", "fall"],
            ["color1", "color2", "color_1", "color_2", "warp_color", "weft_color"],
            ["color", "diffuse", "base", "base_color", "albedo", "source", "background", "transmission"],
        ]
        var colors = groups.lazy.map { $0.compactMap { shader.color($0) } }.first { !$0.isEmpty } ?? []
        if colors.isEmpty {
            colors = shader.values.keys.sorted()
                .filter { $0.contains("color") && !$0.contains("outline") && !$0.contains("default") && !$0.contains("knot") }
                .compactMap { shader.color($0) }
        }
        if !colors.isEmpty { return colors.reduce(.zero, +) / Float(colors.count) }
        for link in shader.links.values.sorted() {
            if let c = averageColor(of: link, depth: depth + 1) { return c }
        }
        return nil
    }

    // MARK: Binary format (KeyShot 14+)

    /// KeyShot 14 can save materials in a binary format (`//--lux:mat:001--`) whose shader graph
    /// isn't documented. Its texture paths are still stored as plain strings.
    static func isBinaryFormat(_ url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        return (try? handle.read(upToCount: 17)).map { String(decoding: $0, as: UTF8.self) } == "//--lux:mat:001--"
    }

    /// Image file names referenced by a binary-format material.
    static func binaryTextureNames(_ url: URL) -> [String] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        let bytes = [UInt8](data)
        var names: [String] = []
        var run: [UInt8] = []
        func flush() {
            defer { run.removeAll(keepingCapacity: true) }
            let text = String(decoding: run, as: UTF8.self)
            // Paths are followed directly by the next field name ("…_Color.pngtexture"), so cut at the extension.
            guard let match = text.range(of: #"[^/\\]+\.(png|jpe?g|tiff?|exr|tga|bmp|webp)"#, options: [.regularExpression, .caseInsensitive])
            else { return }
            names.append(String(text[match]))
        }
        for byte in bytes {
            if byte >= 0x20 && byte < 0x7F || byte >= 0x80 { run.append(byte) } else if !run.isEmpty { flush() }
        }
        if !run.isEmpty { flush() }
        return Array(Set(names)).sorted()
    }

    // MARK: Embedded thumbnail

    /// The preview KeyShot embeds as hex on the `icon` line (PNG or JPEG).
    static func thumbnail(_ url: URL, maxPixelSize: Int = 320) -> CGImage? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let bytes = [UInt8](data)
        guard let iconStart = bytes.firstRange(of: Array("\nicon ".utf8))?.upperBound else { return rawImage(in: bytes, maxPixelSize: maxPixelSize) }
        var end = iconStart
        while end < bytes.count, bytes[end] != UInt8(ascii: "\n") { end += 1 }
        let hexLine = bytes[iconStart..<end]
        // Skip the type prefix (e.g. "bX3…") to the image's magic number.
        let magics = [Array("89504e47".utf8), Array("ffd8ff".utf8)]
        guard let start = magics.compactMap({ hexLine.firstRange(of: $0)?.lowerBound }).min() else { return nil }
        var image = [UInt8]()
        image.reserveCapacity((end - start) / 2)
        var p = start
        func nibble(_ c: UInt8) -> UInt8? {
            switch c {
            case 48...57: c - 48
            case 97...102: c - 87
            case 65...70: c - 55
            default: nil
            }
        }
        while p + 1 < end, let hi = nibble(bytes[p]), let lo = nibble(bytes[p + 1]) {
            image.append(hi << 4 | lo)
            p += 2
        }
        return decode(Data(image), maxPixelSize: maxPixelSize)
    }

    /// Binary-format files embed the preview as raw JPEG/PNG bytes.
    private static func rawImage(in bytes: [UInt8], maxPixelSize: Int) -> CGImage? {
        let jpeg = bytes.firstRange(of: [0xFF, 0xD8, 0xFF])?.lowerBound
        let png = bytes.firstRange(of: [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])?.lowerBound
        guard let start = [jpeg, png].compactMap({ $0 }).min() else { return nil }
        // ImageIO stops at the image's own end marker, so trailing bytes are harmless.
        return decode(Data(bytes[start...]), maxPixelSize: maxPixelSize)
    }

    private static func decode(_ data: Data, maxPixelSize: Int) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                        kCGImageSourceThumbnailMaxPixelSize: maxPixelSize]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }
}

/// A KeyShot material reduced to UsdPreviewSurface terms.
/// KeyShot shading is far richer than USD's, so this is an approximation.
struct KeyShotMaterial {
    enum Family {
        case metal, glass, paint, plastic, cloth, emissive, other
    }

    /// How one KeyShot surface type maps onto PBR inputs.
    struct Mapping {
        var family: Family
        var colorKeys: [String]
        var roughnessKeys: [String] = ["roughness"]
        var metallic: Float = 0
        var opacity: Float = 1
        var clearcoat: Float = 0
        var defaultRoughness: Float?
        /// The `color` parameter is only a tint (the look comes from presets, thin films or
        /// encrypted data), so the color is sampled from KeyShot's preview render instead.
        var colorFromPreview = false
    }

    static func mapping(for type: String) -> Mapping? {
        switch type {
        case "lux_metal", "lux_anisotropic":
            Mapping(family: .metal, colorKeys: ["color"], metallic: 1)
        case "lux_metal_coated":
            Mapping(family: .metal, colorKeys: ["color"], metallic: 1, clearcoat: 1, colorFromPreview: true)
        case "lux_multilayer_thinfilm", "lux_thin_film":
            Mapping(family: .metal, colorKeys: ["color"], metallic: 0.8, defaultRoughness: 0.1)
        case "metallic_paint", "lux_metallic_paint":
            Mapping(family: .paint, colorKeys: ["base", "color"], roughnessKeys: ["metal_roughness", "roughness"],
                    metallic: 0.5, clearcoat: 1)
        case "dupont_paint", "axalta_paint":
            Mapping(family: .paint, colorKeys: [], clearcoat: 1, colorFromPreview: true)
        case "lux_paint":
            Mapping(family: .paint, colorKeys: ["color", "base"], clearcoat: 1)
        case "lux_generic":
            Mapping(family: .other, colorKeys: ["base_color"])
        case "lux_plastic", "lux_plastic_simple", "lux_advanced", "lux_rough_plastic", "lux_translucent",
             "lux_translucent_medium", "lux_skin", "lux_leather":
            Mapping(family: .plastic, colorKeys: ["diffuse", "color"])
        case "lux_cloudy_plastic", "lux_plastic_cloudy":
            Mapping(family: .plastic, colorKeys: ["transmission", "diffuse"], opacity: 0.6)
        case "lux_diffuse", "lux_flat":
            Mapping(family: .other, colorKeys: ["diffuse", "color"], defaultRoughness: 1)
        case "lux_toon":
            Mapping(family: .other, colorKeys: ["color"], defaultRoughness: 1)
        case "lux_fuzz", "lux_velvet", "lux_cloth":
            Mapping(family: .cloth, colorKeys: ["color", "diffuse"], defaultRoughness: 0.9)
        case "lux_real_cloth":
            Mapping(family: .cloth, colorKeys: ["warp_color", "weft_color"],
                    roughnessKeys: ["warp_roughness", "weft_roughness"], defaultRoughness: 0.8)
        case "lux_glass", "lux_glass_simple", "lux_solid_glass", "lux_window_glass", "lux_dielectric":
            Mapping(family: .glass, colorKeys: ["color", "transmission"], opacity: 0.2, defaultRoughness: 0)
        case "lux_gem":
            Mapping(family: .glass, colorKeys: ["color", "transmission"], opacity: 0.35, defaultRoughness: 0)
        case "lux_liquid":
            Mapping(family: .glass, colorKeys: ["color", "transmission_out"], opacity: 0.3, defaultRoughness: 0)
        case "lux_scattering_medium":
            Mapping(family: .glass, colorKeys: ["albedo", "transmission"], opacity: 0.5)
        case "lux_emissive", "lux_light_area", "lux_ies_light", "lux_spotlight", "lux_mesh_light", "lux_point_light":
            Mapping(family: .emissive, colorKeys: ["color"])
        case "lux_moldtech_plastic", "lux_translucent2":
            Mapping(family: .plastic, colorKeys: ["diffuse", "color"])
        case "lux_thinfilm":
            Mapping(family: .metal, colorKeys: ["color"], metallic: 0.8, defaultRoughness: 0.1)
        case "bsdf_axf_carpaint":
            Mapping(family: .paint, colorKeys: [], metallic: 0.4, clearcoat: 1, defaultRoughness: 0.3, colorFromPreview: true)
        case "lux_constant":
            Mapping(family: .other, colorKeys: ["color"], defaultRoughness: 1)
        case "lux_openpbr":
            Mapping(family: .other, colorKeys: ["base_color", "color"])
        case let type where (type.hasPrefix("lux_") || type.hasPrefix("bsdf_")) && !utilityTypes.contains(where: type.hasPrefix):
            // Unknown surface (measured AxF, cutaway, x-ray...): the color comes from the preview render.
            Mapping(family: .other, colorKeys: ["color", "diffuse", "base_color", "base"])
        default:
            nil
        }
    }

    /// Texture, pattern and wrapper nodes that are never the surface itself.
    private static let utilityTypes = [
        "lux_bumpmap", "lux_displace", "lux_composite", "lux_color_adjust", "lux_noise", "lux_fractal_noise",
        "lux_mesh", "lux_marble", "lux_wood", "lux_brushed", "lux_worley", "lux_scratches", "lux_color_gradient",
        "lux_color_blend", "lux_edge_mask", "lux_label", "lux_weave", "lux_flakes", "lux_leather_tex", "lux_camouflage",
        "lux_const", "lux_occlusion", "lux_curvature", "lux_granite", "lux_cell", "lux_spots", "lux_tiles",
    ]

    var shaderType: String
    var family: Family
    /// sRGB base color; nil when KeyShot doesn't expose one (e.g. encrypted Axalta/DuPont paints).
    var color: SIMD3<Float>?
    /// True when `color` was flattened from a procedural.
    var colorIsApproximate = false
    var roughness: Float?
    var metallic: Float
    var opacity: Float
    var clearcoat: Float
    var clearcoatRoughness: Float = 0.03
    var emissive: SIMD3<Float>?
    /// Shader ids feeding these inputs, for translating texture graphs into nodes.
    var colorLink: Int?
    var roughnessLink: Int?
    var opacityLink: Int?
    /// Texture shader used as a tangent-space normal map by a bump-map wrapper.
    var normalMapLink: Int?

    func isLinked(_ key: String) -> Bool {
        switch key {
        case "color", "diffuse", "base", "transmission": colorLink != nil
        case "roughness": roughnessLink != nil
        default: false
        }
    }

    static func load(_ url: URL) -> KeyShotMaterial? {
        KeyShotDocument.load(url).flatMap(KeyShotMaterial.init(document:))
    }

    /// Linear base reflectance (F0) of KeyShot's measured metal presets, from published
    /// physically based values. Preset numbers were matched against KeyShot's material names.
    static let metalPresets: [Int: SIMD3<Float>] = [
        1: [1.000, 0.766, 0.336],   // Gold
        2: [0.955, 0.638, 0.538],   // Copper
        3: [0.913, 0.922, 0.924],   // Aluminum
        4: [0.542, 0.497, 0.449],   // Titanium
        5: [0.972, 0.960, 0.915],   // Silver
        6: [0.660, 0.609, 0.526],   // Nickel
        7: [0.550, 0.556, 0.554],   // Chrome
        8: [0.664, 0.824, 0.850],   // Zinc
        9: [0.562, 0.565, 0.578],   // Iron
        10: [0.673, 0.637, 0.585],  // Platinum
        11: [0.910, 0.778, 0.423],  // Brass
        12: [0.800, 0.800, 0.800],  // Magnesium
        13: [0.610, 0.590, 0.560],  // Niobium
    ]

    init?(document doc: KeyShotDocument) {
        guard let (bsdf, bump) = doc.surface, let map = Self.mapping(for: bsdf.type) else { return nil }
        shaderType = bsdf.type
        family = map.family
        metallic = map.metallic
        opacity = map.opacity
        clearcoat = map.clearcoat

        // Color: constant(s), or the average of whatever procedural drives it.
        let constantColors = map.colorKeys.compactMap { key in bsdf.links[key] == nil ? bsdf.color(key) : nil }
        colorLink = map.colorKeys.lazy.compactMap { bsdf.links[$0] }.first
        if let link = colorLink {
            // Texture chains supply their own color; only procedurals are flattened.
            if !doc.containsTexture(link), let average = doc.averageColor(of: link) {
                color = average.linearToSRGB
                colorIsApproximate = true
            }
        } else if !constantColors.isEmpty {
            color = (constantColors.reduce(.zero, +) / Float(constantColors.count)).linearToSRGB
        }

        if map.colorFromPreview {
            color = nil
            colorLink = nil
        }

        // KeyShot's roughness is on a squared (GGX alpha) scale; UsdPreviewSurface's is perceptual.
        // KeyShot's own USD export writes √roughness (0.1 → 0.316), so do the same.
        roughnessLink = map.roughnessKeys.lazy.compactMap { bsdf.links[$0] }.first
        let roughnessValues = map.roughnessKeys.compactMap { bsdf.number($0) }
        roughness = roughnessValues.isEmpty ? map.defaultRoughness
            : sqrtf(max(0, roughnessValues.reduce(0, +) / Float(roughnessValues.count)))

        switch bsdf.type {
        case "lux_metal_coated":
            // The base metal comes from a measured preset; `color` only applies to the custom preset 0.
            // Only "coated" metals (anodized) get a clearcoat, and their thin-film color can't be
            // expressed in USD, so those keep the color sampled from KeyShot's preview.
            let coated = bsdf.values["coated"]?.first == "on"
            clearcoat = coated ? 1 : 0
            if !coated {
                let preset = bsdf.number("preset").map { Int($0) } ?? 0
                if let metal = Self.metalPresets[preset] {
                    color = metal.linearToSRGB
                } else if let custom = bsdf.color("color") {
                    color = custom.linearToSRGB
                }
            }
        case "lux_generic":
            metallic = bsdf.number("metallic") ?? 0
            clearcoat = bsdf.number("clearcoat") ?? 0
            clearcoatRoughness = sqrtf(bsdf.number("clearcoat_roughness") ?? 0.001)
        case "metallic_paint", "lux_metallic_paint":
            metallic = min(1, (bsdf.number("metal_coverage") ?? 0.5)) * 0.6
            clearcoatRoughness = sqrtf(bsdf.number("roughness") ?? 0.001)
        case "lux_plastic":
            if let t = bsdf.color("specular_transmission"), t.max() > 0 { opacity = 1 - min(0.8, t.max() * 0.8) }
        case "lux_glass_simple":
            if let transparency = bsdf.number("transparency") { opacity = max(0.1, 1 - transparency * 0.85) }
        default:
            break
        }
        if family == .metal || family == .paint, clearcoat > 0, let r = roughness, bsdf.type == "lux_metal_coated" {
            clearcoatRoughness = min(r, 0.05)
        }

        // Glass in USDZ can't refract or absorb, so derive a look from KeyShot's transmission tint:
        // colored glass keeps its hue and is mostly opaque (so the color doesn't wash out against
        // what's behind it); neutral glass darkens with its transmission (black glass → near-black,
        // clear glass → white and see-through).
        if family == .glass, !constantColors.isEmpty {
            let tint = constantColors.reduce(.zero, +) / Float(constantColors.count)
            let transmission = min(1, simd_dot(tint, SIMD3(0.2126, 0.7152, 0.0722)))
            let saturation = tint.max() > 0 ? (tint.max() - tint.min()) / tint.max() : 0
            if saturation > 0.15 {
                color = tint.linearToSRGB
                opacity = max(opacity, 0.75)
            } else {
                color = (tint * transmission).linearToSRGB
                opacity = max(opacity, 1 - transmission * (1 - opacity))
            }
        }

        // KeyShot "alpha" is opacity (1 = opaque) on most surfaces.
        if let alpha = bsdf.number("alpha"), alpha < 1 { opacity = min(opacity, max(0, alpha)) }
        opacityLink = bsdf.links["alpha"]

        if family == .emissive {
            emissive = color ?? SIMD3(repeating: 1)
            color = SIMD3(repeating: 0.05)
            colorLink = nil
        }

        // A bump wrapper whose source texture is in normal-map mode becomes a normal map.
        if let bump, let source = bump.ref("bumpmap"), let texture = doc.shaders[source],
           texture.strings["texture"] != nil, texture.number("bump_mode") == 1 {
            normalMapLink = source
        }
    }
}

extension SIMD3 where Scalar == Float {
    /// Linear → sRGB transfer (KeyShot stores linear colors; graph colors are sRGB).
    var linearToSRGB: SIMD3<Float> {
        func encode(_ x: Float) -> Float {
            let v = Swift.max(0, Swift.min(1, x))
            return v <= 0.0031308 ? v * 12.92 : 1.055 * powf(v, 1 / 2.4) - 0.055
        }
        return SIMD3(encode(x), encode(y), encode(z))
    }
}
