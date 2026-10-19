import Compression
import Foundation
import SceneKit
import simd

// MARK: - Binary FBX encoding

/// One property of an FBX node record.
enum FBXProperty {
    case bool(Bool)
    case int32(Int32)
    case int64(Int64)
    case float64(Double)
    case string([UInt8])
    case raw(Data)
    case int32Array([Int32])
    case float64Array([Double])

    static func text(_ s: String) -> FBXProperty { .string(Array(s.utf8)) }
    /// Object names are stored as `name \0\1 Class` in binary FBX.
    static func objectName(_ name: String, _ cls: String) -> FBXProperty {
        .string(Array(name.utf8) + [0x00, 0x01] + Array(cls.utf8))
    }
}

/// A node record: name, properties, nested nodes.
final class FBXNode {
    let name: String
    var properties: [FBXProperty]
    var children: [FBXNode] = []

    init(_ name: String, _ properties: [FBXProperty] = [], _ children: [FBXNode] = []) {
        self.name = name
        self.properties = properties
        self.children = children
    }

    @discardableResult
    func add(_ name: String, _ properties: FBXProperty...) -> FBXNode {
        let node = FBXNode(name, properties)
        children.append(node)
        return node
    }

    func add(_ node: FBXNode) { children.append(node) }
}

/// Writes binary FBX 7.4 (32-bit record offsets), following the layout Blender's exporter uses.
enum FBXBinaryEncoder {
    private static let headMagic = Array("Kaydara FBX Binary  ".utf8) + [0x00, 0x1A, 0x00]
    static let fileID: [UInt8] = [0x28, 0xB3, 0x2A, 0xEB, 0xB6, 0x24, 0xCC, 0xC2, 0xBF, 0xC8, 0xB0, 0x2A, 0xA9, 0x2B, 0xFC, 0xF1]
    static let creationTime = "1970-01-01 10:00:00:000"
    private static let footID: [UInt8] = [0xFA, 0xBC, 0xAB, 0x09, 0xD0, 0xC8, 0xD4, 0x66, 0xB1, 0x76, 0xFB, 0x83, 0x1C, 0xF7, 0x26, 0x7E]
    private static let footMagic: [UInt8] = [0xF8, 0x5A, 0x8C, 0x6A, 0xDE, 0xF5, 0xD9, 0x7E, 0xEC, 0xE9, 0x0C, 0xE3, 0x75, 0x8F, 0x29, 0x0B]
    private static let sentinel = [UInt8](repeating: 0, count: 13)
    static let version: UInt32 = 7400

    static func encode(_ topLevel: [FBXNode]) -> Data {
        var out = [UInt8]()
        out.reserveCapacity(1 << 20)
        out += headMagic
        append(&out, version)
        writeChildren(topLevel, into: &out, parentHasProperties: true, isLast: false)
        // Footer.
        out += footID
        out += [0, 0, 0, 0]
        var pad = ((out.count + 15) & ~15) - out.count
        if pad == 0 { pad = 16 }
        out += [UInt8](repeating: 0, count: pad)
        append(&out, version)
        out += [UInt8](repeating: 0, count: 120)
        out += footMagic
        return Data(out)
    }

    private static func writeChildren(_ children: [FBXNode], into out: inout [UInt8], parentHasProperties: Bool, isLast: Bool) {
        if !children.isEmpty {
            for (i, child) in children.enumerated() { write(child, into: &out, isLast: i == children.count - 1) }
            out += sentinel
        } else if !parentHasProperties && !isLast {
            out += sentinel
        }
    }

    private static func write(_ node: FBXNode, into out: inout [UInt8], isLast: Bool) {
        let start = out.count
        append(&out, UInt32(0))                         // end offset, patched below
        append(&out, UInt32(node.properties.count))
        let propertyLengthAt = out.count
        append(&out, UInt32(0))                         // property list length, patched below
        let name = Array(node.name.utf8)
        out.append(UInt8(name.count))
        out += name
        let propertiesStart = out.count
        for property in node.properties { write(property, into: &out) }
        patch(&out, at: propertyLengthAt, UInt32(out.count - propertiesStart))
        writeChildren(node.children, into: &out, parentHasProperties: !node.properties.isEmpty, isLast: isLast)
        patch(&out, at: start, UInt32(out.count))
    }

