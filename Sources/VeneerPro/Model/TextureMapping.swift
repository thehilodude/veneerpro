import SceneKit
import simd

/// How a material's textures are projected onto the parts that use it (like KeyShot's mapping types).
/// Anything but `.uv` generates new texture coordinates, measured in real-world units so a tile has the
/// same physical size on every part. USDZ and FBX only carry UVs, so the projection is baked into them.
struct TextureMapping: Equatable {
    enum Kind: String, CaseIterable, Identifiable {
        case uv = "UV"
        case planar = "Planar"
        case box = "Box"
        case cylindrical = "Cylindrical"
        case spherical = "Spherical"

        var id: String { rawValue }

        var symbol: String {
            switch self {
            case .uv: "square.grid.3x3"
            case .planar: "square.stack.3d.down.forward"
            case .box: "cube"
            case .cylindrical: "cylinder"
            case .spherical: "globe"
            }
        }

        /// Whether the projection has a direction to choose.
        var hasAxis: Bool { self == .planar || self == .cylindrical || self == .spherical }
    }

    enum Axis: String, CaseIterable, Identifiable {
        case x = "X", y = "Y", z = "Z"
        var id: String { rawValue }
        var index: Int { self == .x ? 0 : self == .y ? 1 : 2 }
    }

    var kind: Kind = .uv
    var axis: Axis = .z
    /// Width of one texture tile, in meters.
    var size: Double = 0.1
    /// Rotation of the texture on the surface, in degrees.
    var rotation: Double = 0
    /// Shift of the texture, in tiles.
    var offset: SIMD2<Double> = .zero

    var isIdentity: Bool { kind == .uv }

    /// Texture coordinates for one polygon. `points` are in meters in model space; `center` and
    /// `radius` describe the material's whole extent (for cylindrical and spherical projection).
    func coordinates(points: [SIMD3<Float>], normal: SIMD3<Float>, center: SIMD3<Float>, radius: Float) -> [SIMD2<Float>] {
        let size = Float(max(self.size, 1e-5))
        var plane: [SIMD2<Float>]
        switch kind {
        case .uv:
            return []
        case .planar:
            plane = points.map { Self.project($0, along: axis.index) }
        case .box:
            let a = abs(normal)
            let dominant = a.x >= a.y && a.x >= a.z ? 0 : (a.y >= a.z ? 1 : 2)
            // Flip on back faces so textures aren't mirrored.
            let flip: Float = normal[dominant] < 0 ? -1 : 1
            plane = points.map { p in
                var uv = Self.project(p, along: dominant)
                uv.x *= dominant == 1 ? 1 : flip
                return uv
            }
        case .cylindrical, .spherical:
            let i = axis.index
            let (u, w) = Self.perpendicular(i)
            var angles = points.map { p -> Float in let d = p - center; return atan2(d[u], d[w]) }
            // Keep one polygon on one side of the seam.
            if let lo = angles.min(), let hi = angles.max(), hi - lo > .pi {
                angles = angles.map { $0 < 0 ? $0 + 2 * .pi : $0 }
            }
            plane = zip(points, angles).map { p, angle in
                let d = p - center
                if kind == .cylindrical { return SIMD2(angle * radius, d[i]) }
                let polar = acos(simd_clamp(d[i] / max(simd_length(d), 1e-6), -1, 1))
                return SIMD2(angle * radius, (Float.pi / 2 - polar) * radius)
            }
        }
        let r = Float(rotation * .pi / 180), c = cos(r), s = sin(r)
        let shift = SIMD2<Float>(Float(offset.x), Float(offset.y))
        return plane.map { p in
            let q = SIMD2(c * p.x - s * p.y, s * p.x + c * p.y) / size + shift
            // SceneKit's texture origin is top-left: flip V so "up" in the world is up in the texture.
            return SIMD2(q.x, -q.y)
        }
    }

    /// The two in-plane coordinates when projecting along `axis`, oriented so textures read upright.
    private static func project(_ p: SIMD3<Float>, along axis: Int) -> SIMD2<Float> {
        switch axis {
        case 0: SIMD2(-p.z, p.y)
        case 1: SIMD2(p.x, -p.z)
        default: SIMD2(p.x, p.y)
        }
    }

