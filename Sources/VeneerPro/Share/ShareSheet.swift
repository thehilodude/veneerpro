import AppKit
import CoreImage.CIFilterBuiltins
import SwiftUI

/// "Share to iPhone or iPad": a QR code for the local link, plus AirDrop / Messages / Mail for the file.
struct ShareSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var copied = false

    private var share: LocalShare { model.share }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "qrcode").appFont(18, weight: .semibold).foregroundStyle(Color.accentColor)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Share to iPhone or iPad").appFont(15, weight: .semibold)
                    Text(share.document?.name ?? model.selectedDocument?.name ?? "")
                        .appFont(12).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
            }
            .padding(.bottom, 16)

            HStack(alignment: .top, spacing: 20) {
                qrCard
                VStack(alignment: .leading, spacing: 10) {
                    instruction(1, "Connect the iPhone or iPad to the same Wi-Fi as this Mac.")
                    instruction(2, "Scan the code with the Camera app.")
                    instruction(3, "Tap View in AR. Keep the page open — it offers the latest version after each edit.")
                    Spacer(minLength: 4)
                    statusLine
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            if let url = share.pageURL {
                HStack(spacing: 8) {
                    Text(url.absoluteString)
                        .appFont(11, design: .monospaced)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                    Spacer()
                    Button(copied ? "Copied" : "Copy Link") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(url.absoluteString, forType: .string)
                        copied = true
                    }
                    .controlSize(.small)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(RoundedRectangle(cornerRadius: 8).fill(Theme.control))
                .padding(.top, 14)
            }

            HStack(spacing: 8) {
                Text("Or send the file:").appFont(11.5).foregroundStyle(.secondary)
                sendButton("AirDrop", symbol: "airplayaudio", service: .sendViaAirDrop)
                sendButton("Messages", symbol: "message", service: .composeMessage)
                sendButton("Mail", symbol: "envelope", service: .composeEmail)
                Spacer()
            }
            .padding(.top, 14)

            Divider().padding(.vertical, 14)

            HStack {
                Text("Anyone on this Wi-Fi with the link can view the model until you stop sharing.")
                    .appFont(10.5).foregroundStyle(.tertiary)
                Spacer()
                Button("Stop Sharing", role: .destructive) {
                    share.stop()
                    dismiss()
                }
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 560)
        .onAppear {
            // Share the selected model (switching if another one was being shared).
            if let document = model.selectedDocument, share.document !== document {
                share.snapshot = { [weak model] in model?.viewport.view?.snapshot() }
                share.start(document)
            }
        }
    }

    private var qrCard: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 14).fill(Color.white)
            if let url = share.pageURL, let image = Self.qrCode(url.absoluteString) {
                Image(decorative: image, scale: 1)
                    .interpolation(.none)
                    .resizable()
                    .padding(12)
            } else if case let .failed(message) = share.status {
                Text(message).appFont(11).foregroundStyle(.red).multilineTextAlignment(.center).padding(12)
            } else {
                ProgressView().controlSize(.small).colorScheme(.light)
            }
        }
        .frame(width: 190, height: 190)
    }

    @ViewBuilder
    private var statusLine: some View {
        HStack(spacing: 6) {
            if share.isExporting || share.fileURL == nil {
                ProgressView().controlSize(.mini)
                Text(share.fileURL == nil ? "Preparing the model…" : "Updating with your latest edits…")
            } else if let updated = share.lastUpdated {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                Text("Up to date · \(updated.formatted(date: .omitted, time: .shortened))")
            }
        }
        .appFont(11.5)
        .foregroundStyle(.secondary)
    }

    private func instruction(_ number: Int, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text("\(number)")
                .appFont(11, weight: .bold)
                .frame(width: 18, height: 18)
                .background(Circle().fill(Color.accentColor.opacity(0.25)))
            Text(text).appFont(12).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func sendButton(_ title: String, symbol: String, service: NSSharingService.Name) -> some View {
        Button {
            guard let file = share.fileURL else { return }
            NSSharingService(named: service)?.perform(withItems: [file])
        } label: {
            Label(title, systemImage: symbol)
        }
        .controlSize(.small)
        .disabled(share.fileURL == nil)
        .help("Send the USDZ file with \(title)")
    }

    /// A crisp QR code for `string`.
    static func qrCode(_ string: String) -> CGImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(string.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }
        let scaled = output.transformed(by: CGAffineTransform(scaleX: 10, y: 10))
        return CIContext().createCGImage(scaled, from: scaled.extent)
    }
}
