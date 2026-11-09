import Foundation
import ImageIO
import SceneKit
import simd

/// Serializes a model and its evaluated material graphs to a USDA layer plus texture files.
final class USDWriter {
    struct MaterialJob {
        /// All SceneKit materials bound to this one USD material.
        let materials: [SCNMaterial]
        let name: String
        let result: MaterialResult
        let evaluator: GraphEvaluator
    }

    private(set) var files: [USDZPackager.Entry] = []
    private var text = ""
    private var depth = 0
    private var materialPaths: [ObjectIdentifier: String] = [:]
    private var passthroughFiles: [TextureRef: String] = [:]
    private var usedFileNames: Set<String> = []
    private let rootName: String

    /// Which parts of the scene to write. The live Vision Pro preview keeps geometry and materials
    /// in separate layers so material edits only re-send the (small) material layer.
    enum Part { case all, materials, geometry }
    var part: Part = .all
    /// Layers composed under this one (e.g. the geometry layer under the material layer).
    var subLayers: [String] = []
    /// Names baked textures after their content, so a re-bake that changed nothing keeps its file name
    /// and a changed one never collides with a viewer's cached older file (used by the live preview).
    var contentHashedTextures = false
    /// Reuses earlier bakes of the same evaluator (an unchanged material) across writes.
    var bakeCache: BakeCache?
    /// When set, source textures larger than this are downscaled (for previews; exports keep full size).
    var maxTextureSize: Int?
    /// Colorways written as a "Colorway" variant set on the default prim, which AR Quick Look shows as a
    /// picker. Each variant's jobs line up with `materials` (same order); the first variant is the default.
    var colorwayVariants: [(name: String, materials: [MaterialJob])] = []
    /// Poses written as a "Pose" variant set: per variant, the transform and visibility of every object
    /// in `poseControlled`. The first variant is the default.
    var poseVariants: [(name: String, states: [ObjectIdentifier: (transform: simd_float4x4, hidden: Bool)])] = []
    /// Objects some pose moves or hides. USD ranks a prim's own opinions above its variants', so these
    /// get their transform and visibility only from the variants, never in the base scene.
    var poseControlled: Set<ObjectIdentifier> = []
    /// False writes hidden objects as visible (see `ExportOptions.hiddenAsVisible`).
    var writesVisibility = true
    /// Each written node's prim name, for the pose overrides.
    private var primNames: [ObjectIdentifier: String] = [:]

    final class BakeCache: @unchecked Sendable {
        fileprivate var entries: [String: USDZPackager.Entry] = [:]
    }

    init(rootName: String) {
        self.rootName = USDWriter.identifier(rootName, fallback: "Model")
    }

