import CoreGraphics
import Foundation
import simd

extension MaterialGraph {
    /// Builds a node graph from a library material: one Image Texture node per map, wired into the
    /// Surface Output, with converter nodes where the maps need adapting (glossiness, DirectX normals).
    convenience init(library material: LibraryMaterial, textures: [MapKind: TextureRef], keyShot: KeyShotMaterial?,
                     previewColor: SIMD3<Float>? = nil) {
        self.init(name: material.name)
        let out = outputNodeID
        typealias C = Channel
        var textureY: CGFloat = 40
        var converterY: CGFloat = 40
        let textureX: CGFloat = 40, converterX: CGFloat = 330, outputX: CGFloat = 620

        func textureNode(_ kind: MapKind) -> UUID? {
            guard let texture = textures[kind] else { return nil }
            let id = addNode(.imageTexture, at: CGPoint(x: textureX, y: textureY), texture: texture)
            textureY += NodeLayout.height(of: node(id)!) + 24
            return id
        }
        func converterNode(_ kind: NodeKind) -> UUID {
            let id = addNode(kind, at: CGPoint(x: converterX, y: converterY))
            converterY += NodeLayout.height(of: node(id)!) + 24
            return id
        }
        func wire(_ from: UUID, _ port: Int, _ channel: C) {
            connect(PortRef(node: from, port: port), PortRef(node: out, port: channel.rawValue))
        }
        func setOutput(_ channel: C, _ value: SIMD4<Float>) {
            update(out) { $0.values[channel.name] = value }
        }

        // Image Texture outputs: 0 Color, 1 R, 2 G, 3 B, 4 Alpha.
        if let id = textureNode(.baseColor) { wire(id, 0, .baseColor) }

        if let id = textureNode(.roughness) {
            wire(id, 1, .roughness)
        } else if let id = textureNode(.glossiness) {
            // Glossiness is inverted roughness.
            let invert = converterNode(.invert)
            connect(PortRef(node: id, port: 0), PortRef(node: invert, port: 0))
            wire(invert, 0, .roughness)
        }

        if let id = textureNode(.metallic) { wire(id, 1, .metallic) }

        if let id = textureNode(.normalGL) {
            wire(id, 0, .normal)
        } else if let id = textureNode(.normalDX) {
            // DirectX normal maps have green flipped relative to OpenGL/USD.
            let separate = converterNode(.separateRGB)
            let invertG = converterNode(.invert)
            let combine = converterNode(.combineRGB)
            connect(PortRef(node: id, port: 0), PortRef(node: separate, port: 0))
            connect(PortRef(node: separate, port: 0), PortRef(node: combine, port: 0))
            connect(PortRef(node: separate, port: 1), PortRef(node: invertG, port: 0))
            connect(PortRef(node: invertG, port: 0), PortRef(node: combine, port: 1))
            connect(PortRef(node: separate, port: 2), PortRef(node: combine, port: 2))
            wire(combine, 0, .normal)
        }

        if let id = textureNode(.occlusion) { wire(id, 1, .occlusion) }
        // A packed Occlusion/Roughness/Metallic map (R/G/B) fills whichever of those has no map of its own.
        if textures[.packedORM] != nil {
            let needsOcclusion = textures[.occlusion] == nil
            let needsRoughness = textures[.roughness] == nil && textures[.glossiness] == nil
            let needsMetallic = textures[.metallic] == nil
            if needsOcclusion || needsRoughness || needsMetallic, let id = textureNode(.packedORM) {
                if needsOcclusion { wire(id, 1, .occlusion) }
                if needsRoughness { wire(id, 2, .roughness) }
                if needsMetallic { wire(id, 3, .metallic) }
            }
        }
        if let id = textureNode(.opacity) { wire(id, 1, .opacity) }
        if let id = textureNode(.emissive) { wire(id, 0, .emissive) }

        // Fill what the maps don't cover from the KeyShot material (or the preview render).
        if let ks = keyShot {
            if textures[.metallic] == nil, textures[.packedORM] == nil, ks.metallic > 0 { setOutput(.metallic, NodeKind.gray(ks.metallic)) }
            if textures[.opacity] == nil, ks.opacity < 1 { setOutput(.opacity, NodeKind.gray(ks.opacity)) }
            if ks.clearcoat > 0 {
                setOutput(.clearcoat, NodeKind.gray(ks.clearcoat))
                setOutput(.clearcoatRoughness, NodeKind.gray(ks.clearcoatRoughness))
            }
            if textures[.emissive] == nil, let e = ks.emissive { setOutput(.emissive, SIMD4(e, 1)) }
            let roughnessFromMaps = textures[.roughness] != nil || textures[.glossiness] != nil
            if !roughnessFromMaps, ks.roughnessLink == nil, let roughness = ks.roughness {
                setOutput(.roughness, NodeKind.gray(simd_clamp(roughness, 0, 1)))
            }
        }
        if textures[.baseColor] == nil, let color = keyShot?.color ?? previewColor {
            setOutput(.baseColor, SIMD4(color, 1))
        }

        update(out) { $0.position = CGPoint(x: textures.isEmpty ? 330 : outputX, y: 40) }
    }
}
