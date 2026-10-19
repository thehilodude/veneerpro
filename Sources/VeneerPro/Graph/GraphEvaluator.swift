import CoreGraphics
import Foundation
import simd

enum TextureChannel: String {
    case rgb, r, g, b, a

    var outputName: String { self == .rgb ? "rgb" : rawValue }
}

/// An unmodified source texture reaching a surface input, which can be referenced
/// directly in the USD instead of being baked.
struct Passthrough: Hashable {
    let texture: TextureRef
    let channel: TextureChannel
}

enum GraphValue {
    case constant(SIMD4<Float>)
    case image(Bitmap, Passthrough?)

    var passthrough: Passthrough? {
        if case let .image(_, p) = self { return p }
        return nil
    }
}

/// The evaluated surface: one value per `MaterialGraph.Channel`.
struct MaterialResult {
    var values: [GraphValue]
    var connected: [Bool]

    subscript(_ channel: MaterialGraph.Channel) -> GraphValue { values[channel.rawValue] }
    func isConnected(_ channel: MaterialGraph.Channel) -> Bool { connected[channel.rawValue] }
}

/// Evaluates a snapshot of a graph at a fixed bake resolution.
/// Constants stay constants; anything touching a texture becomes a bitmap.
final class GraphEvaluator {
    let size: Int
    private let nodes: [UUID: GraphNode]
    private let links: [PortRef: PortRef]
    private let outputID: UUID
    private var cache: [PortRef: GraphValue] = [:]
    private var sampled: [UUID: Bitmap] = [:]

    init(graph: MaterialGraph, size: Int) {
        self.size = size
        nodes = Dictionary(uniqueKeysWithValues: graph.nodes.map { ($0.id, $0) })
        links = Dictionary(graph.links.map { ($0.to, $0.from) }, uniquingKeysWith: { a, _ in a })
        outputID = graph.outputNodeID
    }

    static func bakeSize(for graph: MaterialGraph) -> Int {
        graph.node(graph.outputNodeID).flatMap { Int($0.option) } ?? 1024
    }

    func evaluateMaterial() -> MaterialResult {
        let out = nodes[outputID]!
        let count = NodeKind.surfaceOutput.inputs.count
        return MaterialResult(
            values: (0..<count).map { input(out, $0) },
            connected: (0..<count).map { links[PortRef(node: outputID, port: $0)] != nil })
    }

    func value(of output: PortRef) -> GraphValue {
        if let cached = cache[output] { return cached }
        guard let node = nodes[output.node] else { return .constant(.zero) }
        let result = compute(node, port: output.port)
        cache[output] = result
        return result
    }

    /// A small preview of a node's first output, for drawing inside the node.
    func thumbnail(of node: UUID) -> CGImage? {
        guard let n = nodes[node], !n.kind.outputs.isEmpty else { return nil }
        return render(value(of: PortRef(node: node, port: 0)))
    }

    func render(_ value: GraphValue, linear: Bool = false) -> CGImage? {
        switch value {
        case let .constant(c): Bitmap(size: 4) { _, _ in c }.cgImage(linear: linear)
        case let .image(bitmap, _): bitmap.cgImage(linear: linear)
        }
    }

    // MARK: - Inputs

    private func input(_ node: GraphNode, _ index: Int) -> GraphValue {
        let socket = node.kind.inputs[index]
        guard let source = links[PortRef(node: node.id, port: index)], let sourceNode = nodes[source.node] else {
            return .constant(node.value(socket.name))
        }
        let value = value(of: source)
        if socket.type == .float, sourceNode.kind.outputs[source.port].type == .color {
            return map(value, Self.luminance)
        }
        return value
    }

    // MARK: - Per-pixel helpers (constants fold automatically)

    private func map(_ a: GraphValue, _ f: (SIMD4<Float>) -> SIMD4<Float>) -> GraphValue {
        switch a {
        case let .constant(c): .constant(f(c))
        case let .image(bitmap, _): .image(bitmap.map(f), nil)
        }
    }

    private func map(_ values: [GraphValue], _ f: ([SIMD4<Float>]) -> SIMD4<Float>) -> GraphValue {
        let bitmaps = values.compactMap { v -> Bitmap? in
            if case let .image(b, _) = v { return b }
            return nil
        }
        guard !bitmaps.isEmpty else {
            return .constant(f(values.map { if case let .constant(c) = $0 { c } else { .zero } }))
        }
        let sources: [(Int) -> SIMD4<Float>] = values.map { v in
            switch v {
            case let .constant(c): { _ in c }
            case let .image(b, _): { b.pixels[$0] }
            }
        }
        return .image(Bitmap(size: size) { x, y in
            let i = y * self.size + x
            return f(sources.map { $0(i) })
        }, nil)
    }

    private func generate(_ f: (Float, Float) -> SIMD4<Float>) -> GraphValue {
        let s = Float(size)
        return .image(Bitmap(size: size) { x, y in f((Float(x) + 0.5) / s, (Float(y) + 0.5) / s) }, nil)
    }

