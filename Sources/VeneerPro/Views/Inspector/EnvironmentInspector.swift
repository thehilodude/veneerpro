import AppKit
import SwiftUI

/// Lighting for the viewer: built-in studios, the user's own HDRIs, and KeyShot's environments.
struct EnvironmentInspector: View {
    @Environment(AppModel.self) private var model
    @State private var dropTargeted = false
    @AppStorage("EnvironmentExpandedGroups") private var expandedGroups = "Studio"

    private var library: EnvironmentLibrary { model.environments }

    var body: some View {
        @Bindable var model = model
        VStack(alignment: .leading, spacing: 0) {
            InspectorSection(title: "Lighting") {
                CurrentEnvironment(source: model.viewer.environment)
                LabeledSlider(title: "Rotation", value: $model.viewer.environmentRotation, range: 0...360, defaultValue: 0,
                              format: { "\(Int($0))°" })
                LabeledSlider(title: "Brightness", value: $model.viewer.environmentIntensity, range: 0...3, defaultValue: 1,
                              format: { String(format: "%.1f×", $0) })
                LabeledSlider(title: "Exposure", value: $model.viewer.exposure, range: -3...3, defaultValue: 0,
                              format: { String(format: "%+.1f", $0) })
                Toggle("Show Environment as Background", isOn: $model.viewer.showEnvironment)
                Toggle("Show Grid", isOn: $model.viewer.showGrid)
            }

            InspectorSection(title: "My HDRIs") {
                if library.custom.isEmpty {
                    VStack(spacing: 6) {
                        Image(systemName: "photo.on.rectangle.angled").font(.title2).foregroundStyle(.tertiary)
                        Text("Drop .hdr, .exr or KeyShot .hdz/.klf files here")
                            .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [5, 4]))
                        .foregroundStyle(dropTargeted ? Color.accentColor : Color.secondary.opacity(0.4)))
                } else {
                    grid(library.custom.map { .file($0) }, removable: true)
                }
                Button {
                    if let first = library.presentAddPanel().first { model.viewer.environment = first }
                } label: {
                    Label("Add HDRI…", systemImage: "plus")
                }
            }

            InspectorSection(title: "Built-in") {
                grid(library.builtIn, removable: false)
            }

            if library.keyShotRoot != nil {
                InspectorSection(title: "KeyShot") {
                    if library.keyShotGroups.isEmpty {
                        ProgressView().controlSize(.small)
                    }
                    ForEach(library.keyShotGroups) { group in
                        DisclosureGroup(isExpanded: expansion(group.title)) {
                            grid(group.sources, removable: false)
                                .padding(.top, 6)
                        } label: {
                            HStack {
                                Text(group.title).font(.subheadline.weight(.medium))
                                Spacer()
                                Text("\(group.sources.count)").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    Text("Studio and Sun & Sky lighting files are re-created from KeyShot's light setups; image environments load as-is.")
                        .font(.caption2).foregroundStyle(.tertiary)
                }
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            let added = library.add(urls)
            if let first = added.first { model.viewer.environment = first }
            return !added.isEmpty
        } isTargeted: { dropTargeted = $0 }
    }

    private func grid(_ sources: [EnvironmentSource], removable: Bool) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 112), spacing: 8)], spacing: 10) {
            ForEach(sources) { source in
                EnvironmentCell(source: source, isSelected: model.viewer.environment == source)
                    .onTapGesture { model.viewer.environment = source }
                    .contextMenu {
                        if case let .file(url) = source {
                            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                            if removable {
                                Button("Remove from My HDRIs", role: .destructive) {
                                    library.remove(url)
                                    if model.viewer.environment == source { model.viewer.environment = .preset(.studio) }
                                }
                            }
                        }
                    }
            }
        }
    }

    private func expansion(_ title: String) -> Binding<Bool> {
        Binding(
            get: { expandedGroups.split(separator: "|").contains { $0 == title } },
            set: { open in
                var set = Set(expandedGroups.split(separator: "|").map(String.init))
                if open { set.insert(title) } else { set.remove(title) }
                expandedGroups = set.sorted().joined(separator: "|")
            }
        )
    }
}

/// The selected environment, shown large.
private struct CurrentEnvironment: View {
    @Environment(AppModel.self) private var model
    let source: EnvironmentSource
    @State private var image: CGImage?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Rectangle().fill(.quaternary)
                .aspectRatio(2, contentMode: .fit)
                .overlay { if let image { Image(decorative: image, scale: 1).resizable() } }
                .clipShape(RoundedRectangle(cornerRadius: 8))
            Text(source.name).font(.callout.weight(.medium)).lineLimit(1)
        }
        .task(id: source.id) {
            image = model.environments.cachedThumbnail(source)
            if image == nil { image = await model.environments.thumbnail(source) }
        }
    }
}

private struct EnvironmentCell: View {
    @Environment(AppModel.self) private var model
    let source: EnvironmentSource
    let isSelected: Bool
    @State private var image: CGImage?

    var body: some View {
        VStack(spacing: 3) {
            Rectangle().fill(.quaternary)
                .aspectRatio(2, contentMode: .fit)
                .overlay {
                    if let image {
                        Image(decorative: image, scale: 1).resizable()
                    } else {
                        ProgressView().controlSize(.mini)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(isSelected ? Color.accentColor : .clear, lineWidth: 2.5))
            Text(source.name)
                .font(.system(size: 10))
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundStyle(isSelected ? .primary : .secondary)
        }
        .contentShape(Rectangle())
        .help(source.name)
        .task(id: source.id) {
            image = model.environments.cachedThumbnail(source)
            if image == nil { image = await model.environments.thumbnail(source) }
        }
    }
}

private struct LabeledSlider: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    var defaultValue: Double? = nil
    let format: (Double) -> String

    var body: some View {
        BarSlider(title: title, value: $value, range: range, defaultValue: defaultValue, format: format)
    }
}