    func write(root: SCNNode, materials: [MaterialJob], metadata: StageMetadata) -> String {
        line("#usda 1.0")
        line("(")
        indented {
            line("customLayerData = {")
            indented {
                line("string creator = \(Self.quoted("Veneer Pro"))")
                if !metadata.copyright.isEmpty { line("string copyright = \(Self.quoted(metadata.copyright))") }
            }
            line("}")
            line("defaultPrim = \(Self.quoted(rootName))")
            line("metersPerUnit = \(Self.number(metadata.metersPerUnit))")
            line("upAxis = \(Self.quoted(metadata.upAxis))")
            if !subLayers.isEmpty {
                line("subLayers = [\(subLayers.map { "@\($0)@" }.joined(separator: ", "))]")
            }
        }
        line(")")
        line("")
        var variantNames: Set<String> = []
        let variants = colorwayVariants.map { (Self.unique(Self.identifier($0.name, fallback: "Colorway"), in: &variantNames), $0.materials) }
        var poseNames: Set<String> = []
        let poses = poseVariants.map { (Self.unique(Self.identifier($0.name, fallback: "Pose"), in: &poseNames), $0.states) }
        line("def Xform \(Self.quoted(rootName)) (")
        indented {
            line("assetInfo = {")
            indented { line("string name = \(Self.quoted(rootName))") }
            line("}")
            line("kind = \"component\"")
            var sets: [(String, String)] = []
            if let first = variants.first { sets.append(("Colorway", first.0)) }
            if let first = poses.first, part != .materials { sets.append(("Pose", first.0)) }
            if !sets.isEmpty {
                line("variants = {")
                indented { for (set, choice) in sets { line("string \(set) = \(Self.quoted(choice))") } }
                line("}")
                line("prepend variantSets = [\(sets.map { Self.quoted($0.0) }.joined(separator: ", "))]")
            }
        }
        line(")")
        // Material prim paths are needed for bindings even when only geometry is written.
        var names: Set<String> = []
        let named: [(MaterialJob, String, String)] = materials.map { job in
            let name = Self.unique(Self.identifier(job.name, fallback: "Material"), in: &names)
            let path = "/\(rootName)/Materials/\(name)"
            for material in job.materials { materialPaths[ObjectIdentifier(material)] = path }
            return (job, name, path)
        }
        block {
            if !named.isEmpty && part != .geometry && variants.isEmpty {
                line("def Scope \"Materials\"")
                block {
                    for (job, name, path) in named { writeMaterial(job, name: name, path: path) }
                }
            }
            if !variants.isEmpty {
                // The materials live in the variants: every variant defines the same material paths,
                // so the meshes' bindings pick up whichever colorway is selected.
                line("def Scope \"Materials\"")
                block {}
                line("variantSet \"Colorway\" = {")
                indented {
                    for (variant, jobs) in variants {
                        line(Self.quoted(variant) + " {")
                        indented {
                            line("over \"Materials\"")
                            block {
                                for (i, (_, name, path)) in named.enumerated() where i < jobs.count {
                                    writeMaterial(jobs[i], name: name, path: path)
                                }
                            }
                        }
                        line("}")
                    }
                }
                line("}")
            }
            if part != .materials {
                var siblingNames: Set<String> = ["Materials"]
                for child in root.childNodes {
                    writeNode(child, siblingNames: &siblingNames)
                }
                if !poses.isEmpty {
                    line("variantSet \"Pose\" = {")
                    indented {
                        for (pose, states) in poses {
                            line(Self.quoted(pose) + " {")
                            indented { for child in root.childNodes { writeOverrides(child, states: states) } }
                            line("}")
                        }
                    }
                    line("}")
                }
            }
        }
        return text
    }

    // MARK: - Materials

    private struct TextureKey: Hashable {
        let file: String
        let colorSpace: String
        let isNormal: Bool
    }

