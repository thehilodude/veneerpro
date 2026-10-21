import AppKit
import Foundation

/// A material in an online CC0 library, before it's downloaded.
struct OnlineAsset: Hashable {
    let provider: OnlineLibrary.Provider
    let id: String
    let thumbnail: URL?
}

/// Browses and downloads free CC0 materials from Poly Haven and ambientCG.
///
/// Listings are fetched once a day and cached; materials are downloaded only when applied — just the
/// maps Veneer Pro uses, at the chosen resolution — into a "Downloaded" folder that works offline.
/// Every request identifies the app (Poly Haven's API terms ask for this), and the library shows a
/// "Powered by Poly Haven" credit while browsing it.
enum OnlineLibrary {
    enum Provider: String, CaseIterable, Hashable {
        case polyHaven = "polyhaven"
        case ambientCG = "ambientcg"

        var displayName: String { self == .polyHaven ? "Poly Haven" : "ambientCG" }
        var credit: String { self == .polyHaven ? "Powered by Poly Haven" : "Materials from ambientCG" }
        var website: URL { URL(string: self == .polyHaven ? "https://polyhaven.com/textures" : "https://ambientcg.com")! }
        /// The library source representing this provider.
        var source: URL { URL(string: "veneer-online://\(rawValue)")! }

        init?(source: URL) {
            guard source.scheme == "veneer-online", let p = Provider(rawValue: source.host ?? "") else { return nil }
            self = p
        }
    }

    static let userAgent = "VeneerPro/1.0 (+https://github.com/thehilodude/veneerpro)"

    static func isOnline(_ url: URL) -> Bool { url.scheme == "veneer-online" }

