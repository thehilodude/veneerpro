import Foundation
import simd

/// A value in KeyShot's binary "chunk" format (used by `.klf` lighting files).
indirect enum KLFValue {
    case bool(Bool)
    case float(Float)
    case int(Int)
    case color(SIMD3<Float>)
    case string(String)
    case object(KLFObject)
    case array([KLFObject])
    case floats([Float])
    case colors([SIMD3<Float>])
    case other
}

/// `{ tag "class" ("key" value)* }`
struct KLFObject {
    var className: String
    var fields: [String: KLFValue] = [:]

    func float(_ key: String) -> Float? {
        switch fields[key] {
        case let .float(v): v
        case let .int(v): Float(v)
        default: nil
        }
    }
    func int(_ key: String) -> Int? {
        switch fields[key] {
        case let .int(v): v
        case let .float(v): Int(v)
        default: nil
        }
    }
    func bool(_ key: String) -> Bool? { if case let .bool(v) = fields[key] { v } else { nil } }
    func color(_ key: String) -> SIMD3<Float>? { if case let .color(v) = fields[key] { v } else { nil } }
    func object(_ key: String) -> KLFObject? { if case let .object(v) = fields[key] { v } else { nil } }
    func array(_ key: String) -> [KLFObject] { if case let .array(v) = fields[key] { v } else { [] } }
    func floats(_ key: String) -> [Float] { if case let .floats(v) = fields[key] { v } else { [] } }
    func colors(_ key: String) -> [SIMD3<Float>] { if case let .colors(v) = fields[key] { v } else { [] } }
}