    private func writeMaterial(_ job: MaterialJob, name: String, path: String) {
        typealias C = MaterialGraph.Channel
        let result = job.result
        var shaders: [TextureKey: String] = [:]
        var textureBlocks: [(name: String, key: TextureKey)] = []
        var inputs: [String] = []

        func textureShader(_ value: GraphValue, channel: C) -> (shader: String, output: String) {
            let colorSpace = channel == .baseColor || channel == .emissive ? "sRGB" : "raw"
            let file: String
            let output: String
            if let passthrough = value.passthrough {
                file = passthroughFile(passthrough.texture)
                output = channel.isColor ? "rgb" : passthrough.channel.outputName
            } else {
                file = bakedFile(value, material: name, channel: channel, evaluator: job.evaluator)
                output = channel.isColor ? "rgb" : "r"
            }
            let key = TextureKey(file: file, colorSpace: colorSpace, isNormal: channel == .normal)
            let shader: String
            if let existing = shaders[key] {
                shader = existing
            } else {
                shader = "Texture\(shaders.count)"
                shaders[key] = shader
                textureBlocks.append((shader, key))
            }
            return (shader, output)
        }

        let usdInputs: [(C, String, String)] = [
            (.baseColor, "color3f", "diffuseColor"), (.metallic, "float", "metallic"),
            (.roughness, "float", "roughness"), (.normal, "normal3f", "normal"),
            (.emissive, "color3f", "emissiveColor"), (.opacity, "float", "opacity"),
            (.occlusion, "float", "occlusion"), (.clearcoat, "float", "clearcoat"),
            (.clearcoatRoughness, "float", "clearcoatRoughness"),
        ]
        for (channel, type, input) in usdInputs {
            if (channel == .normal || channel == .occlusion) && !result.isConnected(channel) { continue }
            switch result[channel] {
            case let .constant(c):
                if channel == .normal { continue }
                if channel.isColor {
                    // USD color constants are linear; graph colors are sRGB-encoded.
                    let linear = SIMD3(Self.srgbToLinear(c.x), Self.srgbToLinear(c.y), Self.srgbToLinear(c.z))
                    inputs.append("\(type) inputs:\(input) = (\(Self.number(linear.x)), \(Self.number(linear.y)), \(Self.number(linear.z)))")
                } else {
                    inputs.append("\(type) inputs:\(input) = \(Self.number(simd_clamp(c.x, 0, 1)))")
                }
            case .image:
                let (shader, output) = textureShader(result[channel], channel: channel)
                inputs.append("\(type) inputs:\(input).connect = <\(path)/\(shader).outputs:\(output)>")
            }
        }

        line("def Material \(Self.quoted(name))")
        block {
            line("token outputs:surface.connect = <\(path)/PreviewSurface.outputs:surface>")
            line("")
            line("def Shader \"PreviewSurface\"")
            block {
                line("uniform token info:id = \"UsdPreviewSurface\"")
                inputs.forEach(line)
                line("int inputs:useSpecularWorkflow = 0")
                line("token outputs:surface")
            }
            guard !textureBlocks.isEmpty else { return }
            line("")
            line("def Shader \"UVReader\"")
            block {
                line("uniform token info:id = \"UsdPrimvarReader_float2\"")
                line("string inputs:varname = \"st\"")
                line("float2 outputs:result")
            }
            for (shader, key) in textureBlocks {
                line("")
                line("def Shader \(Self.quoted(shader))")
                block {
                    line("uniform token info:id = \"UsdUVTexture\"")
                    line("asset inputs:file = @\(key.file)@")
                    line("float2 inputs:st.connect = <\(path)/UVReader.outputs:result>")
                    line("token inputs:sourceColorSpace = \(Self.quoted(key.colorSpace))")
                    line("token inputs:wrapS = \"repeat\"")
                    line("token inputs:wrapT = \"repeat\"")
                    if key.isNormal {
                        line("float4 inputs:scale = (2, 2, 2, 1)")
                        line("float4 inputs:bias = (-1, -1, -1, 0)")
                    }
                    line("float3 outputs:rgb")
                    line("float outputs:r")
                    line("float outputs:g")
                    line("float outputs:b")
                    line("float outputs:a")
                }
            }
        }
    }

    private func passthroughFile(_ texture: TextureRef) -> String {
        if let existing = passthroughFiles[texture] { return existing }
        let file = uniqueFileName(Self.identifier(texture.name, fallback: "texture"), ext: texture.fileExtension)
        let data = maxTextureSize.flatMap { Self.downscaled(texture.data, maxPixelSize: $0, jpeg: ["jpg", "jpeg"].contains(texture.fileExtension.lowercased())) }
        files.append(USDZPackager.Entry(path: file, data: data ?? texture.data))
        passthroughFiles[texture] = file
        return file
    }

