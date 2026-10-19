import AppKit
import Darwin
import Network
import Observation
import SceneKit

/// Shares the selected model with iPhones and iPads on the same Wi-Fi — no app or App Store needed.
///
/// A tiny web server on the Mac serves a page (reached by scanning a QR code) with a "View in AR" link
/// that opens the model in AR Quick Look. The model is re-exported shortly after every edit, and the
/// page notices and offers the latest version. Links carry a random token and stop working when
/// sharing stops; nothing leaves the local network.
@MainActor
@Observable
final class LocalShare {
    enum Status: Equatable {
        case idle
        case starting
        case ready
        case failed(String)
    }

    private(set) var status: Status = .idle
    /// The link to open on the phone (encoded in the QR code).
    private(set) var pageURL: URL?
    private(set) var isExporting = false
    private(set) var lastUpdated: Date?
    /// The exported file being served, for AirDrop / Messages.
    private(set) var fileURL: URL?
    private(set) weak var document: ModelDocument?

    var isActive: Bool { status != .idle }

    @ObservationIgnored private var listener: NWListener?
    @ObservationIgnored private var folder: URL?
    @ObservationIgnored private var token = ""
    @ObservationIgnored private var version = 0
    @ObservationIgnored private var thumbnail: Data?
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var exportTask: Task<Void, Never>?
    @ObservationIgnored private var pendingExport = false
    /// Takes a picture of the viewport for the page.
    @ObservationIgnored var snapshot: (() -> NSImage?)?

    // MARK: Lifecycle

    func start(_ document: ModelDocument) {
        stop()
        self.document = document
        status = .starting
        token = Self.randomToken()
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("VeneerPro-Share-\(token)")
        try? FileManager.default.createDirectory(at: folder!, withIntermediateDirectories: true)

        do {
            let listener = try NWListener(using: .tcp, on: .any)
            listener.newConnectionHandler = { [weak self] connection in
                Task { @MainActor in self?.serve(connection) }
            }
            listener.stateUpdateHandler = { [weak self] state in
                Task { @MainActor in self?.listenerChanged(state) }
            }
            listener.start(queue: .main)
            self.listener = listener
        } catch {
            status = .failed(error.localizedDescription)
            return
        }
        observeEdits()
        scheduleExport(delay: 0)
    }

    func stop() {
        listener?.cancel()
        listener = nil
        exportTask?.cancel()
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        if let folder { try? FileManager.default.removeItem(at: folder) }
        folder = nil
        fileURL = nil
        pageURL = nil
        lastUpdated = nil
        thumbnail = nil
        document = nil
        status = .idle
    }

    private func listenerChanged(_ state: NWListener.State) {
        switch state {
        case .ready:
            guard let port = listener?.port?.rawValue else { return }
            guard let host = Self.localAddress() else {
                status = .failed("Connect this Mac to Wi-Fi or Ethernet to share on the local network.")
                return
            }
            pageURL = URL(string: "http://\(host):\(port)/s/\(token)/")
            status = .ready
        case let .failed(error):
            status = .failed(error.localizedDescription)
        default:
            break
        }
    }

    // MARK: Keeping the file current

