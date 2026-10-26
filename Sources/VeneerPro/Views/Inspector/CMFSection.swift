import SwiftUI

/// The selected material's color code and finish, specified the way they're handed to suppliers.
struct CMFSection: View {
    let entry: MaterialEntry
    /// The color picker opens inline, under the color, so it never covers the model.
    @AppStorage("ColorPickerOpen") private var choosingColor = false

    var body: some View {
        let graph = entry.graph
        let spec = graph.spec
        InspectorSection(title: "Color & Finish") {
            // Color
            HStack(alignment: .top, spacing: 10) {
                Button { withAnimation(.snappy(duration: 0.2)) { choosingColor.toggle() } } label: {
                    ColorChip(color: graph.constantBaseColor, size: 40)
                }
                .buttonStyle(.plain)
                .help("Choose a color by RAL code, hex, RGB or L*a*b*")
                VStack(alignment: .leading, spacing: 2) {
                    if let code = spec.colorCode, graph.colorMatchesSpec {
                        Text(code).font(.system(size: 13, weight: .semibold))
                        if let name = spec.colorName { Text(name).font(.system(size: 11.5)).foregroundStyle(.secondary) }
                    } else if graph.baseColorIsLinked {
                        Text("Texture").font(.system(size: 13, weight: .semibold))
                        Text("Base color comes from a node").font(.system(size: 11.5)).foregroundStyle(.secondary)
                    } else {
                        Text("Custom Color").font(.system(size: 13, weight: .semibold))
                        if let code = spec.colorCode {
                            Text("Changed from \(code)").font(.system(size: 11.5)).foregroundStyle(.orange)
                        }
                    }
                    if let rgb = graph.constantBaseColor { ColorReadout(rgb: rgb) }
                }
                Spacer(minLength: 0)
            }
            Button(choosingColor ? "Done" : "Choose Color…") {
                withAnimation(.snappy(duration: 0.2)) { choosingColor.toggle() }
            }
            .controlSize(.small)
            if choosingColor {
                ColorStandardPicker(graph: graph)
                    .background(RoundedRectangle(cornerRadius: Theme.corner).fill(Theme.control))
                    .transition(.opacity)
            }

            Divider().padding(.vertical, 2)

            // Finish
            InspectorRow(title: "Finish") {
                Menu {
                    ForEach(FinishPreset.Category.allCases, id: \.self) { category in
                        Section(category.rawValue) {
                            ForEach(FinishPreset.all.filter { $0.category == category }) { finish in
                                Button("\(finish.name)  ·  \(finish.detail)") { graph.applyFinish(finish) }
                            }
                        }
                    }
                } label: {
                    Text(graph.finishMatchesSpec ? spec.finish?.name ?? "Custom" : "Custom")
                }
                .fixedSize()
            }
            if let finish = spec.finish {
                Text(graph.finishMatchesSpec ? finish.detail : "Changed from \(finish.name)")
                    .font(.caption)
                    .foregroundStyle(graph.finishMatchesSpec ? Color.secondary : Color.orange)
            }
        }
    }
}

/// Hex, RGB and L*a*b* of a color, plus the nearest RAL.
private struct ColorReadout: View {
    let rgb: SIMD3<Float>

    var body: some View {
        let lab = ColorStandards.lab(rgb)
        let nearest = ColorStandards.nearestRAL(to: rgb)
        let c = rgb * 255
        VStack(alignment: .leading, spacing: 1) {
            Text("\(ColorStandards.hexString(rgb))   RGB \(Int(c.x.rounded())) \(Int(c.y.rounded())) \(Int(c.z.rounded()))")
            Text(String(format: "L*a*b*  %.1f  %.1f  %.1f", lab.x, lab.y, lab.z))
            if nearest.deltaE >= 0.5 {
                Text("Nearest \(nearest.color.code) · ΔE \(String(format: "%.1f", nearest.deltaE))")
            }
        }
        .font(.system(size: 10.5).monospacedDigit())
        .foregroundStyle(.secondary)
        .textSelection(.enabled)
    }
}

