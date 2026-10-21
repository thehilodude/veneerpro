import AppKit
import Darwin
import Network
import Observation
import SceneKit
import SystemConfiguration

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
    @ObservationIgnored private var iconPNG: Data?
    /// "W 30.8 · D 43.2 · H 62.6 cm" and the material count, shown on the page.
    @ObservationIgnored private var sizeText = ""
    @ObservationIgnored private var materialCount = 0
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
            if iconPNG == nil { iconPNG = Self.png(NSApp.applicationIconImage, maxSize: 128) }
            materialCount = document.materials.count
            if let size = document.size() {
                func cm(_ m: Float) -> String { let v = Double(m) * 100; return v >= 100 ? String(format: "%.0f", v) : String(format: "%.1f", v) }
                sizeText = "W \(cm(size.x)) · D \(cm(size.z)) · H \(cm(size.y)) cm"
            }
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
        case "icon.png":
            send(connection, status: iconPNG == nil ? "404 Not Found" : "200 OK", type: "image/png", body: iconPNG ?? Data())
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

    /// The phone's landing page, styled like the desktop app: dark canvas, a rounded preview card (Safari adds its
    /// AR badge to the image) with a status capsule, the size readout, and an accent "View in AR" button that opens AR Quick Look.
    /// It polls for newer versions after edits on the Mac.
    private func page() -> String {
        let name = Self.html(document?.name ?? "Model")
        let v = fileURL == nil ? 0 : version
        let size = Self.html(sizeText)
        let materials = materialCount == 1 ? "1 material" : "\(materialCount) materials"
        let mac = Self.html(Self.computerName)
        let ar = "model.usdz?v=\(v)#allowsContentScaling=1"
        // SF-style glyphs as inline SVG (AR cube, and a refresh arrow).
        let arIcon = #"<svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M12 2 3 7v10l9 5 9-5V7z"/><path d="M3 7l9 5 9-5M12 12v10"/></svg>"#
        return """
        <!doctype html>
        <html><head><meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
        <meta name="theme-color" content="#131313">
        <title>\(name) · Veneer Pro</title>
        <style>
          :root {
            color-scheme: dark;
            --canvas: #131313; --panel: #222223; --control: rgba(255,255,255,.075); --hairline: rgba(255,255,255,.08);
            --text: #f2f2f2; --secondary: rgba(235,235,245,.6); --tertiary: rgba(235,235,245,.32);
            --accent: #0a84ff; --red: #e63228; --yellow: #ffc107; --blue: #1f5fd8;
          }
          * { box-sizing: border-box; -webkit-tap-highlight-color: transparent; }
          body { margin: 0; background: var(--canvas); color: var(--text);
                 font: 15px -apple-system, BlinkMacSystemFont, system-ui, sans-serif; -webkit-font-smoothing: antialiased; }
          main { max-width: 560px; margin: 0 auto; padding: max(16px, env(safe-area-inset-top)) 16px max(28px, env(safe-area-inset-bottom)); }
          header { display: flex; align-items: center; gap: 10px; margin: 4px 2px 18px; }
          header img { width: 34px; height: 34px; border-radius: 8px; }
          header .app { font-weight: 700; font-size: 15px; }
          header .from { font-size: 12px; color: var(--secondary); }
          .panel { background: var(--panel); border: 1px solid var(--hairline); border-radius: 16px; overflow: hidden; }
          .title { padding: 16px 16px 12px; }
          h1 { font-size: 22px; margin: 0 0 8px; letter-spacing: -.01em; }
          .chips { display: flex; flex-wrap: wrap; gap: 6px; }
          .chip { font-size: 12px; font-weight: 500; padding: 4px 9px; border-radius: 999px; background: var(--control);
                  color: var(--secondary); font-variant-numeric: tabular-nums; }
          .canvas { position: relative; margin: 0 10px; border-radius: 12px; overflow: hidden; background: var(--canvas);
                    border: 1px solid var(--hairline); }
          .canvas a, .canvas img { display: block; width: 100%; }
          .canvas img { aspect-ratio: 4 / 3; object-fit: cover; }
          .status { position: absolute; left: 10px; top: 10px; display: flex; align-items: center; gap: 6px; padding: 5px 10px;
                    border-radius: 999px; font-size: 11.5px; font-weight: 500; color: var(--secondary);
                    background: rgba(40,40,42,.55); -webkit-backdrop-filter: blur(18px); backdrop-filter: blur(18px);
                    border: 1px solid rgba(255,255,255,.1); }
          .dot { width: 7px; height: 7px; border-radius: 50%; background: #30d158; }
          .dot.busy { background: var(--yellow); animation: pulse 1s ease-in-out infinite; }
          @keyframes pulse { 50% { opacity: .35; } }
          .actions { padding: 12px 10px 10px; }
          .button { display: flex; align-items: center; justify-content: center; gap: 8px; padding: 14px; border-radius: 12px;
                    background: var(--accent); color: white; font-weight: 600; font-size: 16px; text-decoration: none; }
          .button img { position: absolute; width: 1px; height: 1px; opacity: 0; }
          .steps { display: grid; grid-template-columns: 1fr 1fr 1fr; gap: 6px; margin: 14px 0 0; }
          .step { background: var(--control); border-radius: 11px; padding: 10px 6px; text-align: center; font-size: 11.5px; color: var(--secondary); }
          .step b { display: block; font-size: 15px; margin-bottom: 3px; }
          .button.update { background: var(--yellow); color: #1a1a1a; animation: glow 1.6s ease-in-out infinite; }
          @keyframes glow { 50% { box-shadow: 0 0 0 5px rgba(255,193,7,.3); } }
          .notice { display: none; margin: 0 2px 10px; font-size: 12.5px; color: var(--secondary); text-align: center; }
          footer { margin-top: 16px; text-align: center; font-size: 11.5px; line-height: 1.5; color: var(--tertiary); }
        </style></head>
        <body><main>
          <header>
            <img src="icon.png" alt="">
            <div><div class="app">Veneer Pro</div><div class="from">Shared from \(mac)</div></div>
          </header>
          <section class="panel">
            <div class="title">
              <h1>\(name)</h1>
              <div class="chips">\(size.isEmpty ? "" : "<span class=\"chip\">\(size)</span>")<span class="chip">\(materials)</span></div>
            </div>
            <div class="canvas">
              <a id="preview" rel="ar" href="\(ar)"><img src="thumb.png?v=\(v)" alt="\(name)" onerror="this.style.minHeight='220px'"></a>
              <div class="status"><span class="dot" id="dot"></span><span id="state">Up to date</span></div>
            </div>
            <div class="actions">
              <div class="notice" id="notice">A newer version is ready on the Mac.</div>
              <a class="button" id="action" rel="ar" href="\(ar)"><img src="thumb.png?v=\(v)" alt="">\(arIcon) View in AR</a>
            </div>
          </section>
          <div class="steps">
            <div class="step"><b style="color: var(--red)">1</b>Tap View in AR</div>
            <div class="step"><b style="color: var(--yellow)">2</b>Place it on a surface</div>
            <div class="step"><b style="color: var(--blue)">3</b>Pinch to scale, drag to move</div>
          </div>
          <footer>Opens in AR Quick Look at true size.<br>Keep this page open — the button changes when there’s a newer version from the Mac.</footer>
        </main>
        <script>
          const shown = \(v);
          let updated = false;
          const refreshIcon = '<svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.2" stroke-linecap="round" stroke-linejoin="round"><path d="M21 12a9 9 0 1 1-2.64-6.36"/><path d="M21 3v6h-6"/></svg>';
          setInterval(async () => {
            try {
              const r = await fetch('version', { cache: 'no-store' });
              const j = await r.json();
              const newer = j.version > shown;
              if (newer && !updated) {
                // The main button becomes the way to the new version, and the old one can't be opened in AR.
                updated = true;
                for (const link of [document.getElementById('action'), document.getElementById('preview')]) {
                  link.removeAttribute('rel');
                  link.href = './';
                }
                const action = document.getElementById('action');
                action.classList.add('update');
                action.innerHTML = refreshIcon + ' Load New Version';
                document.getElementById('notice').style.display = 'block';
              }
              document.getElementById('dot').className = j.exporting ? 'dot busy' : 'dot';
              document.getElementById('state').textContent = j.exporting ? 'Updating…' : (newer ? 'Update ready' : 'Up to date');
            } catch (e) {
              document.getElementById('state').textContent = 'Mac not reachable';
              document.getElementById('dot').className = 'dot busy';
            }
          }, 3000);
        </script>
        </body></html>
        """
    }

    // MARK: Helpers

    /// The Mac's name ("Kevin's MacBook Pro"), read from System Configuration (fast, unlike Host lookups).
    private static let computerName: String = (SCDynamicStoreCopyComputerName(nil, nil) as String?) ?? "your Mac"

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
