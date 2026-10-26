import AppKit
import Observation
import SceneKit
import simd

struct GraphNode: Identifiable {
    var id = UUID()
    var kind: NodeKind
    var position: CGPoint
    /// Default values for unconnected inputs and for float/color/vector fields, keyed by name.
    var values: [String: SIMD4<Float>]
    var option: String
    var texture: TextureRef?

    init(kind: NodeKind, position: CGPoint, texture: TextureRef? = nil) {
        self.kind = kind
        self.position = position
        self.values = kind.defaultValues
        self.option = kind == .surfaceOutput ? "1024" : kind.defaultOption
        self.texture = texture
    }

    func value(_ name: String) -> SIMD4<Float> { values[name] ?? .zero }
}

struct PortRef: Hashable {
    var node: UUID
    var port: Int
}

struct GraphLink: Identifiable, Hashable {
    var id = UUID()
    var from: PortRef
    var to: PortRef
}

/// A node-based material. Evaluating it produces the inputs of a UsdPreviewSurface.
@Observable
final class MaterialGraph: Identifiable {
    let id = UUID()
    var name: String
    var nodes: [GraphNode] = []
    var links: [GraphLink] = []
    /// Color code and finish (see CMFSpec.swift).
    var spec = CMFSpec()
    /// Bumped on every edit so observers can re-evaluate.
    private(set) var revision = 0
    @ObservationIgnored var onChange: (() -> Void)?
    /// Called for every user-visible edit, including node moves (which don't re-evaluate).
    @ObservationIgnored var onEdit: (() -> Void)?

    var outputNodeID: UUID { nodes.first { $0.kind == .surfaceOutput }!.id }

    init(name: String) {
        self.name = name
        nodes.append(GraphNode(kind: .surfaceOutput, position: CGPoint(x: 620, y: 40)))
    }

    func touch() {
        revision &+= 1
        onEdit?()
        onChange?()
    }

    /// Moves a node without re-evaluating the graph.
    func move(_ id: UUID, to position: CGPoint) {
        guard let i = index(of: id) else { return }
        nodes[i].position = position
        onEdit?()
    }

    /// The graph's editable content, for undo. Nodes and links are value types, so this is cheap.
    struct Snapshot: Equatable {
        var name: String
        var nodes: [GraphNode]
        var links: [GraphLink]
        var spec = CMFSpec()

        static func == (a: Snapshot, b: Snapshot) -> Bool {
            a.name == b.name && a.spec == b.spec && a.links == b.links && a.nodes.count == b.nodes.count
                && zip(a.nodes, b.nodes).allSatisfy { $0.id == $1.id && $0.position == $1.position && $0.values == $1.values
                    && $0.option == $1.option && $0.texture === $1.texture && $0.kind == $1.kind }
        }
    }

    var snapshot: Snapshot { Snapshot(name: name, nodes: nodes, links: links, spec: spec) }

    /// Replaces the content with a snapshot (re-evaluates, but isn't reported as a new edit).
    func restore(_ snapshot: Snapshot) {
        let edit = onEdit
        onEdit = nil
        name = snapshot.name
        nodes = snapshot.nodes
        links = snapshot.links
        spec = snapshot.spec
        touch()
        onEdit = edit
    }

    func node(_ id: UUID) -> GraphNode? { nodes.first { $0.id == id } }

    func index(of id: UUID) -> Int? { nodes.firstIndex { $0.id == id } }

    func update(_ id: UUID, _ body: (inout GraphNode) -> Void) {
        guard let i = index(of: id) else { return }
        body(&nodes[i])
        touch()
    }

    @discardableResult
    func addNode(_ kind: NodeKind, at position: CGPoint, texture: TextureRef? = nil) -> UUID {
        let node = GraphNode(kind: kind, position: position, texture: texture)
        nodes.append(node)
        touch()
        return node.id
    }

    func removeNode(_ id: UUID) {
        guard node(id)?.kind != .surfaceOutput else { return }
        nodes.removeAll { $0.id == id }
        links.removeAll { $0.from.node == id || $0.to.node == id }
        touch()
    }

    func duplicateNode(_ id: UUID) {
        guard var copy = node(id), copy.kind != .surfaceOutput else { return }
        copy.id = UUID()
        copy.position.x += 30
        copy.position.y += 30
        nodes.append(copy)
        touch()
    }

    func link(into input: PortRef) -> GraphLink? { links.first { $0.to == input } }

    /// Connects an output to an input, replacing any existing link into that input.
    /// Returns false if the connection would create a cycle.
    @discardableResult
    func connect(_ from: PortRef, _ to: PortRef) -> Bool {
        guard from.node != to.node, !reaches(from: to.node, target: from.node) else { return false }
        links.removeAll { $0.to == to }
        links.append(GraphLink(from: from, to: to))
        touch()
        return true
    }

    func disconnect(_ input: PortRef) {
        links.removeAll { $0.to == input }
        touch()
    }

    /// True if `target` is downstream of `start`.
    private func reaches(from start: UUID, target: UUID) -> Bool {
        var stack = [start]
        var seen: Set<UUID> = []
        while let current = stack.popLast() {
            if current == target { return true }
            guard seen.insert(current).inserted else { continue }
            stack += links.filter { $0.from.node == current }.map(\.to.node)
        }
        return false
    }

