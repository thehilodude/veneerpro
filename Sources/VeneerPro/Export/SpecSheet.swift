import AppKit
import SceneKit
import UniformTypeIdentifiers

/// A CMF specification PDF: one landscape page per colorway (or the current materials), with renders,
/// dimensions, and each material's color code, color values and finish.
enum SpecSheet {
    /// One colorway's page content.
    struct Page {
        var model: String
        var variant: String
        var hero: CGImage?
        var views: [(title: String, image: CGImage?)]
        var dimensions: String
        var rows: [Row]
    }

    struct Row {
        var name: String
        var swatch: CGImage?
        var color: SIMD3<Float>?
        /// "RAL 5015 · Sky blue", "Texture", or "Custom color".
        var colorTitle: String
        /// "#2874B2 · L*a*b* 47.2 −1.2 −39.4".
        var colorValues: String?
        /// "VDI 27 · Ra 2.24 µm" or "Custom".
        var finish: String
        /// "Metallic 0.00 · Roughness 0.45".
        var surface: String
        var parts: Int
    }

    // MARK: Collecting

    /// The current look of `document` as a page; the materials must already be refreshed.
    @MainActor
    static func page(for document: ModelDocument, variant: String, renders: [CGImage]) -> Page {
        let rows = document.materials.map { entry -> Row in
            let graph = entry.graph
            let color = graph.constantBaseColor
            let colorTitle: String
            if let code = graph.spec.colorCode, graph.colorMatchesSpec {
                colorTitle = [code, graph.spec.colorName].compactMap { $0 }.joined(separator: " · ")
            } else if graph.baseColorIsLinked {
                colorTitle = "Texture"
            } else {
                colorTitle = "Custom color"
            }
            let colorValues = color.map { rgb -> String in
                let lab = ColorStandards.lab(rgb)
                return ColorStandards.hexString(rgb) + String(format: "  ·  L*a*b* %.1f  %.1f  %.1f", lab.x, lab.y, lab.z)
            }
            let finish = graph.finishMatchesSpec ? graph.spec.finish.map { "\($0.name) · \($0.detail)" } ?? "Custom" : "Custom"
            let output = graph.node(graph.outputNodeID)
            func value(_ channel: MaterialGraph.Channel) -> String {
                graph.link(into: PortRef(node: graph.outputNodeID, port: channel.rawValue)) != nil
                    ? "map" : String(format: "%.2f", output?.value(channel.name).x ?? 0)
            }
            var surface = "Metallic \(value(.metallic))  ·  Roughness \(value(.roughness))"
            if let clearcoat = output?.value(MaterialGraph.Channel.clearcoat.name).x, clearcoat > 0 {
                surface += String(format: "  ·  Clear coat %.2f", clearcoat)
            }
            if let opacity = output?.value(MaterialGraph.Channel.opacity.name).x, opacity < 1 {
                surface += String(format: "  ·  Opacity %.2f", opacity)
            }
            let materials = Set(entry.materials.map(ObjectIdentifier.init))
            var parts = 0
            document.root.enumerateHierarchy { node, _ in
                if !node.isHidden, node.geometry?.materials.contains(where: { materials.contains(ObjectIdentifier($0)) }) == true { parts += 1 }
            }
            return Row(name: entry.name, swatch: entry.swatch, color: color, colorTitle: colorTitle,
                       colorValues: colorValues, finish: finish, surface: surface, parts: parts)
        }
        .filter { $0.parts > 0 }

        // Materials with the same specified color and finish are listed once ("Zinc + 4 more").
        var merged: [Row] = []
        var counts: [Int] = []
        for row in rows {
            if row.color != nil, let i = merged.firstIndex(where: { $0.color != nil && $0.colorTitle == row.colorTitle
                && $0.colorValues == row.colorValues && $0.finish == row.finish && $0.surface == row.surface }) {
                merged[i].parts += row.parts
                counts[i] += 1
            } else {
                merged.append(row)
                counts.append(1)
            }
        }
        for i in merged.indices where counts[i] > 1 { merged[i].name += "  + \(counts[i] - 1) more" }

        var dimensions = ""
        if let size = document.size() {
            func cm(_ m: Float) -> String { String(format: m >= 1 ? "%.0f" : "%.1f", m * 100) }
            func inch(_ m: Float) -> String { String(format: "%.1f", m / 0.0254) }
            dimensions = "W \(cm(size.x)) × D \(cm(size.z)) × H \(cm(size.y)) cm   (\(inch(size.x)) × \(inch(size.z)) × \(inch(size.y)) in)"
        }
        let titles = ["Front", "Side", "Top"]
        return Page(model: document.name, variant: variant, hero: renders.first,
                    views: titles.enumerated().map { i, title in (title, renders.indices.contains(i + 1) ? renders[i + 1] : nil) },
                    dimensions: dimensions, rows: merged)
    }

