import SwiftUI

/// The Object tab's list of saved poses (e.g. Closed / Open): click one to apply it.
struct PosesSection: View {
    @Environment(AppModel.self) private var model
    let document: ModelDocument

    var body: some View {
        let _ = document.sceneRevision
        InspectorSection(title: "Poses") {
            if document.poses.isEmpty {
                Text("Arrange the model (hinges, gumball, visibility), save it as a pose, then make others like Open and Closed. They export as a Pose picker for AR Quick Look.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Save Current Pose") { model.savePose() }
                    .controlSize(.small)
            } else {
                ForEach(document.poses) { pose in
                    PoseRow(pose: pose, document: document)
                }
                if document.poseIsModified, let active = document.activePose {
                    HStack(spacing: 6) {
                        Text("“\(active.name)” has unsaved changes")
                            .font(.caption).foregroundStyle(.secondary)
                            .lineLimit(1)
                        Spacer()
                        Button("Update") { model.updatePose(active) }
                        Button("Save as New") { model.savePose() }
                    }
                    .controlSize(.small)
                }
            }
        } accessory: {
            Button { model.savePose() } label: { Image(systemName: "plus") }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Save the current arrangement as a new pose")
        }
    }
}

private struct PoseRow: View {
    @Environment(AppModel.self) private var model
    let pose: Pose
    let document: ModelDocument
    @State private var renaming = false
    @State private var draft = ""
    @FocusState private var nameFocused: Bool

    private var isActive: Bool { document.activePoseID == pose.id }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "figure.stand.line.dotted.figure.stand")
                .font(.system(size: 12))
                .frame(width: 20)
            if renaming {
                TextField("Name", text: $draft)
                    .textFieldStyle(.roundedBorder)
                    .focused($nameFocused)
                    .onSubmit(commitRename)
                    .onExitCommand { renaming = false }
                    .onChange(of: nameFocused) { _, focused in if !focused { commitRename() } }
            } else {
                Text(pose.name).lineLimit(1).font(.system(size: 12.5))
                if isActive, document.poseIsModified {
                    Text("Modified")
                        .font(.system(size: 10, weight: .medium))
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(Capsule().fill(Color.white.opacity(0.18)))
                }
            }
            Spacer(minLength: 0)
            if isActive, !renaming { Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)) }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: Theme.corner).fill(isActive ? Color.accentColor.opacity(0.85) : .clear))
        .foregroundStyle(isActive ? Color.white : .primary)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { startRename() }
        .onTapGesture { if !renaming { model.applyPose(pose) } }
        .contextMenu {
            Button("Apply") { model.applyPose(pose) }
            Button("Update with Current Arrangement") { model.updatePose(pose) }
            Divider()
            Button("Rename…") { startRename() }
            Divider()
            Button("Delete", role: .destructive) { model.deletePose(pose) }
        }
        .help(isActive ? "The current pose" : "Click to apply “\(pose.name)”")
    }

    private func startRename() {
        draft = pose.name
        renaming = true
        nameFocused = true
    }

    private func commitRename() {
        guard renaming else { return }
        model.renamePose(pose, to: draft)
        renaming = false
    }
}