    /// `data` re-encoded at most `maxPixelSize` on its longer side, or nil when it's already that small.
    static func downscaled(_ data: Data, maxPixelSize: Int, jpeg: Bool) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int, let height = properties[kCGImagePropertyPixelHeight] as? Int,
              max(width, height) > maxPixelSize else { return nil }
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                        kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
                                        kCGImageSourceCreateThumbnailWithTransform: true]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, (jpeg ? "public.jpeg" : "public.png") as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, (jpeg ? [kCGImageDestinationLossyCompressionQuality: 0.9] : [:]) as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return output as Data
    }

    private func bakedFile(_ value: GraphValue, material: String, channel: MaterialGraph.Channel, evaluator: GraphEvaluator) -> String {
        let suffix = Self.identifier(channel.name, fallback: "channel")
        let cacheKey = "\(ObjectIdentifier(evaluator).hashValue)/\(material)/\(channel.rawValue)"
        if let hit = bakeCache?.entries[cacheKey], !usedFileNames.contains(hit.path.lowercased()) {
            usedFileNames.insert(hit.path.lowercased())
            files.append(hit)
            return hit.path
        }
        let image = evaluator.render(value, linear: !(channel == .baseColor || channel == .emissive))
        let data = image?.pngData() ?? Data()
        var base = "\(material)_\(suffix)"
        if contentHashedTextures {
            var hasher = Hasher()
            hasher.combine(data)
            base += "_" + String(UInt(bitPattern: hasher.finalize()), radix: 36)
        }
        let file = uniqueFileName(base, ext: "png")
        let entry = USDZPackager.Entry(path: file, data: data)
        files.append(entry)
        bakeCache?.entries[cacheKey] = entry
        return file
    }

    private func uniqueFileName(_ base: String, ext: String) -> String {
        var name = "textures/\(base).\(ext)"
        var n = 1
        while usedFileNames.contains(name.lowercased()) {
            name = "textures/\(base)_\(n).\(ext)"
            n += 1
        }
        usedFileNames.insert(name.lowercased())
        return name
    }

    // MARK: - Geometry

    /// Writes `over`s giving each pose-controlled object under `node` its state in this variant.
    private func writeOverrides(_ node: SCNNode, states: [ObjectIdentifier: (transform: simd_float4x4, hidden: Bool)]) {
        func changed(_ n: SCNNode) -> Bool { poseControlled.contains(ObjectIdentifier(n)) }
        func anyChanged(_ n: SCNNode) -> Bool { changed(n) || n.childNodes.contains(where: anyChanged) }
        guard let name = primNames[ObjectIdentifier(node)], anyChanged(node) else { return }
        line("over \(Self.quoted(name))")
        block {
            if changed(node) {
                let state = states[ObjectIdentifier(node)] ?? (node.simdTransform, node.isHidden)
                writeTransform(SCNMatrix4(state.transform), always: true)
                line("token visibility = \(state.hidden ? "\"invisible\"" : "\"inherited\"")")
            }
            for child in node.childNodes { writeOverrides(child, states: states) }
        }
    }

    private func writeTransform(_ m: SCNMatrix4, always: Bool = false) {
        guard always || !SCNMatrix4IsIdentity(m) else { return }
        let rows = [[m.m11, m.m12, m.m13, m.m14], [m.m21, m.m22, m.m23, m.m24],
                    [m.m31, m.m32, m.m33, m.m34], [m.m41, m.m42, m.m43, m.m44]]
        let matrix = rows.map { "(" + $0.map { Self.number(Double($0)) }.joined(separator: ", ") + ")" }.joined(separator: ", ")
        line("matrix4d xformOp:transform = (\(matrix))")
        line("uniform token[] xformOpOrder = [\"xformOp:transform\"]")
    }

    private func writeNode(_ node: SCNNode, siblingNames: inout Set<String>) {
        let name = Self.unique(Self.identifier(node.name ?? "", fallback: node.geometry != nil ? "Mesh" : "Node"), in: &siblingNames)
        primNames[ObjectIdentifier(node)] = name
        line("def Xform \(Self.quoted(name))")
        let controlled = poseControlled.contains(ObjectIdentifier(node))
        block {
            if !controlled { writeTransform(node.transform) }
            if node.isHidden, !controlled, writesVisibility { line("token visibility = \"invisible\"") }
            var childNames: Set<String> = []
            if let geometry = node.geometry {
                writeMesh(geometry, name: Self.unique("Geometry", in: &childNames))
            }
            for child in node.childNodes {
                writeNode(child, siblingNames: &childNames)
            }
        }
    }

    private func writeMesh(_ geometry: SCNGeometry, name: String) {
        guard let mesh = MeshData(geometry) else { return }
        let materials = geometry.materials
        let bindings: [String?] = mesh.elementFaces.indices.map { i in
            materials.isEmpty ? nil : materialPaths[ObjectIdentifier(materials[i % materials.count])]
        }
        // Group faces by bound material.
        var groups: [(path: String, faces: [Int32])] = []
        var faceStart: Int32 = 0
        for (i, count) in mesh.elementFaces.enumerated() {
            let faces = Array(faceStart..<(faceStart + Int32(count)))
            faceStart += Int32(count)
            guard let path = bindings[i] else { continue }
            if let g = groups.firstIndex(where: { $0.path == path }) {
                groups[g].faces += faces
            } else {
                groups.append((path, faces))
            }
        }
        let doubleSided = materials.contains { $0.isDoubleSided }

        line("def Mesh \(Self.quoted(name)) (")
        indented { line("prepend apiSchemas = [\"MaterialBindingAPI\"]") }
        line(")")
        block {
            let (lo, hi) = mesh.bounds
            line("float3[] extent = [\(Self.vec(lo)), \(Self.vec(hi))]")
            line("int[] faceVertexCounts = [\(mesh.counts.map(String.init).joined(separator: ", "))]")
            line("int[] faceVertexIndices = [\(mesh.indices.map(String.init).joined(separator: ", "))]")
            if groups.count == 1, groups[0].faces.count == mesh.counts.count {
                line("rel material:binding = <\(groups[0].path)>")
            }
            if let normals = mesh.normals {
                line("normal3f[] normals = [\(normals.map(Self.vec).joined(separator: ", "))] (")
                indented { line("interpolation = \"\(mesh.normalsPerCorner ? "faceVarying" : "vertex")\"") }
                line(")")
            }
            line("point3f[] points = [\(mesh.points.map(Self.vec).joined(separator: ", "))]")
            if let uvs = mesh.uvs {
                // SceneKit's texture origin is top-left; USD's is bottom-left.
                let st = uvs.map { "(\(Self.number($0.x)), \(Self.number(1 - $0.y)))" }
                line("texCoord2f[] primvars:st = [\(st.joined(separator: ", "))] (")
                indented { line("interpolation = \"\(mesh.uvsPerCorner ? "faceVarying" : "vertex")\"") }
                line(")")
            }
            if doubleSided { line("uniform bool doubleSided = 1") }
            line("uniform token subdivisionScheme = \"none\"")
            if groups.count > 1 || (groups.count == 1 && groups[0].faces.count != mesh.counts.count) {
                line("uniform token subsetFamily:materialBind:familyType = \"nonOverlapping\"")
                for (i, group) in groups.enumerated() {
                    line("")
                    line("def GeomSubset \"Subset\(i)\" (")
                    indented { line("prepend apiSchemas = [\"MaterialBindingAPI\"]") }
                    line(")")
                    block {
                        line("uniform token elementType = \"face\"")
                        line("uniform token familyName = \"materialBind\"")
                        line("int[] indices = [\(group.faces.map(String.init).joined(separator: ", "))]")
                        line("rel material:binding = <\(group.path)>")
                    }
                }
            }
        }
    }

    // MARK: - Text output

    private func line(_ s: String) {
        text += s.isEmpty ? "\n" : String(repeating: "    ", count: depth) + s + "\n"
    }

    private func indented(_ body: () -> Void) {
        depth += 1
        body()
        depth -= 1
    }

    private func block(_ body: () -> Void) {
        line("{")
        indented(body)
        line("}")
    }

    static func quoted(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n") + "\""
    }

    static func number(_ v: Float) -> String { v.isFinite ? "\(v)" : "0" }
    static func number(_ v: Double) -> String { v.isFinite ? "\(v)" : "0" }
    static func vec(_ v: SIMD3<Float>) -> String { "(\(number(v.x)), \(number(v.y)), \(number(v.z)))" }

    static func srgbToLinear(_ c: Float) -> Float {
        c <= 0.04045 ? c / 12.92 : powf((c + 0.055) / 1.055, 2.4)
    }

    /// A valid USD prim identifier.
    static func identifier(_ s: String, fallback: String) -> String {
        var result = String(s.unicodeScalars.map { scalar -> Character in
            (scalar.isASCII && (CharacterSet.alphanumerics.contains(scalar) || scalar == "_")) ? Character(scalar) : "_"
        })
        if result.allSatisfy({ $0 == "_" }) { result = fallback }
        if result.first!.isNumber { result = "_" + result }
        return result
    }

    static func unique(_ name: String, in used: inout Set<String>) -> String {
        var candidate = name
        var n = 1
        while used.contains(candidate) {
            candidate = "\(name)_\(n)"
            n += 1
        }
        used.insert(candidate)
        return candidate
    }
}

