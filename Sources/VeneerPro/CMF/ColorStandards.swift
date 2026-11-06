import Foundation
import simd

/// A named color from a color system, e.g. RAL 5015 Sky blue.
struct StandardColor: Identifiable, Hashable {
    enum System: String, CaseIterable, Identifiable {
        case ral = "RAL Classic"
        case ralDesign = "RAL Design System+"
        case ralEffect = "RAL Effect"

        var id: String { rawValue }
        var shortName: String {
            switch self {
            case .ral: "Classic"
            case .ralDesign: "Design System+"
            case .ralEffect: "Effect"
            }
        }
        var colors: [StandardColor] {
            switch self {
            case .ral: ColorStandards.ralClassic
            case .ralDesign: ColorStandards.ralDesign
            case .ralEffect: ColorStandards.ralEffect
            }
        }
        /// The system a code like "RAL 000 15 00" or "RAL 110-M" belongs to.
        static func of(code: String) -> System? { allCases.first { system in system.colors.contains { $0.code == code } } }
    }

    let system: System
    let code: String
    let name: String
    let hex: UInt32
    let group: String

    var id: String { code }
    var rgb: SIMD3<Float> { ColorStandards.rgb(hex: hex) }
}

/// Color systems and conversions for specifying colors the way they're specified to suppliers.
/// Colors are sRGB, gamma-encoded (the same space as the material graph's color values).
enum ColorStandards {
    static func rgb(hex: UInt32) -> SIMD3<Float> {
        SIMD3(Float((hex >> 16) & 0xFF), Float((hex >> 8) & 0xFF), Float(hex & 0xFF)) / 255
    }

    static func hexString(_ rgb: SIMD3<Float>) -> String {
        let c = simd_clamp(rgb, .zero, SIMD3(repeating: 1)) * 255
        return String(format: "#%02X%02X%02X", Int(c.x.rounded()), Int(c.y.rounded()), Int(c.z.rounded()))
    }