struct ColorChip: View {
    let color: SIMD3<Float>?
    var size: CGFloat = 22

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.22)
            .fill(color.map { Color(.sRGB, red: Double($0.x), green: Double($0.y), blue: Double($0.z)) } ?? Color.gray.opacity(0.3))
            .overlay {
                if color == nil { Image(systemName: "photo").foregroundStyle(.secondary) }
            }
            .overlay(RoundedRectangle(cornerRadius: size * 0.22).strokeBorder(Color.white.opacity(0.15)))
            .frame(width: size, height: size)
    }
}

/// Picks a base color from RAL Classic, or by hex/RGB, L*a*b*, or another system's code.
private struct ColorStandardPicker: View {
    enum Mode: String, CaseIterable { case ral = "RAL", value = "Hex/RGB", lab = "L*a*b*", other = "Other" }

    let graph: MaterialGraph
    @AppStorage("ColorPickerMode") private var mode: Mode = .ral
    @State private var search = ""
    @State private var group: String?
    @State private var hovered: StandardColor?
    @State private var valueText = ""
    @State private var l = 50.0
    @State private var a = 0.0
    @State private var b = 0.0
    @State private var otherCode = ""
    @State private var otherName = ""

    @AppStorage("RALSystem") private var system: StandardColor.System = .ral

    /// Each system's color families, in display order, with their counts.
    private static let families: [StandardColor.System: [(name: String, count: Int)]] = {
        let order = ["White", "Grey", "Black", "Red", "Orange", "Yellow", "Brown", "Green", "Blue", "Violet"]
        var result: [StandardColor.System: [(String, Int)]] = [:]
        for system in StandardColor.System.allCases {
            var counts: [String: Int] = [:]
            var seen: [String] = []
            for color in system.colors {
                if counts[color.group] == nil { seen.append(color.group) }
                counts[color.group, default: 0] += 1
            }
            // Classic keeps RAL's own groups in RAL's order; the others use hue families.
            let names = system == .ral ? seen : order.filter { counts[$0] != nil }
            result[system] = names.map { ($0, counts[$0]!) }
        }
        return result
    }()

    private static func label(_ color: StandardColor) -> String {
        color.name.isEmpty ? color.code : "\(color.code) · \(color.name)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("", selection: $mode) {
                ForEach(Mode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            if graph.baseColorIsLinked {
                Label("Applying a color replaces the texture driving Base Color.", systemImage: "info.circle")
                    .font(.caption).foregroundStyle(.secondary)
            }

            switch mode {
            case .ral: ralBrowser
            case .value: valueEntry
            case .lab: labEntry
            case .other: otherEntry
            }
        }
        .padding(10)
        .onAppear {
            let current = graph.constantBaseColor ?? SIMD3(repeating: 0.8)
            valueText = ColorStandards.hexString(current)
            let lab = ColorStandards.lab(current)
            (l, a, b) = (lab.x.rounded(), lab.y.rounded(), lab.z.rounded())
        }
    }

    private var ralColors: [StandardColor] {
        // Codes match with or without spaces ("000 15 00", "0001500", "110-M").
        let query = search.trimmingCharacters(in: .whitespaces)
        let compact = query.replacingOccurrences(of: " ", with: "")
        return system.colors.filter { color in
            (group == nil || color.group == group)
                && (query.isEmpty || color.name.localizedCaseInsensitiveContains(query)
                    || color.code.replacingOccurrences(of: " ", with: "").localizedCaseInsensitiveContains(compact))
        }
    }

    private var searchPrompt: String {
        switch system {
        case .ral: "Search code or name, e.g. 7016 or anthracite"
        case .ralDesign: "Search code or name, e.g. 270 30 25 or navy"
        case .ralEffect: "Search code, e.g. 110-M"
        }
    }

