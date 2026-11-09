// Lets shared code use AppKit's type names on iPad, where UIKit provides the equivalents.
#if os(iOS)
import UIKit

typealias NSColor = UIColor
typealias NSImage = UIImage
typealias NSFont = UIFont

extension UIColor {
    convenience init(calibratedRed r: CGFloat, green g: CGFloat, blue b: CGFloat, alpha a: CGFloat) {
        self.init(red: r, green: g, blue: b, alpha: a)
    }
    convenience init(srgbRed r: CGFloat, green g: CGFloat, blue b: CGFloat, alpha a: CGFloat) {
        self.init(red: r, green: g, blue: b, alpha: a)
    }
    convenience init(calibratedWhite w: CGFloat, alpha a: CGFloat) { self.init(white: w, alpha: a) }
    var usingSRGB: UIColor? { self }
}

extension UIImage {
    /// AppKit-style: an image from a CGImage (the size argument is ignored; UIKit uses pixel size).
    convenience init(cgImage: CGImage, size: CGSize) { self.init(cgImage: cgImage) }

    /// AppKit-style CGImage access.
    func cgImage(forProposedRect rect: UnsafeMutablePointer<CGRect>?, context: Any?, hints: [AnyHashable: Any]?) -> CGImage? {
        if let cgImage { return cgImage }
        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { _ in draw(at: .zero) }.cgImage
    }

    /// AppKit images can be named; UIKit images can't.
    func name() -> String? { nil }
}
#endif

import SceneKit

/// The scalar type inside SCNVector3/SCNVector4: CGFloat on the Mac, Float on iPad.
#if os(macOS)
typealias SCNFloat = CGFloat
#else
typealias SCNFloat = Float
#endif

import ImageIO
import UniformTypeIdentifiers

/// PNG data for an image (ImageIO; works on Mac and iPad).
func pngData(_ image: CGImage) -> Data? {
    let data = NSMutableData()
    guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { return nil }
    CGImageDestinationAddImage(destination, image, nil)
    return CGImageDestinationFinalize(destination) ? data as Data : nil
}

import SwiftUI

#if os(iOS)
extension Color {
    init(nsColor: UIColor) { self.init(uiColor: nsColor) }
}
#endif

/// Holding Option for fine slider control (Mac only; iPad has no modifier keys held mid-drag).
@MainActor var isFineAdjustKeyDown: Bool {
    #if os(macOS)
    NSEvent.modifierFlags.contains(.option)
    #else
    false
    #endif
}

extension View {
    /// The Delete key on the Mac; nothing on iPad (where swipe and context menus delete).
    @ViewBuilder func onDeleteKey(perform action: @escaping () -> Void) -> some View {
        #if os(macOS)
        onDeleteCommand(perform: action)
        #else
        self
        #endif
    }
}

#if os(macOS)
typealias PlatformViewRepresentable = NSViewRepresentable
typealias PlatformTapGesture = NSClickGestureRecognizer
#else
typealias PlatformViewRepresentable = UIViewRepresentable
typealias PlatformTapGesture = UITapGestureRecognizer

extension UIColor {
    static var controlAccentColor: UIColor { .tintColor }
}
#endif

extension View {
    /// A checkbox on the Mac; the standard switch on iPad.
    @ViewBuilder func checkboxStyle() -> some View {
        #if os(macOS)
        toggleStyle(.checkbox)
        #else
        self
        #endif
    }

    /// The Escape key on the Mac (cancels an edit); nothing on iPad.
    @ViewBuilder func onEscapeKey(perform action: @escaping () -> Void) -> some View {
        #if os(macOS)
        onExitCommand(perform: action)
        #else
        self
        #endif
    }
}

/// Opening links and revealing files, per platform.
@MainActor enum PlatformActions {
    static func open(_ url: URL) {
        #if os(macOS)
        NSWorkspace.shared.open(url)
        #else
        UIApplication.shared.open(url)
        #endif
    }

    /// Whether files can be shown in a file browser (the Finder) from the app.
    static var canRevealFiles: Bool {
        #if os(macOS)
        true
        #else
        false
        #endif
    }

    static func reveal(_ urls: [URL]) {
        #if os(macOS)
        NSWorkspace.shared.activateFileViewerSelecting(urls)
        #endif
    }
}

extension View {
    /// A left-right resize cursor while hovering (Mac; iPad pointers keep their shape).
    @ViewBuilder func resizeCursorOnHover() -> some View {
        #if os(macOS)
        onHover { inside in if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() } }
        #else
        self
        #endif
    }
}

extension View {
    /// A text-link button on the Mac; a borderless button on iPad.
    @ViewBuilder func linkButtonStyle() -> some View {
        #if os(macOS)
        buttonStyle(.link)
        #else
        buttonStyle(.borderless)
        #endif
    }
}

/// Interface wording that differs between mouse and touch.
enum UIWords {
    #if os(iOS)
    static let click = "Tap"
    static let doubleClick = "Double-tap"
    static let rightClick = "Touch and hold"
    static let isTouch = true
    #else
    static let click = "Click"
    static let doubleClick = "Double-click"
    static let rightClick = "Right-click"
    static let isTouch = false
    #endif
}
