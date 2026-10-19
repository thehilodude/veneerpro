import CoreGraphics
import Foundation
import simd

extension MaterialGraph {
    /// Translates a KeyShot material file into a node graph.
    ///
    /// Surface parameters become Surface Output values. Where KeyShot drives a parameter from a
    /// texture chain, the chain is rebuilt with real nodes: `texture2_*` → Image Texture,
    /// `lux_color_adjust` → Hue / Saturation, `convert_rgba_to_float` → Map Range. Procedurals
    /// (wood, noise, brushed...) have no USD equivalent and are flattened to a color.
    ///
    /// - Parameters:
    ///   - textures: loaded textures keyed by lowercased file name.
    ///   - previewColor: sRGB color sampled from KeyShot's preview, used when the file has none.
    convenience init(keyShot ks: KeyShotMaterial, document doc: KeyShotDocument, name: String,
                     textures: [String: TextureRef], previewColor: SIMD3<Float>?) {
        self.init(name: name)
        let out = outputNodeID
        typealias C = Channel
        func setOutput(_ channel: C, _ value: SIMD4<Float>) {
            update(out) { $0.values[channel.name] = value }
        }

        let base = ks.color ?? previewColor ?? SIMD3(repeating: 0.8)
        setOutput(.baseColor, SIMD4(base, 1))
        setOutput(.metallic, NodeKind.gray(ks.metallic))
        setOutput(.roughness, NodeKind.gray(simd_clamp(ks.roughness ?? 0.5, 0, 1)))
        setOutput(.opacity, NodeKind.gray(ks.opacity))
        if ks.clearcoat > 0 {
            setOutput(.clearcoat, NodeKind.gray(ks.clearcoat))
            setOutput(.clearcoatRoughness, NodeKind.gray(ks.clearcoatRoughness))
        }
        if let e = ks.emissive { setOutput(.emissive, SIMD4(e, 1)) }

        // Rebuild texture chains as nodes, memoized per KeyShot shader.
        var built: [Int: UUID] = [:]
        func translate(_ id: Int, depth: Int = 0) -> UUID? {
            if let existing = built[id] { return existing }
            guard depth < 8, let shader = doc.shaders[id] else { return nil }
            var node: UUID?
            switch shader.type {
            case let type where type.hasPrefix("texture2"):
                guard let file = shader.strings["texture"], let texture = textures[file.lowercased()] else { return nil }
                node = addNode(.imageTexture, at: .zero, texture: texture)
            case "lux_color_adjust":
                guard let input = shader.links["color"].flatMap({ translate($0, depth: depth + 1) }) else { return nil }
                let hsv = addNode(.hueSaturation, at: .zero)
                var hue = shader.number("hue") ?? 0
                if abs(hue) > 1 { hue /= 360 } // degrees
                update(hsv) {
                    $0.values["Hue"] = NodeKind.gray(hue)
                    $0.values["Saturation"] = NodeKind.gray(shader.number("saturation") ?? 1)
                    $0.values["Value"] = NodeKind.gray(shader.number("value") ?? 1)
                }
                connect(PortRef(node: input, port: 0), PortRef(node: hsv, port: 0))
                node = hsv
            case let type where type.hasPrefix("convert_"):
                guard let input = shader.links["input"].flatMap({ translate($0, depth: depth + 1) }) else { return nil }
                let fromMin = shader.number("input_from") ?? 0, fromMax = shader.number("input_to") ?? 1
                let toMin = shader.number("output_from") ?? 0, toMax = shader.number("output_to") ?? 1
                if fromMin == 0, fromMax == 1, toMin == 0, toMax == 1 {
                    node = input // identity remap: wire the source straight through
                } else {
                    let remap = addNode(.mapRange, at: .zero)
                    update(remap) {
                        $0.values["From Min"] = NodeKind.gray(fromMin)
                        $0.values["From Max"] = NodeKind.gray(fromMax)
                        $0.values["To Min"] = NodeKind.gray(toMin)
                        $0.values["To Max"] = NodeKind.gray(toMax)
                    }
                    connect(PortRef(node: input, port: 0), PortRef(node: remap, port: 0))
                    node = remap
                }
            case let type where type.hasPrefix("edgeshader"):
                // Rounded-edge wrappers just pass their input through.
                node = shader.links["input"].flatMap { translate($0, depth: depth + 1) }
            default:
                return nil
            }
            if let node { built[id] = node }
            return node
        }

        func link(_ id: Int?, to channel: C) {
            guard let id, let node = translate(id), let kind = self.node(node)?.kind else { return }
            // Float inputs read a texture's R channel; everything else uses the first output.
            let port = (kind == .imageTexture && !channel.isColor) ? 1 : 0
            connect(PortRef(node: node, port: port), PortRef(node: out, port: channel.rawValue))
        }
        link(ks.colorLink, to: ks.family == .emissive ? .emissive : .baseColor)
        link(ks.roughnessLink, to: .roughness)
        link(ks.opacityLink, to: .opacity)
        link(ks.normalMapLink, to: .normal)

        autoLayout()
    }
}

extension CGImage {
    /// The material's color in a preview render: the most common color, ignoring the backdrop
    /// (estimated from the corners) so labels, floors and studio backgrounds don't skew it.
    func dominantColor() -> SIMD3<Float>? {
        let size = 64
        var pixels = [UInt8](repeating: 0, count: size * size * 4)
        guard let ctx = CGContext(data: &pixels, width: size, height: size, bitsPerComponent: 8, bytesPerRow: size * 4,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.draw(self, in: CGRect(x: 0, y: 0, width: size, height: size))
        func color(_ x: Int, _ y: Int) -> SIMD3<Float> {
            let i = (y * size + x) * 4
            return SIMD3(Float(pixels[i]), Float(pixels[i + 1]), Float(pixels[i + 2])) / 255
        }
        var corners: [SIMD3<Float>] = []
        for (cx, cy) in [(0, 0), (size - 4, 0), (0, size - 4), (size - 4, size - 4)] {
            for y in cy..<(cy + 4) { for x in cx..<(cx + 4) { corners.append(color(x, y)) } }
        }
        let background = corners.reduce(.zero, +) / Float(corners.count)

        // Bucket the remaining pixels (8 levels per channel) and average the fullest bucket.
        var buckets: [Int: (sum: SIMD3<Float>, count: Int)] = [:]
        for y in (size / 8)..<(size * 7 / 8) {
            for x in (size / 8)..<(size * 7 / 8) {
                let c = color(x, y)
                guard simd_distance(c, background) > 0.12 else { continue }
                let key = Int(c.x * 7.99) * 64 + Int(c.y * 7.99) * 8 + Int(c.z * 7.99)
                buckets[key, default: (.zero, 0)].sum += c
                buckets[key, default: (.zero, 0)].count += 1
            }
        }
        guard let best = buckets.values.max(by: { $0.count < $1.count }), best.count > 8 else { return nil }
        return best.sum / Float(best.count)
    }
}