    private var ralBrowser: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("System", selection: $system) {
                ForEach(StandardColor.System.allCases) { system in
                    Text("\(system.rawValue)  (\(system.colors.count.formatted()))").tag(system)
                }
            }
            .labelsHidden()
            .onChange(of: system) { group = nil; hovered = nil }
            TextField(searchPrompt, text: $search)
                .textFieldStyle(.roundedBorder)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    FilterChip(title: "All", count: system.colors.count, selected: group == nil) { group = nil }
                    ForEach(Self.families[system] ?? [], id: \.name) { family in
                        FilterChip(title: family.name, count: family.count,
                                   selected: group == family.name) { group = group == family.name ? nil : family.name }
                    }
                }
            }
            ScrollView {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 5), count: 9), spacing: 5) {
                    ForEach(ralColors) { color in
                        let selected = graph.spec.colorCode == color.code && graph.colorMatchesSpec
                        Button { graph.applyColor(color.rgb, code: color.code, name: color.name) } label: {
                            RoundedRectangle(cornerRadius: 7)
                                .fill(Color(.sRGB, red: Double(color.rgb.x), green: Double(color.rgb.y), blue: Double(color.rgb.z)))
                                .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Color.white.opacity(0.15)))
                                .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Color.accentColor, lineWidth: selected ? 2.5 : 0))
                                .aspectRatio(1, contentMode: .fit)
                        }
                        .buttonStyle(.plain)
                        .onHover { if $0 { hovered = color } }
                        .help(Self.label(color))
                    }
                }
                .padding(2)
            }
            .frame(height: 200)
            let shown = hovered ?? system.colors.first { $0.code == graph.spec.colorCode }
            HStack {
                Text(shown.map(Self.label) ?? "\(ralColors.count.formatted()) colors")
                    .font(.system(size: 12, weight: .medium))
                Spacer()
                if let shown { Text(ColorStandards.hexString(shown.rgb)).font(.system(size: 11).monospaced()).foregroundStyle(.secondary) }
            }
            Text(system == .ralEffect
                 ? "Screen colors approximate RAL Effect; metallic shades (-M) also need a metallic finish. Confirm against a physical fan deck."
                 : "Screen colors are approximations of \(system.rawValue); confirm against a physical fan deck.")
                .font(.caption2).foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var valueEntry: some View {
        let parsed = ColorStandards.parse(valueText)
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                ColorChip(color: parsed, size: 28)
                TextField("#2874B2 or 40, 116, 178", text: $valueText)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(applyValue)
            }
            Text("Hex, or sRGB as 0–255 or 0–1 values.").font(.caption).foregroundStyle(.secondary)
            Button("Apply", action: applyValue).disabled(parsed == nil)
        }
    }

    private func applyValue() {
        guard let rgb = ColorStandards.parse(valueText) else { return }
        graph.applyColor(rgb, code: ColorStandards.hexString(rgb), name: nil)
    }

    private var labEntry: some View {
        let rgb = ColorStandards.rgb(lab: SIMD3(l, a, b))
        let back = ColorStandards.lab(rgb)
        let clipped = ColorStandards.deltaE(back, SIMD3(l, a, b)) > 1
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                ColorChip(color: rgb, size: 28)
                labField("L*", $l)
                labField("a*", $a)
                labField("b*", $b)
            }
            if clipped {
                Label("Outside the sRGB gamut; shown as the closest displayable color.", systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.orange)
            }
            Text("CIELAB, D65 white point.").font(.caption).foregroundStyle(.secondary)
            Button("Apply") {
                graph.applyColor(rgb, code: String(format: "L*a*b* %.0f %.0f %.0f", l, a, b), name: nil)
            }
        }
    }

    private func labField(_ title: String, _ value: Binding<Double>) -> some View {
        HStack(spacing: 3) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            TextField(title, value: value, format: .number.precision(.fractionLength(0...1)))
                .textFieldStyle(.roundedBorder)
                .frame(width: 52)
        }
    }

    private var otherEntry: some View {
        let parsed = ColorStandards.parse(valueText)
        return VStack(alignment: .leading, spacing: 8) {
            TextField("Code, e.g. PANTONE 2945 C or NCS S 2060-R80B", text: $otherCode)
                .textFieldStyle(.roundedBorder)
            TextField("Name (optional)", text: $otherName)
                .textFieldStyle(.roundedBorder)
            HStack {
                ColorChip(color: parsed, size: 28)
                TextField("Screen color: #hex or R, G, B", text: $valueText)
                    .textFieldStyle(.roundedBorder)
            }
            Text("Pantone and NCS libraries are licensed, so enter the code with the sRGB value from your swatch book or supplier.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button("Apply") {
                guard let rgb = parsed else { return }
                let code = otherCode.trimmingCharacters(in: .whitespaces)
                graph.applyColor(rgb, code: code.isEmpty ? ColorStandards.hexString(rgb) : code,
                                 name: otherName.isEmpty ? nil : otherName)
            }
            .disabled(parsed == nil)
        }
    }
}
