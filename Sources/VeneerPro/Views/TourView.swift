#if os(macOS)
import SwiftUI

/// A paged introduction to Veneer Pro's features, with screenshots (Resources/Tour/tour-N.jpg).
/// Opened from the welcome screen and Help → Veneer Pro Tour.
struct TourView: View {
    static let windowID = "tour"

    @Environment(\.dismissWindow) private var dismissWindow
    @State private var page = 0

    struct Page {
        let image: Int
        let symbol: String
        let title: String
        let summary: String
        let tips: [(symbol: String, text: String)]
    }

    static let pages: [Page] = [
        Page(image: 1, symbol: "sparkles", title: "Welcome to Veneer Pro",
             summary: "Bring in a 3D model, give it real colors and finishes, and see it at full size in AR on iPhone, iPad and Apple Vision Pro.",
             tips: [("square.and.arrow.down", "Open models with ⌘O or drop them on the window: \(importFormats)."),
                    ("doc.badge.gearshape", "Save a project (⌘S) to keep models, materials, colorways and poses together in one .vnr file."),
                    ("arrow.uturn.backward", "Every change can be undone with ⌘Z.")]),
        Page(image: 2, symbol: "square.grid.3x3.fill", title: "Materials",
             summary: Distribution.isAppStore
                ? "Browse thousands of free materials from ambientCG, or link your own library folders and Substance texture sets."
                : "Browse thousands of free materials from Poly Haven and ambientCG, or link your own KeyShot, Substance and texture libraries.",
             tips: [("hand.point.up.left", "Double-click a material to apply it to the selected part, or drag it onto the model."),
                    ("square.grid.3x3", "Filters narrow the list by category; downloads stay available offline."),
                    ("point.3.connected.trianglepath.dotted", "Need more control? The Nodes button opens the material's node graph.")]),
        Page(image: 3, symbol: "paintpalette", title: "Color & Finish",
             summary: Distribution.isAppStore
                ? "Specify color by hex, RGB, CIELAB or any color system's code, and pick a finish the way a supplier would."
                : "Specify color the way suppliers do: RAL Classic, Design System+ and Effect, or hex, RGB, CIELAB and any other code.",
             tips: [("eyedropper", "Choose Color… opens the picker right in the inspector, so the model stays in view."),
                    ("circle.lefthalf.filled", "Finish presets cover paint gloss levels, SPI and VDI 3400 plastics, metals and coatings."),
                    ("number", "Codes travel with the material into colorways, spec sheets and the share page.")]),
        Page(image: 4, symbol: "swatchpalette", title: "Colorways",
             summary: "Save the current materials as a colorway, try another look, and switch between them with a click.",
             tips: [("plus.circle", "Click + in Colorways (Materials tab) to save; edits after applying show as Modified."),
                    ("square.split.2x1", "Compare ▸ Compare Colorway puts two colorways side by side."),
                    ("arkit", "Exports include every colorway as a picker in AR Quick Look.")]),
        Page(image: 5, symbol: "cube.transparent", title: "Objects, Gumball & Hinges",
             summary: "Pick parts in the viewer or the Scene list, group and rearrange them, and move them with the gumball.",
             tips: [("cursorarrow.click.2", "⌘- or ⇧-click selects several parts; ⌘G groups them; drag rows to rearrange."),
                    ("move.3d", "Drag the gumball's arrows to move and its rings to rotate (⇧ snaps to 15°) around the pivot."),
                    ("door.left.hand.open", "Hinges swing a lid or a door around its pivot between angle limits (Object tab).")]),
        Page(image: 6, symbol: "figure.stand.line.dotted.figure.stand", title: "Poses",
             summary: "Save arrangements like Open and Closed, with every part's position, visibility and hinge angle.",
             tips: [("plus.circle", "Arrange the model, then click + in Poses (Object tab); click a pose to switch."),
                    ("eye.slash", "Show and hide parts per pose, like this lamp's open and closed versions."),
                    ("arkit", "Poses export as a second picker in AR Quick Look, next to Colorway.")]),
        Page(image: 7, symbol: "ruler", title: "True Scale",
             summary: "Judge size in context: place the model on a desk or in a bedroom, next to everyday objects at real-world size.",
             tips: [("square.split.bottomrightquarter", "True Scale in the viewer bar switches scenes; props and a 175 cm person can be toggled."),
                    ("rectangle.bottomhalf.filled", "A ground plane with a soft shadow grounds the model in the studio (Environment tab)."),
                    ("ruler", "The size readout shows width, depth and height in cm or inches.")]),
        Page(image: 8, symbol: "iphone.gen3.radiowaves.left.and.right", title: "Share to iPhone & iPad",
             summary: "Scan a QR code to open the model in AR on any iPhone or iPad on your Wi-Fi. No app or upload needed.",
             tips: [("qrcode", "iPhone & iPad in the toolbar shows the code; the page tells you when there's a newer version."),
                    ("visionpro", "Vision Pro shows the model live on Apple Vision Pro, updating as you edit."),
                    ("lock.shield", "Nothing leaves your local network; Stop Sharing ends the link.")]),
        Page(image: 9, symbol: "arkit", title: "AR Match",
             summary: "See the model rendered by RealityKit, the engine behind AR Quick Look and Vision Pro, using the exact file your iPhone gets.",
             tips: [("arkit", "AR Match in the viewer bar; it updates after each edit."),
                    ("hand.draw", "Drag to orbit, scroll or pinch to zoom, double-click to reframe."),
                    ("square.and.arrow.up", "Export (⌘E) writes USDZ or FBX when you're happy with it.")]),
        Page(image: 10, symbol: "doc.richtext", title: "Spec Sheets",
             summary: "Hand off a PDF with renders, overall dimensions, and every material's color code, values and finish, with a page per colorway.",
             tips: [("doc.text", "File ▸ Export Spec Sheet (⌥⌘P), or Spec Sheet… in the Properties tab."),
                    ("square.on.square", "Materials with identical specs are listed once."),
                    ("checkmark.seal", "Screen colors are approximations; confirm against physical standards.")]),
    ]

