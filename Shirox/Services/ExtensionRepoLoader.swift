import Foundation

/// What a link given to Add Module is, when it's one of the extension formats.
enum ExtensionRepoLoader {
    typealias Fetch = (URL) async throws -> Data

    /// `stremio://host/…` is Stremio's install link for `https://host/…`.
    static func normalized(_ url: URL) -> URL {
        guard url.scheme?.lowercased() == "stremio",
              var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url }
        parts.scheme = "https"
        return parts.url ?? url
    }

    static func detect(_ data: Data, url: URL, fetch: Fetch) async throws -> ExtensionLink? {
        guard let json = try? JSONSerialization.jsonObject(with: data) else { return nil }
        let base = url.deletingLastPathComponent()

        if let object = json as? [String: Any] {
            if object["sourceName"] == nil, object["id"] is String, object["resources"] != nil, object["types"] != nil {
                guard let name = object["name"] as? String, let id = object["id"] as? String else { return nil }
                return .stremio(StremioManifest(url: url, id: id, name: name,
                                                version: object["version"] as? String ?? "0.0.0",
                                                description: object["description"] as? String,
                                                logo: object["logo"] as? String ?? object["icon"] as? String, raw: object))
            }
            if let scrapers = object["scrapers"] as? [[String: Any]] {
                let entries = scrapers.compactMap { s -> ExtensionRepoEntry? in
                    guard s["enabled"] as? Bool != false, !ExtensionAdultCheck.isAdult(entry: s),
                          let id = s["id"] as? String, let file = s["filename"] as? String,
                          let fileURL = URL(string: file, relativeTo: base)?.absoluteURL else { return nil }
                    return ExtensionRepoEntry(key: id, name: s["name"] as? String ?? id, version: string(s["version"]),
                                              iconUrl: s["logo"] as? String, language: (s["contentLanguage"] as? [String])?.first,
                                              description: s["description"] as? String, fileURL: fileURL, raw: s)
                }
                return .repo(ExtensionRepo(kind: .nuvio, name: object["name"] as? String ?? repoName(url),
                                           url: url, base: base, entries: entries))
            }
            if let lists = object["pluginLists"] as? [String] {
                var entries: [ExtensionRepoEntry] = []
                for list in lists {
                    guard let listURL = URL(string: list, relativeTo: base)?.absoluteURL,
                          let listData = try? await fetch(listURL),
                          let items = try? JSONSerialization.jsonObject(with: listData) as? [[String: Any]] else { continue }
                    for p in items {
                        guard !ExtensionAdultCheck.isAdult(entry: p), let key = p["packageName"] as? String,
                              let file = p["url"] as? String, let fileURL = URL(string: file, relativeTo: listURL)?.absoluteURL,
                              !entries.contains(where: { $0.key == key }) else { continue }
                        entries.append(ExtensionRepoEntry(key: key, name: p["name"] as? String ?? key, version: string(p["version"]),
                                                          iconUrl: p["iconUrl"] as? String, language: (p["languages"] as? [String])?.first,
                                                          description: p["description"] as? String, fileURL: fileURL, raw: p))
                    }
                }
                return .repo(ExtensionRepo(kind: .skystream, name: object["name"] as? String ?? repoName(url),
                                           url: url, base: base, entries: entries))
            }
        }
        if let array = json as? [[String: Any]], !array.isEmpty,
           array.allSatisfy({ $0["value"] is String && $0["display_name"] is String }) {
            let entries = array.compactMap { p -> ExtensionRepoEntry? in
                guard p["disabled"] as? Bool != true, !ExtensionAdultCheck.isAdult(entry: p),
                      let value = p["value"] as? String,
                      let dir = URL(string: "dist/\(value)/", relativeTo: base)?.absoluteURL else { return nil }
                return ExtensionRepoEntry(key: value, name: p["display_name"] as? String ?? value, version: string(p["version"]),
                                          iconUrl: p["icon"] as? String, language: nil,
                                          description: nil, fileURL: dir, raw: p)
            }
            return .repo(ExtensionRepo(kind: .vega, name: repoName(url), url: url, base: base, entries: entries))
        }
        return nil
    }

    private static func string(_ value: Any?) -> String {
        if let s = value as? String { return s }
        if let n = value as? NSNumber { return n.stringValue }
        return "0"
    }

    /// "owner/repo" for a raw.githubusercontent.com link; the host otherwise.
    static func repoName(_ url: URL) -> String {
        let parts = url.pathComponents.filter { $0 != "/" }
        if url.host == "raw.githubusercontent.com", parts.count >= 2 { return "\(parts[0])/\(parts[1])" }
        return url.host ?? url.absoluteString
    }
}