    private static func write(_ property: FBXProperty, into out: inout [UInt8]) {
        switch property {
        case let .bool(v): out += [UInt8(ascii: "C"), v ? 1 : 0]
        case let .int32(v): out.append(UInt8(ascii: "I")); append(&out, UInt32(bitPattern: v))
        case let .int64(v): out.append(UInt8(ascii: "L")); append(&out, UInt64(bitPattern: v))
        case let .float64(v): out.append(UInt8(ascii: "D")); append(&out, v.bitPattern)
        case let .string(bytes): out.append(UInt8(ascii: "S")); append(&out, UInt32(bytes.count)); out += bytes
        case let .raw(data): out.append(UInt8(ascii: "R")); append(&out, UInt32(data.count)); out += data
        case let .int32Array(values):
            var raw = [UInt8]()
            raw.reserveCapacity(values.count * 4)
            for v in values { append(&raw, UInt32(bitPattern: v)) }
            writeArray("i", count: values.count, raw: raw, into: &out)
        case let .float64Array(values):
            var raw = [UInt8]()
            raw.reserveCapacity(values.count * 8)
            for v in values { append(&raw, v.bitPattern) }
            writeArray("d", count: values.count, raw: raw, into: &out)
        }
    }

    /// Arrays larger than a few dozen values are zlib-compressed (encoding 1), as FBX SDK files are.
    private static func writeArray(_ type: Character, count: Int, raw: [UInt8], into out: inout [UInt8]) {
        out.append(type.asciiValue!)
        append(&out, UInt32(count))
        if raw.count > 128, let compressed = zlib(raw), compressed.count < raw.count {
            append(&out, UInt32(1))
            append(&out, UInt32(compressed.count))
            out += compressed
        } else {
            append(&out, UInt32(0))
            append(&out, UInt32(raw.count))
            out += raw
        }
    }

    /// A zlib stream: 2-byte header, raw deflate (Compression framework), Adler-32 trailer.
    private static func zlib(_ input: [UInt8]) -> [UInt8]? {
        var deflated = [UInt8](repeating: 0, count: input.count + input.count / 10 + 64)
        let size = input.withUnsafeBufferPointer { src in
            deflated.withUnsafeMutableBufferPointer { dst in
                compression_encode_buffer(dst.baseAddress!, dst.count, src.baseAddress!, src.count, nil, COMPRESSION_ZLIB)
            }
        }
        guard size > 0 else { return nil }
        var a: UInt32 = 1, b: UInt32 = 0
        var i = 0
        while i < input.count {
            let end = min(i + 5552, input.count)   // largest run before the sums can overflow
            while i < end { a += UInt32(input[i]); b += a; i += 1 }
            a %= 65521
            b %= 65521
        }
        let adler = (b << 16) | a
        return [0x78, 0x9C] + deflated[0..<size] + [UInt8(adler >> 24), UInt8(adler >> 16 & 0xFF), UInt8(adler >> 8 & 0xFF), UInt8(adler & 0xFF)]
    }

    private static func append<T: FixedWidthInteger>(_ out: inout [UInt8], _ value: T) {
        withUnsafeBytes(of: value.littleEndian) { out += $0 }
    }

    private static func patch(_ out: inout [UInt8], at offset: Int, _ value: UInt32) {
        withUnsafeBytes(of: value.littleEndian) { bytes in
            for i in 0..<4 { out[offset + i] = bytes[i] }
        }
    }
}

// MARK: - Scene → FBX

