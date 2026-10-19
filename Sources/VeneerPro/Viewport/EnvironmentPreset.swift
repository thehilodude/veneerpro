import CoreGraphics
import Foundation
import simd

/// Procedurally generated HDR lighting environments (equirectangular, linear float).
///
/// Reflections are only as good as what there is to reflect: lights must be far brighter than
/// their surroundings (values well above 1.0) for metals and clearcoats to show highlights,
/// which an 8-bit image can't hold. `makeHDRImage` is used for lighting; `makeImage` is a
/// tone-mapped copy for the visible background and thumbnails.
enum EnvironmentPreset: String, CaseIterable, Identifiable {
    case studio = "Studio"
    case sunset = "Sunset"
    case overcast = "Overcast"
    case night = "Night"
    case warehouse = "Warehouse"

    var id: String { rawValue }

    /// Background color used when the environment is hidden.
    var backdrop: SIMD3<Float> { self == .night ? [0.05, 0.05, 0.07] : [0.18, 0.18, 0.19] }

    // MARK: Radiance

    /// Linear radiance arriving from direction `d` (y up).
    private func radiance(_ d: SIMD3<Float>) -> SIMD3<Float> {
        let phi = atan2f(d.z, d.x)            // azimuth, -π...π
        let up = d.y                           // elevation sine
        switch self {
        case .studio:
            // Dark grey cyclorama, a big overhead softbox, two tall strip lights and a soft front fill.
            var c = SIMD3<Float>(repeating: up > 0 ? 0.24 + 0.12 * up : 0.12 + 0.06 * (1 + up))
            c += SIMD3(repeating: 7) * Self.cap(up, from: 0.82, softness: 0.04)
            c += SIMD3(repeating: 10) * Self.strip(phi, center: 0.55, width: 0.10) * Self.band(up, -0.45, 0.55)
            c += SIMD3(repeating: 6) * Self.strip(phi, center: 2.9, width: 0.14) * Self.band(up, -0.35, 0.6)
            // Front fill sits behind the default camera (+z), lighting the model without washing out the backdrop.
            c += SIMD3(repeating: 2.2) * Self.strip(phi, center: 1.35, width: 0.5) * Self.band(up, -0.1, 0.35)
            return c
        case .sunset:
            let sunDir = simd_normalize(SIMD3<Float>(-0.75, 0.10, 0.65))
            let sky = simd_mix(SIMD3<Float>(1.6, 0.75, 0.35), SIMD3<Float>(0.25, 0.4, 0.9), SIMD3(repeating: Self.smooth(0, 0.6, up)))
            var c = up > 0 ? sky : SIMD3<Float>(0.12, 0.08, 0.06) * (1 + up)
            let s = simd_dot(d, sunDir)
            c += SIMD3<Float>(80, 40, 14) * Self.smooth(0.9993, 0.9997, s)      // sun disc
            c += SIMD3<Float>(2.5, 1.0, 0.3) * powf(max(0, s), 40)               // glow
            return c
        case .overcast:
            // Bright, soft dome with a slightly brighter zenith; grey ground.
            return up > 0 ? SIMD3<Float>(repeating: 1.4 + 1.2 * up) * SIMD3(0.95, 0.98, 1.05)
                          : SIMD3<Float>(repeating: 0.22 + 0.08 * (1 + up))
        case .night:
            var c = up > 0 ? SIMD3<Float>(0.015, 0.02, 0.05) * (1 + up) : SIMD3<Float>(0.01, 0.01, 0.015)
            // Lit windows and street lights scattered around the horizon.
            let cell = Int(((phi + .pi) / (2 * .pi)) * 48)
            let lit = (cell * 7919 % 13) < 5
            if lit {
                let warm = cell % 3 != 0
                c += (warm ? SIMD3<Float>(6, 3.6, 1.6) : SIMD3<Float>(2.5, 3.2, 5))
                    * Self.band(up, 0.02, 0.10 + Float(cell % 4) * 0.04)
                    * Self.strip(phi, center: (Float(cell) + 0.5) / 48 * 2 * .pi - .pi, width: 0.05)
            }
            c += SIMD3<Float>(3, 3, 3.4) * Self.cap(up, from: 0.97, softness: 0.01) // moon-ish highlight
            return c
        case .warehouse:
            var c = up > 0.55 ? SIMD3<Float>(0.18, 0.17, 0.16)
                : up > -0.05 ? SIMD3<Float>(0.32, 0.29, 0.25)
                : SIMD3<Float>(0.14, 0.12, 0.1)
            // Rows of ceiling fixtures.
            if up > 0.5 {
                let rows = sinf(atan2f(d.z, up) * 9)
                c += SIMD3<Float>(9, 8.6, 8) * Self.smooth(0.92, 0.97, rows) * Self.smooth(-0.6, -0.3, -abs(d.x / max(up, 0.01)))
            }
            // A tall window wall.
            c += SIMD3<Float>(3.0, 3.3, 3.8) * Self.strip(phi, center: 2.2, width: 0.7) * Self.band(up, 0.0, 0.5)
            return c
        }
    }

