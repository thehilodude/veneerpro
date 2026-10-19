import SceneKit
import SwiftUI

/// The object hierarchy of the selected model, like KeyShot's Scene tree.
struct SceneOutline: View {
    @Environment(AppModel.self) private var model
    @State private var search = ""

    struct Item: Identifiable {
        let id: ObjectIdentifier
        let node: SCNNode
        let name: String
        let isMesh: Bool
        let isHidden: Bool
        var children: [Item]?
    }

    var body: some View {
        if let document = model.selectedDocument {
            let items = Self.items(for: document, revision: document.sceneRevision, filter: search)
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

                List(selection: Binding(
                    get: { model.selectedNode.map(ObjectIdentifier.init) },
                    set: { id in model.select(id.flatMap { Self.find($0, in: items) }, showInspector: true) }
                )) {
                    OutlineGroup(items, children: \.children) { item in
                        row(item)
                            .tag(item.id)
                            .contextMenu { menu(item.node) }
                    }
                }
                .listStyle(.sidebar)
                .onDeleteCommand { if let node = model.selectedNode { model.delete(node) } }
            }
        } else {
            Text("Import a model to see its objects").foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func row(_ item: Item) -> some View {
        let isolated = model.isolatedNode === item.node
        return HStack(spacing: 6) {
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
    }

    @ViewBuilder
    private func menu(_ node: SCNNode) -> some View {
        Button(model.isolatedNode === node ? "Show All" : "Isolate") { model.toggleIsolation(node) }
        Button(node.isHidden ? "Show" : "Hide") { model.setHidden(node, !node.isHidden) }
        Button("Give This Object Its Own Materials") { model.makeMaterialsUnique(for: node) }
        Divider()
        Button("Delete", role: .destructive) { model.delete(node) }
    }

    // MARK: Tree

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

    static func find(_ id: ObjectIdentifier, in items: [Item]) -> SCNNode? {
        for item in items {
            if item.id == id { return item.node }
            if let found = find(id, in: item.children ?? []) { return found }
        }
        return nil
    }
}