    // MARK: Drawing

    /// Letter in the US, A4 elsewhere; landscape.
    static var pageSize: CGSize {
        Locale.current.measurementSystem == .us ? CGSize(width: 792, height: 612) : CGSize(width: 842, height: 595)
    }

    static func write(_ pages: [Page], project: String?, to url: URL) throws {
        var mediaBox = CGRect(origin: .zero, size: pageSize)
        guard let context = CGContext(url as CFURL, mediaBox: &mediaBox, [
            kCGPDFContextTitle as String: "\(pages.first?.model ?? "Model") CMF Specification",
            kCGPDFContextCreator as String: "Veneer Pro",
        ] as CFDictionary) else { throw CocoaError(.fileWriteUnknown) }

        // Each colorway starts a page; materials that don't fit continue on the next.
        var sheets: [(page: Page, rows: ArraySlice<SpecSheet.Row>, continued: Bool)] = []
        for page in pages {
            var rows = page.rows[...]
            let first = rows.prefix(rowsPerPage(continued: false))
            sheets.append((page, first, false))
            rows = rows.dropFirst(first.count)
            while !rows.isEmpty {
                let next = rows.prefix(rowsPerPage(continued: true))
                sheets.append((page, next, true))
                rows = rows.dropFirst(next.count)
            }
        }
        let date = Date().formatted(date: .long, time: .omitted)
        for (n, sheet) in sheets.enumerated() {
            context.beginPDFPage(nil)
            NSGraphicsContext.saveGraphicsState()
            // Draw top-down, like a page.
            context.translateBy(x: 0, y: pageSize.height)
            context.scaleBy(x: 1, y: -1)
            NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
            draw(sheet.page, rows: Array(sheet.rows), continued: sheet.continued, project: project, date: date,
                 pageNumber: n + 1, pageCount: sheets.count)
            NSGraphicsContext.restoreGraphicsState()
            context.endPDFPage()
        }
        context.closePDF()
    }

    private static let margin: CGFloat = 36
    private static let headerHeight: CGFloat = 62
    private static let footerHeight: CGFloat = 26
    private static let rowHeight: CGFloat = 66
    private static var contentTop: CGFloat { margin + headerHeight }
    private static var contentBottom: CGFloat { pageSize.height - margin - footerHeight }
    private static var leftWidth: CGFloat { (pageSize.width - margin * 2) * 0.54 }

    private static func rowsPerPage(continued: Bool) -> Int {
        let height = contentBottom - contentTop - 22
        let perColumn = max(1, Int(height / rowHeight))
        return continued ? perColumn * 2 : perColumn
    }

    private static let ink = NSColor(white: 0.1, alpha: 1)
    private static let secondary = NSColor(white: 0.42, alpha: 1)
    private static let hairline = NSColor(white: 0.85, alpha: 1)

    private static func text(_ string: String, _ size: CGFloat, _ weight: NSFont.Weight = .regular, _ color: NSColor = ink,
                             monospacedDigits: Bool = false) -> NSAttributedString {
        let font = monospacedDigits ? NSFont.monospacedDigitSystemFont(ofSize: size, weight: weight) : NSFont.systemFont(ofSize: size, weight: weight)
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        return NSAttributedString(string: string, attributes: [.font: font, .foregroundColor: color, .paragraphStyle: paragraph])
    }

