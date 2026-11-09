#if os(macOS)
import AppKit
#else
import UIKit
#endif
import SwiftUI

/// Veneer Pro's look: a dark, Pixelmator/Photomator-style workspace with a recessed canvas, flat
/// collapsible inspector sections and bar sliders that carry their label and value inside.
enum Theme {
    /// Behind the canvas.
    static let canvas = Color(nsColor: NSColor(white: 0.075, alpha: 1))
    /// Panels (sidebar, inspector).
    static let panel = Color(nsColor: NSColor(white: 0.135, alpha: 1))
    /// Controls sitting on a panel (slider tracks, fields, tiles).
    static let control = Color.white.opacity(0.075)
    static let controlHover = Color.white.opacity(0.11)
    /// Slider fill.
    static let fill = Color.white.opacity(0.17)
    static let hairline = Color.white.opacity(0.08)
    static let corner: CGFloat = 7
}

// MARK: - Section

/// A flat, collapsible inspector section, as in Pixelmator Pro's adjustments.
struct InspectorSection<Content: View, Accessory: View>: View {
    let title: String
    @ViewBuilder var content: Content
    @ViewBuilder var accessory: Accessory
    @AppStorage private var collapsed: Bool

    init(title: String, @ViewBuilder content: () -> Content, @ViewBuilder accessory: () -> Accessory) {
        self.title = title
        self.content = content()
        self.accessory = accessory()
        _collapsed = AppStorage(wrappedValue: false, "InspectorCollapsed." + title)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "chevron.right")
                    .appFont(9, weight: .bold)
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(collapsed ? 0 : 90))
                Text(title)
                    .appFont(13, weight: .semibold)
                Spacer()
                accessory
            }
            .padding(.vertical, 10)
            .contentShape(Rectangle())
            .onTapGesture { withAnimation(.snappy(duration: 0.2)) { collapsed.toggle() } }

            if !collapsed {
                VStack(alignment: .leading, spacing: 8) { content }
                    .padding(.bottom, 14)
                    .transition(.opacity)
            }
            Rectangle().fill(Theme.hairline).frame(height: 1)
        }
    }
}

extension InspectorSection where Accessory == EmptyView {
    init(title: String, @ViewBuilder content: () -> Content) {
        self.init(title: title, content: content, accessory: { EmptyView() })
    }
}

// MARK: - Bar slider

/// Pixelmator-style slider: a rounded bar that fills to the value, with the label on the left and
/// the value on the right. Drag anywhere to adjust (hold ⌥ for fine control), double-click to reset.
struct BarSlider: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    var defaultValue: Double?
    /// Maps the bar position (0…1) to a value, for non-linear ranges like sizes.
    var curve: Curve = .linear
    var format: (Double) -> String = { String(format: "%.2f", $0) }

    enum Curve { case linear, logarithmic }

    @State private var dragStart: Double?
    @State private var hovering = false

    var body: some View {
        GeometryReader { proxy in
            let fraction = position(of: value)
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: Theme.corner)
                    .fill(hovering || dragStart != nil ? Theme.controlHover : Theme.control)
                RoundedRectangle(cornerRadius: Theme.corner)
                    .fill(dragStart != nil ? Color.accentColor.opacity(0.55) : Theme.fill)
                    .frame(width: max(0, proxy.size.width * fraction))
                HStack {
                    Text(title).foregroundStyle(.primary.opacity(0.9))
                    Spacer(minLength: 6)
                    Text(format(value)).monospacedDigit().foregroundStyle(.secondary)
                }
                .appFont(11.5)
                .padding(.horizontal, 9)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { drag in
                        if dragStart == nil { dragStart = fraction }
                        let fine = isFineAdjustKeyDown ? 0.1 : 1
                        let delta = Double(drag.translation.width / max(proxy.size.width, 1)) * fine
                        value = self.value(at: min(max(dragStart! + delta, 0), 1))
                    }
                    .onEnded { drag in
                        // A click without dragging jumps to that spot.
                        if abs(drag.translation.width) < 2 {
                            value = self.value(at: min(max(Double(drag.location.x / max(proxy.size.width, 1)), 0), 1))
                        }
                        dragStart = nil
                    }
            )
            .simultaneousGesture(TapGesture(count: 2).onEnded { if let defaultValue { value = defaultValue } })
            .onHover { hovering = $0 }
        }
        .frame(height: 24)
        .help(defaultValue == nil ? title : "\(title) — double-click to reset, hold ⌥ for fine control")
    }

    private func position(of v: Double) -> Double {
        switch curve {
        case .linear: return (v - range.lowerBound) / (range.upperBound - range.lowerBound)
        case .logarithmic:
            let lo = log(range.lowerBound), hi = log(range.upperBound)
            return (log(max(v, range.lowerBound)) - lo) / (hi - lo)
        }
    }

    private func value(at t: Double) -> Double {
        switch curve {
        case .linear: return range.lowerBound + t * (range.upperBound - range.lowerBound)
        case .logarithmic: return exp(log(range.lowerBound) + t * (log(range.upperBound) - log(range.lowerBound)))
        }
    }
}

// MARK: - Tiles and tabs

/// A square tool tile with an icon and caption, used for choosing among a few modes.
struct ToolTile: View {
    let title: String
    let symbol: String
    let isSelected: Bool
    var action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: symbol).appFont(15, weight: .regular).frame(height: 18)
                Text(title).appFont(9.5, weight: .medium).lineLimit(1).minimumScaleFactor(0.8)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .foregroundStyle(isSelected ? Color.white : .secondary)
            .background(RoundedRectangle(cornerRadius: Theme.corner)
                .fill(isSelected ? Color.accentColor : hovering ? Theme.controlHover : Theme.control))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

