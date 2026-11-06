import Foundation
import simd

/// A spray paint you can buy, for matching a specified color to something a student can paint a model with.
struct SprayPaint: Identifiable, Hashable {
    let brand: String
    /// The sheen the line dries to (MTN 94 is a matte paint).
    var sheen: SprayFinish.Sheen = .matte
    let code: String
    let name: String
    let hex: UInt32

    var id: String { brand + code + name }
    var rgb: SIMD3<Float> { ColorStandards.rgb(hex: hex) }
    var title: String { [brand, code, name].filter { !$0.isEmpty }.joined(separator: " ") }

    /// A web search for this can, to find it at a local store or online.
    var searchURL: URL { SprayPaints.search("\(title) spray paint") }
}

/// Off-the-shelf spray paints and matching (opt-in: Color & Finish ▸ Spray Paint Matches).
enum SprayPaints {
    /// Turns matching on in the inspector; also the spec sheet's default.
    static let settingKey = "SprayPaintMatches"
    static var enabled: Bool { UserDefaults.standard.bool(forKey: settingKey) }

    static let all: [SprayPaint] = parse(mtn94Table, brand: "MTN 94")

    struct Match: Hashable {
        let paint: SprayPaint
        let deltaE: Double
        /// The RAL code this can is named after (e.g. MTN 94 RV-7016 for RAL 7016), when it matches the color's code.
        var ralNamesake: String?

        /// How noticeable the difference is likely to be.
        var closeness: String {
            switch deltaE {
            case ..<2: "Very close"
            case ..<5: "Close"
            default: "Nearest available"
            }
        }
    }

    /// The closest cans to `rgb` (CIEDE2000), best first. A can named after the color's RAL number is
    /// marked when it's among them.
    static func matches(for rgb: SIMD3<Float>, code: String? = nil, count: Int = 3) -> [Match] {
        let target = ColorStandards.lab(rgb)
        let number = ralNumber(code)
        return all.map { paint in
            Match(paint: paint, deltaE: ColorStandards.deltaE(target, ColorStandards.lab(paint.rgb)),
                  ralNamesake: number != nil && ralNumber(paint.code) == number ? "RAL \(number!)" : nil)
        }
        .sorted { $0.deltaE < $1.deltaE }
        .prefix(count)
        .map { $0 }
    }

    /// A can named after the color's RAL number that isn't among the closest matches. Shown separately:
    /// shoppers will look for it, but brands' "RAL" shades often differ (MTN 94 RV-3020 vs RAL 3020: ΔE 12).
    static func namesake(for rgb: SIMD3<Float>, code: String?, excluding shown: [Match]) -> Match? {
        guard let number = ralNumber(code),
              let paint = all.first(where: { ralNumber($0.code) == number }),
              !shown.contains(where: { $0.paint == paint }) else { return nil }
        return Match(paint: paint, deltaE: ColorStandards.deltaE(ColorStandards.lab(rgb), ColorStandards.lab(paint.rgb)),
                     ralNamesake: "RAL \(number)")
    }

    /// "7016" from "RAL 7016", "RV-7016" or "R-7016" (four-digit RAL Classic numbers only).
    private static func ralNumber(_ code: String?) -> String? {
        guard let code, let match = code.firstMatch(of: #/^(?:RAL |RV?-)(\d{4})$/#) else { return nil }
        return String(match.1)
    }

    /// For RAL colors: many aerosols are sold already matched to RAL codes, and paint stores can mix
    /// RAL shades into spray cans, so the code itself is the most exact thing to buy.
    static func ralSprayURL(for code: String?) -> URL? {
        guard let code, code.hasPrefix("RAL ") else { return nil }
        return search("\(code) spray paint")
    }

    /// Short lines for spec sheets: what to buy, e.g. "Spray: RAL 5015 (satin) · MTN 94 RV-152 + satin
    /// clear (ΔE 2.5)", then a note when the finish itself can't be sprayed.
    static func summary(for rgb: SIMD3<Float>, code: String?, finish: SprayFinish) -> [String] {
        let note = finish.shortLimit.map { "Finish: \($0)" }
        // Metallic and see-through materials don't come in solid colors; textures still need the color.
        if let note, !finish.colorStillApplies { return [note] }
        let best = matches(for: rgb, code: code, count: 1).first
        let ral = code.flatMap { $0.hasPrefix("RAL ") ? $0 + (finish.sheenLabel.map { " (\($0))" } ?? "") : nil }
        let nearest = best.map { match in
            let can = match.paint.code.isEmpty ? match.paint.title : "\(match.paint.brand) \(match.paint.code)"
            let coat = finish.clearCoat(over: match.paint).map { " + \($0)" } ?? ""
            return "\(can)\(coat) (ΔE \(String(format: "%.1f", match.deltaE)))"
        }
        let buy: String?
        switch (ral, nearest) {
        case let (ral?, nearest?): buy = "Spray: \(ral) · \(nearest)"
        case let (ral?, nil): buy = "Spray: \(ral)"
        case let (nil, nearest?): buy = "Nearest spray: \(nearest)"
        default: buy = nil
        }
        return [buy, note].compactMap { $0 }
    }

    static func search(_ query: String) -> URL {
        var components = URLComponents(string: "https://www.google.com/search")!
        components.queryItems = [URLQueryItem(name: "q", value: query)]
        return components.url!
    }

    private static func parse(_ table: String, brand: String) -> [SprayPaint] {
        table.split(separator: "\n").compactMap { line in
            let parts = line.split(separator: "|", omittingEmptySubsequences: false)
            guard parts.count == 3, let hex = UInt32(parts[2], radix: 16) else { return nil }
            return SprayPaint(brand: brand, code: String(parts[0]), name: String(parts[1]), hex: hex)
        }
    }
}

/// What a material's finish means for spraying it: the sheen to buy (or reach with a clear coat), and
/// finishes a can of colored paint can't reproduce.
struct SprayFinish: Equatable {
    enum Sheen: String, Comparable {
        case matte, satin, semiGloss = "semi-gloss", gloss

