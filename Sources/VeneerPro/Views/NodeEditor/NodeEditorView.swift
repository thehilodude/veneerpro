import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Node-based material editor: drag from an output port to an input port to connect,
/// drag a connected input away to disconnect, drag the background to pan, pinch or ⌘-scroll to zoom.
struct NodeEditorView: View {
    static let space = "nodeGraph"

    let entry: MaterialEntry
    private var graph: MaterialGraph { entry.graph }
    @Environment(AppModel.self) private var model

    @State private var pan = CGSize(width: 20, height: 20)
    @State private var panStart: CGSize?
    @State private var zoom: CGFloat = 0.9
    @State private var zoomStart: CGFloat?
    @State private var selection: UUID?
    @State private var nodeDrag: (id: UUID, origin: CGPoint, start: CGPoint)?
    @State private var pending: PendingLink?
    @State private var viewSize: CGSize = .zero
    /// Keep re-framing on resize until the user pans or zooms.
    @State private var userAdjusted = false
    @FocusState private var focused: Bool

    private struct PendingLink {
        /// The fixed end of the wire being dragged.
        var anchor: PortRef
        var anchorSide: PortSide
        var type: SocketType
        var current: CGPoint
    }

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                background
                wires.allowsHitTesting(false)
                nodesLayer
                ScrollWheelCatcher { delta, zoomModifier, location in
                    userAdjusted = true
                    if zoomModifier {
                        setZoom(zoom * (1 + delta.height / 200), around: location)
                    } else {
                        pan.width += delta.width
                        pan.height += delta.height
                    }
                }
                .allowsHitTesting(false)
            }
            .clipped()
            .overlay(alignment: .topLeading) { toolbar }
            .overlay(alignment: .bottomLeading) { hint }
            .onAppear { viewSize = geo.size; fit() }
            .onChange(of: geo.size) { _, size in
                viewSize = size
                if !userAdjusted { fit() }
            }
            .onChange(of: entry.id) { _, _ in selection = nil; fit() }
            .onChange(of: ObjectIdentifier(entry.graph)) { _, _ in
                // A library material (or reset) swapped the graph: frame the new nodes.
                selection = nil
                userAdjusted = false
                fit()
            }
            .onDrop(of: [.fileURL, .plainText, .utf8PlainText], isTargeted: nil) { providers, location in
                drop(providers, at: location)
            }
        }
        .background(Color(white: 0.11))
        .environment(\.colorScheme, .dark)
        .focusable()
        .focusEffectDisabled()
        .focused($focused)
        .onDeleteCommand { deleteSelection() }
    }

    // MARK: Layers

    private var background: some View {
        Canvas { context, size in
            // Dot grid that follows pan and zoom.
            let spacing = 24 * zoom
            guard spacing > 4 else { return }
            let startX = pan.width.truncatingRemainder(dividingBy: spacing)
            let startY = pan.height.truncatingRemainder(dividingBy: spacing)
            var path = Path()
            var x = startX
            while x < size.width {
                var y = startY
                while y < size.height {
                    path.addEllipse(in: CGRect(x: x - 1, y: y - 1, width: 2, height: 2))
                    y += spacing
                }
                x += spacing
            }
            context.fill(path, with: .color(.white.opacity(0.08)))
        }
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 2)
                .onChanged { drag in
                    userAdjusted = true
                    if panStart == nil { panStart = pan }
                    pan = CGSize(width: panStart!.width + drag.translation.width,
                                 height: panStart!.height + drag.translation.height)
                }
                .onEnded { _ in panStart = nil }
        )
        .simultaneousGesture(
            MagnifyGesture()
                .onChanged { value in
                    userAdjusted = true
                    if zoomStart == nil { zoomStart = zoom }
                    setZoom(zoomStart! * value.magnification, around: value.startLocation)
                }
                .onEnded { _ in zoomStart = nil }
        )
        .onTapGesture {
            selection = nil
            focused = true
        }
        .contextMenu { addNodeMenuItems() }
    }

    private var wires: some View {
        Canvas { context, _ in
            let nodes = Dictionary(uniqueKeysWithValues: graph.nodes.map { ($0.id, $0) })
            for link in graph.links {
                guard let from = nodes[link.from.node], let to = nodes[link.to.node],
                      link.from.port < from.kind.outputs.count else { continue }
                let type = from.kind.outputs[link.from.port].type
                let a = viewPoint(NodeLayout.outputPoint(from, link.from.port))
                let b = viewPoint(NodeLayout.inputPoint(to, link.to.port))
                let highlighted = selection == from.id || selection == to.id
                drawWire(&context, a, b, color: type.tint.opacity(highlighted ? 1 : 0.75), width: highlighted ? 3 : 2)
            }
            if let pending, let anchorNode = nodes[pending.anchor.node] {
                let anchor = pending.anchorSide == .output
                    ? NodeLayout.outputPoint(anchorNode, pending.anchor.port)
                    : NodeLayout.inputPoint(anchorNode, pending.anchor.port)
                let a = viewPoint(anchor), b = viewPoint(pending.current)
                if pending.anchorSide == .output {
                    drawWire(&context, a, b, color: pending.type.tint, width: 2, dashed: true)
                } else {
                    drawWire(&context, b, a, color: pending.type.tint, width: 2, dashed: true)
                }
            }
        }
    }

    private func drawWire(_ context: inout GraphicsContext, _ a: CGPoint, _ b: CGPoint, color: Color, width: CGFloat, dashed: Bool = false) {
        let dx = max(abs(b.x - a.x) * 0.5, 40 * zoom)
        var path = Path()
        path.move(to: a)
        path.addCurve(to: b, control1: CGPoint(x: a.x + dx, y: a.y), control2: CGPoint(x: b.x - dx, y: b.y))
        context.stroke(path, with: .color(.black.opacity(0.5)), style: StrokeStyle(lineWidth: width + 2, lineCap: .round))
        context.stroke(path, with: .color(color),
                       style: StrokeStyle(lineWidth: width, lineCap: .round, dash: dashed ? [6, 4] : []))
    }

    private var nodesLayer: some View {
        let links = graph.links
        return ZStack(alignment: .topLeading) {
            ForEach(graph.nodes) { node in
                NodeView(
                    node: node,
                    graph: graph,
                    thumbnail: entry.thumbnails[node.id],
                    isSelected: selection == node.id,
                    connectedInputs: Set(links.filter { $0.to.node == node.id }.map(\.to.port)),
                    connectedOutputs: Set(links.filter { $0.from.node == node.id }.map(\.from.port)),
                    onSelect: { select(node.id) },
                    onMove: { location, ended in moveNode(node, location, ended) },
                    onPortDrag: { portDrag(node, $0) }
                )
                .offset(x: node.position.x, y: node.position.y)
                .contextMenu {
                    if node.kind != .surfaceOutput {
                        Button("Duplicate") { graph.duplicateNode(node.id) }
                        Button("Disconnect Inputs") {
                            for i in node.kind.inputs.indices { graph.disconnect(PortRef(node: node.id, port: i)) }
                        }
                        Divider()
                        Button("Delete", role: .destructive) { graph.removeNode(node.id) }
                    } else {
                        Button("Disconnect All Inputs") {
                            for i in node.kind.inputs.indices { graph.disconnect(PortRef(node: node.id, port: i)) }
                        }
                    }
                }
            }
        }
        .frame(width: 0, height: 0, alignment: .topLeading)
        .coordinateSpace(name: Self.space)
        .scaleEffect(zoom, anchor: .topLeading)
        .offset(pan)
    }

    // MARK: Overlays

    private var toolbar: some View {
        HStack(spacing: 8) {
            Menu {
                addNodeMenuItems()
            } label: {
                Label("Add Node", systemImage: "plus")
            }
            .menuStyle(.button)
            .fixedSize()

            Divider().frame(height: 16)
            Button { setZoom(zoom / 1.2, around: center) } label: { Image(systemName: "minus.magnifyingglass") }
                .help("Zoom Out")
            Text("\(Int(zoom * 100))%").appFont(11, monospacedDigits: true).frame(width: 40)
            Button { setZoom(zoom * 1.2, around: center) } label: { Image(systemName: "plus.magnifyingglass") }
                .help("Zoom In")
            Button { fit() } label: { Image(systemName: "arrow.up.left.and.down.right.magnifyingglass") }
                .help("Frame All Nodes")
            Button { graph.autoLayout(); fit() } label: { Image(systemName: "rectangle.3.group") }
                .help("Arrange Nodes")
        }
        .buttonStyle(.borderless)
        .controlSize(.small)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
        .padding(10)
    }

    private var hint: some View {
        Text("Drag ports to connect · drag background or scroll to pan · ⌘-scroll or pinch to zoom · drop images to add textures")
            .appFont(10)
            .foregroundStyle(.secondary)
            .padding(8)
    }

    @ViewBuilder
    private func addNodeMenuItems() -> some View {
        ForEach(NodeCategory.allCases, id: \.self) { category in
            Section(category.rawValue) {
                ForEach(NodeKind.allCases.filter { $0.category == category }, id: \.self) { kind in
                    Button(kind.title) { add(kind) }
                }
            }
        }
    }

    // MARK: Actions

    private var center: CGPoint { CGPoint(x: viewSize.width / 2, y: viewSize.height / 2) }

    private func viewPoint(_ p: CGPoint) -> CGPoint {
        CGPoint(x: p.x * zoom + pan.width, y: p.y * zoom + pan.height)
    }

    private func graphPoint(_ p: CGPoint) -> CGPoint {
        CGPoint(x: (p.x - pan.width) / zoom, y: (p.y - pan.height) / zoom)
    }

    private func setZoom(_ newZoom: CGFloat, around point: CGPoint) {
        let clamped = min(2.5, max(0.25, newZoom))
        let anchor = graphPoint(point)
        zoom = clamped
        pan = CGSize(width: point.x - anchor.x * clamped, height: point.y - anchor.y * clamped)
    }

    private func fit() {
        guard !graph.nodes.isEmpty, viewSize.width > 0 else { return }
        let rects = graph.nodes.map { CGRect(origin: $0.position, size: CGSize(width: NodeLayout.width, height: NodeLayout.height(of: $0))) }
        let bounds = rects.dropFirst().reduce(rects[0]) { $0.union($1) }.insetBy(dx: -40, dy: -50)
        let z = min(1.1, max(0.25, min(viewSize.width / bounds.width, viewSize.height / bounds.height)))
        zoom = z
        pan = CGSize(width: (viewSize.width - bounds.width * z) / 2 - bounds.minX * z,
                     height: (viewSize.height - bounds.height * z) / 2 - bounds.minY * z + 12)
    }

    private func add(_ kind: NodeKind) {
        var point = graphPoint(CGPoint(x: center.x - NodeLayout.width / 2 * zoom, y: center.y - 60 * zoom))
        // Nudge so repeated adds don't stack exactly.
        while graph.nodes.contains(where: { abs($0.position.x - point.x) < 4 && abs($0.position.y - point.y) < 4 }) {
            point.x += 24
            point.y += 24
        }
        selection = graph.addNode(kind, at: point)
    }

    /// Image files become texture nodes; a library material replaces the whole graph.
    private func drop(_ providers: [NSItemProvider], at location: CGPoint) -> Bool {
        let fileProviders = providers.filter { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }
        guard !fileProviders.isEmpty else {
            return model.libraryMaterial(fromDrop: providers) { material in
                model.apply(material, to: entry)
                userAdjusted = false
            }
        }
        let start = graphPoint(location)
        for (i, provider) in fileProviders.enumerated() {
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url, let texture = TextureRef.load(url: url, maxPixelSize: 4096) else { return }
                Task { @MainActor in
                    selection = graph.addNode(.imageTexture, at: CGPoint(x: start.x, y: start.y + CGFloat(i) * 160), texture: texture)
                }
            }
        }
        return true
    }

    private func select(_ id: UUID) {
        selection = id
        focused = true
    }

    private func deleteSelection() {
        guard let selection else { return }
        graph.removeNode(selection)
        self.selection = nil
    }

    private func moveNode(_ node: GraphNode, _ location: CGPoint, _ ended: Bool) {
        if nodeDrag?.id != node.id {
            nodeDrag = (node.id, node.position, location)
            select(node.id)
        }
        guard let drag = nodeDrag else { return }
        graph.move(node.id, to: CGPoint(x: drag.origin.x + location.x - drag.start.x,
                                        y: drag.origin.y + location.y - drag.start.y))
        if ended { nodeDrag = nil }
    }

    private func portDrag(_ node: GraphNode, _ event: PortDragEvent) {
        if pending == nil {
            switch event.side {
            case .output:
                pending = PendingLink(anchor: PortRef(node: node.id, port: event.port), anchorSide: .output,
                                      type: node.kind.outputs[event.port].type, current: event.location)
            case .input:
                let input = PortRef(node: node.id, port: event.port)
                if let existing = graph.link(into: input), let source = graph.node(existing.from.node) {
                    // Pick up the existing wire by its input end.
                    graph.disconnect(input)
                    pending = PendingLink(anchor: existing.from, anchorSide: .output,
                                          type: source.kind.outputs[existing.from.port].type, current: event.location)
                } else {
                    pending = PendingLink(anchor: input, anchorSide: .input,
                                          type: node.kind.inputs[event.port].type, current: event.location)
                }
            }
        }
        pending?.current = event.location
        guard event.ended, let link = pending else { return }
        pending = nil
        let reach: CGFloat = 16
        func distance(_ a: CGPoint, _ b: CGPoint) -> CGFloat { hypot(a.x - b.x, a.y - b.y) }

        if link.anchorSide == .output {
            let target = graph.nodes.lazy.flatMap { n in
                n.kind.inputs.indices.map { (PortRef(node: n.id, port: $0), NodeLayout.inputPoint(n, $0)) }
            }.filter { distance($0.1, event.location) < reach }.min { distance($0.1, event.location) < distance($1.1, event.location) }
            if let target { graph.connect(link.anchor, target.0) }
        } else {
            let target = graph.nodes.lazy.flatMap { n in
                n.kind.outputs.indices.map { (PortRef(node: n.id, port: $0), NodeLayout.outputPoint(n, $0)) }
            }.filter { distance($0.1, event.location) < reach }.min { distance($0.1, event.location) < distance($1.1, event.location) }
            if let target { graph.connect(target.0, link.anchor) }
        }
    }
}

