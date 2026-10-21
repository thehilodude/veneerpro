import Foundation

/// A Poly Haven or ambientCG HDRI, before it's downloaded.
struct OnlineHDRI: Identifiable, Hashable, Codable {
    let provider: String
    let assetID: String
    let name: String
    /// Filter tags as "Group|value".
    let tags: Set<String>
    let thumbnail: String?

    var id: String { provider + "/" + assetID }
    var source: OnlineLibrary.Provider { OnlineLibrary.Provider(rawValue: provider) ?? .polyHaven }
}

/// Free CC0 HDRIs from Poly Haven and ambientCG: listings (cached for a day) and downloads.
extension OnlineLibrary {
    /// Filter groups in display order, with readable labels for Poly Haven's tags.
    static let hdriGroups: [(title: String, values: [String])] = [
        ("Setting", ["outdoor", "indoor", "studio", "urban", "nature", "skies", "pure skies"]),
        ("Time of Day", ["sunrise-sunset", "morning-afternoon", "midday", "day", "morning", "evening", "night"]),
        ("Sky", ["clear", "partly cloudy", "overcast"]),
        ("Light", ["natural light", "artificial light"]),
        ("Contrast", ["low contrast", "medium contrast", "high contrast"]),
    ]

    static func hdriLabel(_ value: String) -> String {
        switch value {
        case "sunrise-sunset": "Sunrise / Sunset"
        case "morning-afternoon": "Morning / Afternoon"
        default: value.capitalized
        }
    }

