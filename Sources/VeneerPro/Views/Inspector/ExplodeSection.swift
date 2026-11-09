import SwiftUI

/// The Object tab's automatic exploded view: a slider from assembled to exploded, plus direction,
/// spacing and saving the result as a pose (which exports as an AR Quick Look variant).
struct ExplodeSection: View {
    @Environment(AppModel.self) private var model
    let document: ModelDocument

    var body: some View {
        let state = document.explode
        InspectorSection(title: "Exploded View") {
            HStack(spacing: 8) {
                Image(systemName: "square.stack.3d.down.right").foregroundStyle(.secondary)
                Slider(value: Binding(get: { Double(state.amount) }, set: { model.setExplode(Float($0), live: true) }), in: 0...1) { editing in
                    if !editing { model.finishExplodeDrag() }
                }
                Text("\(Int((state.amount * 100).rounded()))%")
                    .appFont(11, monospacedDigits: true).foregroundStyle(.secondary)
                    .frame(width: 36, alignment: .trailing)
            }
            .help("Pull the parts apart along the directions they'd come off in disassembly")

            LabeledContent("Order") {
                Picker("Order", selection: Binding(get: { state.order }, set: { model.updateExplodeSettings(order: $0) })) {
                    ForEach(ExplodePlan.Order.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
            .help("Automatic: parts come off in a sensible disassembly order. Scene List: the top row of the Scene list comes off first and ends up outermost; the last row stays put")
            if state.order == .sceneList {
                Text("The top of the Scene list comes off first. Drag rows in the Scene tab to change the order; the view updates as you go.")
                    .appFont(10).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            LabeledContent("Direction") {
                Picker("Direction", selection: Binding(get: { state.axis }, set: { model.updateExplodeSettings(axis: $0) })) {
                    ForEach(ExplodePlan.Axis.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
            .help("Auto: stacked parts go up and down, side-by-side parts split apart, overhanging parts move out the way they stick out. X, Y or Z sends every part along that axis where it can come out that way")

            LabeledContent("Spacing") {
                Slider(value: Binding(get: { Double(state.spacing) }, set: { model.updateExplodeSettings(spacing: Float($0), live: true) }), in: 0.3...3) { editing in
                    if !editing { model.finishExplodeDrag() }
                }
            }
            Toggle("Spread parts inside groups", isOn: Binding(get: { state.nested }, set: { model.updateExplodeSettings(nested: $0) }))
                .help("Off: groups move as single blocks")

            HStack {
                Button("Collapse") { model.setExplode(0) }
                    .disabled(state.amount == 0)
                Spacer()
                Button("Save as Pose") { model.saveExplodedPose() }
                    .disabled(state.amount == 0)
                    .help("Save this arrangement as an “Exploded” pose; poses export as a picker in AR Quick Look")
            }
            .controlSize(.small)

            Text("\(UIWords.rightClick) a part in the Scene list ▸ Explode Direction to pin which way it comes out. Gumball nudges are kept when you change the amount.")
                .appFont(10).foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