/// Flattened polygon data read out of an SCNGeometry.
struct MeshData {
    var points: [SIMD3<Float>]
    var normals: [SIMD3<Float>]?
    var uvs: [SIMD2<Float>]?
    /// True when normals/uvs hold one value per face corner (USD "faceVarying") instead of per point.
    var normalsPerCorner = false
    var uvsPerCorner = false
    var counts: [Int32] = []
    var indices: [Int32] = []
    /// Number of faces contributed by each geometry element, in element order.
    var elementFaces: [Int] = []

    var bounds: (SIMD3<Float>, SIMD3<Float>) {
        guard let first = points.first else { return (.zero, .zero) }
        return points.reduce((first, first)) { (simd_min($0.0, $1), simd_max($0.1, $1)) }
    }

    /// One face: per corner, an index for each index channel.
    private typealias Face = [[Int32]]

    /// SceneKit geometry isn't safe to read from several threads at once, and exports (AR Match, Share
    /// to iPhone, Vision Pro, Export) can run at the same time, so reads take turns.
    private static let readLock = NSLock()

    init?(_ geometry: SCNGeometry) {
        Self.readLock.lock()
        defer { Self.readLock.unlock() }
        guard let vertexSource = geometry.sources(for: .vertex).first else { return nil }
        points = Self.read(vertexSource).map { SIMD3($0[0], $0[safe: 1], $0[safe: 2]) }

        // SceneKit can index positions, normals and UVs separately ("index channels"), as it does for
        // USD files with per-corner UVs/normals (common in FBX conversions). Read every element's faces
        // as corner tuples first, then work out which channel feeds which source.
        let faceLists = geometry.elements.map(Self.faces(of:))
        var channelMax: [Int32] = []
        for faces in faceLists {
            for face in faces {
                for corner in face {
                    if channelMax.count < corner.count { channelMax += Array(repeating: -1, count: corner.count - channelMax.count) }
                    for (c, i) in corner.enumerated() { channelMax[c] = max(channelMax[c], i) }
                }
            }
        }
        func channel(for count: Int) -> Int? {
            let fitting = channelMax.indices.filter { channelMax[$0] < count }
            return fitting.first { channelMax[$0] == count - 1 } ?? fitting.first
        }
        guard let positionChannel = channel(for: points.count) else { return nil }

        // Normals and UVs: per point when they share the position channel, otherwise per corner.
        var normalSource: (values: [SIMD3<Float>], channel: Int)?
        if let source = geometry.sources(for: .normal).first, let c = channel(for: source.vectorCount) {
            normalSource = (Self.read(source).map { SIMD3($0[0], $0[safe: 1], $0[safe: 2]) }, c)
        }
        var uvSource: (values: [SIMD2<Float>], channel: Int)?
        if let source = geometry.sources(for: .texcoord).first, let c = channel(for: source.vectorCount) {
            uvSource = (Self.read(source).map { SIMD2($0[0], $0[safe: 1]) }, c)
        }
        normalsPerCorner = normalSource.map { $0.channel != positionChannel || $0.values.count != points.count } ?? false
        uvsPerCorner = uvSource.map { $0.channel != positionChannel || $0.values.count != points.count } ?? false
        if let normalSource, !normalsPerCorner { normals = normalSource.values }
        if let uvSource, !uvsPerCorner { uvs = uvSource.values }
        var cornerNormals: [SIMD3<Float>] = [], cornerUVs: [SIMD2<Float>] = []

        let vertexCount = Int32(points.count)
        for faces in faceLists {
            var added = 0
            for face in faces {
                let positions = face.map { $0[positionChannel] }
                guard positions.count >= 3, positions.allSatisfy({ $0 >= 0 && $0 < vertexCount }) else { continue }
                counts.append(Int32(positions.count))
                indices += positions
                if normalsPerCorner, let normalSource {
                    cornerNormals += face.map { Int($0[normalSource.channel]) < normalSource.values.count ? normalSource.values[Int($0[normalSource.channel])] : .zero }
                }
                if uvsPerCorner, let uvSource {
                    cornerUVs += face.map { Int($0[uvSource.channel]) < uvSource.values.count ? uvSource.values[Int($0[uvSource.channel])] : .zero }
                }
                added += 1
            }
            elementFaces.append(added)
        }
        if normalsPerCorner { normals = cornerNormals }
        if uvsPerCorner { uvs = cornerUVs }
        guard !counts.isEmpty else { return nil }
    }

