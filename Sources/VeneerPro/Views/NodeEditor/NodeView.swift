import AppKit
import SwiftUI
import UniformTypeIdentifiers

enum PortSide { case input, output }

struct PortDragEvent {
    let side: PortSide
    let port: Int
    let location: CGPoint
    let ended: Bool
}

/// One node card. Geometry must match `NodeLayout` exactly.
struct NodeView: View {
    let node: GraphNode
    let graph: MaterialGraph
    let thumbnail: CGImage?
    let isSelected: Bool
    let connectedInputs: Set<Int>
    let connectedOutputs: Set<Int>
    var onSelect: () -> Void
    var onMove: (_ location: CGPoint, _ ended: Bool) -> Void
    var onPortDrag: (PortDragEvent) -> Void

    @State private var dragOrigin: CGPoint?

    var body: some View {
        VStack(spacing: 0) {
            header
            VStack(spacing: 0) {
                ForEach(Array(node.kind.outputs.enumerated()), id: \.offset) { i, socket in
                    outputRow(i, socket)
                }
                ForEach(Array(node.kind.inputs.enumerated()), id: \.offset) { i, socket in
                    inputRow(i, socket)
                }
                ForEach(Array(node.kind.fields.enumerated()), id: \.offset) { _, field in
                    fieldRow(field)
                        .frame(height: NodeLayout.fieldHeight(field))
                        .padding(.horizontal, 10)
                }
                if NodeLayout.showsPreview(node.kind) {
                    previewImage
                }
            }
            .padding(.vertical, NodeLayout.padding)
        }
        .frame(width: NodeLayout.width, height: NodeLayout.height(of: node), alignment: .top)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color(white: 0.17)))
        .overlay(RoundedRectangle(cornerRadius: 8)
            .strokeBorder(isSelected ? Color.accentColor : Color.black.opacity(0.6), lineWidth: isSelected ? 2 : 1))
        .shadow(color: .black.opacity(0.4), radius: 6, y: 3)
        .onTapGesture(perform: onSelect)
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 6) {
            Text(node.kind.title)
                .appFont(12, weight: .semibold)
                .lineLimit(1)
            Spacer()
            if node.kind == .surfaceOutput {
                Image(systemName: "cube.fill").appFont(10).opacity(0.7)
            }
        }
        .padding(.horizontal, 10)
        .frame(height: NodeLayout.header)
        .frame(maxWidth: .infinity)
        .background(
            UnevenRoundedRectangle(topLeadingRadius: 8, topTrailingRadius: 8)
                .fill((node.kind.category?.tint ?? Color(red: 0.3, green: 0.6, blue: 0.4)).opacity(0.85))
        )
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 1, coordinateSpace: .named(NodeEditorView.space))
                .onChanged { onMove($0.location, false) }
                .onEnded { onMove($0.location, true) }
        )
    }

    // MARK: Rows

    private func outputRow(_ index: Int, _ socket: Socket) -> some View {
        HStack {
            Spacer()
            Text(socket.name).appFont(11).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .frame(height: NodeLayout.row)
        .overlay(alignment: .trailing) {
            port(socket.type, filled: connectedOutputs.contains(index), side: .output, index: index)
                .offset(x: NodeLayout.portRadius)
        }
    }

    private func inputRow(_ index: Int, _ socket: Socket) -> some View {
        Group {
            if connectedInputs.contains(index) {
                HStack {
                    Text(socket.name).appFont(11).foregroundStyle(.secondary)
                    Spacer()
                }
            } else if socket.type == .float {
                ValueSlider(label: socket.name, value: binding(socket.name), range: socket.range)
            } else {
                ColorRow(label: socket.name, value: binding(socket.name))
            }
        }
        .padding(.horizontal, 12)
        .frame(height: NodeLayout.row)
        .overlay(alignment: .leading) {
            port(socket.type, filled: connectedInputs.contains(index), side: .input, index: index)
                .offset(x: -NodeLayout.portRadius)
        }
    }

    @ViewBuilder
    private func fieldRow(_ field: Field) -> some View {
        switch field {
        case let .color(name, _):
            ColorRow(label: name, value: binding(name))
        case let .float(name, _, range):
            ValueSlider(label: name, value: binding(name), range: range)
        case let .vector2(name, _):
            HStack(spacing: 4) {
                Text(name).appFont(11).foregroundStyle(.secondary)
                Spacer()
                NumberField(value: component(name, 0))
                NumberField(value: component(name, 1))
            }
        case let .option(name, options):
            Picker(name, selection: Binding(
                get: { node.option },
                set: { value in graph.update(node.id) { $0.option = value } }
            )) {
                ForEach(options, id: \.self) { Text($0).tag($0) }
            }
            .appFont(11)
            .controlSize(.small)
        case .texture:
            TextureField(texture: node.texture) { texture in
                graph.update(node.id) { $0.texture = texture }
            }
        }
    }

    private var previewImage: some View {
        Group {
            if let thumbnail {
                Image(decorative: thumbnail, scale: 1)
                    .resizable()
                    .interpolation(.medium)
            } else {
                Color.black.opacity(0.3)
            }
        }
        .frame(width: NodeLayout.preview - 8, height: NodeLayout.preview - 8)
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .frame(height: NodeLayout.preview)
    }

    private func port(_ type: SocketType, filled: Bool, side: PortSide, index: Int) -> some View {
        Circle()
            .fill(filled ? type.tint : Color(white: 0.15))
            .overlay(Circle().strokeBorder(type.tint, lineWidth: 2))
            .frame(width: NodeLayout.portRadius * 2, height: NodeLayout.portRadius * 2)
            .contentShape(Circle().inset(by: -5))
            .gesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .named(NodeEditorView.space))
                    .onChanged { onPortDrag(PortDragEvent(side: side, port: index, location: $0.location, ended: false)) }
                    .onEnded { onPortDrag(PortDragEvent(side: side, port: index, location: $0.location, ended: true)) }
            )
    }

    // MARK: Bindings

    private func binding(_ name: String) -> Binding<SIMD4<Float>> {
        Binding(
            get: { node.value(name) },
            set: { value in graph.update(node.id) { $0.values[name] = value } }
        )
    }

    private func component(_ name: String, _ i: Int) -> Binding<Float> {
        Binding(
            get: { node.value(name)[i] },
            set: { value in graph.update(node.id) { $0.values[name, default: .zero][i] = value } }
        )
    }
}