/// Writes a model and its evaluated material graphs as a binary FBX with embedded textures.
///
/// Materials use FBX's Phong properties with the conventions Blender's exporter uses (and Blender,
/// Unity, Maya and KeyShot read back): base color → DiffuseColor, metallic → ReflectionFactor,
/// roughness → ShininessExponent ((1 − r)·10)², emissive → EmissiveColor, normal map → NormalMap.
final class FBXWriter {
    private var nextID: Int64 = 1_000_000
    private var objects = FBXNode("Objects")
    private var connections = FBXNode("Connections")
    private var counts: [String: Int] = [:]
    private var materialIDs: [ObjectIdentifier: Int64] = [:]
    private var textureIDs: [String: Int64] = [:]
    private let textureFolder: String

    init(fileName: String) {
        // The folder name FBX importers conventionally extract embedded media into.
        textureFolder = (fileName as NSString).deletingPathExtension + ".fbm"
    }

    private func newID() -> Int64 {
        nextID += 1
        return nextID
    }

    private func connect(_ child: Int64, to parent: Int64, property: String? = nil) {
        if let property {
            connections.add("C", .text("OP"), .int64(child), .int64(parent), .text(property))
        } else {
            connections.add("C", .text("OO"), .int64(child), .int64(parent))
        }
    }

    private static func p(_ name: String, _ type: String, _ label: String, _ flags: String, _ values: FBXProperty...) -> FBXNode {
        FBXNode("P", [.text(name), .text(type), .text(label), .text(flags)] + values)
    }

    func write(root: SCNNode, materials: [USDWriter.MaterialJob], metadata: StageMetadata) -> Data {
        for job in materials { writeMaterial(job) }
        for child in root.childNodes { writeNode(child, parent: 0) }

        let header = FBXNode("FBXHeaderExtension")
        header.add("FBXHeaderVersion", .int32(1003))
        header.add("FBXVersion", .int32(Int32(FBXBinaryEncoder.version)))
        header.add("EncryptionType", .int32(0))
        let stamp = FBXNode("CreationTimeStamp")
        let now = Calendar(identifier: .gregorian).dateComponents([.year, .month, .day, .hour, .minute, .second], from: Date())
        stamp.add("Version", .int32(1000))
        for (key, value) in [("Year", now.year), ("Month", now.month), ("Day", now.day), ("Hour", now.hour),
                             ("Minute", now.minute), ("Second", now.second), ("Millisecond", 0)] {
            stamp.add(key, .int32(Int32(value ?? 0)))
        }
        header.add(stamp)
        header.add("Creator", .text("Veneer Pro"))

        let zUp = metadata.upAxis == "Z"
        let settings = FBXNode("GlobalSettings")
        settings.add("Version", .int32(1000))
        let props = FBXNode("Properties70")
        // Axis system: Y-up (or Z-up), right-handed, matching the source's orientation.
        props.add(Self.p("UpAxis", "int", "Integer", "", .int32(zUp ? 2 : 1)))
        props.add(Self.p("UpAxisSign", "int", "Integer", "", .int32(1)))
        props.add(Self.p("FrontAxis", "int", "Integer", "", .int32(zUp ? 1 : 2)))
        props.add(Self.p("FrontAxisSign", "int", "Integer", "", .int32(zUp ? -1 : 1)))
        props.add(Self.p("CoordAxis", "int", "Integer", "", .int32(0)))
        props.add(Self.p("CoordAxisSign", "int", "Integer", "", .int32(1)))
        props.add(Self.p("OriginalUpAxis", "int", "Integer", "", .int32(zUp ? 2 : 1)))
        props.add(Self.p("OriginalUpAxisSign", "int", "Integer", "", .int32(1)))
        // FBX units are centimeters per unit.
        props.add(Self.p("UnitScaleFactor", "double", "Number", "", .float64(metadata.metersPerUnit * 100)))
        props.add(Self.p("OriginalUnitScaleFactor", "double", "Number", "", .float64(metadata.metersPerUnit * 100)))
        props.add(Self.p("AmbientColor", "ColorRGB", "Color", "", .float64(0), .float64(0), .float64(0)))
        props.add(Self.p("DefaultCamera", "KString", "", "", .text("Producer Perspective")))
        props.add(Self.p("TimeMode", "enum", "", "", .int32(11)))
        props.add(Self.p("TimeSpanStart", "KTime", "Time", "", .int64(0)))
        props.add(Self.p("TimeSpanStop", "KTime", "Time", "", .int64(46_186_158_000)))
        props.add(Self.p("CustomFrameRate", "double", "Number", "", .float64(-1)))
        settings.add(props)

        let documents = FBXNode("Documents")
        documents.add("Count", .int32(1))
        let document = FBXNode("Document", [.int64(newID()), .text(""), .text("Scene")])
        let docProps = FBXNode("Properties70")
        docProps.add(Self.p("SourceObject", "object", "", ""))
        docProps.add(Self.p("ActiveAnimStackName", "KString", "", "", .text("")))
        document.add(docProps)
        document.add("RootNode", .int64(0))
        documents.add(document)

        let definitions = FBXNode("Definitions")
        definitions.add("Version", .int32(100))
        definitions.add("Count", .int32(Int32(counts.values.reduce(1, +))))
        let globals = FBXNode("ObjectType", [.text("GlobalSettings")])
        globals.add("Count", .int32(1))
        definitions.add(globals)
        for type in ["Model", "Geometry", "Material", "Texture", "Video"] where counts[type, default: 0] > 0 {
            let def = FBXNode("ObjectType", [.text(type)])
            def.add("Count", .int32(Int32(counts[type]!)))
            definitions.add(def)
        }

        let takes = FBXNode("Takes")
        takes.add("Current", .text(""))

        return FBXBinaryEncoder.encode([
            header,
            FBXNode("FileId", [.raw(Data(FBXBinaryEncoder.fileID))]),
            FBXNode("CreationTime", [.text(FBXBinaryEncoder.creationTime)]),
            FBXNode("Creator", [.text("Veneer Pro")]),
            settings,
            documents,
            FBXNode("References"),
            definitions,
            objects,
            connections,
            takes,
        ])
    }