    private static func draw(_ string: NSAttributedString, at point: CGPoint, width: CGFloat, alignRight: Bool = false) {
        let height = ceil(string.size().height)
        let w = min(width, ceil(string.size().width) + 1)
        let x = alignRight ? point.x + width - w : point.x
        string.draw(with: CGRect(x: x, y: point.y, width: w, height: height), options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
    }

    private static func line(_ y: CGFloat) {
        hairline.setFill()
        CGRect(x: margin, y: y, width: pageSize.width - margin * 2, height: 0.75).fill()
    }

    private static func draw(_ page: Page, rows: [Row], continued: Bool, project: String?, date: String, pageNumber: Int, pageCount: Int) {
        let width = pageSize.width - margin * 2
        // Header
        draw(text(page.model, 22, .semibold), at: CGPoint(x: margin, y: margin - 4), width: width * 0.6)
        draw(text(page.variant + (continued ? " (continued)" : ""), 12, .regular, secondary), at: CGPoint(x: margin, y: margin + 26), width: width * 0.6)
        draw(text("CMF Specification", 11, .semibold), at: CGPoint(x: margin, y: margin), width: width, alignRight: true)
        draw(text(date, 10, .regular, secondary), at: CGPoint(x: margin, y: margin + 16), width: width, alignRight: true)
        if let project {
            draw(text("Project: \(project)", 10, .regular, secondary), at: CGPoint(x: margin, y: margin + 30), width: width, alignRight: true)
        }
        line(margin + headerHeight - 10)

        if continued {
            drawTable(rows, in: CGRect(x: margin, y: contentTop, width: width, height: contentBottom - contentTop), columns: 2)
        } else {
            drawRenders(page, in: CGRect(x: margin, y: contentTop, width: leftWidth, height: contentBottom - contentTop))
            let x = margin + leftWidth + 22
            drawTable(rows, in: CGRect(x: x, y: contentTop, width: pageSize.width - margin - x, height: contentBottom - contentTop), columns: 1)
        }

        // Footer
        line(pageSize.height - margin - 16)
        draw(text("Screen colors and finish renders are approximations. Confirm against physical standards before release.", 8.5, .regular, secondary),
             at: CGPoint(x: margin, y: pageSize.height - margin - 10), width: width * 0.8)
        draw(text("Veneer Pro  ·  \(pageNumber) / \(pageCount)", 8.5, .regular, secondary),
             at: CGPoint(x: margin, y: pageSize.height - margin - 10), width: width, alignRight: true)
    }

    private static func drawRenders(_ page: Page, in rect: CGRect) {
        let viewsHeight: CGFloat = 104
        let heroRect = CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: rect.height - viewsHeight - 38)
        NSColor(white: 0.965, alpha: 1).setFill()
        NSBezierPath(roundedRect: heroRect, xRadius: 8, yRadius: 8).fill()
        if let hero = page.hero { drawImage(hero, fitting: heroRect.insetBy(dx: 8, dy: 8)) }

        let gap: CGFloat = 10
        let viewWidth = (rect.width - gap * 2) / 3
        for (i, view) in page.views.enumerated() {
            let box = CGRect(x: rect.minX + CGFloat(i) * (viewWidth + gap), y: heroRect.maxY + 12, width: viewWidth, height: viewsHeight - 16)
            NSColor(white: 0.965, alpha: 1).setFill()
            NSBezierPath(roundedRect: box, xRadius: 6, yRadius: 6).fill()
            if let image = view.image { drawImage(image, fitting: box.insetBy(dx: 6, dy: 6)) }
            draw(text(view.title, 8.5, .medium, secondary), at: CGPoint(x: box.minX, y: box.maxY + 3), width: box.width)
        }
        draw(text("Overall  " + page.dimensions, 10, .medium, ink, monospacedDigits: true),
             at: CGPoint(x: rect.minX, y: rect.maxY - 14), width: rect.width)
    }

    private static func drawTable(_ rows: [Row], in rect: CGRect, columns: Int) {
        draw(text("Materials", 12, .semibold), at: CGPoint(x: rect.minX, y: rect.minY - 2), width: rect.width)
        let top = rect.minY + 22
        let perColumn = max(1, Int((rect.maxY - top) / rowHeight))
        let columnWidth = (rect.width - CGFloat(columns - 1) * 22) / CGFloat(columns)
        for (i, row) in rows.enumerated() {
            let column = i / perColumn, index = i % perColumn
            guard column < columns else { break }
            let x = rect.minX + CGFloat(column) * (columnWidth + 22)
            let y = top + CGFloat(index) * rowHeight
            drawRow(row, in: CGRect(x: x, y: y, width: columnWidth, height: rowHeight))
        }
    }