    private func observeEdits() {
        let center = NotificationCenter.default
        for name in [Notification.Name.materialsDidChange, .sceneDidChange] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    if name == .sceneDidChange, (note.object as AnyObject?) !== self.document { return }
                    self.scheduleExport(delay: 1.0)
                }
            })
        }
    }

    /// Re-exports once edits pause; edits during an export queue one more.
    private func scheduleExport(delay: Double) {
        if isExporting {
            pendingExport = true
            return
        }
        exportTask?.cancel()
        exportTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, let self else { return }
            await self.export()
        }
    }

    private func export() async {
        guard let document, let folder else { return }
        isExporting = true
        version += 1
        let url = folder.appendingPathComponent("\(Self.safeName(document.name))-\(version).usdz")
        do {
            _ = try await Exporter.export(document, to: url, options: ExportOptions(binary: true, validate: false))
            if let old = fileURL, old != url { try? FileManager.default.removeItem(at: old) }
            fileURL = url
            lastUpdated = Date()
            if let image = snapshot?(), let png = Self.png(image, maxSize: 900) { thumbnail = png }
        } catch {
            status = .failed(error.localizedDescription)
        }
        isExporting = false
        if pendingExport {
            pendingExport = false
            scheduleExport(delay: 0.3)
        }
    }

    // MARK: HTTP

    private func serve(_ connection: NWConnection) {
        connection.start(queue: .main)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) { [weak self] data, _, _, _ in
            Task { @MainActor in
                guard let self else { connection.cancel(); return }
                let request = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
                let path = request.split(separator: " ").dropFirst().first.map(String.init) ?? "/"
                self.respond(to: path, on: connection)
            }
        }
    }

    private func respond(to rawPath: String, on connection: NWConnection) {
        let path = rawPath.split(separator: "?").first.map(String.init) ?? rawPath
        let prefix = "/s/\(token)/"
        guard !token.isEmpty, path.hasPrefix(prefix) else {
            return send(connection, status: "404 Not Found", type: "text/plain", body: Data("Not found".utf8))
        }
        switch String(path.dropFirst(prefix.count)) {
        case "":
            send(connection, status: "200 OK", type: "text/html; charset=utf-8", body: Data(page().utf8))
        case "model.usdz":
            guard let fileURL, let data = try? Data(contentsOf: fileURL, options: .mappedIfSafe) else {
                return send(connection, status: "503 Service Unavailable", type: "text/plain", body: Data("Still preparing the model".utf8))
            }
            send(connection, status: "200 OK", type: "model/vnd.usdz+zip", body: data,
                 extraHeaders: ["Content-Disposition": "inline; filename=\"\(Self.safeName(document?.name ?? "Model")).usdz\""])
        case "thumb.png":
            send(connection, status: thumbnail == nil ? "404 Not Found" : "200 OK", type: "image/png", body: thumbnail ?? Data())
        case "version":
            let json = "{\"version\":\(fileURL == nil ? 0 : version),\"exporting\":\(isExporting)}"
            send(connection, status: "200 OK", type: "application/json", body: Data(json.utf8))
        default:
            send(connection, status: "404 Not Found", type: "text/plain", body: Data("Not found".utf8))
        }
    }

    private func send(_ connection: NWConnection, status: String, type: String, body: Data, extraHeaders: [String: String] = [:]) {
        var head = "HTTP/1.1 \(status)\r\nContent-Type: \(type)\r\nContent-Length: \(body.count)\r\n"
        head += "Cache-Control: no-store\r\nConnection: close\r\n"
        for (key, value) in extraHeaders { head += "\(key): \(value)\r\n" }
        head += "\r\n"
        connection.send(content: Data(head.utf8) + body, completion: .contentProcessed { _ in connection.cancel() })
    }

    /// The phone's landing page: a big tappable preview that opens AR Quick Look, and a watcher that
    /// offers the newest version after edits on the Mac.
    private func page() -> String {
        let name = Self.html(document?.name ?? "Model")
        let v = fileURL == nil ? 0 : version
        return """
        <!doctype html>
        <html><head><meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
        <title>\(name) · Veneer Pro</title>
        <style>
          :root { color-scheme: dark; }
          body { margin: 0; font: 16px -apple-system, system-ui, sans-serif; background: #161617; color: #f2f2f2;
                 display: flex; flex-direction: column; align-items: center; min-height: 100vh; }
          main { width: min(92vw, 520px); padding: 28px 0 40px; text-align: center; }
          .brand { font-size: 13px; color: #8d8d92; letter-spacing: .02em; }
          h1 { font-size: 26px; margin: 6px 0 20px; }
          a.ar { display: block; border-radius: 22px; overflow: hidden; background: #232325; box-shadow: 0 12px 40px #0008; }
          a.ar img { display: block; width: 100%; aspect-ratio: 4 / 3; object-fit: cover; }
          .button { display: block; margin-top: 18px; padding: 15px; border-radius: 14px; background: #2f7cf6;
                    color: white; font-weight: 600; text-decoration: none; font-size: 17px; }
          .note { margin-top: 14px; color: #8d8d92; font-size: 13px; line-height: 1.4; }
          #update { display: none; margin-top: 14px; padding: 12px; border-radius: 12px; background: #2b2b2e; color: #ffd166; }
          #update a { color: #ffd166; font-weight: 600; }
        </style></head>
        <body><main>
          <div class="brand">Shared from Veneer Pro</div>
          <h1>\(name)</h1>
          <a class="ar" rel="ar" href="model.usdz?v=\(v)#allowsContentScaling=1">
            <img src="thumb.png?v=\(v)" alt="\(name)" onerror="this.style.minHeight='200px'">
          </a>
          <a class="button" rel="ar" href="model.usdz?v=\(v)#allowsContentScaling=1"><img src="thumb.png?v=\(v)" width="1" height="1" style="opacity:0;position:absolute" alt="">View in AR</a>
          <div id="update">The model was updated on the Mac. <a href="./">Load the latest version</a></div>
          <div class="note">Opens in AR Quick Look on iPhone and iPad.<br>Keep this page open — it tells you when there’s a newer version.</div>
        </main>
        <script>
          const shown = \(v);
          setInterval(async () => {
            try {
              const r = await fetch('version', { cache: 'no-store' });
              const j = await r.json();
              if (j.version > shown) document.getElementById('update').style.display = 'block';
            } catch (e) {}
          }, 3000);
        </script>
        </body></html>
        """
    }

    // MARK: Helpers

    /// The Mac's IPv4 address on Wi-Fi or Ethernet.
    private static func localAddress() -> String? {
        var addresses: [(name: String, ip: String)] = []
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return nil }
        defer { freeifaddrs(list) }
        for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let entry = pointer.pointee
            guard let address = entry.ifa_addr, address.pointee.sa_family == UInt8(AF_INET),
                  (Int32(entry.ifa_flags) & IFF_UP) != 0, (Int32(entry.ifa_flags) & IFF_LOOPBACK) == 0 else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(address, socklen_t(address.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else { continue }
            let ip = String(cString: host)
            guard !ip.hasPrefix("169.254.") else { continue }
            addresses.append((String(cString: entry.ifa_name), ip))
        }
        // Prefer the built-in Wi-Fi/Ethernet ports over VPNs and bridges.
        return (addresses.first { $0.name == "en0" } ?? addresses.first { $0.name.hasPrefix("en") } ?? addresses.first)?.ip
    }

    private static func randomToken() -> String {
        let alphabet = Array("abcdefghjkmnpqrstuvwxyz23456789")
        return String((0..<10).map { _ in alphabet.randomElement()! })
    }

    private static func safeName(_ name: String) -> String {
        let cleaned = name.components(separatedBy: CharacterSet(charactersIn: "/\\:?%*|\"<>")).joined(separator: "-")
        return cleaned.isEmpty ? "Model" : cleaned
    }

    private static func html(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }

    private static func png(_ image: NSImage, maxSize: CGFloat) -> Data? {
        let scale = min(1, maxSize / max(image.size.width, image.size.height, 1))
        let size = NSSize(width: image.size.width * scale, height: image.size.height * scale)
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width), pixelsHigh: Int(size.height),
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(in: NSRect(origin: .zero, size: size))
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:])
    }
}