    // MARK: Hierarchy & meshes

    private func writeNode(_ node: SCNNode, parent: Int64) {
        let id = newID()
        let name = node.name ?? (node.geometry != nil ? "Mesh" : "Group")
        let isMesh = node.geometry.flatMap(MeshData.init) != nil
        counts["Model", default: 0] += 1

        let model = FBXNode("Model", [.int64(id), .objectName(name, "Model"), .text(isMesh ? "Mesh" : "Null")])
        model.add("Version", .int32(232))
        let props = FBXNode("Properties70")
        let (t, r, s) = Self.decompose(node.simdTransform)
        props.add(Self.p("RotationActive", "bool", "", "", .int32(1)))
        props.add(Self.p("InheritType", "enum", "", "", .int32(1)))
        props.add(Self.p("DefaultAttributeIndex", "int", "Integer", "", .int32(0)))
        props.add(Self.p("Lcl Translation", "Lcl Translation", "", "A", .float64(t.x), .float64(t.y), .float64(t.z)))
        props.add(Self.p("Lcl Rotation", "Lcl Rotation", "", "A", .float64(r.x), .float64(r.y), .float64(r.z)))
        props.add(Self.p("Lcl Scaling", "Lcl Scaling", "", "A", .float64(s.x), .float64(s.y), .float64(s.z)))
        if node.isHidden { props.add(Self.p("Visibility", "Visibility", "", "A", .float64(0))) }
        model.add(props)
        model.add("MultiLayer", .int32(0))
        model.add("MultiTake", .int32(0))
        model.add("Shading", .bool(true))
        model.add("Culling", .text("CullingOff"))
        objects.add(model)
        connect(id, to: parent)

        if isMesh, let geometry = node.geometry, let mesh = MeshData(geometry) {
            writeGeometry(mesh, geometry: geometry, name: name, model: id)
        }
        for child in node.childNodes { writeNode(child, parent: id) }
    }