    static func luminance(_ c: SIMD4<Float>) -> SIMD4<Float> {
        NodeKind.gray(simd_dot(SIMD3(c.x, c.y, c.z), SIMD3(0.2126, 0.7152, 0.0722)))
    }

    // MARK: - Nodes

    private func compute(_ node: GraphNode, port: Int) -> GraphValue {
        switch node.kind {
        case .surfaceOutput:
            return .constant(.zero)

        case .color:
            var c = node.value("Color")
            c.w = 1
            return .constant(c)

        case .value:
            return .constant(NodeKind.gray(node.value("Value").x))

        case .imageTexture:
            return textureOutput(node, port: port)

        case .checker:
            let a = node.value("Color 1"), b = node.value("Color 2")
            let scale = max(1, node.value("Scale").x.rounded())
            return generate { u, v in
                (Int(u * scale) + Int(v * scale)) % 2 == 0 ? a : b
            }

        case .gradient:
            let a = node.value("Color 1"), b = node.value("Color 2")
            let kind = node.option
            return generate { u, v in
                let t: Float = switch kind {
                case "Vertical": v
                case "Radial": min(1, simd_length(SIMD2(u - 0.5, v - 0.5)) * 2)
                default: u
                }
                return simd_mix(a, b, SIMD4(repeating: t))
            }

        case .noise:
            // Whole cells per axis, wrapped, so the bake tiles seamlessly. Stretch elongates the cells
            // along U for grain and brushed streaks (older graphs without the field read as 1).
            let stretch = max(1, node.value("Stretch").x)
            let sy = max(1, node.value("Scale").x.rounded())
            let sx = max(1, (sy / stretch).rounded())
            let period = SIMD2<Int32>(Int32(sx), Int32(sy))
            let seed = UInt32(max(0, node.value("Seed").x))
            let color = node.option == "Color"
            return generate { u, v in
                if color {
                    return SIMD4(Self.valueNoise(u * sx, v * sy, seed: seed, period: period),
                                 Self.valueNoise(u * sx, v * sy, seed: seed &+ 101, period: period),
                                 Self.valueNoise(u * sx, v * sy, seed: seed &+ 211, period: period), 1)
                }
                return NodeKind.gray(Self.valueNoise(u * sx, v * sy, seed: seed, period: period))
            }

        case .mix:
            let blend = node.option
            return map([input(node, 0), input(node, 1), input(node, 2)]) { p in
                let a = p[0], b = p[1], f = simd_clamp(p[2].x, 0, 1)
                let blended: SIMD4<Float> = switch blend {
                case "Multiply": a * b
                case "Screen": 1 - (1 - a) * (1 - b)
                case "Overlay": SIMD4((0..<4).map { a[$0] < 0.5 ? 2 * a[$0] * b[$0] : 1 - 2 * (1 - a[$0]) * (1 - b[$0]) })
                default: b
                }
                var r = simd_mix(a, blended, SIMD4(repeating: f))
                r.w = 1
                return r
            }

        case .math:
            let op = MathOperation(rawValue: node.option) ?? .add
            return map([input(node, 0), input(node, 1)]) { p in op.apply(p[0], p[1]) }

        case .invert:
            return map(input(node, 0)) { c in SIMD4(1 - c.x, 1 - c.y, 1 - c.z, 1) }

        case .hueSaturation:
            let hue = node.value("Hue").x, sat = node.value("Saturation").x, val = node.value("Value").x
            return map(input(node, 0)) { c in
                var hsv = Self.rgbToHSV(SIMD3(c.x, c.y, c.z))
                hsv.x = (hsv.x + hue).truncatingRemainder(dividingBy: 1)
                if hsv.x < 0 { hsv.x += 1 }
                hsv.y = simd_clamp(hsv.y * sat, 0, 1)
                hsv.z *= val
                let rgb = Self.hsvToRGB(hsv)
                return SIMD4(rgb, 1)
            }

        case .brightnessContrast:
            let brightness = node.value("Brightness").x, contrast = node.value("Contrast").x
            return map(input(node, 0)) { c in
                var r = (c - 0.5) * contrast + 0.5 + brightness
                r.w = 1
                return r
            }

        case .separateRGB:
            let channel = min(port, 3)
            return map(input(node, 0)) { c in NodeKind.gray(c[channel]) }

        case .combineRGB:
            return map([input(node, 0), input(node, 1), input(node, 2)]) { p in SIMD4(p[0].x, p[1].x, p[2].x, 1) }

        case .normalStrength:
            let strength = node.value("Strength").x
            return map(input(node, 0)) { c in
                var n = SIMD3(c.x, c.y, c.z) * 2 - 1
                n.x *= strength
                n.y *= strength
                n = simd_normalize(SIMD3(n.x, n.y, max(n.z, 0.0001)))
                return SIMD4(n * 0.5 + 0.5, 1)
            }

        case .mapRange:
            let fromMin = node.value("From Min").x, fromMax = node.value("From Max").x
            let toMin = node.value("To Min").x, toMax = node.value("To Max").x
            let span = fromMax - fromMin
            return map(input(node, 0)) { c in
                let t = span == 0 ? 0 : simd_clamp((c.x - fromMin) / span, 0, 1)
                return NodeKind.gray(toMin + t * (toMax - toMin))
            }
        }
    }