    private static var importFormats: String {
        Distribution.isAppStore ? "USDZ, USD, OBJ and more" : "USDZ, USD, FBX, OBJ and more"
    }

    var body: some View {
        let current = Self.pages[page]
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 26) {
                screenshot(current.image)
                    .frame(width: 600, height: 375)
                details(current)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 28)
            .padding(.top, 28)
            .id(page)
            .transition(.opacity)

            Spacer(minLength: 0)
            footer
        }
        .frame(width: 1000, height: 500)
        .background(Theme.panel)
        .onKeyPress(.leftArrow) { go(-1); return .handled }
        .onKeyPress(.rightArrow) { go(1); return .handled }
        .onExitCommand { dismissWindow(id: Self.windowID) }
    }

    private func screenshot(_ n: Int) -> some View {
        Group {
            if let url = Bundle.main.url(forResource: "tour-\(n)", withExtension: "jpg"), let image = NSImage(contentsOf: url) {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fit)
            } else {
                Color.black.opacity(0.3)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.white.opacity(0.12)))
        .shadow(color: .black.opacity(0.35), radius: 14, y: 6)
        .frame(width: 600, height: 375)
    }

    private func details(_ page: Page) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(page.title, systemImage: page.symbol)
                .appFont(21, weight: .bold)
                .labelStyle(TitleLabelStyle())
            Text(page.summary)
                .appFont(13)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 10) {
                ForEach(Array(page.tips.enumerated()), id: \.offset) { _, tip in
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Image(systemName: tip.symbol)
                            .appFont(12, weight: .semibold)
                            .foregroundStyle(Color.accentColor)
                            .frame(width: 18)
                        Text(tip.text)
                            .appFont(12.5)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .padding(.top, 4)
        }
    }

    private var footer: some View {
        HStack {
            Button("Skip Tour") { dismissWindow(id: Self.windowID) }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            Spacer()
            HStack(spacing: 7) {
                ForEach(Self.pages.indices, id: \.self) { i in
                    Circle()
                        .fill(i == page ? Color.accentColor : Color.white.opacity(0.22))
                        .frame(width: 7, height: 7)
                        .contentShape(Rectangle().inset(by: -4))
                        .onTapGesture { withAnimation(.easeInOut(duration: 0.2)) { page = i } }
                }
            }
            Spacer()
            HStack(spacing: 8) {
                Button("Back") { go(-1) }
                    .disabled(page == 0)
                if page == Self.pages.count - 1 {
                    Button("Get Started") { dismissWindow(id: Self.windowID) }
                        .keyboardShortcut(.defaultAction)
                } else {
                    Button("Next") { go(1) }
                        .keyboardShortcut(.defaultAction)
                }
            }
            .controlSize(.large)
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 18)
        .background(Color.black.opacity(0.12))
    }

    private func go(_ step: Int) {
        let next = min(max(page + step, 0), Self.pages.count - 1)
        guard next != page else { return }
        withAnimation(.easeInOut(duration: 0.2)) { page = next }
    }
}

/// Icon and title side by side, with the icon in the accent color.
private struct TitleLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 10) {
            configuration.icon.foregroundStyle(Color.accentColor)
            configuration.title
        }
    }
}
#endif