    private func writeGeometry(_ mesh: MeshData, geometry: SCNGeometry, name: String, model: Int64) {
        let id = newID()
        counts["Geometry", default: 0] += 1
        let node = FBXNode("Geometry", [.int64(id), .objectName(name, "Geometry"), .text("Mesh")])
        node.add("GeometryVersion", .int32(124))
        node.add("Vertices", .float64Array(mesh.points.flatMap { [Double($0.x), Double($0.y), Double($0.z)] }))

        // Polygon vertex indices; the last index of each polygon is stored as -(index + 1).
        var polygonIndices: [Int32] = []
        polygonIndices.reserveCapacity(mesh.indices.count)
        var cursor = 0
        for count in mesh.counts {
            for k in 0..<Int(count) {
                let index = mesh.indices[cursor + k]
                polygonIndices.append(k == Int(count) - 1 ? ~index : index)
            }
            cursor += Int(count)
        }
        node.add("PolygonVertexIndex", .int32Array(polygonIndices))

        let layer = FBXNode("Layer", [.int32(0)])
        layer.add("Version", .int32(100))
        func layerElement(_ type: String) {
            let element = FBXNode("LayerElement")
            element.add("Type", .text(type))
            element.add("TypedIndex", .int32(0))
            layer.add(element)
        }

        if let normals = mesh.normals {
            let element = FBXNode("LayerElementNormal", [.int32(0)])
            element.add("Version", .int32(101))
            element.add("Name", .text(""))
            element.add("MappingInformationType", .text("ByPolygonVertex"))
            element.add("ReferenceInformationType", .text("Direct"))
            let perCorner = mesh.normalsPerCorner ? normals : mesh.indices.map { normals[Int($0)] }
            element.add("Normals", .float64Array(perCorner.flatMap { [Double($0.x), Double($0.y), Double($0.z)] }))
            node.add(element)
            layerElement("LayerElementNormal")
        }

        if let uvs = mesh.uvs {
            let element = FBXNode("LayerElementUV", [.int32(0)])
            element.add("Version", .int32(101))
            element.add("Name", .text("UVMap"))
            element.add("MappingInformationType", .text("ByPolygonVertex"))
            element.add("ReferenceInformationType", .text("IndexToDirect"))
            // SceneKit's texture origin is top-left; FBX's is bottom-left.
            element.add("UV", .float64Array(uvs.flatMap { [Double($0.x), Double(1 - $0.y)] }))
            element.add("UVIndex", .int32Array(mesh.uvsPerCorner ? (0..<Int32(uvs.count)).map { $0 } : mesh.indices))
            node.add(element)
            layerElement("LayerElementUV")
        }

        // Material slots: the materials connected to the model, in order; each face picks one.
        let sceneMaterials = geometry.materials
        var slots: [Int64] = []
        var faceSlots: [Int32] = []
        for (element, faceCount) in mesh.elementFaces.enumerated() {
            var slot: Int32 = 0
            if !sceneMaterials.isEmpty, let materialID = materialIDs[ObjectIdentifier(sceneMaterials[element % sceneMaterials.count])] {
                if let existing = slots.firstIndex(of: materialID) {
                    slot = Int32(existing)
                } else {
                    slot = Int32(slots.count)
                    slots.append(materialID)
                }
            }
            faceSlots += Array(repeating: slot, count: faceCount)
        }
        if !slots.isEmpty {
            let element = FBXNode("LayerElementMaterial", [.int32(0)])
            element.add("Version", .int32(101))
            element.add("Name", .text(""))
            let single = Set(faceSlots).count <= 1
            element.add("MappingInformationType", .text(single ? "AllSame" : "ByPolygon"))
            element.add("ReferenceInformationType", .text("IndexToDirect"))
            element.add("Materials", .int32Array(single ? [0] : faceSlots))
            node.add(element)
            layerElement("LayerElementMaterial")
        }
        node.add(layer)
        objects.add(node)
        connect(id, to: model)
        for materialID in slots { connect(materialID, to: model) }
    }