    /// Where downloaded HDRIs are kept (shown under My HDRIs).
    static var hdriFolder: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Veneer Pro/Downloaded HDRIs", isDirectory: true)
    }

    static func hdriCatalog(_ provider: Provider) async throws -> [OnlineHDRI] {
        let cache = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("VeneerPro/Online/\(provider.rawValue)-hdris.json")
        if let attributes = try? FileManager.default.attributesOfItem(atPath: cache.path),
           let modified = attributes[.modificationDate] as? Date, Date().timeIntervalSince(modified) < 86_400,
           let data = try? Data(contentsOf: cache), let cached = try? JSONDecoder().decode([OnlineHDRI].self, from: data) {
            return cached
        }
        let items: [OnlineHDRI]
        switch provider {
        case .polyHaven: items = try await polyHavenHDRIs()
        case .ambientCG: items = try await ambientCGHDRIs()
        }
        try? FileManager.default.createDirectory(at: cache.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONEncoder().encode(items).write(to: cache)
        return items
    }

    private static func polyHavenHDRIs() async throws -> [OnlineHDRI] {
        let json = try await fetchJSON("https://api.polyhaven.com/assets?t=hdris") as? [String: [String: Any]] ?? [:]
        return json.map { id, info in
            let categories = Set(info["categories"] as? [String] ?? [])
            var tags: Set<String> = []
            for (group, values) in hdriGroups {
                for value in values where categories.contains(value) { tags.insert(group + "|" + value) }
            }
            return OnlineHDRI(provider: Provider.polyHaven.rawValue, assetID: id, name: info["name"] as? String ?? id,
                              tags: tags, thumbnail: info["thumbnail_url"] as? String)
        }
        .sorted { $0.name.localizedLowercase < $1.name.localizedLowercase }
    }

    private static func ambientCGHDRIs() async throws -> [OnlineHDRI] {
        var items: [OnlineHDRI] = []
        var offset = 0
        while true {
            let url = "https://ambientcg.com/api/v2/full_json?type=HDRI&sort=Popular&limit=250&offset=\(offset)&include=previewData,displayData"
            let json = try await fetchJSON(url) as? [String: Any] ?? [:]
            let found = json["foundAssets"] as? [[String: Any]] ?? []
            for asset in found {
                guard let id = asset["assetId"] as? String else { continue }
                // "Evening Sky HDRI" → Time of Day: evening, Setting: skies.
                let category = (asset["displayCategory"] as? String ?? "").lowercased()
                var tags: Set<String> = []
                for time in ["day", "morning", "evening", "night"] where category.hasPrefix(time) { tags.insert("Time of Day|" + time) }
                tags.insert("Setting|" + (category.contains("sky") ? "skies" : category.contains("indoor") ? "indoor" : "outdoor"))
                let previews = asset["previewImage"] as? [String: String]
                items.append(OnlineHDRI(provider: Provider.ambientCG.rawValue, assetID: id,
                                        name: asset["displayName"] as? String ?? id, tags: tags,
                                        thumbnail: previews?["256-PNG"] ?? previews?["512-PNG"]))
            }
            offset += found.count
            if found.isEmpty || offset >= (json["numberOfResults"] as? Int ?? 0) { break }
        }
        return items
    }

    /// Display names of downloaded HDRIs (their files are named by asset ID), keyed by asset ID.
    private static var namesFile: URL { hdriFolder.appendingPathComponent("names.json") }
    nonisolated(unsafe) private static var namesCache: [String: String]?
    private static let namesLock = NSLock()

    static func displayName(forDownloaded url: URL) -> String? {
        namesLock.lock(); defer { namesLock.unlock() }
        if namesCache == nil {
            namesCache = (try? Data(contentsOf: namesFile)).flatMap { try? JSONDecoder().decode([String: String].self, from: $0) } ?? [:]
        }
        let id = url.deletingPathExtension().lastPathComponent
            .replacingOccurrences(of: #"_(1|2|4|8|16)K$"#, with: "", options: .regularExpression)
        return namesCache?[id]
    }

    private static func rememberName(_ item: OnlineHDRI) {
        namesLock.lock(); defer { namesLock.unlock() }
        var names = namesCache ?? ((try? Data(contentsOf: namesFile)).flatMap { try? JSONDecoder().decode([String: String].self, from: $0) } ?? [:])
        names[item.assetID] = item.name
        namesCache = names
        try? JSONEncoder().encode(names).write(to: namesFile)
    }

    /// The downloaded file for `item`, at any resolution, if there is one.
    static func downloadedHDRI(_ item: OnlineHDRI) -> URL? {
        let folder = hdriFolder.appendingPathComponent(item.source.displayName)
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.lastPathComponent.hasPrefix(item.assetID + "_") }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }.last
    }

    /// Downloads `item` at `resolution` ("1K", "2K", "4K"), returning the HDR file.
    static func downloadHDRI(_ item: OnlineHDRI, resolution: String) async throws -> URL {
        let folder = hdriFolder.appendingPathComponent(item.source.displayName, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        rememberName(item)
        let res = resolution.uppercased()
        if let existing = ["hdr", "exr"].map({ folder.appendingPathComponent("\(item.assetID)_\(res).\($0)") })
            .first(where: { FileManager.default.fileExists(atPath: $0.path) }) {
            return existing
        }
        switch item.source {
        case .polyHaven:
            let files = try await fetchJSON("https://api.polyhaven.com/files/\(item.assetID)") as? [String: Any] ?? [:]
            let byRes = (files["hdri"] as? [String: Any])?[res.lowercased()] as? [String: Any]
            guard let hdr = byRes?["hdr"] as? [String: Any], let link = (hdr["url"] as? String).flatMap(URL.init(string:)) else {
                throw URLError(.resourceUnavailable)
            }
            let destination = folder.appendingPathComponent("\(item.assetID)_\(res).hdr")
            try await fetchFile(link, to: destination)
            return destination
        case .ambientCG:
            let staging = FileManager.default.temporaryDirectory.appendingPathComponent("VeneerPro-HDRI-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: staging) }
            let zip = staging.appendingPathComponent("download.zip")
            try await fetchFile(URL(string: "https://ambientcg.com/get?file=\(item.assetID)_\(res).zip")!, to: zip)
            try unzip(zip, into: staging)
            let found = FileManager.default.enumerator(at: staging, includingPropertiesForKeys: nil)?.allObjects as? [URL] ?? []
            guard let hdr = found.first(where: { ["hdr", "exr"].contains($0.pathExtension.lowercased()) }) else {
                throw URLError(.cannotDecodeContentData)
            }
            let destination = folder.appendingPathComponent("\(item.assetID)_\(res).\(hdr.pathExtension.lowercased())")
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: hdr, to: destination)
            return destination
        }
    }
}
