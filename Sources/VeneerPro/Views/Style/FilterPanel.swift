import SwiftUI

/// One group of filter chips, e.g. "Time of Day" with "Sunrise / Sunset", "Midday"….
struct FilterGroup: Identifiable {
    struct Option: Identifiable {
        let value: String
        let label: String
        let count: Int
        var id: String { value }
    }

    let title: String
    let options: [Option]
    var id: String { title }

    /// The selection key for `value` in this group.
    func key(_ value: String) -> String { title + "|" + value }
}

/// Filtering by tag keys ("Group|value"): within a group any selected value matches; across groups all must.
enum FilterMatch {
    static func matches(_ tags: Set<String>, selection: Set<String>) -> Bool {
        guard !selection.isEmpty else { return true }
        var byGroup: [Substring: [String]] = [:]
        for key in selection { byGroup[key.split(separator: "|", maxSplits: 1).first ?? "", default: []].append(key) }
        return byGroup.values.allSatisfy { keys in keys.contains(where: tags.contains) }
    }

    /// Option counts for `group` given `items`' tags, sorted by count.
    static func options(for group: String, in items: [Set<String>], labels: (String) -> String = { $0 },
                        order: [String]? = nil) -> [FilterGroup.Option] {
        var counts: [String: Int] = [:]
        let prefix = group + "|"
        for tags in items {
            for tag in tags where tag.hasPrefix(prefix) { counts[String(tag.dropFirst(prefix.count)), default: 0] += 1 }
        }
        let values: [String]
        if let order {
            values = order.filter { counts[$0] != nil } + counts.keys.filter { !order.contains($0) }.sorted()
        } else {
            values = counts.keys.sorted { counts[$0]! != counts[$1]! ? counts[$0]! > counts[$1]! : $0 < $1 }
        }
        return values.map { FilterGroup.Option(value: $0, label: labels($0), count: counts[$0] ?? 0) }
    }
}

/// A collapsible filter section of wrapping chips, grouped under small headings.
struct FilterPanel: View {
    let groups: [FilterGroup]
    @Binding var selection: Set<String>
    /// Remembers whether the panel is open, per place it's used.
    @AppStorage private var expanded: Bool
    /// Long groups whose full list is showing.
    @State private var showingAll: Set<String> = []

    /// Groups longer than this show their most common options first, with a "Show all" chip.
    private static let shortListLength = 12

    init(groups: [FilterGroup], selection: Binding<Set<String>>, storageKey: String) {
        self.groups = groups
        _selection = selection
        _expanded = AppStorage(wrappedValue: true, "FilterPanelExpanded." + storageKey)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Button {
                    withAnimation(.snappy(duration: 0.2)) { expanded.toggle() }
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "line.3.horizontal.decrease.circle\(selection.isEmpty ? "" : ".fill")")
                            .foregroundStyle(selection.isEmpty ? Color.secondary : Color.accentColor)
                        Text("Filters").font(.system(size: 11.5, weight: .semibold))
                        if !selection.isEmpty {
                            Text("\(selection.count)")
                                .font(.system(size: 10, weight: .bold))
                                .padding(.horizontal, 5).padding(.vertical, 1)
                                .background(Capsule().fill(Color.accentColor))
                                .foregroundStyle(.white)
                        }
                        Image(systemName: "chevron.right")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(.secondary)
                            .rotationEffect(.degrees(expanded ? 90 : 0))
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                Spacer()
                if !selection.isEmpty {
                    Button("Clear") { selection = [] }
                        .buttonStyle(.plain)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
            if expanded {
                ForEach(groups.filter { !$0.options.isEmpty }) { group in
                    VStack(alignment: .leading, spacing: 5) {
                        Text(group.title.uppercased())
                            .font(.system(size: 9.5, weight: .semibold))
                            .foregroundStyle(.tertiary)
                        let long = group.options.count > Self.shortListLength
                        let showAll = showingAll.contains(group.title)
                        FlowLayout(spacing: 5) {
                            ForEach(visibleOptions(group, all: !long || showAll)) { option in
                                let key = group.key(option.value)
                                FilterChip(title: option.label, count: option.count, selected: selection.contains(key)) {
                                    if selection.contains(key) { selection.remove(key) } else { selection.insert(key) }
                                }
                            }
                            if long {
                                Button(showAll ? "Show less" : "Show all \(group.options.count)") {
                                    if showAll { showingAll.remove(group.title) } else { showingAll.insert(group.title) }
                                }
                                .buttonStyle(.plain)
                                .font(.system(size: 10.5, weight: .semibold))
                                .foregroundStyle(Color.accentColor)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 3.5)
                            }
                        }
                    }
                }
                .transition(.opacity)
            }
        }
    }
}

extension FilterPanel {
    /// A long group's most common options (plus any that are selected), in the group's own order.
    fileprivate func visibleOptions(_ group: FilterGroup, all: Bool) -> [FilterGroup.Option] {
        guard !all else { return group.options }
        let top = Set(group.options.sorted { $0.count > $1.count }.prefix(Self.shortListLength).map(\.value))
        return group.options.filter { top.contains($0.value) || selection.contains(group.key($0.value)) }
    }
}

struct FilterChip: View {
    let title: String
    let count: Int
    let selected: Bool
    var action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Text(title).lineLimit(1)
                Text("\(count)").foregroundStyle(selected ? Color.white.opacity(0.75) : .secondary)
            }
            .font(.system(size: 10.5, weight: .medium))
            .padding(.horizontal, 8)
            .padding(.vertical, 3.5)
            .background(Capsule().fill(selected ? Color.accentColor : hovering ? Theme.controlHover : Theme.control))
            .foregroundStyle(selected ? Color.white : .primary)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

/// Wraps children onto multiple lines.
struct FlowLayout: Layout {
    var spacing: CGFloat = 4

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrange(proposal.width ?? .infinity, subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for (subview, origin) in zip(subviews, arrange(bounds.width, subviews).origins) {
            subview.place(at: CGPoint(x: bounds.minX + origin.x, y: bounds.minY + origin.y), proposal: .unspecified)
        }
    }

    private func arrange(_ width: CGFloat, _ subviews: Subviews) -> (origins: [CGPoint], size: CGSize) {
        var origins: [CGPoint] = []
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, maxX: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            origins.append(CGPoint(x: x, y: y))
            x += size.width + spacing
            maxX = max(maxX, x - spacing)
            rowHeight = max(rowHeight, size.height)
        }
        return (origins, CGSize(width: maxX, height: y + rowHeight))
    }
}
