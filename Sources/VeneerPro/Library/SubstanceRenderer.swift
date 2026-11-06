import CryptoKit
import Foundation

/// Renders Adobe Substance archives (`.sbsar`, as downloaded from Substance 3D Assets) to texture maps
/// with Adobe's `sbsrender` command-line tool, which ships with Substance 3D Designer and the Substance
/// Automation Toolkit. Substance archives are compiled procedural graphs: only Adobe's engine can
/// evaluate them, so without `sbsrender` they can be browsed but not applied.
enum SubstanceRenderer {
    enum Failure: LocalizedError {
        case notInstalled
        case failed(String)

        var errorDescription: String? {
            switch self {
            case .notInstalled:
                "Substance archives (.sbsar) need Adobe’s Substance renderer, which comes with Adobe Substance 3D Designer. Install Designer, or export the material’s texture maps (PNG) from a Substance app and add that folder to the library instead."
            case let .failed(message):
                "Substance couldn’t render this material. \(message)"
            }
        }
    }

    /// Where `sbsrender` is: a path saved in the "SubstanceRendererPath" default, or a Substance app
    /// or Automation Toolkit install.
    static var executable: URL? {
        let fm = FileManager.default
        if let custom = UserDefaults.standard.string(forKey: "SubstanceRendererPath"), fm.isExecutableFile(atPath: custom) {
            return URL(fileURLWithPath: custom)
        }
        var candidates: [String] = []
        let apps = (try? fm.contentsOfDirectory(atPath: "/Applications")) ?? []
        for name in apps where name.localizedCaseInsensitiveContains("Substance") {
            let base = "/Applications/" + name
            if name.hasSuffix(".app") {
                candidates.append(base + "/Contents/MacOS/sbsrender")
            } else {
                // A folder holding the app, or the Automation Toolkit.
                candidates.append(base + "/sbsrender")
                for inner in (try? fm.contentsOfDirectory(atPath: base)) ?? [] where inner.hasSuffix(".app") {
                    candidates.append(base + "/" + inner + "/Contents/MacOS/sbsrender")
                }
            }
        }
        return candidates.first(where: fm.isExecutableFile(atPath:)).map(URL.init(fileURLWithPath:))
    }

    static var isAvailable: Bool { !Distribution.isAppStore && executable != nil }

    /// Renders every output of `archive` at 2^`sizeLog2` pixels (cached by file and size) and returns
    /// the image files, named `<archive>_<output>.png` so the map classifier can sort them.
    static func render(_ archive: URL, sizeLog2: Int) async throws -> [URL] {
        guard let tool = executable else { throw Failure.notInstalled }
        let folder = cacheFolder(for: archive, sizeLog2: sizeLog2)
        let existing = images(in: folder)
        if !existing.isEmpty { return existing }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        let process = Process()
        process.executableURL = tool
        process.arguments = [
            "render",
            "--input", archive.path,
            "--output-path", folder.path,
            "--output-name", "{inputName}_{outputNodeName}",
            "--output-format", "png",
            // No shell is involved, so the $ needs no escaping.
            "--set-value", "$outputsize@\(sizeLog2),\(sizeLog2)",
        ]
        let errors = Pipe()
        process.standardError = errors
        process.standardOutput = FileHandle.nullDevice
        // The handler is attached before launch so a fast render can't finish unnoticed.
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            process.terminationHandler = { _ in continuation.resume() }
            do {
                try process.run()
            } catch {
                process.terminationHandler = nil
                continuation.resume(throwing: error)
            }
        }
        let rendered = images(in: folder)
        guard process.terminationStatus == 0, !rendered.isEmpty else {
            let message = String(data: errors.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            try? FileManager.default.removeItem(at: folder)
            throw Failure.failed(message.isEmpty ? "sbsrender exited with status \(process.terminationStatus)." : message)
        }
        return rendered
    }

    /// ~/Library/Caches/VeneerPro/Substance/<hash of path + modification date>-<size>/
    private static func cacheFolder(for archive: URL, sizeLog2: Int) -> URL {
        let modified = (try? archive.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)?
            .timeIntervalSince1970 ?? 0
        let digest = SHA256.hash(data: Data("\(archive.path)|\(modified)".utf8))
        let key = digest.prefix(8).map { String(format: "%02x", $0) }.joined()
        return FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("VeneerPro/Substance/\(key)-\(sizeLog2)", isDirectory: true)
    }

    private static func images(in folder: URL) -> [URL] {
        ((try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [])
            .filter { LibraryMaterial.imageExtensions.contains($0.pathExtension.lowercased()) }
    }
}