// MARK: - Controls

/// A Blender-style compact slider: drag anywhere to set, shows label and value.
struct ValueSlider: View {
    let label: String
    @Binding var value: SIMD4<Float>
    let range: ClosedRange<Float>

    var body: some View {
        GeometryReader { geo in
            let fraction = CGFloat((value.x - range.lowerBound) / (range.upperBound - range.lowerBound))
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 4).fill(Color(white: 0.2))
                RoundedRectangle(cornerRadius: 4).fill(Color(white: 0.36))
                    .frame(width: max(0, min(1, fraction)) * geo.size.width)
                HStack {
                    Text(label).lineLimit(1)
                    Spacer()
                    Text(value.x, format: .number.precision(.fractionLength(range.upperBound > 10 ? 0 : 2)))
                        .monospacedDigit()
                }
                .appFont(11)
                .padding(.horizontal, 6)
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { drag in
                let t = Float(max(0, min(1, drag.location.x / geo.size.width)))
                let v = range.lowerBound + t * (range.upperBound - range.lowerBound)
                value = NodeKind.gray(v)
            })
        }
        .frame(height: 18)
    }
}

struct ColorRow: View {
    let label: String
    @Binding var value: SIMD4<Float>

    var body: some View {
        HStack {
            Text(label).appFont(11).foregroundStyle(.secondary)
            Spacer()
            ColorPicker(label, selection: Binding(
                get: { Color(.sRGB, red: Double(value.x), green: Double(value.y), blue: Double(value.z)) },
                set: { color in
                    guard let c = NSColor(color).usingColorSpace(.sRGB) else { return }
                    value = SIMD4(Float(c.redComponent), Float(c.greenComponent), Float(c.blueComponent), 1)
                }
            ), supportsOpacity: false)
            .labelsHidden()
            .controlSize(.small)
        }
    }
}

struct NumberField: View {
    @Binding var value: Float

    var body: some View {
        TextField("", value: $value, format: .number.precision(.fractionLength(0...2)))
            .textFieldStyle(.roundedBorder)
            .appFont(11)
            .controlSize(.small)
            .frame(width: 50)
    }
}

struct TextureField: View {
    let texture: TextureRef?
    var onChange: (TextureRef?) -> Void

    var body: some View {
        HStack(spacing: 8) {
            Group {
                if let texture {
                    Image(decorative: texture.cgImage, scale: 1).resizable().interpolation(.medium)
                } else {
                    Image(systemName: "photo").appFont(17).foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(Color.black.opacity(0.3))
                }
            }
            .frame(width: 54, height: 54)
            .clipShape(RoundedRectangle(cornerRadius: 4))
            VStack(alignment: .leading, spacing: 4) {
                Text(texture?.name ?? "No Image")
                    .appFont(11).lineLimit(1).truncationMode(.middle)
                if let texture {
                    Text("\(Int(texture.size.width))×\(Int(texture.size.height))")
                        .appFont(10).foregroundStyle(.secondary)
                }
                HStack(spacing: 4) {
                    Button("Choose…", action: choose).controlSize(.mini)
                    if texture != nil {
                        Button { onChange(nil) } label: { Image(systemName: "xmark") }
                            .controlSize(.mini)
                            .help("Remove Texture")
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .dropDestination(for: URL.self) { urls, _ in
            guard let texture = urls.first.flatMap(TextureRef.load(url:)) else { return false }
            onChange(texture)
            return true
        }
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        guard panel.runModal() == .OK, let url = panel.url, let texture = TextureRef.load(url: url) else { return }
        onChange(texture)
    }
}
