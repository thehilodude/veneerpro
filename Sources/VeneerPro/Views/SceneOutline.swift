import SceneKit
import SwiftUI
import UniformTypeIdentifiers

/// The object hierarchy of the selected model, like KeyShot's Scene tree. Selection follows the
/// viewport (parents open and the row scrolls into view), ⌘/⇧-click selects several objects, and rows
/// can be dragged onto a group (into it) or onto an object (just above it).
struct SceneOutline: View {
    @Environment(AppModel.self) private var model
    @State private var search = ""
    /// Groups the user has opened (and ones opened to reveal a selection).
    @State private var expanded: Set<ObjectIdentifier> = []
    @State private var dropTarget: ObjectIdentifier?

    struct Item: Identifiable {
        let id: ObjectIdentifier
        let node: SCNNode
        let name: String
        let isMesh: Bool
        let isHidden: Bool
        var children: [Item]?
    }

    /// One visible row of the flattened tree.
    private struct Row: Identifiable {
        let item: Item
        let depth: Int
        var id: ObjectIdentifier { item.id }
    }

    var body: some View {
        if let document = model.selectedDocument {
            let items = Self.items(for: document, revision: document.sceneRevision, filter: search)
            let rows = flatten(items, depth: 0)
            let byID = Dictionary(uniqueKeysWithValues: Self.allItems(items).map { ($0.id, $0.node) })
            VStack(spacing: 0) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Filter objects", text: $search).textFieldStyle(.plain)
                    if model.isolatedNode != nil {
                        Button("Show All") { model.isolatedNode = nil }
                            .controlSize(.small)
                    }
                }
                .padding(.horizontal, 8).padding(.vertical, 5)
                .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 7))
                .padding(.horizontal, 10).padding(.bottom, 6)

                ScrollViewReader { proxy in
                    List(selection: Binding(
                        get: { Set(model.selectedNodes.map(ObjectIdentifier.init)) },
                        set: { ids in
                            // Keep the existing order, adding newly picked rows at the end (the primary).
                            let kept = model.selectedNodes.filter { ids.contains(ObjectIdentifier($0)) }
                            let added = ids.subtracting(kept.map(ObjectIdentifier.init)).compactMap { byID[$0] }
                            let nodes = kept + added
                            if nodes.count == 1 { model.select(nodes[0], showInspector: true) } else { model.selectedNodes = nodes }
                        }
                    )) {
                        ForEach(rows) { row in
                            rowView(row)
                                .tag(row.id)
                                .id(row.id)
                                .contextMenu { menu(row.item.node) }
                                .draggable(DraggedObjects(ids: dragIDs(for: row.item.node)))
                                .dropDestination(for: DraggedObjects.self) { dropped, _ in
                                    drop(dropped.flatMap(\.ids), on: row.item, nodes: byID)
                                } isTargeted: { inside in
                                    if inside { dropTarget = row.id } else if dropTarget == row.id { dropTarget = nil }
                                }
                        }
                    }
                    .listStyle(.sidebar)
                    .onDeleteCommand { model.deleteSelection() }
                    .onChange(of: model.selectedNode.map(ObjectIdentifier.init)) { _, id in
                        guard let node = model.selectedNode, let id else { return }
                        reveal(node, in: document)
                        withAnimation { proxy.scrollTo(id) }
                    }
                }
            }
        } else {
            Text("Import a model to see its objects").foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func rowView(_ row: Row) -> some View {
        let item = row.item
        let isolated = model.isolatedNode === item.node
        let isOpen = expanded.contains(item.id) || !search.isEmpty
        return HStack(spacing: 4) {
            Color.clear.frame(width: CGFloat(row.depth) * 14, height: 1)
            if item.children != nil {
                Button {
                    if expanded.contains(item.id) { expanded.remove(item.id) } else { expanded.insert(item.id) }
                } label: {
                    Image(systemName: "chevron.right")
                        .appFont(9, weight: .bold)
                        .rotationEffect(.degrees(isOpen ? 90 : 0))
                        .frame(width: 12)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            } else {
                Color.clear.frame(width: 12, height: 1)
            }
            Image(systemName: item.isMesh ? "cube" : "folder")
                .foregroundStyle(item.isMesh ? Color.accentColor : .secondary)
                .frame(width: 16)
            Text(item.name)
                .lineLimit(1)
                .foregroundStyle(item.isHidden ? .tertiary : .primary)
            Spacer(minLength: 4)
            Button { model.toggleIsolation(item.node) } label: {
                Image(systemName: isolated ? "scope" : "circle.dashed")
            }
            .buttonStyle(.borderless)
            .foregroundStyle(isolated ? Color.accentColor : .secondary)
            .opacity(isolated ? 1 : 0.55)
            .help(isolated ? "Show all objects" : "Isolate: show only this object")
            Button { model.setHidden(item.node, !item.isHidden) } label: {
                Image(systemName: item.isHidden ? "eye.slash" : "eye")
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .help(item.isHidden ? "Show" : "Hide (exported as invisible)")
        }
        .overlay(alignment: item.isMesh ? .top : .center) {
            // Where a drop will land: into a group, or above an object.
            if dropTarget == item.id {
                if item.isMesh {
                    Rectangle().fill(Color.accentColor).frame(height: 2).offset(y: -3)
                } else {
                    RoundedRectangle(cornerRadius: 5).strokeBorder(Color.accentColor, lineWidth: 2).padding(-2)
                }
            }
        }
    }

    @ViewBuilder
    private func menu(_ node: SCNNode) -> some View {
        let selection = model.selectedNodes.contains { $0 === node } ? model.selectedNodes : [node]
        if selection.count > 1 {
            Button("Group \(selection.count) Objects") { model.selectedNodes = selection; model.groupSelection() }
            Divider()
            Button("Delete \(selection.count) Objects", role: .destructive) { model.selectedNodes = selection; model.deleteSelection() }
        } else {
            Button(model.isolatedNode === node ? "Show All" : "Isolate") { model.toggleIsolation(node) }
            Button(node.isHidden ? "Show" : "Hide") { model.setHidden(node, !node.isHidden) }
            Button("Give This Object Its Own Materials") { model.makeMaterialsUnique(for: node) }
            Divider()
            Button("Group") { model.selectedNodes = [node]; model.groupSelection() }
            if node.geometry == nil, !node.childNodes.isEmpty { Button("Ungroup") { model.ungroup(node) } }
            Button("Move Up") { model.reorder(node, by: -1) }
            Button("Move Down") { model.reorder(node, by: 1) }
            if node.parent !== model.selectedDocument?.root {
                Button("Move Out of Group") { model.moveOutOfGroup(node) }
                Button("Select Parent Group") { if let parent = node.parent { model.select(parent, showInspector: true) } }
            }
            Divider()
            Button("Delete", role: .destructive) { model.delete(node) }
        }
    }

    // MARK: Drag and drop

    /// Dragging a selected row drags the whole selection.
    private func dragIDs(for node: SCNNode) -> [String] {
        let nodes = model.selectedNodes.contains { $0 === node } ? model.selectedNodes : [node]
        return nodes.map { Self.key(ObjectIdentifier($0)) }
    }

    private func drop(_ keys: [String], on target: Item, nodes byID: [ObjectIdentifier: SCNNode]) -> Bool {
        dropTarget = nil
        let lookup = Dictionary(uniqueKeysWithValues: byID.map { (Self.key($0.key), $0.value) })
        let nodes = keys.compactMap { lookup[$0] }
        guard !nodes.isEmpty, !nodes.contains(where: { $0 === target.node }) else { return false }
        if target.isMesh {
            guard let parent = target.node.parent, let index = parent.childNodes.firstIndex(of: target.node) else { return false }
            model.move(nodes, into: parent, at: index)
        } else {
            model.move(nodes, into: target.node, at: target.node.childNodes.count)
            expanded.insert(target.id)
        }
        return true
    }

    private static func key(_ id: ObjectIdentifier) -> String { String(UInt(bitPattern: id.hashValue)) }

    // MARK: Tree

    /// Opens every group above `node` so its row is visible.
    private func reveal(_ node: SCNNode, in document: ModelDocument) {
        var current = node.parent
        while let parent = current, parent !== document.root {
            expanded.insert(ObjectIdentifier(parent))
            current = parent.parent
        }
    }

    private func flatten(_ items: [Item], depth: Int) -> [Row] {
        items.flatMap { item -> [Row] in
            let open = expanded.contains(item.id) || !search.isEmpty
            return [Row(item: item, depth: depth)] + (open ? flatten(item.children ?? [], depth: depth + 1) : [])
        }
    }

    private static func allItems(_ items: [Item]) -> [Item] {
        items.flatMap { [$0] + allItems($0.children ?? []) }
    }

    static func items(for document: ModelDocument, revision: Int, filter: String) -> [Item] {
        func build(_ node: SCNNode) -> Item? {
            let children = node.childNodes.compactMap(build)
            let name = AppModel.displayName(node)
            let matches = filter.isEmpty || name.localizedCaseInsensitiveContains(filter)
            guard matches || !children.isEmpty else { return nil }
            return Item(id: ObjectIdentifier(node), node: node, name: name, isMesh: node.geometry != nil,
                        isHidden: node.isHidden, children: children.isEmpty ? nil : children)
        }
        return document.root.childNodes.compactMap(build)
    }
}

/// Outline rows being dragged, identified within this window's tree.
struct DraggedObjects: Codable, Transferable {
    var ids: [String]

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .veneerObjects)
    }
}

extension UTType {
    static let veneerObjects = UTType(exportedAs: "com.thehilodude.veneerpro.objects")
}
