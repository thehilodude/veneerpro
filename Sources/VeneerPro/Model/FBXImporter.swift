import AppKit
import Foundation

/// Imports FBX by running Apple's own FBX → USD converter, the Autodesk FBX SDK-based plugin that
/// ships inside Reality Converter (free from developer.apple.com). The plugin exports a C entry point
/// `RealityConverter_FBXtoUSD(ConversionParameters *)`; it runs in a helper process (this same
/// executable with `--fbx-helper`) so a problematic file can't take down the app.
enum FBXImporter {
    static let realityConverterBundleID = "com.apple.RealityConverter"
    private static let pluginPath = "Contents/XPCServices/RealityConverterService.xpc/Contents/PlugIns/FBXConverter.bundle"
    private static let resultPrefix = "RC2-FBX-RESULT:"

    /// FBX converter plugins from every installed copy of Reality Converter.
    static var pluginCandidates: [URL] {
        var apps = NSWorkspace.shared.urlsForApplications(withBundleIdentifier: realityConverterBundleID)
        let standard = URL(fileURLWithPath: "/Applications/Reality Converter.app")
        if !apps.contains(standard) { apps.insert(standard, at: 0) }
        return apps.map { $0.appendingPathComponent(pluginPath) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    static var isAvailable: Bool { !pluginCandidates.isEmpty }

    // MARK: Converting (app side)

    /// Converts `fbx` to a binary USD file in a temporary folder.
    static func convert(_ fbx: URL) async throws -> URL {
        let candidates = pluginCandidates
        guard !candidates.isEmpty else { throw ConverterError.fbxUnavailable }
        guard let executable = Bundle.main.executableURL else { throw ConverterError.fbxFailed("Can't locate the converter helper.") }

        return try await Task.detached(priority: .userInitiated) { () throws -> URL in
            let fm = FileManager.default
            let work = fm.temporaryDirectory.appendingPathComponent("VeneerPro-FBX-\(UUID().uuidString)")
            try fm.createDirectory(at: work, withIntermediateDirectories: true)
            let source = stageMissingTextures(fbx, in: work)
            let output = work.appendingPathComponent(fbx.deletingPathExtension().lastPathComponent + ".usdc")

            var lastError = "No Reality Converter installation could load its FBX plugin."
            for plugin in candidates {
                let result = runHelper(executable, plugin: plugin, input: source, output: output)
                switch result {
                case .converted:
                    return output
                case let .failed(message):
                    // The file itself was rejected; another copy of the plugin won't do better.
                    throw ConverterError.fbxFailed(message)
                case let .pluginUnusable(message):
                    lastError = message // e.g. a copy macOS won't let other apps load; try the next one
                }
            }
            throw ConverterError.fbxFailed(lastError)
        }.value
    }

    private enum HelperResult {
        case converted
        case failed(String)
        case pluginUnusable(String)
    }

    private static func runHelper(_ executable: URL, plugin: URL, input: URL, output: URL) -> HelperResult {
        let process = Process()
        process.executableURL = executable
        process.arguments = ["--fbx-helper", plugin.path, input.path, output.path]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice // the converter is chatty about USD "coding errors"
        do { try process.run() } catch { return .pluginUnusable(error.localizedDescription) }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        let line = String(decoding: data, as: UTF8.self).split(separator: "\n")
            .last { $0.hasPrefix(resultPrefix) }.map { $0.dropFirst(resultPrefix.count) }
        guard let line, let json = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else {
            return .pluginUnusable("The FBX converter stopped unexpectedly (exit code \(process.terminationStatus)).")
        }
        if json["loaded"] as? Bool == false {
            return .pluginUnusable(json["message"] as? String ?? "The FBX plugin couldn't be loaded.")
        }
        let issues = (json["issues"] as? [String]) ?? []
        if json["status"] as? Bool == true, FileManager.default.fileExists(atPath: output.path) {
            return .converted
        }
        return .failed(issues.first ?? "The FBX file couldn't be converted.")
    }

    // MARK: Helper process

    /// Runs the conversion when launched as `--fbx-helper <plugin> <in.fbx> <out.usdc>`, then exits.
    static func runHelperIfRequested() {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--fbx-helper"), args.count > i + 3 else { return }
        func finish(_ result: [String: Any]) -> Never {
            let data = (try? JSONSerialization.data(withJSONObject: result)) ?? Data("{}".utf8)
            print(resultPrefix + String(decoding: data, as: UTF8.self))
            exit(0)
        }
        let plugin = URL(fileURLWithPath: args[i + 1])
        guard let bundle = Bundle(url: plugin), bundle.load() else {
            finish(["loaded": false, "message": "macOS wouldn't load the FBX plugin at \(plugin.path)."])
        }
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "RealityConverter_FBXtoUSD"),
              let parametersClass = NSClassFromString("ConversionParameters") as? NSObject.Type else {
            finish(["loaded": false, "message": "This version of Reality Converter's FBX plugin isn't supported."])
        }
        typealias Convert = @convention(c) (AnyObject) -> Unmanaged<AnyObject>?
        let convert = unsafeBitCast(symbol, to: Convert.self)

        let parameters = parametersClass.init()
        parameters.setValue(URL(fileURLWithPath: args[i + 2]), forKey: "sourceFBX")
        parameters.setValue(URL(fileURLWithPath: args[i + 3]), forKey: "outputUSD")
        parameters.setValue(NSMutableDictionary(), forKey: "materials")

        let result = convert(parameters)?.takeUnretainedValue() as? NSObject
        let issues = ((result?.value(forKey: "issues") as? [NSObject]) ?? []).compactMap { $0.value(forKey: "message") as? String }
        finish(["loaded": true, "status": (result?.value(forKey: "status") as? Bool) ?? false, "issues": issues])
    }

    // MARK: Missing textures

    /// FBX files often reference textures by a path from the author's machine (`/Users/sam/…/wood.png`)
    /// while the image ships next to the model, typically in a sibling `Textures` folder. If any
    /// referenced texture is missing but a file with the same name exists nearby, convert a staged
    /// copy of the FBX with those textures placed where its relative paths expect them.
    static func stageMissingTextures(_ fbx: URL, in work: URL) -> URL {
        let folder = fbx.deletingLastPathComponent()
        let references = textureReferences(in: fbx)
        guard !references.isEmpty else { return fbx }
        let fm = FileManager.default

        func exists(_ path: String) -> Bool {
            path.hasPrefix("/") ? fm.fileExists(atPath: path) : fm.fileExists(atPath: folder.appendingPathComponent(path).path)
        }
        // Group the absolute and relative forms of each texture by file name.
        let byName = Dictionary(grouping: references) { ($0 as NSString).lastPathComponent.lowercased() }
        let missing = byName.filter { !$0.value.contains(where: exists) }
        guard !missing.isEmpty else { return fbx }

        let nearby = nearbyImages(around: folder)
        var staged = false
        let stage = work.appendingPathComponent("staged")
        for (name, paths) in missing {
            guard let found = nearby[name] else { continue }
            for path in paths where !path.hasPrefix("/") && !path.contains("..") {
                let destination = stage.appendingPathComponent(path)
                try? fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? fm.removeItem(at: destination)
                if (try? fm.createSymbolicLink(at: destination, withDestinationURL: found)) != nil { staged = true }
            }
            // Also next to the FBX by bare name, which the FBX SDK tries as a fallback.
            let bare = stage.appendingPathComponent(found.lastPathComponent)
            if !fm.fileExists(atPath: bare.path), (try? fm.createDirectory(at: stage, withIntermediateDirectories: true)) != nil,
               (try? fm.createSymbolicLink(at: bare, withDestinationURL: found)) != nil {
                staged = true
            }
        }
        guard staged else { return fbx }
        let copy = stage.appendingPathComponent(fbx.lastPathComponent)
        guard (try? fm.createSymbolicLink(at: copy, withDestinationURL: fbx)) != nil else { return fbx }
        return copy
    }

    /// Image paths stored in the FBX (binary FBX keeps them as plain strings).
    private static func textureReferences(in fbx: URL) -> [String] {
        guard let data = try? Data(contentsOf: fbx, options: .mappedIfSafe) else { return [] }
        var references = Set<String>()
        var run: [UInt8] = []
        let pattern = try? NSRegularExpression(pattern: #"[^\x00-\x1f"*?<>|]*\.(png|jpe?g|tga|tiff?|bmp|psd|exr|hdr)"#,
                                              options: .caseInsensitive)
        func flush() {
            defer { run.removeAll(keepingCapacity: true) }
            guard run.count >= 5 else { return }
            let text = String(decoding: run, as: UTF8.self)
            for match in pattern?.matches(in: text, range: NSRange(text.startIndex..., in: text)) ?? [] {
                if let range = Range(match.range, in: text) {
                    references.insert(text[range].replacingOccurrences(of: "\\", with: "/").trimmingCharacters(in: .whitespaces))
                }
            }
        }
        for byte in data {
            if byte >= 0x20 && byte != 0x7F { run.append(byte) } else if !run.isEmpty { flush() }
        }
        flush()
        return Array(references)
    }

    /// Image files near the FBX (its folder, the parent, and the grandparent, a few levels deep), by lowercased name.
    private static func nearbyImages(around folder: URL) -> [String: URL] {
        var images: [String: URL] = [:]
        let roots = [folder, folder.deletingLastPathComponent(), folder.deletingLastPathComponent().deletingLastPathComponent()]
        var visited = 0
        for root in roots {
            guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil,
                                                                  options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { continue }
            for case let url as URL in enumerator {
                if enumerator.level > 4 { enumerator.skipDescendants(); continue }
                visited += 1
                if visited > 20_000 { return images }
                let name = url.lastPathComponent.lowercased()
                if LibraryMaterial.imageExtensions.contains(url.pathExtension.lowercased()) || url.pathExtension.lowercased() == "psd",
                   images[name] == nil {
                    images[name] = url
                }
            }
        }
        return images
    }
}
