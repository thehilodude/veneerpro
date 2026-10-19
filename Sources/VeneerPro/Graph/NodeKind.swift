import SwiftUI
import simd

enum SocketType {
    case color
    case float

    var tint: Color {
        switch self {
        case .color: Color(red: 0.95, green: 0.78, blue: 0.25)
        case .float: Color(white: 0.7)
        }
    }
}

struct Socket {
    let name: String
    let type: SocketType
    var defaultValue: SIMD4<Float> = .zero
    /// Range for the inline slider shown when a float input is unconnected.
    var range: ClosedRange<Float> = 0...1
}

/// A non-socket control on a node (stored in `GraphNode.values` or `GraphNode.option`).
enum Field {
    case color(String, SIMD4<Float>)
    case float(String, SIMD4<Float>, ClosedRange<Float>)
    case vector2(String, SIMD4<Float>)
    case option(String, [String])
    case texture
}

enum NodeCategory: String, CaseIterable {
    case input = "Input"
    case texture = "Texture"
    case color = "Color"
    case converter = "Converter"

    var tint: Color {
        switch self {
        case .input: Color(red: 0.55, green: 0.35, blue: 0.75)
        case .texture: Color(red: 0.85, green: 0.45, blue: 0.25)
        case .color: Color(red: 0.75, green: 0.65, blue: 0.2)
        case .converter: Color(red: 0.25, green: 0.55, blue: 0.8)
        }
    }
}

enum NodeKind: String, CaseIterable, Codable {
    case surfaceOutput
    case color
    case value
    case imageTexture
    case checker
    case gradient
    case noise
    case mix
    case math
    case invert
    case hueSaturation
    case brightnessContrast
    case separateRGB
    case combineRGB
    case normalStrength
    case mapRange

    static func gray(_ v: Float) -> SIMD4<Float> { SIMD4(v, v, v, 1) }

    var title: String {
        switch self {
        case .surfaceOutput: "Surface Output"
        case .color: "Color"
        case .value: "Value"
        case .imageTexture: "Image Texture"
        case .checker: "Checker"
        case .gradient: "Gradient"
        case .noise: "Noise"
        case .mix: "Mix"
        case .math: "Math"
        case .invert: "Invert"
        case .hueSaturation: "Hue / Saturation"
        case .brightnessContrast: "Brightness / Contrast"
        case .separateRGB: "Separate RGBA"
        case .combineRGB: "Combine RGB"
        case .normalStrength: "Normal Strength"
        case .mapRange: "Map Range"
        }
    }

    var category: NodeCategory? {
        switch self {
        case .surfaceOutput: nil
        case .color, .value: .input
        case .imageTexture, .checker, .gradient, .noise: .texture
        case .mix, .invert, .hueSaturation, .brightnessContrast: .color
        case .math, .separateRGB, .combineRGB, .normalStrength, .mapRange: .converter
        }
    }

    var inputs: [Socket] {
        switch self {
        case .surfaceOutput:
            [Socket(name: "Base Color", type: .color, defaultValue: Self.gray(0.8)),
             Socket(name: "Metallic", type: .float, defaultValue: Self.gray(0)),
             Socket(name: "Roughness", type: .float, defaultValue: Self.gray(0.5)),
             Socket(name: "Normal", type: .color, defaultValue: SIMD4(0.5, 0.5, 1, 1)),
             Socket(name: "Emissive", type: .color, defaultValue: Self.gray(0)),
             Socket(name: "Opacity", type: .float, defaultValue: Self.gray(1)),
             Socket(name: "Occlusion", type: .float, defaultValue: Self.gray(1)),
             Socket(name: "Clearcoat", type: .float, defaultValue: Self.gray(0)),
             Socket(name: "Clearcoat Roughness", type: .float, defaultValue: Self.gray(0.01))]
        case .mix:
            [Socket(name: "A", type: .color, defaultValue: Self.gray(0)),
             Socket(name: "B", type: .color, defaultValue: Self.gray(1)),
             Socket(name: "Factor", type: .float, defaultValue: Self.gray(0.5))]
        case .math:
            [Socket(name: "A", type: .float, defaultValue: Self.gray(0.5), range: 0...4),
             Socket(name: "B", type: .float, defaultValue: Self.gray(0.5), range: 0...4)]
        case .invert, .hueSaturation, .brightnessContrast, .separateRGB:
            [Socket(name: "Color", type: .color, defaultValue: Self.gray(0.5))]
        case .combineRGB:
            [Socket(name: "R", type: .float), Socket(name: "G", type: .float), Socket(name: "B", type: .float)]
        case .normalStrength:
            [Socket(name: "Normal", type: .color, defaultValue: SIMD4(0.5, 0.5, 1, 1))]
        case .mapRange:
            [Socket(name: "Value", type: .float, defaultValue: Self.gray(0.5))]
        case .color, .value, .imageTexture, .checker, .gradient, .noise:
            []
        }
    }

