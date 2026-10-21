import CoreGraphics
import Foundation
import simd

/// The built-in procedural studio (equirectangular, linear float): the offline default, used until a
/// Poly Haven or ambientCG HDRI is downloaded.
///
/// Reflections are only as good as what there is to reflect: lights must be far brighter than
/// their surroundings (values well above 1.0) for metals and clearcoats to show highlights,
/// which an 8-bit image can't hold. `makeHDRImage` is used for lighting; `makeImage` is a
/// tone-mapped copy for the visible background and thumbnails.
enum EnvironmentPreset: String, CaseIterable, Identifiable {
    case studio = "Studio"

    var id: String { rawValue }

    /// Background color used when the environment is hidden.
    var backdrop: SIMD3<Float> { [0.18, 0.18, 0.19] }

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
