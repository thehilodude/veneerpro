import AppKit
import SwiftUI

/// The launch splash, kept deliberately quiet: identity and Import on the left; recent models, a
/// three-step strip and the supported formats on the right.
struct WelcomeView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow
    @AppStorage(WelcomeView.showAtLaunchKey) private var showAtLaunch = true
    @State private var dropTargeted = false
    /// The step under the pointer, and the one clicked to stay open.
    @State private var hoveredStep: Step?
    @State private var pinnedStep: Step?

    /// The workflow, shown as a strip; hovering or clicking a step reveals more about it.
    enum Step: Int, CaseIterable, Identifiable {
        case importModel, apply, refine, view
        var id: Int { rawValue }

        var title: String {
            switch self {
            case .importModel: "Import"
            case .apply: "Apply materials"
            case .refine: "Refine"
            case .view: "View in AR"
            }
        }

        var symbol: String {
            switch self {
            case .importModel: "square.and.arrow.down"
            case .apply: "circle.hexagongrid"
            case .refine: "slider.horizontal.3"
            case .view: "visionpro"
            }
        }

        var tint: Color {
            switch self {
            case .importModel: WelcomeView.red
            case .apply: WelcomeView.yellow
            case .refine: WelcomeView.blue
            case .view: .white
            }
        }

        var detail: String {
            switch self {
            case .importModel:
                "Drop files or folders onto the window, or press ⌘O. Parts and materials are read automatically — USDZ, USD, FBX, OBJ and more."
            case .apply:
                "Pick from Poly Haven and ambientCG, or your Visune, KeyShot and Substance libraries. Drag a material onto a part, or double-click it to apply."
            case .refine:
                "Tune colors and finishes in the node editor, and set Box, Planar or Cylindrical mapping in real-world sizes."
            case .view:
                "View it live on Apple Vision Pro, or export a USDZ to see it in AR Quick Look on your iPhone, iPad or Mac."
            }
        }
    }

    private var activeStep: Step? { hoveredStep ?? pinnedStep }

    /// `openStep` starts with that step's details showing.
    init(openStep: Step? = nil) {
        _pinnedStep = State(initialValue: openStep)
    }

    static let showAtLaunchKey = "ShowWelcomeAtLaunch"
    static let windowID = "welcome"

    var body: some View {
        HStack(spacing: 0) {
            identity
                .frame(width: 300)
            Rectangle().fill(Color.white.opacity(0.07)).frame(width: 1)
            content
        }
        .frame(width: 760, height: 460)
        .background(Theme.panel)
        .overlay {
            if dropTargeted {
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(Color.accentColor, lineWidth: 3)
                    .padding(6)
                    .allowsHitTesting(false)
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            importModels(urls)
            return true
        } isTargeted: { dropTargeted = $0 }
        .onExitCommand { close() }
    }

    // MARK: Left: identity and Import

    private var identity: some View {
        VStack(spacing: 0) {
            Spacer()
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 104, height: 104)
                .shadow(color: .black.opacity(0.4), radius: 12, y: 6)
            Text("Veneer Pro")
                .font(.system(size: 26, weight: .bold))
                .padding(.top, 14)
            Text("AR Model Maker & CMF Visualizer")
                .font(.system(size: 12.5))
                .foregroundStyle(.secondary)
                .padding(.top, 2)
            Button {
                if model.presentImportPanel() { close() }
            } label: {
                Label("Import Model…", systemImage: "square.and.arrow.down")
                    .font(.system(size: 13.5, weight: .semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .foregroundStyle(.white)
                    .background(RoundedRectangle(cornerRadius: 10).fill(Color.accentColor))
            }
            .buttonStyle(.plain)
            .keyboardShortcut("o")
            .help("Import models (⌘O)")
            .padding(.top, 26)
            Text("or drop files anywhere")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .padding(.top, 8)
            Spacer()
            Toggle("Show at launch", isOn: $showAtLaunch)
                .toggleStyle(.checkbox)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Text("Version \(Self.version)")
                .font(.system(size: 10.5))
                .foregroundStyle(.tertiary)
                .padding(.top, 6)
        }
        .padding(.horizontal, 34)
        .padding(.top, 20)
        .padding(.bottom, 16)
        .background(LinearGradient(colors: [Color.white.opacity(0.05), .clear], startPoint: .top, endPoint: .bottom))
    }

    // MARK: Right: recents, steps, formats

    private var content: some View {
        VStack(alignment: .leading, spacing: 0) {
            recents
            Spacer(minLength: 12)
            steps
            Text(Self.formatLine)
                .font(.system(size: 10.5, weight: .medium))
                .tracking(0.5)
                .foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity)
                .padding(.top, 12)
                .help("Imports: \(ModelDocument.importableExtensions.map { $0.uppercased() }.joined(separator: ", ")). Exports: USDZ, FBX.")
        }
        .padding(24)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var recents: some View {
        let recent = model.recentModels.filter { FileManager.default.fileExists(atPath: $0.path) }.prefix(6)
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text("Recent").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                Spacer()
                if !recent.isEmpty {
                    Button("Clear") { model.clearRecentModels() }
                        .buttonStyle(.plain).font(.system(size: 10.5)).foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 8)
            .padding(.bottom, 4)
            if recent.isEmpty {
                Text("Models you import will appear here.")
                    .font(.system(size: 12))
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 8)
                    .padding(.top, 4)
            }
            ForEach(Array(recent), id: \.self) { url in
                RecentRow(url: url) { importModels([url]) }
            }
        }
    }

    /// The strip keeps a fixed size; details float in a card above it without moving the buttons
    /// (moving them out from under the pointer would end the hover and make it flicker).
    private var steps: some View {
        HStack(spacing: 2) {
            ForEach(Step.allCases) { step in
                if step != .importModel {
                    Image(systemName: "chevron.right").font(.system(size: 9, weight: .bold)).foregroundStyle(.tertiary)
                }
                stepButton(step)
            }
        }
        .padding(6)
        .background(RoundedRectangle(cornerRadius: 12).fill(Theme.control))
        // Hover is cleared only when leaving the whole strip, so crossing the gaps between steps doesn't flicker.
        .onHover { inside in if !inside { hoveredStep = nil } }
        .overlay(alignment: .top) {
            detailCard
                .alignmentGuide(.top) { $0[.bottom] + 8 }
        }
        .animation(.snappy(duration: 0.18), value: activeStep)
    }

    @ViewBuilder
    private var detailCard: some View {
        ZStack {
            if let step = activeStep {
                VStack(alignment: .leading, spacing: 4) {
                    Text(step.title).font(.system(size: 12, weight: .semibold)).foregroundStyle(step.tint)
                    Text(step.detail)
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 11)
                .background(RoundedRectangle(cornerRadius: 12).fill(Color(white: 0.19)))
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(step.tint.opacity(0.35)))
                .shadow(color: .black.opacity(0.35), radius: 10, y: 4)
                .allowsHitTesting(false)
                .id(step)
                .transition(.opacity.combined(with: .offset(y: 6)))
            }
        }
    }

    private func stepButton(_ step: Step) -> some View {
        let isActive = activeStep == step
        return Button {
            pinnedStep = pinnedStep == step ? nil : step
        } label: {
            VStack(spacing: 6) {
                Image(systemName: step.symbol).font(.system(size: 17, weight: .semibold)).foregroundStyle(step.tint)
                    .frame(height: 22)
                Text(step.title).font(.system(size: 11.5, weight: .medium)).lineLimit(1).minimumScaleFactor(0.85)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 9)
            .background(RoundedRectangle(cornerRadius: 9).fill(isActive ? step.tint.opacity(0.14) : .clear))
            .overlay(RoundedRectangle(cornerRadius: 9)
                .strokeBorder(pinnedStep == step ? step.tint.opacity(0.5) : .clear, lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { inside in if inside { hoveredStep = step } }
    }

    // MARK: Actions

    private func importModels(_ urls: [URL]) {
        model.importModels(urls)
        close()
    }

    private func close() {
        openWindow(id: "main")
        dismissWindow(id: Self.windowID)
    }

    // The icon's primaries.
    static let red = Color(red: 0.90, green: 0.20, blue: 0.16)
    static let yellow = Color(red: 1.0, green: 0.76, blue: 0.03)
    static let blue = Color(red: 0.12, green: 0.37, blue: 0.85)

    /// USD, USDA and USDC read as one family on the welcome screen.
    static let formatLine = "USDZ · USD · FBX · OBJ · DAE · SCN · ABC · PLY · STL"

    static var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = info?["CFBundleVersion"] as? String ?? "1"
        return "\(short) (\(build))"
    }
}

private struct RecentRow: View {
    let url: URL
    var action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                Image(systemName: "cube").font(.system(size: 12)).foregroundStyle(.secondary).frame(width: 18)
                Text(url.deletingPathExtension().lastPathComponent)
                    .font(.system(size: 12.5))
                    .lineLimit(1)
                Spacer()
                Text(url.pathExtension.uppercased())
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 7).fill(hovering ? Color.white.opacity(0.08) : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(url.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
    }
}