    var outputs: [Socket] {
        switch self {
        case .surfaceOutput: []
        case .value: [Socket(name: "Value", type: .float)]
        case .imageTexture:
            [Socket(name: "Color", type: .color), Socket(name: "R", type: .float),
             Socket(name: "G", type: .float), Socket(name: "B", type: .float),
             Socket(name: "Alpha", type: .float)]
        case .separateRGB:
            [Socket(name: "R", type: .float), Socket(name: "G", type: .float),
             Socket(name: "B", type: .float), Socket(name: "Alpha", type: .float)]
        case .math: [Socket(name: "Result", type: .float)]
        case .normalStrength: [Socket(name: "Normal", type: .color)]
        case .mapRange: [Socket(name: "Value", type: .float)]
        default: [Socket(name: "Color", type: .color)]
        }
    }

    var fields: [Field] {
        switch self {
        case .surfaceOutput: [.option("Bake Size", ["512", "1024", "2048", "4096"])]
        case .color: [.color("Color", Self.gray(0.8))]
        case .value: [.float("Value", Self.gray(0.5), 0...1)]
        case .imageTexture: [.texture, .vector2("Tiling", SIMD4(1, 1, 0, 0))]
        case .checker:
            [.color("Color 1", Self.gray(0.9)), .color("Color 2", Self.gray(0.2)),
             .float("Scale", Self.gray(8), 1...64)]
        case .gradient:
            [.option("Type", ["Horizontal", "Vertical", "Radial"]),
             .color("Color 1", Self.gray(0)), .color("Color 2", Self.gray(1))]
        case .noise:
            [.option("Type", ["Grayscale", "Color"]), .float("Scale", Self.gray(8), 1...128),
             .float("Stretch", Self.gray(1), 1...64), .float("Seed", Self.gray(0), 0...100)]
        case .mix: [.option("Blend", ["Mix", "Multiply", "Screen", "Overlay"])]
        case .math: [.option("Operation", MathOperation.allCases.map(\.rawValue))]
        case .hueSaturation:
            [.float("Hue", Self.gray(0), -0.5...0.5), .float("Saturation", Self.gray(1), 0...2),
             .float("Value", Self.gray(1), 0...2)]
        case .brightnessContrast:
            [.float("Brightness", Self.gray(0), -1...1), .float("Contrast", Self.gray(1), 0...2)]
        case .normalStrength: [.float("Strength", Self.gray(1), 0...3)]
        case .mapRange:
            [.float("From Min", Self.gray(0), 0...1), .float("From Max", Self.gray(1), 0...1),
             .float("To Min", Self.gray(0), 0...1), .float("To Max", Self.gray(1), 0...1)]
        case .invert, .separateRGB, .combineRGB: []
        }
    }

    var defaultOption: String {
        for case let .option(_, options) in fields { return options.first ?? "" }
        return ""
    }

    var defaultValues: [String: SIMD4<Float>] {
        var values: [String: SIMD4<Float>] = [:]
        for socket in inputs { values[socket.name] = socket.defaultValue }
        for field in fields {
            switch field {
            case let .color(name, v), let .float(name, v, _), let .vector2(name, v): values[name] = v
            default: break
            }
        }
        return values
    }
}

enum MathOperation: String, CaseIterable {
    case add = "Add"
    case subtract = "Subtract"
    case multiply = "Multiply"
    case divide = "Divide"
    case minimum = "Minimum"
    case maximum = "Maximum"
    case difference = "Difference"
    case power = "Power"

    func apply(_ a: SIMD4<Float>, _ b: SIMD4<Float>) -> SIMD4<Float> {
        var r: SIMD4<Float>
        switch self {
        case .add: r = a + b
        case .subtract: r = a - b
        case .multiply: r = a * b
        case .divide: r = SIMD4((0..<4).map { b[$0] == 0 ? 0 : a[$0] / b[$0] })
        case .minimum: r = simd_min(a, b)
        case .maximum: r = simd_max(a, b)
        case .difference: r = simd_abs(a - b)
        case .power: r = SIMD4((0..<4).map { powf(max(a[$0], 0), b[$0]) })
        }
        r.w = 1
        return r
    }
}