    /// Parses "#2874B2", "2874b2", "40, 116, 178" (0–255) or "0.16 0.45 0.70" (0–1).
    static func parse(_ text: String) -> SIMD3<Float>? {
        let trimmed = text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "#", with: "")
        if trimmed.count == 6, let value = UInt32(trimmed, radix: 16) { return rgb(hex: value) }
        let parts = trimmed.split(whereSeparator: { ", ;".contains($0) }).compactMap { Float($0) }
        guard parts.count == 3 else { return nil }
        let scale: Float = parts.contains { $0 > 1 } ? 255 : 1
        return simd_clamp(SIMD3(parts[0], parts[1], parts[2]) / scale, .zero, SIMD3(repeating: 1))
    }

    // MARK: CIELAB (D65)

    private static let white = SIMD3<Double>(0.95047, 1.0, 1.08883)

    static func lab(_ rgb: SIMD3<Float>) -> SIMD3<Double> {
        func linear(_ c: Double) -> Double { c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
        let r = linear(Double(rgb.x)), g = linear(Double(rgb.y)), b = linear(Double(rgb.z))
        let xyz = SIMD3(0.4124564 * r + 0.3575761 * g + 0.1804375 * b,
                        0.2126729 * r + 0.7151522 * g + 0.0721750 * b,
                        0.0193339 * r + 0.1191920 * g + 0.9503041 * b) / white
        func f(_ t: Double) -> Double { t > 216.0 / 24389 ? cbrt(t) : (24389.0 / 27 * t + 16) / 116 }
        let fx = f(xyz.x), fy = f(xyz.y), fz = f(xyz.z)
        return SIMD3(116 * fy - 16, 500 * (fx - fy), 200 * (fy - fz))
    }

    /// The sRGB color for a CIELAB value, clipped to the sRGB gamut.
    static func rgb(lab: SIMD3<Double>) -> SIMD3<Float> {
        let fy = (lab.x + 16) / 116, fx = fy + lab.y / 500, fz = fy - lab.z / 200
        func inverse(_ t: Double) -> Double { t * t * t > 216.0 / 24389 ? t * t * t : (116 * t - 16) / (24389.0 / 27) }
        let xyz = SIMD3(inverse(fx), inverse(fy), inverse(fz)) * white
        let r = 3.2404542 * xyz.x - 1.5371385 * xyz.y - 0.4985314 * xyz.z
        let g = -0.9692660 * xyz.x + 1.8760108 * xyz.y + 0.0415560 * xyz.z
        let b = 0.0556434 * xyz.x - 0.2040259 * xyz.y + 1.0572252 * xyz.z
        func encoded(_ c: Double) -> Float {
            let c = min(max(c, 0), 1)
            return Float(c <= 0.0031308 ? 12.92 * c : 1.055 * pow(c, 1 / 2.4) - 0.055)
        }
        return SIMD3(encoded(r), encoded(g), encoded(b))
    }

    /// CIEDE2000 color difference. Under ~1 is hard to see; 2–3 is a close match.
    static func deltaE(_ lab1: SIMD3<Double>, _ lab2: SIMD3<Double>) -> Double {
        let (l1, a1, b1) = (lab1.x, lab1.y, lab1.z), (l2, a2, b2) = (lab2.x, lab2.y, lab2.z)
        let deg = Double.pi / 180
        let cBar = (hypot(a1, b1) + hypot(a2, b2)) / 2
        let g = 0.5 * (1 - sqrt(pow(cBar, 7) / (pow(cBar, 7) + pow(25, 7))))
        let a1p = (1 + g) * a1, a2p = (1 + g) * a2
        let c1p = hypot(a1p, b1), c2p = hypot(a2p, b2)
        func hue(_ b: Double, _ a: Double) -> Double {
            guard a != 0 || b != 0 else { return 0 }
            let h = atan2(b, a) / deg
            return h < 0 ? h + 360 : h
        }
        let h1p = hue(b1, a1p), h2p = hue(b2, a2p)
        let dLp = l2 - l1, dCp = c2p - c1p
        var dhp = h2p - h1p
        if c1p * c2p == 0 { dhp = 0 } else if dhp > 180 { dhp -= 360 } else if dhp < -180 { dhp += 360 }
        let dHp = 2 * sqrt(c1p * c2p) * sin(dhp / 2 * deg)
        let lBarP = (l1 + l2) / 2, cBarP = (c1p + c2p) / 2
        var hBarP = h1p + h2p
        if c1p * c2p != 0 {
            hBarP = abs(h1p - h2p) > 180 ? (h1p + h2p + (h1p + h2p < 360 ? 360 : -360)) / 2 : (h1p + h2p) / 2
        }
        let t = 1 - 0.17 * cos((hBarP - 30) * deg) + 0.24 * cos(2 * hBarP * deg)
            + 0.32 * cos((3 * hBarP + 6) * deg) - 0.20 * cos((4 * hBarP - 63) * deg)
        let dTheta = 30 * exp(-pow((hBarP - 275) / 25, 2))
        let rc = 2 * sqrt(pow(cBarP, 7) / (pow(cBarP, 7) + pow(25, 7)))
        let sl = 1 + 0.015 * pow(lBarP - 50, 2) / sqrt(20 + pow(lBarP - 50, 2))
        let sc = 1 + 0.045 * cBarP, sh = 1 + 0.015 * cBarP * t
        let rt = -sin(2 * dTheta * deg) * rc
        return sqrt(pow(dLp / sl, 2) + pow(dCp / sc, 2) + pow(dHp / sh, 2) + rt * (dCp / sc) * (dHp / sh))
    }

    static let ralDesign = parse(table: ralDesignTable, system: .ralDesign)
    static let ralEffect = parse(table: ralEffectTable, system: .ralEffect)

    /// Reads "code|name|hex" lines, grouping colors into families by hue.
    private static func parse(table: String, system: StandardColor.System) -> [StandardColor] {
        table.split(separator: "\n").compactMap { line in
            let parts = line.split(separator: "|", omittingEmptySubsequences: false)
            guard parts.count == 3, let hex = UInt32(parts[2], radix: 16) else { return nil }
            return StandardColor(system: system, code: String(parts[0]), name: String(parts[1]), hex: hex,
                                 group: family(of: rgb(hex: hex)))
        }
    }

    /// A color family from CIELCh hue, for filtering large palettes.
    static func family(of rgb: SIMD3<Float>) -> String {
        let lab = lab(rgb)
        let chroma = hypot(lab.y, lab.z)
        if chroma < 8 { return lab.x > 88 ? "White" : lab.x < 22 ? "Black" : "Grey" }
        var hue = atan2(lab.z, lab.y) * 180 / .pi
        if hue < 0 { hue += 360 }
        // Low-lightness warm hues read as browns rather than oranges or yellows.
        if (35..<100).contains(hue), lab.x < 52, chroma < 45 { return "Brown" }
        switch hue {
        case 0..<25, 345...360: return "Red"
        case 25..<65: return "Orange"
        case 65..<105: return "Yellow"
        case 105..<190: return "Green"
        case 190..<280: return "Blue"
        default: return "Violet"
        }
    }

    /// The closest RAL Classic color and its CIEDE2000 difference.
    /// Nil when there are no RAL colors (the App Store edition leaves the tables out).
    static func nearestRAL(to rgb: SIMD3<Float>) -> (color: StandardColor, deltaE: Double)? {
        let target = lab(rgb)
        let ranked = ralClassic.map { ($0, deltaE(target, lab($0.rgb))) }
        return ranked.min { $0.1 < $1.1 }
    }
}