    /// Where downloaded materials live; added to the library as "Downloaded".
    static var downloadsFolder: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Veneer Pro/Downloaded Materials", isDirectory: true)
    }

    // MARK: Listings

    /// Every material the provider offers (cached for a day).
    static func catalog(_ provider: Provider) async throws -> [LibraryMaterial] {
        let cache = cacheFolder.appendingPathComponent("\(provider.rawValue).json")
        if let attributes = try? FileManager.default.attributesOfItem(atPath: cache.path),
           let modified = attributes[.modificationDate] as? Date, Date().timeIntervalSince(modified) < 86_400,
           let data = try? Data(contentsOf: cache), let cached = try? decodeCatalog(data, provider) {
            return cached
        }
        let entries: [CatalogEntry]
        switch provider {
        case .polyHaven: entries = try await polyHavenCatalog()
        case .ambientCG: entries = try await ambientCGCatalog()
        }
        try? FileManager.default.createDirectory(at: cacheFolder, withIntermediateDirectories: true)
        try? JSONEncoder().encode(entries).write(to: cache)
        return entries.map { $0.material(provider) }
    }

    private struct CatalogEntry: Codable {
        let id, name, category: String
        let thumbnail: String?

        func material(_ provider: Provider) -> LibraryMaterial {
            LibraryMaterial(location: URL(string: "veneer-online://\(provider.rawValue)/\(id)")!, name: name, category: category,
                            maps: [:], keyShotFile: nil,
                            onlineAsset: OnlineAsset(provider: provider, id: id, thumbnail: thumbnail.flatMap(URL.init(string:))))
        }
    }

    private static func decodeCatalog(_ data: Data, _ provider: Provider) throws -> [LibraryMaterial] {
        try JSONDecoder().decode([CatalogEntry].self, from: data).map { $0.material(provider) }
    }

    private static func polyHavenCatalog() async throws -> [CatalogEntry] {
        let json = try await fetchJSON("https://api.polyhaven.com/assets?t=textures") as? [String: [String: Any]] ?? [:]
        return json.map { id, info in
            // "Metal/Painted/Chipped" → "Metal".
            let path = info["category"] as? String ?? (info["categories"] as? [String])?.first?.capitalized ?? "Other"
            let top = path.split(separator: "/").first.map(String.init) ?? "Other"
            return CatalogEntry(id: id, name: info["name"] as? String ?? id, category: top,
                                thumbnail: info["thumbnail_url"] as? String)
        }
        .sorted { ($0.category, $0.name) < ($1.category, $1.name) }
    }

    private static func ambientCGCatalog() async throws -> [CatalogEntry] {
        var entries: [CatalogEntry] = []
        var offset = 0
        // Polite paging: one request at a time.
        while true {
            let url = "https://ambientcg.com/api/v2/full_json?type=Material&sort=Popular&limit=250&offset=\(offset)&include=previewData,displayData"
            let json = try await fetchJSON(url) as? [String: Any] ?? [:]
            let found = json["foundAssets"] as? [[String: Any]] ?? []
            for asset in found {
                guard let id = asset["assetId"] as? String else { continue }
                let previews = asset["previewImage"] as? [String: String]
                entries.append(CatalogEntry(id: id, name: asset["displayName"] as? String ?? id,
                                            category: asset["displayCategory"] as? String ?? "Other",
                                            thumbnail: previews?["256-PNG"] ?? previews?["512-PNG"]))
            }
            offset += found.count
            let total = json["numberOfResults"] as? Int ?? 0
            if found.isEmpty || offset >= total { break }
        }
        return entries.sorted { ($0.category, $0.name) < ($1.category, $1.name) }
    }

    // MARK: Downloading

    /// Downloads `asset`'s maps (if not already) and returns the material folder.
    static func download(_ material: LibraryMaterial, resolution: String) async throws -> URL {
        guard let asset = material.onlineAsset else { throw URLError(.badURL) }
        let folder = downloadsFolder
            .appendingPathComponent(asset.provider.displayName)
            .appendingPathComponent(safe(material.category))
            .appendingPathComponent(safe(material.name), isDirectory: true)
        let marker = folder.appendingPathComponent(".resolution")
        if let existing = try? String(contentsOf: marker, encoding: .utf8), existing == resolution { return folder }

        let staging = cacheFolder.appendingPathComponent("staging-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: staging) }
        switch asset.provider {
        case .polyHaven: try await downloadPolyHaven(asset.id, name: material.name, resolution: resolution, into: staging)
        case .ambientCG: try await downloadAmbientCG(asset.id, resolution: resolution, into: staging)
        }
        // Swap the finished set into place.
        try? FileManager.default.removeItem(at: folder)
        try FileManager.default.createDirectory(at: folder.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: staging, to: folder)
        try resolution.write(to: marker, atomically: true, encoding: .utf8)
        return folder
    }

    private static func downloadPolyHaven(_ id: String, name: String, resolution: String, into folder: URL) async throws {
        let files = try await fetchJSON("https://api.polyhaven.com/files/\(id)") as? [String: Any] ?? [:]
        let res = resolution.lowercased()   // "2k"
        func url(_ key: String) -> URL? {
            guard let byRes = files[key] as? [String: Any] else { return nil }
            let entry = (byRes[res] ?? byRes["2k"] ?? byRes["1k"]) as? [String: Any]
            let format = (entry?["jpg"] ?? entry?["png"]) as? [String: Any]
            return (format?["url"] as? String).flatMap(URL.init(string:))
        }
        // Poly Haven map → a file name the library's map classifier understands.
        var wanted: [(key: String, suffix: String)] = [("Diffuse", "BaseColor"), ("nor_gl", "NormalGL")]
        if files["arm"] != nil {
            wanted.append(("arm", "OcclusionRoughnessMetallic"))   // AO, roughness, metal in R, G, B
        } else {
            wanted += [("Rough", "Roughness"), ("AO", "AO"), ("Metal", "Metallic")]
        }
        for (key, suffix) in wanted {
            guard let source = url(key) else { continue }
            try await fetchFile(source, to: folder.appendingPathComponent("\(safe(name))_\(suffix).\(source.pathExtension)"))
        }
        guard !((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).isEmpty else {
            throw URLError(.resourceUnavailable)
        }
    }

    private static func downloadAmbientCG(_ id: String, resolution: String, into folder: URL) async throws {
        // e.g. Metal063_2K-JPG.zip, containing Metal063_2K-JPG_Color.jpg, _NormalGL, _Roughness, _Metalness…
        let zip = folder.appendingPathComponent("download.zip")
        try await fetchFile(URL(string: "https://ambientcg.com/get?file=\(id)_\(resolution.uppercased())-JPG.zip")!, to: zip)
        try unzip(zip, into: folder)
        try? FileManager.default.removeItem(at: zip)
        // Keep only maps USDZ can use (drop displacement, DirectX normals and extras).
        for file in (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [] {
            let kind = MapKind.classify(file)
            let keep = LibraryMaterial.imageExtensions.contains(file.pathExtension.lowercased())
                && kind != nil && kind != .normalDX && !(kind?.isUnsupported ?? true)
            if !keep { try? FileManager.default.removeItem(at: file) }
        }
    }

    // MARK: Networking

    private static var cacheFolder: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("VeneerPro/Online", isDirectory: true)
    }

    private static func request(_ url: URL) -> URLRequest {
        var request = URLRequest(url: url)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        return request
    }

    static func fetchJSON(_ string: String) async throws -> Any {
        let (data, response) = try await URLSession.shared.data(for: request(URL(string: string)!))
        if let http = response as? HTTPURLResponse, http.statusCode >= 400 { throw URLError(.badServerResponse) }
        return try JSONSerialization.jsonObject(with: data)
    }

    static func fetchFile(_ url: URL, to destination: URL) async throws {
        let (temp, response) = try await URLSession.shared.download(for: request(url))
        if let http = response as? HTTPURLResponse, http.statusCode >= 400 { throw URLError(.badServerResponse) }
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: temp, to: destination)
    }

    /// Extracts a zip with the system's `ditto`.
    static func unzip(_ zip: URL, into folder: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-x", "-k", zip.path, folder.path]
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw URLError(.cannotDecodeContentData) }
    }

    /// Thumbnail image data (identified requests, cached by URLSession).
    static func thumbnailData(_ url: URL) async -> Data? {
        try? await URLSession.shared.data(for: request(url)).0
    }

    private static func safe(_ name: String) -> String {
        let cleaned = name.components(separatedBy: CharacterSet(charactersIn: "/\\:?%*|\"<>")).joined(separator: "-")
        return cleaned.isEmpty ? "Material" : cleaned
    }
}
