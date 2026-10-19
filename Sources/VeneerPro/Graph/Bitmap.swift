import CoreGraphics
import Foundation
import simd

/// A square RGBA float image, row 0 at the top. All node math runs on these on the CPU,
/// so every operation is exact and independent of Core Image color management.
struct Bitmap {
    let size: Int
    var pixels: [SIMD4<Float>]

    init(size: Int, pixels: [SIMD4<Float>]) {
        self.size = size
        self.pixels = pixels
    }

    /// Fills each pixel from `f(x, y)` in parallel over rows.
    init(size: Int, _ f: (Int, Int) -> SIMD4<Float>) {
        self.size = size
        var pixels = [SIMD4<Float>](repeating: .zero, count: size * size)
        pixels.withUnsafeMutableBufferPointer { buffer in
            let base = buffer.baseAddress!
            DispatchQueue.concurrentPerform(iterations: size) { y in
                for x in 0..<size { base[y * size + x] = f(x, y) }
            }
        }
        self.pixels = pixels
    }

    func map(_ f: (SIMD4<Float>) -> SIMD4<Float>) -> Bitmap {
        Bitmap(size: size) { x, y in f(pixels[y * size + x]) }
    }

    enum AlphaMode { case opaque, straight }

    /// Encodes to an 8-bit CGImage. `linear` tags the image as raw data (roughness, normals, ...).
    func cgImage(alpha: AlphaMode = .opaque, linear: Bool = false) -> CGImage? {
        var bytes = [UInt8](repeating: 255, count: size * size * 4)
        bytes.withUnsafeMutableBufferPointer { buffer in
            let base = buffer.baseAddress!
            DispatchQueue.concurrentPerform(iterations: size) { y in
                for x in 0..<size {
                    let i = y * size + x
                    let p = simd_clamp(pixels[i], .zero, .one)
                    let a = alpha == .opaque ? 1 : p.w
                    // CGImage requires premultiplied alpha for RGBA8.
                    base[i * 4 + 0] = UInt8((p.x * a * 255).rounded())
                    base[i * 4 + 1] = UInt8((p.y * a * 255).rounded())
                    base[i * 4 + 2] = UInt8((p.z * a * 255).rounded())
                    base[i * 4 + 3] = UInt8((a * 255).rounded())
                }
            }
        }
        let space = linear ? CGColorSpace(name: CGColorSpace.linearSRGB)! : CGColorSpace(name: CGColorSpace.sRGB)!
        let info: CGImageAlphaInfo = alpha == .opaque ? .noneSkipLast : .premultipliedLast
        guard let provider = CGDataProvider(data: Data(bytes) as CFData) else { return nil }
        return CGImage(width: size, height: size, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: size * 4,
                       space: space, bitmapInfo: CGBitmapInfo(rawValue: info.rawValue), provider: provider,
                       decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }
}

/// Decoded 8-bit pixels of a texture, sampled bilinearly with wrapping.
final class TexturePixels {
    let width: Int
    let height: Int
    private let bytes: [UInt8]

    init(_ image: CGImage) {
        let width = image.width, height = image.height
        self.width = width
        self.height = height
        // Keep the source's own RGB space so data textures are not color converted.
        let space = (image.colorSpace?.model == .rgb ? image.colorSpace : nil) ?? CGColorSpace(name: CGColorSpace.sRGB)!
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        bytes.withUnsafeMutableBytes { raw in
            let ctx = CGContext(data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                bytesPerRow: width * 4, space: space,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
                ?? CGContext(data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8,
                             bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            ctx?.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        self.bytes = bytes
    }

    @inline(__always)
    private func texel(_ x: Int, _ y: Int) -> SIMD4<Float> {
        let wx = ((x % width) + width) % width
        let wy = ((y % height) + height) % height
        let i = (wy * width + wx) * 4
        let a = Float(bytes[i + 3]) / 255
        guard a > 0 else { return .zero }
        // Un-premultiply so color channels are independent of alpha.
        return SIMD4(Float(bytes[i]) / 255 / a, Float(bytes[i + 1]) / 255 / a, Float(bytes[i + 2]) / 255 / a, a)
    }

    /// Samples at UV in [0, 1) with v = 0 at the top row.
    func sample(u: Float, v: Float) -> SIMD4<Float> {
        let fx = u * Float(width) - 0.5
        let fy = v * Float(height) - 0.5
        let x0 = Int(fx.rounded(.down)), y0 = Int(fy.rounded(.down))
        let tx = fx - Float(x0), ty = fy - Float(y0)
        let top = simd_mix(texel(x0, y0), texel(x0 + 1, y0), SIMD4(repeating: tx))
        let bottom = simd_mix(texel(x0, y0 + 1), texel(x0 + 1, y0 + 1), SIMD4(repeating: tx))
        return simd_mix(top, bottom, SIMD4(repeating: ty))
    }
}