    /// Lays nodes out in columns by their distance from the output node.
    func autoLayout() {
        var depth: [UUID: Int] = [outputNodeID: 0]
        var queue = [outputNodeID]
        while !queue.isEmpty {
            let current = queue.removeFirst()
            for link in links where link.to.node == current {
                let d = depth[current]! + 1
                if (depth[link.from.node] ?? -1) < d {
                    depth[link.from.node] = d
                    queue.append(link.from.node)
                }
            }
        }
        let maxDepth = depth.values.max() ?? 0
        var rowY: [Int: CGFloat] = [:]
        // Keep the order of the output's inputs so wires don't cross.
        let order = nodes.sorted { a, b in
            let ia = links.first { $0.from.node == a.id }?.to.port ?? 99
            let ib = links.first { $0.from.node == b.id }?.to.port ?? 99
            return ia < ib
        }
        for node in order {
            // Unconnected nodes go in the leftmost column.
            let d = depth[node.id] ?? max(maxDepth, 1)
            let y = rowY[d, default: 40]
            move(node.id, to: CGPoint(x: 40 + CGFloat(max(maxDepth, 1) - d) * 260, y: y))
            rowY[d] = y + NodeLayout.height(of: node) + 24
        }
    }
}

// MARK: - Building a graph from an imported SceneKit material

extension MaterialGraph {
    /// Surface output input index for each SceneKit material property.
    enum Channel: Int, CaseIterable {
        case baseColor = 0, metallic, roughness, normal, emissive, opacity, occlusion, clearcoat, clearcoatRoughness

        var isColor: Bool { self == .baseColor || self == .emissive || self == .normal }
        var name: String { NodeKind.surfaceOutput.inputs[rawValue].name }

        func property(of m: SCNMaterial) -> SCNMaterialProperty {
            switch self {
            case .baseColor: m.diffuse
            case .metallic: m.metalness
            case .roughness: m.roughness
            case .normal: m.normal
            case .emissive: m.emission
            case .opacity: m.transparent
            case .occlusion: m.ambientOcclusion
            case .clearcoat: m.clearCoat
            case .clearcoatRoughness: m.clearCoatRoughness
            }
        }
    }

    convenience init(material: SCNMaterial, fallbackName: String) {
        self.init(name: material.name ?? fallbackName)
        let out = outputNodeID
        var textureNodes: [TextureRef: UUID] = [:]
        var textureCache: [ObjectIdentifier: TextureRef] = [:]
        var y: CGFloat = 40

        for channel in Channel.allCases {
            let property = channel.property(of: material)
            let contents = property.contents
            if let color = Self.colorValue(contents) {
                if channel == .opacity {
                    update(out) { $0.values[channel.name] = NodeKind.gray(color.x * Float(material.transparency)) }
                } else if channel != .normal && channel != .occlusion {
                    // SceneKit fills unused normal/AO slots with placeholder colors; only textures matter there.
                    update(out) { $0.values[channel.name] = channel.isColor ? color : NodeKind.gray(color.x) }
                }
                continue
            }
            let texture: TextureRef?
            if let object = contents as AnyObject?, let cached = textureCache[ObjectIdentifier(object)] {
                texture = cached
            } else {
                texture = TextureRef.from(contents: contents, fallbackName: "\(name)_\(channel.name)")
                if let texture, let object = contents as AnyObject? { textureCache[ObjectIdentifier(object)] = texture }
            }
            guard let texture else { continue }

            let nodeID: UUID
            if let existing = textureNodes[texture] {
                nodeID = existing
            } else {
                nodeID = addNode(.imageTexture, at: CGPoint(x: 300, y: y), texture: texture)
                textureNodes[texture] = nodeID
                y += NodeLayout.height(of: node(nodeID)!) + 24
            }
            let outputPort: Int
            if channel.isColor {
                outputPort = 0
            } else {
                let mask = property.textureComponents
                outputPort = mask == .green ? 2 : mask == .blue ? 3 : mask == .alpha ? 4 : 1
            }
            connect(PortRef(node: nodeID, port: outputPort), PortRef(node: out, port: channel.rawValue))
        }
        update(out) { $0.position = CGPoint(x: textureNodes.isEmpty ? 300 : 620, y: 40) }
    }

    private static func colorValue(_ contents: Any?) -> SIMD4<Float>? {
        switch contents {
        case nil: return nil
        case let number as NSNumber: return NodeKind.gray(number.floatValue)
        case let color as NSColor: return srgbComponents(color)
        default:
            if CFGetTypeID(contents as CFTypeRef) == CGColor.typeID, let color = NSColor(cgColor: contents as! CGColor) {
                return srgbComponents(color)
            }
            return nil
        }
    }

    /// Graph colors are sRGB-encoded. SceneKit tags USD's linear colors as "Display P3 Linear";
    /// those are plain linear values, so only the transfer curve is undone (no gamut mapping),
    /// which keeps an import → export round trip exact.
    private static func srgbComponents(_ color: NSColor) -> SIMD4<Float>? {
        if let space = color.colorSpace.cgColorSpace, (space.name as String?)?.contains("Linear") == true,
           color.numberOfComponents >= 3 {
            var c = [CGFloat](repeating: 0, count: color.numberOfComponents)
            color.getComponents(&c)
            func encode(_ v: CGFloat) -> Float {
                let x = Float(max(0, v))
                return x <= 0.0031308 ? x * 12.92 : 1.055 * powf(x, 1 / 2.4) - 0.055
            }
            return SIMD4(encode(c[0]), encode(c[1]), encode(c[2]), Float(color.alphaComponent))
        }
        guard let c = color.usingColorSpace(.sRGB) else { return nil }
        return SIMD4(Float(c.redComponent), Float(c.greenComponent), Float(c.blueComponent), Float(c.alphaComponent))
    }
}
