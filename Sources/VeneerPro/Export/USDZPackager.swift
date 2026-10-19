import Foundation

/// Writes a USDZ package: an uncompressed ZIP whose file data is 64-byte aligned,
/// with the root layer as the first entry.
enum USDZPackager {
    struct Entry {
        let path: String
        let data: Data
    }

    static func write(_ entries: [Entry], to url: URL) throws {
        var archive = Data()
        var central = Data()

        for entry in entries {
            let name = Data(entry.path.utf8)
            let crc = CRC32.checksum(entry.data)
            let size = UInt32(entry.data.count)
            let headerOffset = UInt32(archive.count)

            // Pad with an extra field so the file data starts on a 64-byte boundary.
            let unpadded = archive.count + 30 + name.count
            var padding = (64 - unpadded % 64) % 64
            if padding > 0 && padding < 4 { padding += 64 }

            archive.append(le32: 0x0403_4B50)
            archive.append(le16: 20)        // version needed
            archive.append(le16: 0)         // flags
            archive.append(le16: 0)         // stored, no compression
            archive.append(le16: 0)         // mod time
            archive.append(le16: 0x21)      // mod date (1980-01-01)
            archive.append(le32: crc)
            archive.append(le32: size)
            archive.append(le32: size)
            archive.append(le16: UInt16(name.count))
            archive.append(le16: UInt16(padding))
            archive.append(name)
            if padding > 0 {
                archive.append(le16: 0x1986)
                archive.append(le16: UInt16(padding - 4))
                archive.append(Data(count: padding - 4))
            }
            assert(archive.count % 64 == 0)
            archive.append(entry.data)

            central.append(le32: 0x0201_4B50)
            central.append(le16: 20)        // version made by
            central.append(le16: 20)        // version needed
            central.append(le16: 0)
            central.append(le16: 0)
            central.append(le16: 0)
            central.append(le16: 0x21)
            central.append(le32: crc)
            central.append(le32: size)
            central.append(le32: size)
            central.append(le16: UInt16(name.count))
            central.append(le16: 0)         // extra length
            central.append(le16: 0)         // comment length
            central.append(le16: 0)         // disk number
            central.append(le16: 0)         // internal attributes
            central.append(le32: 0)         // external attributes
            central.append(le32: headerOffset)
            central.append(name)
        }

        let centralOffset = UInt32(archive.count)
        archive.append(central)
        archive.append(le32: 0x0605_4B50)
        archive.append(le16: 0)
        archive.append(le16: 0)
        archive.append(le16: UInt16(entries.count))
        archive.append(le16: UInt16(entries.count))
        archive.append(le32: UInt32(central.count))
        archive.append(le32: centralOffset)
        archive.append(le16: 0)

        try archive.write(to: url, options: .atomic)
    }
}

enum CRC32 {
    private static let table: [UInt32] = (0..<256).map { i in
        var c = UInt32(i)
        for _ in 0..<8 { c = c & 1 != 0 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1 }
        return c
    }

    static func checksum(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        data.withUnsafeBytes { bytes in
            for byte in bytes { crc = table[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8) }
        }
        return crc ^ 0xFFFF_FFFF
    }
}

private extension Data {
    mutating func append(le16 value: UInt16) { Swift.withUnsafeBytes(of: value.littleEndian) { append(contentsOf: $0) } }
    mutating func append(le32 value: UInt32) { Swift.withUnsafeBytes(of: value.littleEndian) { append(contentsOf: $0) } }
}
