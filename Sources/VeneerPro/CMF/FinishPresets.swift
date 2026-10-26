import Foundation

/// A surface finish as specified on a CMF sheet, translated into the material's PBR inputs.
///
/// Roughness values are visual approximations: gloss units, SPI grades and VDI 3400 Ra values don't
/// map exactly onto a renderer's roughness, so judge final finishes against physical samples.
struct FinishPreset: Identifiable, Hashable {
    enum Category: String, CaseIterable {
        case paint = "Paint & Coatings"
        case spi = "Plastic · SPI Mold Finish"
        case vdi = "Plastic · VDI 3400 Texture"
        case metal = "Metal"
    }

    /// Fine surface variation, added as a noise node driving roughness.
    struct Grain: Hashable {
        /// Noise scale (higher is finer).
        var scale: Float
        /// Stretch along one direction, for brushed finishes.
        var stretch: Float = 1
        /// How far roughness varies around its base value.
        var amount: Float
    }

    let id: String
    let name: String
    let category: Category
    /// The standard's own description, e.g. "60° gloss > 85 GU" or "Ra 2.24 µm".
    let detail: String
    var metallic: Float = 0
    let roughness: Float
    var clearcoat: Float = 0
    var clearcoatRoughness: Float = 0.03
    var grain: Grain?

    static func preset(id: String?) -> FinishPreset? { all.first { $0.id == id } }

    static let all: [FinishPreset] = paint + spi + vdi + metal

    // Gloss bands follow the 60° gloss unit (GU) ranges used for paints (ISO 2813).
    static let paint: [FinishPreset] = [
        FinishPreset(id: "paint.highgloss", name: "High Gloss", category: .paint, detail: "60° gloss > 85 GU", roughness: 0.06),
        FinishPreset(id: "paint.gloss", name: "Gloss", category: .paint, detail: "60° gloss 70–85 GU", roughness: 0.14),
        FinishPreset(id: "paint.semigloss", name: "Semi-Gloss", category: .paint, detail: "60° gloss 35–70 GU", roughness: 0.27),
        FinishPreset(id: "paint.satin", name: "Satin", category: .paint, detail: "60° gloss 10–35 GU", roughness: 0.42),
        FinishPreset(id: "paint.matte", name: "Matte", category: .paint, detail: "60° gloss < 10 GU", roughness: 0.62),
        FinishPreset(id: "paint.flat", name: "Flat", category: .paint, detail: "60° gloss < 5 GU", roughness: 0.8),
        FinishPreset(id: "paint.clearcoat", name: "Clear-Coated Paint", category: .paint, detail: "Satin base under a gloss clear coat",
                     roughness: 0.4, clearcoat: 1, clearcoatRoughness: 0.03),
        FinishPreset(id: "paint.piano", name: "Piano Gloss", category: .paint, detail: "Polished gloss under a clear coat",
                     roughness: 0.08, clearcoat: 1, clearcoatRoughness: 0.02),
        FinishPreset(id: "paint.softtouch", name: "Soft-Touch", category: .paint, detail: "Elastomeric matte coating", roughness: 0.86),
        FinishPreset(id: "paint.powderfine", name: "Powder Coat, Fine Texture", category: .paint, detail: "Fine orange-peel texture",
                     roughness: 0.5, grain: Grain(scale: 96, amount: 0.16)),
        FinishPreset(id: "paint.powderwrinkle", name: "Powder Coat, Wrinkle", category: .paint, detail: "Coarse wrinkle texture",
                     roughness: 0.62, grain: Grain(scale: 40, amount: 0.3)),
    ]

    // SPI (Society of the Plastics Industry) mold polish grades.
    static let spi: [FinishPreset] = [
        FinishPreset(id: "spi.a1", name: "SPI A-1", category: .spi, detail: "Grade #3 diamond buff · mirror", roughness: 0.02),
        FinishPreset(id: "spi.a2", name: "SPI A-2", category: .spi, detail: "Grade #6 diamond buff", roughness: 0.04),
        FinishPreset(id: "spi.a3", name: "SPI A-3", category: .spi, detail: "Grade #15 diamond buff", roughness: 0.07),
        FinishPreset(id: "spi.b1", name: "SPI B-1", category: .spi, detail: "600 grit paper", roughness: 0.17),
        FinishPreset(id: "spi.b2", name: "SPI B-2", category: .spi, detail: "400 grit paper", roughness: 0.23),
        FinishPreset(id: "spi.b3", name: "SPI B-3", category: .spi, detail: "320 grit paper", roughness: 0.29),
        FinishPreset(id: "spi.c1", name: "SPI C-1", category: .spi, detail: "600 grit stone", roughness: 0.37),
        FinishPreset(id: "spi.c2", name: "SPI C-2", category: .spi, detail: "400 grit stone", roughness: 0.44),
        FinishPreset(id: "spi.c3", name: "SPI C-3", category: .spi, detail: "320 grit stone", roughness: 0.51),
        FinishPreset(id: "spi.d1", name: "SPI D-1", category: .spi, detail: "Dry blast, glass bead", roughness: 0.6,
                     grain: Grain(scale: 120, amount: 0.12)),
        FinishPreset(id: "spi.d2", name: "SPI D-2", category: .spi, detail: "Dry blast, #240 oxide", roughness: 0.7,
                     grain: Grain(scale: 100, amount: 0.16)),
        FinishPreset(id: "spi.d3", name: "SPI D-3", category: .spi, detail: "Dry blast, #24 oxide", roughness: 0.82,
                     grain: Grain(scale: 64, amount: 0.2)),
    ]

    // VDI 3400 EDM textures, with the standard's Ra values (µm).
    static let vdi: [FinishPreset] = zip(stride(from: 12, through: 45, by: 3),
                                         ["0.40", "0.56", "0.80", "1.12", "1.60", "2.24", "3.15", "4.50", "6.30", "9.00", "12.5", "18.0"])
        .map { ref, ra in
        let t = Float(ref - 12) / 33
        return FinishPreset(id: "vdi.\(ref)", name: "VDI \(ref)", category: .vdi,
                            detail: "Ra \(ra) µm", roughness: 0.45 + 0.47 * t,
                            grain: Grain(scale: 128 - 80 * t, amount: 0.08 + 0.17 * t))
    }

    static let metal: [FinishPreset] = [
        FinishPreset(id: "metal.mirror", name: "Mirror Polished", category: .metal, detail: "Buffed to a mirror", metallic: 1, roughness: 0.03),
        FinishPreset(id: "metal.polished", name: "Polished", category: .metal, detail: "Bright polish", metallic: 1, roughness: 0.1),
        FinishPreset(id: "metal.brushed", name: "Brushed", category: .metal, detail: "Directional grain",
                     metallic: 1, roughness: 0.32, grain: Grain(scale: 48, stretch: 40, amount: 0.22)),
        FinishPreset(id: "metal.bead", name: "Bead Blasted", category: .metal, detail: "Uniform satin from glass bead blasting",
                     metallic: 1, roughness: 0.5, grain: Grain(scale: 128, amount: 0.1)),
        FinishPreset(id: "metal.anodized", name: "Anodized", category: .metal, detail: "Type II, color from the base color",
                     metallic: 1, roughness: 0.36),
        FinishPreset(id: "metal.anodizedblast", name: "Bead Blasted + Anodized", category: .metal, detail: "Matte anodized",
                     metallic: 1, roughness: 0.48, grain: Grain(scale: 128, amount: 0.08)),
        FinishPreset(id: "metal.hardanodized", name: "Hard Anodized", category: .metal, detail: "Type III, dark and matte",
                     metallic: 1, roughness: 0.6),
    ]
}
