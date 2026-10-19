import Foundation

/// A file stored inside a USDZ package. SceneKit refers to these with URLs like
/// `file:///path/model.usdz?offset=50458368&size=5268186`; the bytes sit uncompressed at that offset.
struct PackagedFile {
    let package: URL
    let offset: UInt64
    let size: Int

    init?(_ url: URL) {
        guard url.isFileURL,
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
              let offset = items.first(where: { $0.name == "offset" })?.value.flatMap(UInt64.init),
              let size = items.first(where: { $0.name == "size" })?.value.flatMap(Int.init) else { return nil }
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        components.query = nil
        guard let package = components.url else { return nil }
        self.package = package
        self.offset = offset
        self.size = size
    }

    func read() -> Data? {
        guard let handle = try? FileHandle(forReadingFrom: package) else { return nil }
        defer { try? handle.close() }
        try? handle.seek(toOffset: offset)
        guard let data = try? handle.read(upToCount: size), data.count == size else { return nil }
        return data
    }

    /// The file's path inside the package (e.g. `1/D_Wood_Walnut_01_DIFF_1.jpg`), from the zip directory.
    var entryName: String? { USDZDirectory.entries(of: package)[offset] }
}

/// Maps data offsets to file names for a USDZ (zip) package, cached per package.
enum USDZDirectory {
    private static let lock = NSLock()
    private static var cache: [URL: [UInt64: String]] = [:]

    static func entries(of package: URL) -> [UInt64: String] {
        lock.lock()
        defer { lock.unlock() }
        if let cached = cache[package] { return cached }
        let result = read(package)
        cache[package] = result
        return result
    }

    private static func read(_ package: URL) -> [UInt64: String] {
        guard let handle = try? FileHandle(forReadingFrom: package),
              let fileSize = try? handle.seekToEnd() else { return [:] }
        defer { try? handle.close() }
        func bytes(at offset: UInt64, _ count: Int) -> Data? {
            guard (try? handle.seek(toOffset: offset)) != nil else { return nil }
            return try? handle.read(upToCount: count)
        }

        // Find the end-of-central-directory record (it may be followed by a comment).
        let tailSize = Int(min(fileSize, 65_557))
        guard let tail = bytes(at: fileSize - UInt64(tailSize), tailSize) else { return [:] }
        let t = [UInt8](tail)
        guard t.count >= 22, let eocd = stride(from: t.count - 22, through: 0, by: -1).first(where: {
            t[$0] == 0x50 && t[$0 + 1] == 0x4B && t[$0 + 2] == 0x05 && t[$0 + 3] == 0x06
        }) else { return [:] }
        let count = Int(t.u16(eocd + 10))
        let directorySize = Int(t.u32(eocd + 12))
        let directoryOffset = UInt64(t.u32(eocd + 16))
        guard let dirData = bytes(at: directoryOffset, directorySize) else { return [:] }
        let d = [UInt8](dirData)

        var result: [UInt64: String] = [:]
        var p = 0
        for _ in 0..<count {
            guard p + 46 <= d.count, d.u32(p) == 0x0201_4B50 else { break }
            let nameLength = Int(d.u16(p + 28)), extraLength = Int(d.u16(p + 30)), commentLength = Int(d.u16(p + 32))
            let localOffset = UInt64(d.u32(p + 42))
            guard p + 46 + nameLength <= d.count else { break }
            let name = String(decoding: d[(p + 46)..<(p + 46 + nameLength)], as: UTF8.self)
            // Data starts after the local header, whose extra field can differ from the central one.
            if let local = bytes(at: localOffset, 30).map({ [UInt8]($0) }), local.count == 30, local.u32(0) == 0x0403_4B50 {
                let dataOffset = localOffset + 30 + UInt64(local.u16(26)) + UInt64(local.u16(28))
                result[dataOffset] = name
            }
            p += 46 + nameLength + extraLength + commentLength
        }
        return result
    }
}

private extension [UInt8] {
    func u16(_ i: Int) -> UInt16 { UInt16(self[i]) | UInt16(self[i + 1]) << 8 }
    func u32(_ i: Int) -> UInt32 { UInt32(u16(i)) | UInt32(u16(i + 2)) << 16 }
}