    /// Translation, Euler XYZ rotation in degrees (FBX's default order), and scale.
    static func decompose(_ m: simd_float4x4) -> (SIMD3<Double>, SIMD3<Double>, SIMD3<Double>) {
        let t = SIMD3<Double>(Double(m.columns.3.x), Double(m.columns.3.y), Double(m.columns.3.z))
        var c0 = SIMD3<Double>(Double(m.columns.0.x), Double(m.columns.0.y), Double(m.columns.0.z))
        var c1 = SIMD3<Double>(Double(m.columns.1.x), Double(m.columns.1.y), Double(m.columns.1.z))
        var c2 = SIMD3<Double>(Double(m.columns.2.x), Double(m.columns.2.y), Double(m.columns.2.z))
        var s = SIMD3<Double>(simd_length(c0), simd_length(c1), simd_length(c2))
        if simd_dot(simd_cross(c0, c1), c2) < 0 { s.x = -s.x }   // mirrored transform
        c0 = simd_normalize(c0) * (s.x < 0 ? -1 : 1)
        c1 = simd_normalize(c1)
        c2 = simd_normalize(c2)
        // R = Rz · Ry · Rx (X applied first). r_ij = row i, column j.
        let r20 = c0.z, r21 = c1.z, r22 = c2.z, r10 = c0.y, r00 = c0.x
        let y = asin(-max(-1, min(1, r20)))
        let x: Double, z: Double
        if abs(r20) < 0.999999 {
            x = atan2(r21, r22)
            z = atan2(r10, r00)
        } else {
            // Gimbal lock: fold all rotation into X.
            x = atan2(-c2.y, c1.y)
            z = 0
        }
        let toDegrees = 180 / Double.pi
        return (t, SIMD3(x, y, z) * toDegrees, s)
    }

    // MARK: Materials & textures

    private func writeMaterial(_ job: USDWriter.MaterialJob) {
        typealias C = MaterialGraph.Channel
        let id = newID()
        counts["Material", default: 0] += 1
        for material in job.materials { materialIDs[ObjectIdentifier(material)] = id }
        let result = job.result

        let node = FBXNode("Material", [.int64(id), .objectName(job.name, "Material"), .text("")])
        node.add("Version", .int32(102))
        node.add("ShadingModel", .text("Phong"))
        node.add("MultiLayer", .int32(0))
        let props = FBXNode("Properties70")

        func linear(_ c: SIMD4<Float>) -> [FBXProperty] {
            [c.x, c.y, c.z].map { .float64(Double(USDWriter.srgbToLinear($0))) }
        }
        func constant(_ channel: C) -> SIMD4<Float>? {
            if case let .constant(c) = result[channel] { return c }
            return nil
        }

        // Base color
        if let c = constant(.baseColor) {
            props.add(FBXNode("P", [.text("DiffuseColor"), .text("Color"), .text(""), .text("A")] + linear(c)))
        } else {
            props.add(Self.p("DiffuseColor", "Color", "", "A", .float64(1), .float64(1), .float64(1)))
            attachTexture(result[.baseColor], channel: .baseColor, job: job, material: id, property: "DiffuseColor")
        }
        props.add(Self.p("DiffuseFactor", "Number", "", "A", .float64(1)))

        // Metallic → ReflectionFactor
        if let c = constant(.metallic) {
            props.add(Self.p("ReflectionFactor", "Number", "", "A", .float64(Double(c.x))))
        } else {
            props.add(Self.p("ReflectionFactor", "Number", "", "A", .float64(1)))
            attachTexture(result[.metallic], channel: .metallic, job: job, material: id, property: "ReflectionFactor")
        }

        // Roughness → ShininessExponent
        if let c = constant(.roughness) {
            let shininess = (1 - Double(simd_clamp(c.x, 0, 1))) * 10
            props.add(Self.p("ShininessExponent", "Number", "", "A", .float64(shininess * shininess)))
        } else {
            props.add(Self.p("ShininessExponent", "Number", "", "A", .float64(25)))
            attachTexture(result[.roughness], channel: .roughness, job: job, material: id, property: "ShininessExponent")
        }
        props.add(Self.p("SpecularColor", "Color", "", "A", .float64(1), .float64(1), .float64(1)))
        props.add(Self.p("SpecularFactor", "Number", "", "A", .float64(0.25)))

        // Emissive
        if let c = constant(.emissive) {
            props.add(FBXNode("P", [.text("EmissiveColor"), .text("Color"), .text(""), .text("A")] + linear(c)))
        } else {
            props.add(Self.p("EmissiveColor", "Color", "", "A", .float64(1), .float64(1), .float64(1)))
            attachTexture(result[.emissive], channel: .emissive, job: job, material: id, property: "EmissiveColor")
        }
        props.add(Self.p("EmissiveFactor", "Number", "", "A", .float64(1)))

        // Opacity
        let opacity = Double(constant(.opacity)?.x ?? 1)
        props.add(Self.p("TransparencyFactor", "Number", "", "A", .float64(1 - opacity)))
        props.add(Self.p("Opacity", "Number", "", "A", .float64(opacity)))

        // Normal map
        if result.isConnected(.normal), case .image = result[.normal] {
            props.add(Self.p("NormalMap", "Vector3D", "Vector", "", .float64(0), .float64(0), .float64(0)))
            attachTexture(result[.normal], channel: .normal, job: job, material: id, property: "NormalMap")
        }
        node.add(props)
        objects.add(node)
    }