    private static func perpendicular(_ axis: Int) -> (Int, Int) {
        switch axis {
        case 0: (2, 1)
        case 1: (0, 2)
        default: (0, 1)
        }
    }
}

/// Bakes material mappings into mesh texture coordinates, keeping each mesh's original geometry so
/// switching back to UV mapping restores it exactly.
/// Used on the main actor (it edits the live scene).
final class MappingBaker {
    /// Mapped geometry → the unmapped geometry it was built from.
    private var sources: [ObjectIdentifier: SCNGeometry] = [:]
    private var meshes: [ObjectIdentifier: MeshData] = [:]

    /// The unmapped geometry behind `geometry`.
    func source(of geometry: SCNGeometry) -> SCNGeometry { sources[ObjectIdentifier(geometry)] ?? geometry }

    /// Carries the unmapped source over to a copy of a mapped geometry (e.g. when an object gets its own materials).
    func inherit(from geometry: SCNGeometry, to copy: SCNGeometry) {
        if let source = sources[ObjectIdentifier(geometry)] { sources[ObjectIdentifier(copy)] = source }
    }

    /// Rebuilds the texture coordinates of every mesh under `root` that uses one of `entries`
    /// (or every mesh, when `entries` is nil). Returns whether anything changed.
    @discardableResult
    func apply(root: SCNNode, entries allEntries: [MaterialEntry], only entries: [MaterialEntry]? = nil, metersPerUnit: Double) -> Bool {
        let targets = entries ?? allEntries
        let targetMaterials = Set(targets.flatMap(\.materials).map(ObjectIdentifier.init))
        var mappingFor: [ObjectIdentifier: (entry: MaterialEntry, mapping: TextureMapping)] = [:]
        for entry in allEntries { for m in entry.materials { mappingFor[ObjectIdentifier(m)] = (entry, entry.mapping) } }

        let nodes = ModelDocument.geometryNodes(in: root).filter { node in
            node.skinner == nil && node.morpher == nil
                && (node.geometry?.materials ?? []).contains { targetMaterials.contains(ObjectIdentifier($0)) }
        }
        guard !nodes.isEmpty else { return false }
        let scale = Float(metersPerUnit)

        var changed = false
        for node in nodes {
            guard let current = node.geometry else { continue }
            let source = source(of: current)
            let materials = current.materials
            let mappings: [(MaterialEntry, TextureMapping)?] = materials.map { mappingFor[ObjectIdentifier($0)].map { ($0.entry, $0.mapping) } }
            if mappings.allSatisfy({ $0?.1.isIdentity ?? true }) {
                // Back to the original UVs.
                if current !== source {
                    source.materials = materials
                    node.geometry = source
                    changed = true
                }
                continue
            }
            guard let mesh = mesh(for: source),
                  let mapped = build(mesh: mesh, source: source, materials: materials, mappings: mappings, node: node,
                                     root: root, scale: scale) else { continue }
            sources[ObjectIdentifier(mapped)] = source
            node.geometry = mapped
            changed = true
        }
        return changed
    }

    private func mesh(for geometry: SCNGeometry) -> MeshData? {
        let key = ObjectIdentifier(geometry)
        if let cached = meshes[key] { return cached }
        let mesh = MeshData(geometry)
        meshes[key] = mesh
        return mesh
    }

