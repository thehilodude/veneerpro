import Foundation
import simd

/// How a material is specified for manufacturing: a color code and a finish. Kept on the graph so
/// colorways, undo and projects carry it with the look it describes.
struct CMFSpec: Equatable {
    /// e.g. "RAL 5015", "PANTONE 2945 C" or "#2874B2".
    var colorCode: String?
    var colorName: String?
    /// The sRGB color applied with the code, to notice when the base color is changed afterwards.
    var color: SIMD3<Float>?
    var finishID: String?
    /// Nodes the finish added (roughness grain), removed when another finish is applied.
    var finishNodes: [UUID] = []

    var finish: FinishPreset? { FinishPreset.preset(id: finishID) }
}

extension MaterialGraph {
    private var output: GraphNode? { node(outputNodeID) }

    private func port(_ channel: Channel) -> PortRef { PortRef(node: outputNodeID, port: channel.rawValue) }

    /// The constant base color, or nil when a node drives it.
    var constantBaseColor: SIMD3<Float>? {
        guard link(into: port(.baseColor)) == nil, let v = output?.value(Channel.baseColor.name) else { return nil }
        return SIMD3(v.x, v.y, v.z)
    }

    var baseColorIsLinked: Bool { link(into: port(.baseColor)) != nil }

    /// Whether the base color is still the color the spec was applied with.
    var colorMatchesSpec: Bool {
        guard let specified = spec.color, let current = constantBaseColor else { return false }
        return simd_reduce_max(simd_abs(specified - current)) < 0.6 / 255
    }

    /// Whether metallic, roughness and clear coat still match the spec's finish.
    var finishMatchesSpec: Bool {
        guard let finish = spec.finish, let output else { return false }
        func near(_ channel: Channel, _ value: Float) -> Bool {
            link(into: port(channel)) == nil && abs(output.value(channel.name).x - value) < 0.005
        }
        let roughnessOK: Bool
        if finish.grain != nil {
            roughnessOK = link(into: port(.roughness)).map { spec.finishNodes.contains($0.from.node) } ?? false
        } else {
            roughnessOK = near(.roughness, finish.roughness)
        }
        return roughnessOK && near(.metallic, finish.metallic) && near(.clearcoat, finish.clearcoat)
            && (finish.clearcoat == 0 || near(.clearcoatRoughness, finish.clearcoatRoughness))
    }

    /// Sets a constant base color (replacing any texture driving it) and records its code.
    func applyColor(_ rgb: SIMD3<Float>, code: String?, name colorName: String?) {
        links.removeAll { $0.to == port(.baseColor) }
        if let i = index(of: outputNodeID) { nodes[i].values[Channel.baseColor.name] = SIMD4(rgb, 1) }
        spec.color = rgb
        spec.colorCode = code
        spec.colorName = colorName
        touch()
    }

    /// Sets metallic, roughness and clear coat for `finish`. Textured finishes drive roughness
    /// with a noise node, replacing any previous finish's nodes and any texture on those inputs.
    func applyFinish(_ finish: FinishPreset) {
        let previous = Set(spec.finishNodes)
        nodes.removeAll { previous.contains($0.id) }
        links.removeAll { previous.contains($0.from.node) || previous.contains($0.to.node) }
        for channel in [Channel.metallic, .roughness, .clearcoat, .clearcoatRoughness] {
            links.removeAll { $0.to == port(channel) }
        }
        guard let i = index(of: outputNodeID) else { return }
        nodes[i].values[Channel.metallic.name] = NodeKind.gray(finish.metallic)
        nodes[i].values[Channel.roughness.name] = NodeKind.gray(finish.roughness)
        nodes[i].values[Channel.clearcoat.name] = NodeKind.gray(finish.clearcoat)
        nodes[i].values[Channel.clearcoatRoughness.name] = NodeKind.gray(finish.clearcoatRoughness)
        var added: [UUID] = []
        if let grain = finish.grain {
            let origin = nodes[i].position
            var noise = GraphNode(kind: .noise, position: CGPoint(x: origin.x - 480, y: origin.y + 260))
            noise.values["Scale"] = NodeKind.gray(grain.scale)
            noise.values["Stretch"] = NodeKind.gray(grain.stretch)
            var range = GraphNode(kind: .mapRange, position: CGPoint(x: origin.x - 240, y: origin.y + 260))
            range.values["To Min"] = NodeKind.gray(max(0, finish.roughness - grain.amount / 2))
            range.values["To Max"] = NodeKind.gray(min(1, finish.roughness + grain.amount / 2))
            nodes += [noise, range]
            links.append(GraphLink(from: PortRef(node: noise.id, port: 0), to: PortRef(node: range.id, port: 0)))
            links.append(GraphLink(from: PortRef(node: range.id, port: 0), to: port(.roughness)))
            added = [noise.id, range.id]
        }
        spec.finishID = finish.id
        spec.finishNodes = added
        touch()
    }

    /// Changes only the recorded spec (e.g. a code typed for the current color).
    func updateSpec(_ change: (inout CMFSpec) -> Void) {
        change(&spec)
        touch()
    }
}
