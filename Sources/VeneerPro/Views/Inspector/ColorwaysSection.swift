import SwiftUI

/// The Materials tab's list of saved colorways: click one to apply it.
struct ColorwaysSection: View {
    @Environment(AppModel.self) private var model
    let document: ModelDocument

    var body: some View {
        InspectorSection(title: "Colorways") {
            if document.colorways.isEmpty {
                Text("Save the current materials as a colorway, then try other looks and switch between them.")
                    .appFont(10).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Save Current Look") { model.saveColorway() }
                    .controlSize(.small)
            } else {
                ForEach(document.colorways) { colorway in
                    ColorwayRow(colorway: colorway, document: document)
                }
                if document.colorwayIsModified, let active = document.activeColorway {
                    HStack(spacing: 6) {
                        Text("“\(active.name)” has unsaved changes")
                            .appFont(10).foregroundStyle(.secondary)
                            .lineLimit(1)
                        Spacer()
                        Button("Update") { model.updateColorway(active) }
                        Button("Save as New") { model.saveColorway() }
                    }
                    .controlSize(.small)
                }
            }
        } accessory: {
            Button { model.saveColorway() } label: { Image(systemName: "plus") }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Save the current materials as a new colorway")
        }
    }
}

private struct ColorwayRow: View {
    @Environment(AppModel.self) private var model
    let colorway: Colorway
    let document: ModelDocument
    @State private var renaming = false
    @State private var draft = ""
    @FocusState private var nameFocused: Bool

    private var isActive: Bool { document.activeColorwayID == colorway.id }

    var body: some View {
        HStack(spacing: 8) {
            SwatchStrip(swatches: colorway.swatches)
            if renaming {
                TextField("Name", text: $draft)
                    .textFieldStyle(.roundedBorder)
                    .focused($nameFocused)
                    .onSubmit(commitRename)
                    .onEscapeKey { renaming = false }
                    .onChange(of: nameFocused) { _, focused in if !focused { commitRename() } }
            } else {
                Text(colorway.name).lineLimit(1).appFont(12.5)
                if isActive, document.colorwayIsModified {
                    Text("Modified")
                        .appFont(10, weight: .medium)
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(Capsule().fill(Color.white.opacity(0.18)))
                }
            }
            Spacer(minLength: 0)
            if isActive, !renaming {
                Image(systemName: "checkmark").appFont(10, weight: .bold)
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: Theme.corner).fill(isActive ? Color.accentColor.opacity(0.85) : .clear))
        .foregroundStyle(isActive ? Color.white : .primary)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { startRename() }
        .onTapGesture { if !renaming { model.applyColorway(colorway) } }
        .contextMenu {
            Button("Apply") { model.applyColorway(colorway) }
            Button("Update with Current Materials") { model.updateColorway(colorway) }
            Divider()
            Button("Rename…") { startRename() }
            Button("Duplicate") { model.duplicateColorway(colorway) }
            Button("Compare Side by Side") { model.compareColorway(colorway) }
            Divider()
            Button("Delete", role: .destructive) { model.deleteColorway(colorway) }
        }
        .help(isActive ? "The current colorway" : "Click to apply “\(colorway.name)”")
    }

    private func startRename() {
        draft = colorway.name
        renaming = true
        nameFocused = true
    }

    private func commitRename() {
        guard renaming else { return }
        model.renameColorway(colorway, to: draft)
        renaming = false
    }
}

/// Overlapping material swatches, like paint chips fanned out.
struct SwatchStrip: View {
    let swatches: [CGImage]
    var size: CGFloat = 20
    var limit = 5

    var body: some View {
        HStack(spacing: -size * 0.35) {
            ForEach(Array(swatches.prefix(limit).enumerated()), id: \.offset) { _, swatch in
                Image(decorative: swatch, scale: 1).resizable()
                    .frame(width: size, height: size)
                    .clipShape(Circle())
                    .overlay(Circle().strokeBorder(Color.black.opacity(0.35), lineWidth: 1))
            }
            if swatches.isEmpty {
                Circle().fill(Color.gray).frame(width: size, height: size)
            }
        }
        .frame(width: size + (size * 0.65) * CGFloat(max(0, min(limit, swatches.count) - 1)), alignment: .leading)
    }
}