    /// Embeds the image for one channel (the original file when unmodified, otherwise a bake)
    /// and connects it to `property` of the material.
    private func attachTexture(_ value: GraphValue, channel: MaterialGraph.Channel, job: USDWriter.MaterialJob,
                               material: Int64, property: String) {
        guard case .image = value else { return }
        var key: String
        var data: Data
        var fileName: String
        if let passthrough = value.passthrough, passthrough.channel == .rgb {
            // Unmodified texture used as a whole image: embed the original bytes. (A single channel
            // of a texture, e.g. roughness in G, can't be selected in FBX, so those are baked.)
            key = "pass:\(passthrough.texture.id)"
            data = passthrough.texture.data
            fileName = USDWriter.identifier(passthrough.texture.name, fallback: "texture") + "." + passthrough.texture.fileExtension
        } else {
            key = "bake:\(job.name):\(channel.rawValue)"
            let image = job.evaluator.render(value, linear: !(channel == .baseColor || channel == .emissive))
            data = image?.pngData() ?? Data()
            fileName = USDWriter.identifier("\(job.name)_\(channel.name)", fallback: "texture") + ".png"
        }

        let textureID: Int64
        if let existing = textureIDs[key] {
            textureID = existing
        } else {
            textureID = newID()
            textureIDs[key] = textureID
            let videoID = newID()
            counts["Texture", default: 0] += 1
            counts["Video", default: 0] += 1
            let baseName = (fileName as NSString).deletingPathExtension
            let relative = "\(textureFolder)/\(fileName)"

            let video = FBXNode("Video", [.int64(videoID), .objectName(baseName, "Video"), .text("Clip")])
            video.add("Type", .text("Clip"))
            let videoProps = FBXNode("Properties70")
            videoProps.add(Self.p("Path", "KString", "XRefUrl", "", .text(relative)))
            video.add(videoProps)
            video.add("UseMipMap", .int32(0))
            video.add("Filename", .text(relative))
            video.add("RelativeFilename", .text(relative))
            video.add("Content", .raw(data))
            objects.add(video)

            let texture = FBXNode("Texture", [.int64(textureID), .objectName(baseName, "Texture"), .text("")])
            texture.add("Type", .text("TextureVideoClip"))
            texture.add("Version", .int32(202))
            texture.add("TextureName", .objectName(baseName, "Texture"))
            let textureProps = FBXNode("Properties70")
            textureProps.add(Self.p("UseMaterial", "bool", "", "", .int32(1)))
            texture.add(textureProps)
            texture.add("Media", .objectName(baseName, "Video"))
            texture.add("FileName", .text(relative))
            texture.add("RelativeFilename", .text(relative))
            texture.add("ModelUVTranslation", .float64(0), .float64(0))
            texture.add("ModelUVScaling", .float64(1), .float64(1))
            texture.add("Texture_Alpha_Source", .text("None"))
            texture.add("Cropping", .int32(0), .int32(0), .int32(0), .int32(0))
            objects.add(texture)
            connect(videoID, to: textureID)
        }
        connect(textureID, to: material, property: property)
    }
}