    private static func smooth(_ a: Float, _ b: Float, _ x: Float) -> Float {
        let t = simd_clamp((x - a) / (b - a), 0, 1)
        return t * t * (3 - 2 * t)
    }

    /// 1 inside a vertical strip around azimuth `center`, with soft edges.
    private static func strip(_ phi: Float, center: Float, width: Float) -> Float {
        let delta = abs(atan2f(sinf(phi - center), cosf(phi - center)))
        return 1 - smooth(width * 0.7, width, delta)
    }

    /// 1 between two elevations, with soft edges.
    private static func band(_ up: Float, _ low: Float, _ high: Float) -> Float {
        smooth(low - 0.03, low, up) * (1 - smooth(high, high + 0.03, up))
    }

    /// 1 above an elevation (an overhead light).
    private static func cap(_ up: Float, from: Float, softness: Float) -> Float {
        smooth(from - softness, from, up)
    }

    // MARK: Images

    private func pixels(width: Int) -> [SIMD4<Float>] {
        let height = width / 2
        var pixels = [SIMD4<Float>](repeating: .zero, count: width * height)
        pixels.withUnsafeMutableBufferPointer { buffer in
            let base = buffer.baseAddress!
            DispatchQueue.concurrentPerform(iterations: height) { y in
                let theta = (Float(y) + 0.5) / Float(height) * .pi
                for x in 0..<width {
                    let phi = (Float(x) + 0.5) / Float(width) * 2 * .pi
                    let d = SIMD3(sinf(theta) * cosf(phi), cosf(theta), sinf(theta) * sinf(phi))
                    base[y * width + x] = SIMD4(radiance(d), 1)
                }
            }
        }
        return pixels
    }

    /// The preset as linear HDR pixels (the viewer's shared environment format).
    func hdrPixels(width: Int) -> HDRPixels {
        HDRPixels(width: width) { radiance($0) }
    }

    /// Linear, unclamped radiance for SceneKit's image-based lighting.
    func makeHDRImage(width: Int = 1024) -> CGImage? {
        let pixels = pixels(width: width)
        let data = pixels.withUnsafeBufferPointer { Data(buffer: $0) }
        guard let provider = CGDataProvider(data: data as CFData),
              let space = CGColorSpace(name: CGColorSpace.extendedLinearSRGB) else { return nil }
        let info = CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.floatComponents.rawValue
            | CGBitmapInfo.byteOrder32Little.rawValue
        return CGImage(width: width, height: width / 2, bitsPerComponent: 32, bitsPerPixel: 128, bytesPerRow: width * 16,
                       space: space, bitmapInfo: CGBitmapInfo(rawValue: info), provider: provider,
                       decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }

    /// Tone-mapped 8-bit sRGB copy, for the visible background and environment thumbnails.
    func makeImage(width: Int = 1024) -> CGImage? {
        let pixels = pixels(width: width)
        var bytes = [UInt8](repeating: 255, count: pixels.count * 4)
        for (i, p) in pixels.enumerated() {
            // Reinhard with a little exposure so the backdrop reads like a photo, not a light map.
            let c = SIMD3(p.x, p.y, p.z) * 1.4
            let mapped = c / (c + 1)
            bytes[i * 4] = UInt8(powf(mapped.x, 1 / 2.2) * 255)
            bytes[i * 4 + 1] = UInt8(powf(mapped.y, 1 / 2.2) * 255)
            bytes[i * 4 + 2] = UInt8(powf(mapped.z, 1 / 2.2) * 255)
        }
        guard let provider = CGDataProvider(data: Data(bytes) as CFData) else { return nil }
        return CGImage(width: width, height: width / 2, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                       space: CGColorSpace(name: CGColorSpace.sRGB)!,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }
}