/// Forwards trackpad / mouse-wheel scrolling over the editor without intercepting clicks.
private struct ScrollWheelCatcher: NSViewRepresentable {
    var onScroll: (_ delta: CGSize, _ zoomModifier: Bool, _ location: CGPoint) -> Void

    func makeNSView(context: Context) -> CatcherView {
        let view = CatcherView()
        view.onScroll = onScroll
        return view
    }

    func updateNSView(_ view: CatcherView, context: Context) {
        view.onScroll = onScroll
    }

    final class CatcherView: NSView {
        var onScroll: ((CGSize, Bool, CGPoint) -> Void)?
        private var monitor: Any?

        override var isFlipped: Bool { true }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                guard let self, event.window === self.window else { return event }
                let point = self.convert(event.locationInWindow, from: nil)
                guard self.bounds.contains(point) else { return event }
                let zoom = event.modifierFlags.contains(.command) || event.modifierFlags.contains(.option)
                let scale: CGFloat = event.hasPreciseScrollingDeltas ? 1 : 8
                self.onScroll?(CGSize(width: event.scrollingDeltaX * scale, height: event.scrollingDeltaY * scale), zoom, point)
                return nil
            }
        }

        deinit {
            if let monitor { NSEvent.removeMonitor(monitor) }
        }
    }
}
