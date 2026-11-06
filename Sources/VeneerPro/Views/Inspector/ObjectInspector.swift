import SceneKit
import SwiftUI

/// Edits the selected object: name, visibility, isolation, transform, and its materials.
struct ObjectInspector: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if let document = model.selectedDocument { PosesSection(document: document) }
        if model.selectedNodes.count > 1, let document = model.selectedDocument {
            let _ = document.sceneRevision
            InspectorSection(title: "\(model.selectedNodes.count) Objects Selected") {
                ForEach(model.selectedNodes, id: \.self) { node in
                    Label(AppModel.displayName(node), systemImage: node.geometry != nil ? "cube" : "folder")
                        .lineLimit(1)
                }
                HStack {
                    Button("Group") { model.groupSelection() }
                        .help("Put the selected objects in a new group (⌘G)")
                    Spacer()
                    Button("Delete", role: .destructive) { model.deleteSelection() }
                }
                Text("⌘- or ⇧-click parts in the viewer or rows in the Scene list to add or remove them.")
                    .appFont(10).foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } else if let node = model.selectedNode, let document = model.selectedDocument {
            // Re-read when the hierarchy changes (undo/redo of renames, visibility…).
            let _ = document.sceneRevision
            ObjectDetails(node: node, document: document)
                .id(ObjectIdentifier(node))
        } else {
            VStack(spacing: 8) {
                Image(systemName: "cube.transparent").appFont(26).foregroundStyle(.tertiary)
                Text("No Object Selected").appFont(13, weight: .semibold)
                Text("Click a part in the viewport, or pick one in the sidebar's Scene tab.")
                    .appFont(10).foregroundStyle(.secondary).multilineTextAlignment(.center)
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
                .appFont(10).foregroundStyle(.tertiary)
            VectorField(title: node.customPivot == nil ? "Pivot (center)" : "Pivot", value: node.pivotPoint, step: 0.01) {
                model.setPivot(node, to: $0)
            }
            HStack(spacing: 6) {
                Button("Center") { model.setPivot(node, to: nil) }
                Button("Bottom") { model.setPivotToBottom(node) }
                Button("Origin") { model.setPivot(node, to: .zero) }
                Spacer()
                Toggle("Edit", isOn: Binding(get: { model.gumball.editPivot }, set: { model.gumball.editPivot = $0 }))
                    .toggleStyle(.button)
                    .help("Drag the gumball's arrows to move the pivot instead of the object")
            }
            .controlSize(.small)
        }

        HingeSection(node: node)

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
                            Text("Shared with other objects").appFont(10).foregroundStyle(.orange)
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
                .appFont(10).foregroundStyle(.tertiary)
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
            Text(title).appFont(10).foregroundStyle(.secondary)
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
                .appFont(10, weight: .bold)
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
                .appFont(11, monospacedDigits: true)
                .controlSize(.small)
        }
    }
}

/// Turns an object into a hinged part (lid, door) that swings around its pivot.
private struct HingeSection: View {
    @Environment(AppModel.self) private var model
    let node: SCNNode

    var body: some View {
        InspectorSection(title: "Hinge") {
            if let hinge = node.hinge {
                BarSlider(title: "Angle", value: Binding(
                    get: { hinge.angle },
                    set: { var h = hinge; h.angle = $0; model.setHinge(node, h) }
                ), range: hinge.minAngle...max(hinge.maxAngle, hinge.minAngle + 1), defaultValue: 0,
                          format: { String(format: "%.0f°", $0) })
                HStack(spacing: 8) {
                    limitField("Min", hinge.minAngle) { var h = hinge; h.minAngle = min($0, h.maxAngle - 1); model.setHinge(node, h, name: "Change Hinge Limits") }
                    limitField("Max", hinge.maxAngle) { var h = hinge; h.maxAngle = max($0, h.minAngle + 1); model.setHinge(node, h, name: "Change Hinge Limits") }
                }
                HStack(spacing: 6) {
                    Button("Set Closed Here") {
                        var h = hinge
                        h.restTransform = node.simdTransform
                        h.angle = 0
                        model.setHinge(node, h, name: "Set Hinge Closed Position")
                    }
                    .help("Make the current position 0°")
                    Spacer()
                    Button("Remove", role: .destructive) { model.removeHinge(from: node) }
                }
                .controlSize(.small)
                Text("Swings around the pivot (orange line in the viewer). Move the pivot onto the hinge line first.")
                    .appFont(10).foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("Swing this object around its pivot, like a lid or a door.")
                    .appFont(10).foregroundStyle(.secondary)
                HStack(spacing: 6) {
                    Text("Add Hinge")
                    ForEach(0..<3, id: \.self) { axis in
                        Button(["X", "Y", "Z"][axis]) { model.addHinge(to: node, worldAxis: axis) }
                            .help("Hinge around the world \(["X", "Y", "Z"][axis]) axis through the pivot")
                    }
                }
                .controlSize(.small)
                Text("Set the pivot on the hinge line first (Transform ▸ Pivot, or the gumball's Edit Pivot).")
                    .appFont(10).foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func limitField(_ title: String, _ value: Double, set: @escaping (Double) -> Void) -> some View {
        HStack(spacing: 4) {
            Text(title).appFont(10).foregroundStyle(.secondary)
            TextField(title, value: Binding(get: { value }, set: set), format: .number.precision(.fractionLength(0)))
                .textFieldStyle(.roundedBorder)
                .frame(width: 56)
            Text("°").appFont(10).foregroundStyle(.secondary)
        }
    }
}