    /// A copy of `source` with one vertex per face corner, carrying projected UVs on mapped elements
    /// and the original UVs elsewhere.
    private func build(mesh: MeshData, source: SCNGeometry, materials: [SCNMaterial], mappings: [(MaterialEntry, TextureMapping)?],
                       node: SCNNode, root: SCNNode, scale: Float) -> SCNGeometry? {
        // Cylindrical and spherical projections wrap around each part's own center, like KeyShot.
        let worldPoints = mesh.points.map { node.simdConvertPosition($0, to: root) * scale }
        let lo = worldPoints.reduce(SIMD3<Float>(repeating: .infinity), simd_min)
        let hi = worldPoints.reduce(SIMD3<Float>(repeating: -.infinity), simd_max)
        let center = (lo + hi) / 2
        func radius(for mapping: TextureMapping) -> Float {
            let i = mapping.axis.index
            let distances = worldPoints.map { p -> Float in
                var d = p - center
                if mapping.kind == .cylindrical { d[i] = 0 }
                return simd_length(d)
            }
            return max(distances.reduce(0, +) / Float(max(distances.count, 1)), 1e-4)
        }
        var positions: [SIMD3<Float>] = [], normals: [SIMD3<Float>] = [], uvs: [SIMD2<Float>] = []
        var elements: [SCNGeometryElement] = []
        let corners = mesh.indices.count
        positions.reserveCapacity(corners)
        uvs.reserveCapacity(corners)
        var corner = 0, face = 0
        for (element, faceCount) in mesh.elementFaces.enumerated() {
            let mapping = materials.isEmpty ? nil : mappings[element % materials.count]
            let radius = mapping.map { radius(for: $0.1) } ?? 1
            var counts: [Int32] = [], indices: [Int32] = []
            for _ in 0..<faceCount {
                let n = Int(mesh.counts[face])
                let cornerRange = corner..<(corner + n)
                let local = cornerRange.map { mesh.points[Int(mesh.indices[$0])] }
                positions += local
                if let meshNormals = mesh.normals {
                    normals += cornerRange.map { mesh.normalsPerCorner ? meshNormals[$0] : meshNormals[Int(mesh.indices[$0])] }
                }
                if let (_, m) = mapping, !m.isIdentity {
                    let world = cornerRange.map { worldPoints[Int(mesh.indices[$0])] }
                    let faceNormal = Self.normal(of: world)
                    uvs += m.coordinates(points: world, normal: faceNormal, center: center, radius: radius)
                } else if let meshUVs = mesh.uvs {
                    uvs += cornerRange.map { mesh.uvsPerCorner ? meshUVs[$0] : meshUVs[Int(mesh.indices[$0])] }
                } else {
                    uvs += Array(repeating: .zero, count: n)
                }
                counts.append(Int32(n))
                indices += cornerRange.map { Int32($0) }
                corner += n
                face += 1
            }
            let data = counts.withUnsafeBytes { Data($0) } + indices.withUnsafeBytes { Data($0) }
            elements.append(SCNGeometryElement(data: data, primitiveType: .polygon, primitiveCount: counts.count, bytesPerIndex: 4))
        }
        guard !positions.isEmpty else { return nil }
        var sources = [Self.source(positions, semantic: .vertex)]
        if normals.count == positions.count { sources.append(Self.source(normals, semantic: .normal)) }
        sources.append(Self.source(uvs, semantic: .texcoord))
        let geometry = SCNGeometry(sources: sources, elements: elements)
        geometry.name = source.name
        geometry.materials = materials
        return geometry
    }

    /// Newell's method: the normal of a (possibly non-planar) polygon.
    private static func normal(of points: [SIMD3<Float>]) -> SIMD3<Float> {
        var n = SIMD3<Float>.zero
        for i in points.indices {
            let a = points[i], b = points[(i + 1) % points.count]
            n += SIMD3((a.y - b.y) * (a.z + b.z), (a.z - b.z) * (a.x + b.x), (a.x - b.x) * (a.y + b.y))
        }
        let length = simd_length(n)
        return length > 0 ? n / length : SIMD3(0, 0, 1)
    }

    private static func source(_ values: [SIMD3<Float>], semantic: SCNGeometrySource.Semantic) -> SCNGeometrySource {
        let packed = values.flatMap { [$0.x, $0.y, $0.z] }
        return SCNGeometrySource(data: packed.withUnsafeBytes { Data($0) }, semantic: semantic, vectorCount: values.count,
                                 usesFloatComponents: true, componentsPerVector: 3, bytesPerComponent: 4, dataOffset: 0, dataStride: 12)
    }

    private static func source(_ values: [SIMD2<Float>], semantic: SCNGeometrySource.Semantic) -> SCNGeometrySource {
        let packed = values.flatMap { [$0.x, $0.y] }
        return SCNGeometrySource(data: packed.withUnsafeBytes { Data($0) }, semantic: semantic, vectorCount: values.count,
                                 usesFloatComponents: true, componentsPerVector: 2, bytesPerComponent: 4, dataOffset: 0, dataStride: 8)
    }
}