    /// Faces of one element as corner tuples (one index per channel).
    private static func faces(of element: SCNGeometryElement) -> [Face] {
        let raw = readIndices(element)
        let channels = max(1, element.indicesChannelCount)
        // Polygon elements store one vertex count per face before the corner indices.
        let header = element.primitiveType == .polygon ? element.primitiveCount : 0
        guard raw.count >= header else { return [] }
        let cornerData = Array(raw[header...])
        let cornerCount = cornerData.count / channels
        func corner(_ i: Int) -> [Int32] {
            (0..<channels).map { c in
                element.hasInterleavedIndicesChannels || channels == 1 ? cornerData[i * channels + c] : cornerData[c * cornerCount + i]
            }
        }

        var faces: [Face] = []
        switch element.primitiveType {
        case .triangles:
            for t in 0..<(cornerCount / 3) { faces.append([corner(t * 3), corner(t * 3 + 1), corner(t * 3 + 2)]) }
        case .triangleStrip:
            if cornerCount >= 3 {
                for t in 0..<(cornerCount - 2) {
                    let tri = t % 2 == 0 ? [corner(t), corner(t + 1), corner(t + 2)] : [corner(t + 1), corner(t), corner(t + 2)]
                    if Set(tri.map { $0[0] }).count == 3 { faces.append(tri) }
                }
            }
        case .polygon:
            var cursor = 0
            for f in 0..<header {
                let n = Int(raw[f])
                guard n >= 3, cursor + n <= cornerCount else { break }
                faces.append((cursor..<(cursor + n)).map(corner))
                cursor += n
            }
        default:
            break // lines and points aren't exported
        }
        return faces
    }