/// An icon tab bar in a recessed pill (the inspector's tabs).
struct IconTabs<Tab: Hashable>: View {
    let tabs: [Tab]
    @Binding var selection: Tab
    let symbol: (Tab) -> String
    let title: (Tab) -> String

    var body: some View {
        HStack(spacing: 2) {
            ForEach(tabs, id: \.self) { tab in
                Button { selection = tab } label: {
                    Image(systemName: symbol(tab))
                        .appFont(13, weight: .medium)
                        .frame(maxWidth: .infinity, minHeight: 24)
                        .foregroundStyle(selection == tab ? Color.white : .secondary)
                        .background(RoundedRectangle(cornerRadius: 6)
                            .fill(selection == tab ? Color.white.opacity(0.16) : .clear))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(title(tab))
            }
        }
        .padding(3)
        .background(RoundedRectangle(cornerRadius: 9).fill(Color.black.opacity(0.25)))
    }
}

/// A label on the left and a compact control on the right.
struct InspectorRow<Control: View>: View {
    let title: String
    @ViewBuilder var control: Control

    var body: some View {
        HStack {
            Text(title).appFont(11.5).foregroundStyle(.secondary)
            Spacer()
            control
        }
        .frame(minHeight: 22)
    }
}

/// A floating translucent capsule of labeled buttons over the canvas.
struct CanvasHUD<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        // Icons only when the viewport is too narrow for the labels.
        ViewThatFits(in: .horizontal) {
            bar
            bar.environment(\.hudIconsOnly, true)
        }
    }

    private var bar: some View {
        HStack(spacing: 2) { content }
            .padding(5)
            .background(.ultraThinMaterial, in: Capsule())
            .overlay(Capsule().strokeBorder(Color.white.opacity(0.1)))
            .shadow(color: .black.opacity(0.35), radius: 10, y: 4)
    }
}

struct HUDButton: View {
    let symbol: String
    let title: String
    let help: String
    var isOn = false
    var action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HUDLabel(symbol: symbol, title: title, isOn: isOn, hovering: hovering)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help)
    }
}

/// An icon and its name, as shown in the viewer bar; menus add a small chevron.
struct HUDLabel: View {
    let symbol: String
    let title: String
    var isOn = false
    var hovering = false
    var isMenu = false
    @Environment(\.hudIconsOnly) private var iconsOnly

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: symbol)
                .appFont(13.5, weight: .medium)
                .frame(width: 18)
            if !iconsOnly {
                Text(title)
                    .appFont(12, weight: .medium)
                    .lineLimit(1)
            }
            if isMenu, !iconsOnly {
                Image(systemName: "chevron.down")
                    .appFont(8, weight: .bold)
                    .opacity(0.6)
            }
        }
        .padding(.horizontal, iconsOnly ? 6 : 10)
        .frame(height: 30)
        .foregroundStyle(isOn ? Color.white : .primary)
        .background(Capsule().fill(isOn ? Color.accentColor.opacity(hovering ? 0.85 : 1) : hovering ? Color.white.opacity(0.12) : .clear))
        .contentShape(Capsule())
    }
}

extension EnvironmentValues {
    /// The viewer bar drops its labels when the viewport is narrow.
    @Entry var hudIconsOnly = false
}

// MARK: - Text size

/// The app-wide text size (View ▸ Text Size). Every font in the app goes through `appFont`, which
/// scales by it, and each window's default text (buttons, toggles, fields) scales too.
enum TextSize {
    static let key = "TextSize"
    static let steps: [CGFloat] = [1.0, 1.12, 1.25, 1.4]
    /// A step larger than the original sizes, which ran small.
    static let defaultStep = 1

    static var step: Int {
        get { UserDefaults.standard.object(forKey: key) as? Int ?? defaultStep }
        set { UserDefaults.standard.set(min(max(newValue, 0), steps.count - 1), forKey: key) }
    }
}

extension EnvironmentValues {
    @Entry var textScale: CGFloat = 1
}

private struct AppFont: ViewModifier {
    @Environment(\.textScale) private var scale
    let size: CGFloat
    let weight: Font.Weight
    let design: Font.Design
    let monospacedDigits: Bool

    func body(content: Content) -> some View {
        let font = Font.system(size: (size * scale).rounded(), weight: weight, design: design)
        content.font(monospacedDigits ? font.monospacedDigit() : font)
    }
}

/// Applies the text size setting to a window's content.
private struct AppTextSize: ViewModifier {
    @AppStorage(TextSize.key) private var step = TextSize.defaultStep

    func body(content: Content) -> some View {
        let scale = TextSize.steps[min(max(step, 0), TextSize.steps.count - 1)]
        content
            .environment(\.textScale, scale)
            .font(.system(size: (13 * scale).rounded()))
    }
}

extension View {
    /// A system font at `size` points, scaled by the text size setting.
    func appFont(_ size: CGFloat, weight: Font.Weight = .regular, design: Font.Design = .default,
                 monospacedDigits: Bool = false) -> some View {
        modifier(AppFont(size: size, weight: weight, design: design, monospacedDigits: monospacedDigits))
    }

    /// Scales this window's text by the text size setting.
    func appTextSize() -> some View { modifier(AppTextSize()) }
}