/// Reads KeyShot `.klf` lighting files (HDRI-editor studios and Sun & Sky) and renders them to HDR.
///
/// The file's `binarychunk` is a typed tree: objects are `{` tag `s`+class, entries are `s`+key
/// followed by a typed value (`B` bool, `f` float32, `w` int32, `c` rgb, `U` string, `{` object,
/// `[ … ]` object array, `<` type `s` byte-count data `>` typed array).
enum KeyShotLighting {
    static func parse(_ url: URL) -> KLFObject? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let bytes = [UInt8](data)
        guard let chunk = bytes.firstRange(of: Array("binarychunk".utf8)),
              let marker = bytes[chunk.upperBound...].firstRange(of: [0x01, 0x02, 0x03, UInt8(ascii: "b")]) else { return nil }
        var parser = Parser(bytes: bytes, p: marker.upperBound + 4) // skip the 4-byte chunk length
        return try? parser.object()
    }

    private struct Parser {
        let bytes: [UInt8]
        var p: Int
        struct Malformed: Error {}

        mutating func byte() throws -> UInt8 {
            guard p < bytes.count else { throw Malformed() }
            defer { p += 1 }
            return bytes[p]
        }
        mutating func string() throws -> String {
            guard try byte() == UInt8(ascii: "s") else { throw Malformed() }
            let n = Int(try byte())
            guard p + n <= bytes.count else { throw Malformed() }
            defer { p += n }
            return String(decoding: bytes[p..<(p + n)], as: UTF8.self)
        }
        mutating func f32() throws -> Float {
            guard p + 4 <= bytes.count else { throw Malformed() }
            defer { p += 4 }
            return Float(bitPattern: UInt32(bytes[p]) | UInt32(bytes[p + 1]) << 8 | UInt32(bytes[p + 2]) << 16 | UInt32(bytes[p + 3]) << 24)
        }
        mutating func object() throws -> KLFObject {
            guard try byte() == UInt8(ascii: "{") else { throw Malformed() }
            _ = try byte() // tag
            var object = KLFObject(className: try string())
            while p < bytes.count, bytes[p] != UInt8(ascii: "}") {
                let key = try string()
                object.fields[key] = try value()
            }
            p += 1
            return object
        }
        mutating func value() throws -> KLFValue {
            switch Character(UnicodeScalar(try byte())) {
            case "B": return .bool(try byte() != 0)
            case "f": return .float(try f32())
            case "w": return .int(Int(Int32(bitPattern: try f32().bitPattern)))
            case "c": return .color(SIMD3(try f32(), try f32(), try f32()))
            case "U": return .string(try string())
            case "{":
                p -= 1
                return .object(try object())
            case "[":
                var items: [KLFObject] = []
                while p < bytes.count, bytes[p] != UInt8(ascii: "]") { items.append(try object()) }
                p += 1
                return .array(items)
            case "<":
                let elementType = try byte()
                guard try byte() == UInt8(ascii: "s") else { throw Malformed() }
                let count = Int(try byte())
                let start = p
                p += count
                guard p < bytes.count, try byte() == UInt8(ascii: ">") else { throw Malformed() }
                var sub = Parser(bytes: bytes, p: start)
                let floats = try (0..<(count / 4)).map { _ in try sub.f32() }
                switch elementType {
                case UInt8(ascii: "f"): return .floats(floats)
                case UInt8(ascii: "c"):
                    return .colors(stride(from: 0, to: floats.count - 2, by: 3).map { SIMD3(floats[$0], floats[$0 + 1], floats[$0 + 2]) })
                default: return .other
                }
            default:
                throw Malformed()
            }
        }
    }

    // MARK: Rendering

    /// Renders the lighting setup to a linear HDR equirectangular map.
    static func render(_ env: KLFObject, width: Int = 2048) -> HDRPixels {
        let map = env.object("map")
        let background = map?.object("background")
        let mapGain = env.float("map.gain") ?? 1
        let pins = collectPins(map?.object("root"))
        let sky = background?.className == "sky" ? Sky(background!) : nil

        return HDRPixels(width: width) { d in
            var c: SIMD3<Float>
            if let sky {
                c = sky.radiance(d)
            } else if let background {
                c = backgroundColor(background, direction: d)
            } else {
                c = .zero
            }
            for pin in pins { pin.composite(onto: &c, direction: d) }
            return c * mapGain
        }
    }

    private static func collectPins(_ group: KLFObject?) -> [Pin] {
        guard let group, group.bool("enabled") != false else { return [] }
        return group.array("items").flatMap { item -> [Pin] in
            if item.className == "pin" {
                return item.bool("enabled") == false ? [] : [Pin(item)]
            }
            return collectPins(item)
        }
    }

    private static func gain(_ object: KLFObject?) -> Float { object?.object("modifiers")?.float("gain") ?? 1 }

    private static func backgroundColor(_ bg: KLFObject, direction d: SIMD3<Float>) -> SIMD3<Float> {
        if bg.className == "gradient", let stops = bg.object("color") {
            // Vertical gradient: x = 0 at the bottom (nadir) to 1 at the top.
            let t = (asinf(simd_clamp(d.y, -1, 1)) / .pi) + 0.5
            return Gradient(stops).color(at: t) * gain(bg)
        }
        return (bg.color("color") ?? .zero) * gain(bg)
    }

    /// Color stops (`x`, `color`, `gain`) with an optional alpha ramp. Each stop's `out`/`in`
    /// weights ease the segment: a weight above 1 holds the value near that stop for longer.
    struct Gradient {
        var x: [Float], colors: [SIMD3<Float>], gains: [Float]
        var easeOut: [Float], easeIn: [Float]
        var alphaX: [Float] = [], alphas: [Float] = [], alphaOut: [Float] = [], alphaIn: [Float] = []

        init(_ stops: KLFObject, alpha: KLFObject? = nil) {
            x = stops.floats("x")
            colors = stops.colors("color")
            gains = stops.floats("gain")
            easeOut = stops.floats("out")
            easeIn = stops.floats("in")
            if let alpha {
                alphaX = alpha.floats("x")
                alphas = alpha.floats("alpha")
                alphaOut = alpha.floats("out")
                alphaIn = alpha.floats("in")
            }
        }

        private static func sample<T>(_ xs: [Float], _ values: [T], outs: [Float], ins: [Float], _ t: Float,
                                      _ lerp: (T, T, Float) -> T) -> T? {
            guard !values.isEmpty, xs.count >= values.count else { return values.first }
            if t <= xs[0] { return values[0] }
            for i in 1..<values.count where t <= xs[i] {
                let f = simd_clamp((t - xs[i - 1]) / max(xs[i] - xs[i - 1], 1e-6), 0, 1)
                let a = max(i - 1 < outs.count ? outs[i - 1] : 1, 0.05)
                let b = max(i < ins.count ? ins[i] : 1, 0.05)
                let fa = powf(f, a), fb = powf(1 - f, b)
                return lerp(values[i - 1], values[i], fa / max(fa + fb, 1e-6))
            }
            return values[values.count - 1]
        }

        func color(at t: Float) -> SIMD3<Float> {
            let withGain = zip(colors, gains.isEmpty ? Array(repeating: 1, count: colors.count) : gains).map { $0 * $1 }
            return Self.sample(x, withGain, outs: easeOut, ins: easeIn, t) { simd_mix($0, $1, SIMD3(repeating: $2)) } ?? .zero
        }

        func alpha(at t: Float) -> Float {
            Self.sample(alphaX, alphas, outs: alphaOut, ins: alphaIn, t) { $0 + ($1 - $0) * $2 } ?? 1
        }
    }

    /// One light of KeyShot's HDRI editor, drawn on the sphere.
    struct Pin {
        let center: SIMD3<Float>, right: SIMD3<Float>, up: SIMD3<Float>
        let circle: Bool
        let radius: Float, halfWidth: Float, halfHeight: Float   // radians
        let falloff: Float
        /// Low 4 bits of KeyShot's `falloffType` (the high bits mark round vs. rectangular pins).
        let falloffCurve: Int
        let mode: Int
        /// KeyShot's studio presets mark the dim mirror image of a light below the horizon as a
        /// "Floor Reflection" pin; it only paints the lower hemisphere.
        let floorOnly: Bool
        let color: SIMD3<Float>?
        let gradient: Gradient?

        init(_ pin: KLFObject) {
            let deg = Float.pi / 180
            let az = (pin.float("az") ?? 0) * deg, el = (pin.float("in") ?? 0) * deg
            let c = HDRPixels.direction(azimuth: az, elevation: el)
            // Tangent frame at the pin's center, rotated by the pin's own rotation.
            let worldUp = abs(c.y) > 0.999 ? SIMD3<Float>(0, 0, -1) : SIMD3<Float>(0, 1, 0)
            var r = simd_normalize(simd_cross(worldUp, c))
            var u = simd_cross(c, r)
            let rot = (pin.float("rotation") ?? 0) * deg
            (r, u) = (r * cosf(rot) + u * sinf(rot), u * cosf(rot) - r * sinf(rot))
            center = c
            right = -r
            up = u
            circle = pin.int("shape") == 1
            radius = (pin.float("radius") ?? 10) * deg
            // Rectangle sizes are half-extents (a 36° pin spans 72°), matching KeyShot's previews.
            halfWidth = (pin.float("width") ?? 10) * deg
            halfHeight = (pin.float("height") ?? 10) * deg
            falloff = max(pin.float("falloff") ?? 0, 0)
            falloffCurve = (pin.int("falloffType") ?? 3) & 0x0F
            let brush = pin.object("brush")
            mode = brush?.int("mode") ?? 0
            if case let .string(name) = pin.fields["name"] {
                floorOnly = name.localizedCaseInsensitiveContains("reflection")
            } else {
                floorOnly = false
            }
            let brushGain = KeyShotLighting.gain(brush)
            if brush?.className == "gradient", let stops = brush?.object("color") {
                var g = Gradient(stops, alpha: brush?.object("alpha"))
                g.gains = (g.gains.isEmpty ? Array(repeating: 1, count: g.colors.count) : g.gains).map { $0 * brushGain }
                gradient = g
                color = nil
            } else {
                gradient = nil
                color = (brush?.color("color") ?? SIMD3(repeating: 1)) * brushGain
            }
        }

        func composite(onto c: inout SIMD3<Float>, direction d: SIMD3<Float>) {
            if floorOnly && d.y > 0 { return }
            let along = simd_dot(d, center)
            guard along > -0.999 else { return }
            // Normalized distance from the center: 0 at the center, 1 at the edge.
            let t: Float
            let gradientT: Float
            if circle {
                t = acosf(simd_clamp(along, -1, 1)) / max(radius, 1e-4)
                gradientT = 1 - t // radial gradients run from the edge (0) to the center (1)
            } else {
                guard along > 0 else { return }
                let u = atan2f(simd_dot(d, right), along), v = atan2f(simd_dot(d, up), along)
                t = max(abs(u) / max(halfWidth, 1e-4), abs(v) / max(halfHeight, 1e-4))
                gradientT = 0.5 + u / max(halfWidth, 1e-4) / 2
            }
            guard t < 1 else { return }
            // A tiny edge keeps hard pins anti-aliased.
            // Edge softness, matched against KeyShot's previews: curve 0 is hard-edged (except the soft
            // floor reflections), curve 4 fades across the whole pin, others soften the outer fraction.
            let edge: Float = switch falloffCurve {
            case 0: floorOnly ? max(falloff, 0.01) : 0.01
            case 4: falloff > 0 ? 1 : 0.01
            default: max(falloff, 0.01)
            }
            let s = simd_clamp((1 - t) / edge, 0, 1)
            var mask = s * s * (3 - 2 * s)
            let value: SIMD3<Float>
            if let gradient {
                value = gradient.color(at: simd_clamp(gradientT, 0, 1))
                mask *= gradient.alpha(at: simd_clamp(gradientT, 0, 1))
            } else {
                value = color ?? .zero
            }
            // Blend modes, inferred by matching KeyShot's previews: 0/2 paint over (dark pins
            // darken, e.g. Light Tent's black flags), 1 adds light, 3 lightens.
            switch mode {
            case 1: c += value * mask
            case 3: c = simd_max(c, value * mask)
            default: c = simd_mix(c, value, SIMD3(repeating: mask))
            }
        }
    }

    /// KeyShot's physical Sun & Sky, approximated: sun position from date, time and latitude,
    /// a simple analytic sky, and a very bright sun disc.
    struct Sky {
        let sun: SIMD3<Float>
        let elevation: Float
        let turbidity: Float
        let ground: SIMD3<Float>
        let sunScale: Float

        init(_ sky: KLFObject) {
            let deg = Float.pi / 180
            let latitude = (sky.float("latitude") ?? 34) * deg
            let month = Float(sky.int("month") ?? 6), day = Float(sky.int("day") ?? 21)
            let dayOfYear = (month - 1) * 30.4 + day
            let declination = 23.44 * deg * sinf(2 * .pi * (284 + dayOfYear) / 365)
            let hourAngle = ((sky.float("time") ?? 12) - 12) * 15 * deg
            let sinEl = sinf(latitude) * sinf(declination) + cosf(latitude) * cosf(declination) * cosf(hourAngle)
            elevation = asinf(simd_clamp(sinEl, -1, 1))
            let cosAz = (sinf(declination) - sinf(elevation) * sinf(latitude)) / max(cosf(elevation) * cosf(latitude), 1e-4)
            var azimuth = acosf(simd_clamp(cosAz, -1, 1))
            if hourAngle > 0 { azimuth = 2 * .pi - azimuth }
            sun = HDRPixels.direction(azimuth: azimuth, elevation: elevation)
            turbidity = sky.float("turbidity") ?? 3
            ground = sky.color("groundColor") ?? SIMD3(repeating: 0.1)
            sunScale = sky.float("sunSizeMultiplier") ?? 1
        }

        func radiance(_ d: SIMD3<Float>) -> SIMD3<Float> {
            let day = simd_clamp(sinf(elevation) * 4 + 0.15, 0, 1)            // fades out below the horizon
            if d.y < 0 { return ground * (0.3 + 1.5 * day) }
            let low = 1 - simd_clamp(sinf(elevation) * 3, 0, 1)                  // warm when the sun is low
            let zenith = simd_mix(SIMD3<Float>(0.25, 0.45, 1.0), SIMD3<Float>(0.15, 0.2, 0.45), SIMD3(repeating: low))
            let horizon = simd_mix(SIMD3<Float>(0.75, 0.85, 1.0), SIMD3<Float>(1.4, 0.7, 0.3), SIMD3(repeating: low))
            let haze = 1 + (turbidity - 2) * 0.08
            var c = simd_mix(horizon * haze, zenith, SIMD3(repeating: powf(max(d.y, 0), 0.5))) * (0.25 + 1.6 * day)
            let s = simd_dot(d, sun)
            let sunColor = simd_mix(SIMD3<Float>(1, 0.95, 0.9), SIMD3<Float>(1, 0.55, 0.2), SIMD3(repeating: low))
            let disc: Float = 0.99995 - 0.00004 * (sunScale - 1)
            c += sunColor * 400 * (s > disc ? 1 : 0) * max(day, 0.2)
            c += sunColor * 3 * powf(max(s, 0), 60) * max(day, 0.3)            // glow around the sun
            return c
        }
    }
}