    private static func drawRow(_ row: Row, in rect: CGRect) {
        hairline.setFill()
        CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: 0.5).fill()
        let chip = CGRect(x: rect.minX, y: rect.minY + 9, width: 34, height: 34)
        NSGraphicsContext.saveGraphicsState()
        let circle = NSBezierPath(ovalIn: chip)
        circle.addClip()
        if let color = row.color {
            NSColor(srgbRed: CGFloat(color.x), green: CGFloat(color.y), blue: CGFloat(color.z), alpha: 1).setFill()
            chip.fill()
        } else if let swatch = row.swatch {
            NSImage(cgImage: swatch, size: chip.size).draw(in: chip, from: .zero, operation: .sourceOver, fraction: 1,
                                                          respectFlipped: true, hints: nil)
        } else {
            NSColor(white: 0.8, alpha: 1).setFill()
            chip.fill()
        }
        NSGraphicsContext.restoreGraphicsState()
        NSColor(white: 0, alpha: 0.15).setStroke()
        circle.lineWidth = 0.5
        circle.stroke()

        let x = chip.maxX + 10, width = rect.maxX - x
        draw(text(row.name, 10.5, .semibold), at: CGPoint(x: x, y: rect.minY + 6), width: width - 50)
        draw(text("\(row.parts) part\(row.parts == 1 ? "" : "s")", 8.5, .regular, secondary),
             at: CGPoint(x: x, y: rect.minY + 7.5), width: width, alignRight: true)
        draw(text(row.colorTitle, 9.5, .medium), at: CGPoint(x: x, y: rect.minY + 20), width: width)
        if let values = row.colorValues {
            draw(text(values, 8.5, .regular, secondary, monospacedDigits: true), at: CGPoint(x: x, y: rect.minY + 32), width: width)
        }
        draw(text("Finish: " + row.finish, 9, .regular), at: CGPoint(x: x, y: rect.minY + (row.colorValues == nil ? 32 : 43)), width: width)
        draw(text(row.surface, 8.5, .regular, secondary, monospacedDigits: true),
             at: CGPoint(x: x, y: rect.minY + (row.colorValues == nil ? 43 : 54)), width: width)
    }

    /// Draws `image` scaled to fit `rect`, centered.
    private static func drawImage(_ image: CGImage, fitting rect: CGRect) {
        let size = CGSize(width: image.width, height: image.height)
        let scale = min(rect.width / size.width, rect.height / size.height)
        let fitted = CGSize(width: size.width * scale, height: size.height * scale)
        let target = CGRect(x: rect.midX - fitted.width / 2, y: rect.midY - fitted.height / 2, width: fitted.width, height: fitted.height)
        NSImage(cgImage: image, size: size).draw(in: target, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
    }
}

extension AppModel {
    /// Exports a spec sheet PDF for the selected model: a page per colorway, or the current materials.
    func presentSpecSheetPanel() {
        guard let document = selectedDocument else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        panel.nameFieldStringValue = "\(document.name) Spec Sheet.pdf"
        panel.directoryURL = projectURL?.deletingLastPathComponent() ?? document.sourceURL.deletingLastPathComponent()
        panel.message = document.colorways.isEmpty
            ? "A CMF specification of the current materials."
            : "A CMF specification with a page for each of the \(document.colorways.count) colorways."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await exportSpecSheet(document, to: url) }
    }

    func exportSpecSheet(_ document: ModelDocument, to url: URL, open: Bool = true) async {
        isBusy = true
        suppressChangeTracking = true
        defer { isBusy = false; status = nil; suppressChangeTracking = false }
        EditHistory.shared.flush()
        let current = document.currentLooks, active = document.activeColorwayID
        var pages: [SpecSheet.Page] = []
        let variants: [(name: String, looks: [UUID: Colorway.Look]?)] = document.colorways.isEmpty
            ? [("Current materials", nil)]
            : document.colorways.map { ("Colorway: \($0.name)", $0.looks) }
        for variant in variants {
            status = "Rendering “\(variant.name)”"
            if let looks = variant.looks {
                document.applyLooks(looks)
                document.applyMappingsNow()
            }
            for entry in document.materials { await entry.waitForRefresh() }
            let renders = viewport.coordinator?.renderStills(of: document.root, angles: [.hero, .front, .side, .top],
                                                             size: CGSize(width: 1400, height: 1000)) ?? []
            pages.append(SpecSheet.page(for: document, variant: variant.name, renders: renders))
        }
        if !document.colorways.isEmpty {
            document.applyLooks(current)
            document.applyMappingsNow()
            document.activeColorwayID = active
        }
        do {
            try SpecSheet.write(pages, project: projectName, to: url)
            if open { NSWorkspace.shared.open(url) }
        } catch {
            errorMessage = "The spec sheet couldn't be saved. \(error.localizedDescription)"
        }
    }
}
