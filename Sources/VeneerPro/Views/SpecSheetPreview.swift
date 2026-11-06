import PDFKit
import SwiftUI
import UniformTypeIdentifiers

/// Shows the spec sheet exactly as it will export, with its options, before saving it.
struct SpecSheetPreview: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @AppStorage(SprayPaints.settingKey) private var sprayDefault = false
    @State private var includeSpray: Bool?
    @State private var pages: (plain: [SpecSheet.Page], spray: [SpecSheet.Page])?
    @State private var pdf: PDFDocument?
    @State private var pageIndex = 0

    private var document: ModelDocument? { model.selectedDocument }
    private var spray: Bool { includeSpray ?? sprayDefault }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ZStack {
                Color(nsColor: NSColor(white: 0.2, alpha: 1))
                if let pdf {
                    PDFPreview(document: pdf, pageIndex: $pageIndex)
                } else {
                    VStack(spacing: 10) {
                        ProgressView()
                        Text(model.status ?? "Rendering views…")
                            .appFont(12).foregroundStyle(.secondary)
                    }
                }
            }
            Divider()
            footer
        }
        .frame(minWidth: 820, idealWidth: 1000, minHeight: 620, idealHeight: 780)
        .task { await render() }
        .onChange(of: spray) { makePDF() }
    }

    private var header: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Spec Sheet Preview").appFont(15, weight: .semibold)
                if let document {
                    Text(document.colorways.isEmpty
                         ? "The current materials of “\(document.name)”"
                         : "A page for each of the \(document.colorways.count) colorways of “\(document.name)”")
                        .appFont(11).foregroundStyle(.secondary)
                }
            }
            Spacer()
            Toggle("Include spray paint matches", isOn: Binding(get: { spray }, set: { includeSpray = $0 }))
                .help("Adds the closest spray paints (and RAL-matched aerosols) under each color. Handy for students; professionals usually leave it off.")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var footer: some View {
        HStack(spacing: 10) {
            if let pdf, pdf.pageCount > 0 {
                Button { pageIndex = max(pageIndex - 1, 0) } label: { Image(systemName: "chevron.left") }
                    .disabled(pageIndex == 0)
                Text("Page \(pageIndex + 1) of \(pdf.pageCount)")
                    .appFont(12, monospacedDigits: true).foregroundStyle(.secondary)
                Button { pageIndex = min(pageIndex + 1, pdf.pageCount - 1) } label: { Image(systemName: "chevron.right") }
                    .disabled(pageIndex >= pdf.pageCount - 1)
            }
            Spacer()
            Button("Cancel") { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button("Export PDF…") { export() }
                .keyboardShortcut(.defaultAction)
                .disabled(pdf == nil)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private func render() async {
        guard let document else { return }
        pages = await model.renderSpecSheet(document)
        makePDF()
    }

    private func makePDF() {
        guard let pages else { return }
        let data = SpecSheet.pdf(spray ? pages.spray : pages.plain, project: model.projectName)
        pdf = data.flatMap(PDFDocument.init(data:))
        pageIndex = min(pageIndex, max((pdf?.pageCount ?? 1) - 1, 0))
    }

    private func export() {
        guard let document, let data = pdf?.dataRepresentation() else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        panel.nameFieldStringValue = "\(document.name) Spec Sheet.pdf"
        panel.directoryURL = model.projectURL?.deletingLastPathComponent() ?? document.sourceURL.deletingLastPathComponent()
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try data.write(to: url, options: .atomic)
            dismiss()
            NSWorkspace.shared.open(url)
        } catch {
            model.errorMessage = "The spec sheet couldn't be saved. \(error.localizedDescription)"
        }
    }
}

/// A PDFKit view showing every page in a scrolling column, fit to the width, tracking the current page.
private struct PDFPreview: NSViewRepresentable {
    let document: PDFDocument
    @Binding var pageIndex: Int

    func makeNSView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.displayDirection = .vertical
        view.backgroundColor = NSColor(white: 0.2, alpha: 1)
        view.pageShadowsEnabled = true
        NotificationCenter.default.addObserver(context.coordinator, selector: #selector(Coordinator.pageChanged(_:)),
                                               name: .PDFViewPageChanged, object: view)
        return view
    }

    func updateNSView(_ view: PDFView, context: Context) {
        context.coordinator.parent = self
        if view.document !== document {
            view.document = document
            view.autoScales = true
        }
        if let page = document.page(at: pageIndex), view.currentPage !== page {
            view.go(to: page)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    final class Coordinator: NSObject {
        var parent: PDFPreview
        init(parent: PDFPreview) { self.parent = parent }

        @objc func pageChanged(_ note: Notification) {
            guard let view = note.object as? PDFView, let page = view.currentPage,
                  let doc = view.document else { return }
            let index = doc.index(for: page)
            if index != parent.pageIndex { DispatchQueue.main.async { self.parent.pageIndex = index } }
        }
    }
}
