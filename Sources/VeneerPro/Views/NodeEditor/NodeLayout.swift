import CoreGraphics

/// Fixed node geometry, shared by the node views and the wire renderer so ports line up exactly.
/// Rows are ordered: header, outputs, inputs, fields, preview.
enum NodeLayout {
    static let width: CGFloat = 220
    static let header: CGFloat = 28
    static let row: CGFloat = 24
    static let textureField: CGFloat = 64
    static let preview: CGFloat = 80
    static let padding: CGFloat = 6
    static let portRadius: CGFloat = 6

    static func fieldHeight(_ field: Field) -> CGFloat {
        if case .texture = field { return textureField }
        return row
    }

    static func showsPreview(_ kind: NodeKind) -> Bool {
        kind != .surfaceOutput && kind != .imageTexture && kind != .color && kind != .value
    }

    static func height(of node: GraphNode) -> CGFloat {
        let kind = node.kind
        return header
            + CGFloat(kind.outputs.count + kind.inputs.count) * row
            + kind.fields.reduce(0) { $0 + fieldHeight($1) }
            + (showsPreview(kind) ? preview : 0)
            + padding * 2
    }

    static func outputPoint(_ node: GraphNode, _ port: Int) -> CGPoint {
        CGPoint(x: node.position.x + width,
                y: node.position.y + header + padding + CGFloat(port) * row + row / 2)
    }

    static func inputPoint(_ node: GraphNode, _ port: Int) -> CGPoint {
        CGPoint(x: node.position.x,
                y: node.position.y + header + padding + CGFloat(node.kind.outputs.count + port) * row + row / 2)
    }
}
