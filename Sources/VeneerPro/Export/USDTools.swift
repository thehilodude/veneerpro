import Foundation
#if os(iOS)
import USDKit
#endif

/// Optional helpers backed by the USD command-line tools that ship with macOS
/// (`/usr/bin/usdcat`, `/usr/bin/usdchecker`). Everything degrades gracefully without them.
enum USDTools {
    static let usdcat = URL(fileURLWithPath: "/usr/bin/usdcat")
    static let usdchecker = URL(fileURLWithPath: "/usr/bin/usdchecker")

    #if os(iOS)
    static var canConvertToBinary: Bool { false }
    static var canValidate: Bool { false }
    #else
    static var canConvertToBinary: Bool { FileManager.default.isExecutableFile(atPath: usdcat.path) }
    static var canValidate: Bool { FileManager.default.isExecutableFile(atPath: usdchecker.path) }
    #endif

    @discardableResult
    static func run(_ tool: URL, _ arguments: [String]) -> (status: Int32, output: String) {
        #if os(iOS)
        return (-1, "The USD command-line tools are only on the Mac.")
        #else
        let process = Process()
        process.executableURL = tool
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do { try process.run() } catch { return (-1, error.localizedDescription) }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
        #endif
    }

    /// Reads stage metadata (units, up axis, copyright) without loading geometry.
    static func readMetadata(url: URL) -> StageMetadata? {
        guard ["usdz", "usd", "usda", "usdc"].contains(url.pathExtension.lowercased()) else { return nil }
        #if os(iOS)
        // No usdcat here. USDKit gives the units and up axis (not the copyright).
        guard let stage = try? USDStage.open(url, loadingPayloads: .none) else { return nil }
        var metadata = StageMetadata()
        if stage.hasAuthoredMetersPerUnit { metadata.metersPerUnit = stage.metersPerUnit }
        if ["Y", "Z"].contains(stage.upAxis.string) { metadata.upAxis = stage.upAxis.string }
        return metadata
        #else
        guard canConvertToBinary else { return nil }
        let result = run(usdcat, ["--layerMetadata", url.path])
        guard result.status == 0 else { return nil }
        return parseMetadata(result.output)
        #endif
    }

    static func parseMetadata(_ text: String) -> StageMetadata {
        var metadata = StageMetadata()
        func capture(_ pattern: String) -> String? {
            guard let regex = try? NSRegularExpression(pattern: pattern),
                  let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
                  let range = Range(match.range(at: 1), in: text) else { return nil }
            return String(text[range])
        }
        if let units = capture(#"metersPerUnit\s*=\s*([0-9.eE+-]+)"#), let value = Double(units) {
            metadata.metersPerUnit = value
        }
        if let axis = capture(#"upAxis\s*=\s*"([YZ])""#) {
            metadata.upAxis = axis
        }
        // usdcat single-quotes strings that contain double quotes.
        if let copyright = capture(#"string copyright\s*=\s*"((?:[^"\\]|\\.)*)""#)
            ?? capture(#"string copyright\s*=\s*'((?:[^'\\]|\\.)*)'"#) {
            metadata.copyright = copyright
                .replacingOccurrences(of: #"\""#, with: "\"")
                .replacingOccurrences(of: #"\'"#, with: "'")
        }
        return metadata
    }

    /// Converts a text layer to the binary crate format.
    static func convertToBinary(_ usda: URL, output: URL) throws {
        let result = run(usdcat, [usda.path, "-o", output.path])
        guard result.status == 0, FileManager.default.fileExists(atPath: output.path) else {
            throw ConverterError.exportFailed("usdcat: \(result.output)")
        }
    }

    /// Runs the ARKit compliance checks, returning one line per issue.
    static func validate(_ usdz: URL) -> [String] {
        guard canValidate else { return [] }
        let result = run(usdchecker, ["--arkit", usdz.path])
        guard result.status != 0 else { return [] }
        return result.output
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.hasPrefix("Error") || $0.hasPrefix("Warning") || $0.contains("(fails") }
    }
}