        private var rank: Int { [.matte: 0, .satin: 1, .semiGloss: 2, .gloss: 3][self]! }
        static func < (a: Sheen, b: Sheen) -> Bool { a.rank < b.rank }
    }

    /// The sheen to aim for, or nil when it can't be told (a textured roughness, say).
    var sheen: Sheen?
    /// A finish paint alone can't match, with what to do instead.
    var limit: String?
    /// The same, in a few words for spec sheets.
    var shortLimit: String?
    /// A clear top coat is part of the finish (clear-coated paint, piano gloss).
    var needsGlossTopCoat = false
    /// The sheen was guessed from roughness (no finish preset), so it's only a hint.
    var estimated = false

    /// "satin", or "satin?" when it's a guess.
    var sheenLabel: String? { sheen.map { $0.rawValue + (estimated ? "?" : "") } }
    /// False for metallic and see-through finishes, where a solid paint color isn't the answer.
    var colorStillApplies = true

    /// The finish of `graph`: its finish preset when it still matches, otherwise its metallic,
    /// opacity and roughness values.
    init(graph: MaterialGraph) {
        self.init(preset: "")
        let output = graph.node(graph.outputNodeID)
        func value(_ channel: MaterialGraph.Channel) -> Float? {
            graph.link(into: PortRef(node: graph.outputNodeID, port: channel.rawValue)) == nil ? output?.value(channel.name).x : nil
        }
        if graph.finishMatchesSpec, let id = graph.spec.finishID {
            self = SprayFinish(preset: id)
            return
        }
        if let metallic = value(.metallic), metallic >= 0.5 {
            limit = "Metallic finish: use a metallic spray; the colors below are solid paints."
            shortLimit = "metallic, use a metallic spray"
            colorStillApplies = false
            return
        }
        if let opacity = value(.opacity), opacity < 0.9 {
            limit = "See-through material: paint won't match it; use a tinted or clear spray."
            shortLimit = "see-through, use a tinted or clear spray"
            colorStillApplies = false
            return
        }
        if let clearcoat = value(.clearcoat), clearcoat > 0.3 { needsGlossTopCoat = true }
        if let roughness = value(.roughness) {
            sheen = roughness < 0.18 ? .gloss : roughness < 0.32 ? .semiGloss : roughness < 0.52 ? .satin : .matte
            estimated = true
        }
        if needsGlossTopCoat { sheen = .gloss; estimated = false }
    }

    private init(preset id: String) {
        let family = id.split(separator: ".").first.map(String.init) ?? ""
        switch id {
        case "paint.highgloss", "paint.gloss": sheen = .gloss
        case "paint.semigloss": sheen = .semiGloss
        case "paint.satin": sheen = .satin
        case "paint.matte", "paint.flat": sheen = .matte
        case "paint.clearcoat", "paint.piano": sheen = .gloss; needsGlossTopCoat = true
        case "paint.softtouch":
            sheen = .matte
            limit = "Soft-touch is a rubbery coating: spray the color matte, or use a soft-touch / rubberized spray."
            shortLimit = "soft-touch, matte color or a rubberized spray"
        case "paint.powderfine", "paint.powderwrinkle":
            sheen = .satin
            limit = "Powder-coat texture can't be sprayed exactly: use a textured (stone or hammered) spray to approximate."
            shortLimit = "textured, approximate with a texture spray"
        case "spi.a1", "spi.a2", "spi.a3": sheen = .gloss
        case "spi.b1", "spi.b2", "spi.b3": sheen = .satin
        case "spi.c1", "spi.c2", "spi.c3": sheen = .matte
        default:
            if family == "spi" || family == "vdi" {
                sheen = .matte
                limit = "Textured plastic can't be sprayed exactly: a matte coat over light sanding, or a fine texture spray, gets closest."
                shortLimit = "textured, matte coat or fine texture spray"
            } else if family == "metal" {
                limit = "Metal finish: use a metallic (or chrome, then candy/tinted) spray; the colors below are solid paints."
                shortLimit = "metallic, use a metallic spray"
                colorStillApplies = false
            }
        }
    }

    /// The clear coat to put over `paint` to reach this sheen, e.g. "satin clear" over matte MTN 94.
    /// Not suggested when the sheen is only a guess.
    func clearCoat(over paint: SprayPaint) -> String? {
        guard let sheen, !estimated, sheen > paint.sheen || needsGlossTopCoat else { return nil }
        return "\(needsGlossTopCoat ? "gloss" : sheen.rawValue) clear"
    }

    /// Advice to show above the matches, e.g. "Satin finish: MTN 94 dries matte, so top it with a satin clear coat."
    func advice(for paints: [SprayPaint]) -> String? {
        if let limit { return limit }
        guard let sheen else { return nil }
        let name = sheen.rawValue.prefix(1).uppercased() + sheen.rawValue.dropFirst()
        if estimated {
            return "Looks \(sheen.rawValue) (no finish set). Pick a finish above for exact sheen advice."
        }
        if let paint = paints.first, let coat = clearCoat(over: paint) {
            return "\(name) finish: \(paint.brand) dries \(paint.sheen.rawValue), so top it with a \(coat) coat."
        }
        return "\(name) finish: buy \(sheen.rawValue) cans where offered."
    }
}