    private static func read(_ source: SCNGeometrySource) -> [[Float]] {
        let n = source.componentsPerVector, stride = source.dataStride, size = source.bytesPerComponent
        return source.data.withUnsafeBytes { raw in
            (0..<source.vectorCount).map { v in
                (0..<n).map { c in
                    let offset = source.dataOffset + v * stride + c * size
                    guard offset + size <= raw.count else { return 0 }
                    if source.usesFloatComponents {
                        switch size {
                        case 8: return Float(raw.loadUnaligned(fromByteOffset: offset, as: Double.self))
                        case 2: return Float(raw.loadUnaligned(fromByteOffset: offset, as: Float16.self))
                        default: return raw.loadUnaligned(fromByteOffset: offset, as: Float.self)
                        }
                    }
                    switch size {
                    case 1: return Float(raw.loadUnaligned(fromByteOffset: offset, as: Int8.self))
                    case 2: return Float(raw.loadUnaligned(fromByteOffset: offset, as: Int16.self))
                    default: return Float(raw.loadUnaligned(fromByteOffset: offset, as: Int32.self))
                    }
                }
            }
        }
    }

    private static func readIndices(_ element: SCNGeometryElement) -> [Int32] {
        let size = element.bytesPerIndex
        guard size > 0 else { return [] }
        let count = element.data.count / size
        return element.data.withUnsafeBytes { raw in
            (0..<count).map { i in
                switch size {
                case 1: Int32(raw.load(fromByteOffset: i, as: UInt8.self))
                case 2: Int32(raw.loadUnaligned(fromByteOffset: i * 2, as: UInt16.self))
                case 8: Int32(truncatingIfNeeded: raw.loadUnaligned(fromByteOffset: i * 8, as: Int64.self))
                default: Int32(bitPattern: raw.loadUnaligned(fromByteOffset: i * 4, as: UInt32.self))
                }
            }
        }
    }
}

private extension Array where Element == Float {
    subscript(safe index: Int) -> Float { index < count ? self[index] : 0 }
}
