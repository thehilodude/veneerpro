import CoreGraphics
import Foundation
import simd

/// A linear, floating-point equirectangular environment (x = azimuth, row 0 = straight up).
struct HDRPixels {
    let width: Int
    let height: Int
    var data: [SIMD4<Float>]

    init(width: Int, height: Int, data: [SIMD4<Float>]) {
        self.width = width
        self.height = height
        self.data = data
    }

    /// Fills each pixel from the unit direction it faces, in parallel over rows.
    /// Direction convention: y up; azimuth 0 faces −z and increases toward +x.
    init(width: Int, _ radiance: (SIMD3<Float>) -> SIMD3<Float>) {
        let height = width / 2
        var data = [SIMD4<Float>](repeating: .zero, count: width * height)
        data.withUnsafeMutableBufferPointer { buffer in
            let base = buffer.baseAddress!
            DispatchQueue.concurrentPerform(iterations: height) { y in
                for x in 0..<width {
                    base[y * width + x] = SIMD4(radiance(Self.direction(x: x, y: y, width: width, height: height)), 1)
                }
            }
        }
        self.init(width: width, height: height, data: data)
    }

    static func direction(x: Int, y: Int, width: Int, height: Int) -> SIMD3<Float> {
        let azimuth = ((Float(x) + 0.5) / Float(width) - 0.5) * 2 * .pi
        let elevation = (0.5 - (Float(y) + 0.5) / Float(height)) * .pi
        return direction(azimuth: azimuth, elevation: elevation)
    }

    static func direction(azimuth: Float, elevation: Float) -> SIMD3<Float> {
        SIMD3(cosf(elevation) * sinf(azimuth), sinf(elevation), -cosf(elevation) * cosf(azimuth))
    }

    /// Reads any CGImage (8-bit or float) into linear float pixels.
    init?(image: CGImage) {
        let width = image.width, height = image.height
        var data = [SIMD4<Float>](repeating: .zero, count: width * height)
        let info = CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.floatComponents.rawValue
            | CGBitmapInfo.byteOrder32Little.rawValue
        let ok = data.withUnsafeMutableBytes { raw -> Bool in
            guard let ctx = CGContext(data: raw.baseAddress, width: width, height: height, bitsPerComponent: 32,
                                      bytesPerRow: width * 16, space: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!,
                                      bitmapInfo: info) else { return false }
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard ok else { return nil }
        self.init(width: width, height: height, data: data)
    }

    /// The environment spun about the vertical axis (a circular horizontal shift).
    func rotated(degrees: Double) -> HDRPixels {
        let shift = Int((degrees / 360 * Double(width)).rounded())
        let s = ((shift % width) + width) % width
        guard s != 0 else { return self }
        var out = data
        for y in 0..<height {
            let row = y * width
            for x in 0..<width { out[row + (x + s) % width] = data[row + x] }
        }
        return HDRPixels(width: width, height: height, data: out)
    }

    /// Float CGImage for SceneKit's image-based lighting.
    func cgImage() -> CGImage? {
        let bytes = data.withUnsafeBufferPointer { Data(buffer: $0) }
        guard let provider = CGDataProvider(data: bytes as CFData) else { return nil }
        let info = CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.floatComponents.rawValue
            | CGBitmapInfo.byteOrder32Little.rawValue
        return CGImage(width: width, height: height, bitsPerComponent: 32, bitsPerPixel: 128, bytesPerRow: width * 16,
                       space: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!, bitmapInfo: CGBitmapInfo(rawValue: info),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }

    /// 8-bit sRGB copy for the visible background: exposure 1, highlights clipped, like a photo.
    func backdropImage() -> CGImage? {
        var bytes = [UInt8](repeating: 255, count: data.count * 4)
        bytes.withUnsafeMutableBufferPointer { out in
            let base = out.baseAddress!
            DispatchQueue.concurrentPerform(iterations: height) { y in
                for x in 0..<width {
                    let i = y * width + x
                    let p = data[i]
                    func encode(_ v: Float) -> UInt8 {
                        let c = simd_clamp(v, 0, 1)
                        return UInt8((c <= 0.0031308 ? c * 12.92 : 1.055 * powf(c, 1 / 2.4) - 0.055) * 255)
                    }
                    base[i * 4] = encode(p.x)
                    base[i * 4 + 1] = encode(p.y)
                    base[i * 4 + 2] = encode(p.z)
                }
            }
        }
        guard let provider = CGDataProvider(data: Data(bytes) as CFData) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                       space: CGColorSpace(name: CGColorSpace.sRGB)!,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }
}