    private func textureOutput(_ node: GraphNode, port: Int) -> GraphValue {
        guard let texture = node.texture else {
            // Missing texture shows as magenta, like most DCC tools.
            return .constant(port == 0 ? SIMD4(1, 0, 1, 1) : NodeKind.gray(port == 4 ? 1 : 0))
        }
        let tiling = node.value("Tiling")
        let tu = tiling.x == 0 ? 1 : tiling.x, tv = tiling.y == 0 ? 1 : tiling.y
        let bitmap: Bitmap
        if let cached = sampled[node.id] {
            bitmap = cached
        } else {
            let pixels = texture.pixels
            let s = Float(size)
            bitmap = Bitmap(size: size) { x, y in
                var u = (Float(x) + 0.5) / s * tu, v = (Float(y) + 0.5) / s * tv
                u -= u.rounded(.down)
                v -= v.rounded(.down)
                return pixels.sample(u: u, v: v)
            }
            sampled[node.id] = bitmap
        }
        let untiled = tu == 1 && tv == 1
        let channel: TextureChannel = [.rgb, .r, .g, .b, .a][min(port, 4)]
        let passthrough = untiled ? Passthrough(texture: texture, channel: channel) : nil
        let image: Bitmap = switch channel {
        case .rgb: bitmap.map { SIMD4($0.x, $0.y, $0.z, 1) }
        case .r: bitmap.map { NodeKind.gray($0.x) }
        case .g: bitmap.map { NodeKind.gray($0.y) }
        case .b: bitmap.map { NodeKind.gray($0.z) }
        case .a: bitmap.map { NodeKind.gray($0.w) }
        }
        return .image(image, passthrough)
    }

    // MARK: - Math utilities

    private static func hash(_ x: Int32, _ y: Int32, _ seed: UInt32) -> Float {
        var h = UInt32(bitPattern: x) &* 374_761_393 &+ UInt32(bitPattern: y) &* 668_265_263 &+ seed &* 2_147_483_647
        h = (h ^ (h >> 13)) &* 1_274_126_177
        h ^= h >> 16
        return Float(h & 0xFFFFFF) / Float(0xFFFFFF)
    }

    /// Smooth value noise; with `period`, lattice cells wrap so the pattern tiles.
    static func valueNoise(_ x: Float, _ y: Float, seed: UInt32, period: SIMD2<Int32>? = nil) -> Float {
        let xi = Int32(x.rounded(.down)), yi = Int32(y.rounded(.down))
        let tx = x - Float(xi), ty = y - Float(yi)
        let sx = tx * tx * (3 - 2 * tx), sy = ty * ty * (3 - 2 * ty)
        func h(_ i: Int32, _ j: Int32) -> Float {
            guard let period else { return hash(i, j, seed) }
            return hash(((i % period.x) + period.x) % period.x, ((j % period.y) + period.y) % period.y, seed)
        }
        let a = h(xi, yi), b = h(xi + 1, yi)
        let c = h(xi, yi + 1), d = h(xi + 1, yi + 1)
        return (a + (b - a) * sx) * (1 - sy) + (c + (d - c) * sx) * sy
    }

    static func rgbToHSV(_ c: SIMD3<Float>) -> SIMD3<Float> {
        let maxC = c.max(), minC = c.min(), delta = maxC - minC
        var h: Float = 0
        if delta > 0 {
            if maxC == c.x { h = (c.y - c.z) / delta }
            else if maxC == c.y { h = 2 + (c.z - c.x) / delta }
            else { h = 4 + (c.x - c.y) / delta }
            h /= 6
            if h < 0 { h += 1 }
        }
        return SIMD3(h, maxC > 0 ? delta / maxC : 0, maxC)
    }

    static func hsvToRGB(_ hsv: SIMD3<Float>) -> SIMD3<Float> {
        let h = hsv.x * 6, s = hsv.y, v = hsv.z
        let i = Int(h.rounded(.down)) % 6
        let f = h - h.rounded(.down)
        let p = v * (1 - s), q = v * (1 - s * f), t = v * (1 - s * (1 - f))
        switch i {
        case 0: return SIMD3(v, t, p)
        case 1: return SIMD3(q, v, p)
        case 2: return SIMD3(p, v, t)
        case 3: return SIMD3(p, q, v)
        case 4: return SIMD3(t, p, v)
        default: return SIMD3(v, p, q)
        }
    }
}
