import SceneKit
import SwiftUI

/// Edits the selected object: name, visibility, isolation, transform, and its materials.
struct ObjectInspector: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if let node = model.selectedNode, let document = model.selectedDocument {
            // Re-read when the hierarchy changes (undo/redo of renames, visibility…).
            let _ = document.sceneRevision
            ObjectDetails(node: node, document: document)
                .id(ObjectIdentifier(node))
        } else {
            VStack(spacing: 8) {
                Image(systemName: "cube.transparent").font(.largeTitle).foregroundStyle(.tertiary)
                Text("No Object Selected").font(.headline)
                Text("Click a part in the viewport, or pick one in the sidebar's Scene tab.")
                    .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 30)
        }
    }
}

private struct ObjectDetails: View {
    @Environment(AppModel.self) private var model
    let node: SCNNode
    let document: ModelDocument
    @State private var name = ""

    var body: some View {
        let meshes = ModelDocument.geometryNodes(in: node)
        let entries = meshes.flatMap { document.entries(for: $0) }.reduce(into: [MaterialEntry]()) { list, entry in
            if !list.contains(where: { $0 === entry }) { list.append(entry) }
        }

        InspectorSection(title: "Object") {
            TextField("Name", text: $name)
                .textFieldStyle(.roundedBorder)
                .onSubmit { model.rename(node, to: name) }
                .onChange(of: name) { _, value in model.rename(node, to: value) }
            LabeledContent("Type", value: node.geometry != nil ? "Mesh" : "Group of \(meshes.count) mesh\(meshes.count == 1 ? "" : "es")")
            HStack {
                Toggle("Visible", isOn: Binding(get: { !node.isHidden }, set: { model.setHidden(node, !$0) }))
                    .help("Hidden objects are exported as invisible.")
                Spacer()
                Button(model.isolatedNode === node ? "Show All" : "Isolate") { model.toggleIsolation(node) }
                    .help("Show only this object in the viewer (doesn't affect export).")
                Button("Delete", role: .destructive) { model.delete(node) }
            }
        }

        InspectorSection(title: "Transform") {
            VectorField(title: "Position", value: node.simdPosition, step: 0.01) {
                model.setTransform(node, position: $0)
            }
            VectorField(title: "Rotation", value: node.simdEulerAngles * (180 / .pi), step: 1, suffix: "°") {
                model.setTransform(node, rotationDegrees: $0)
            }
            VectorField(title: "Scale", value: node.simdScale, step: 0.01) {
                model.setTransform(node, scale: $0)
            }
            Text("In the model's own units. Drag a field's label to scrub.")
                .font(.caption2).foregroundStyle(.tertiary)
        }

        InspectorSection(title: "Materials") {
            if entries.isEmpty {
                Text("No materials").foregroundStyle(.secondary)
            }
            ForEach(entries) { entry in
                let sharedElsewhere = entry.materials.contains { material in
                    ModelDocument.geometryNodes(in: document.root).contains { mesh in
                        !meshes.contains(mesh) && (mesh.geometry?.materials ?? []).contains { $0 === material }
                    }
                }
                HStack(spacing: 8) {
                    Group {
                        if let swatch = entry.swatch { Image(decorative: swatch, scale: 1).resizable() } else { Color.gray }
                    }
                    .frame(width: 22, height: 22)
                    .clipShape(Circle())
                    VStack(alignment: .leading, spacing: 1) {
                        Text(entry.name).lineLimit(1)
                        if sharedElsewhere {
                            Text("Shared with other objects").font(.caption2).foregroundStyle(.orange)
                        }
                    }
                    Spacer()
                    Button("Edit") {
                        model.selectedMaterialID = entry.id
                    }
                    .controlSize(.small)
                }
            }
            Button {
                model.makeMaterialsUnique(for: node)
            } label: {
                Label("Give This Object Its Own Materials", systemImage: "square.on.square.dashed")
            }
            .help("Copies this object's materials so editing them, or applying a library material, changes only this object.")
            Text("Tip: with an object selected, the material library's Apply button applies to that object only.")
                .font(.caption2).foregroundStyle(.tertiary)
        }
        .onAppear { name = node.name ?? "" }
    }
}

/// Three number fields (X, Y, Z) whose labels can be dragged to scrub the value.
private struct VectorField: View {
    let title: String
    let value: SIMD3<Float>
    let step: Float
    var suffix = ""
    var onChange: (SIMD3<Float>) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            HStack(spacing: 4) {
                ForEach(0..<3, id: \.self) { axis in
                    AxisField(label: ["X", "Y", "Z"][axis], tint: [Color.red, .green, .blue][axis],
                              value: value[axis], step: step) { newValue in
                        var v = value
                        v[axis] = newValue
                        onChange(v)
                    }
                }
            }
        }
    }
}

private struct AxisField: View {
    let label: String
    let tint: Color
    let value: Float
    let step: Float
    var onChange: (Float) -> Void
    @State private var dragStart: Float?

    var body: some View {
        HStack(spacing: 2) {
            Text(label)
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(tint)
                .frame(width: 12)
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 1).onChanged { drag in
                    if dragStart == nil { dragStart = value }
                    onChange(dragStart! + Float(drag.translation.width) * step)
                }.onEnded { _ in dragStart = nil })
                .onHover { inside in if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() } }
            TextField(label, value: Binding(get: { Double(value) }, set: { onChange(Float($0)) }),
                      format: .number.precision(.fractionLength(0...3)))
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 11).monospacedDigit())
                .controlSize(.small)
        }
    }
}
