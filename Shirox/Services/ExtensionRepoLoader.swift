import Foundation

/// What a link given to Add Module is, when it's one of the extension formats.
enum ExtensionRepoLoader {
    typealias Fetch = (URL) async throws -> Data

    /// `stremio://host/…` is Stremio's install link for `https://host/…`; `mana://add-repo?url=…`
    /// is Mana's for the repo at `url`.
    static func normalized(_ url: URL) -> URL {
        if url.scheme?.lowercased() == "mana",
           let link = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "url" })?.value,
           let repo = URL(string: link), ["http", "https"].contains(repo.scheme?.lowercased() ?? "") {
            return repo
        }
        guard url.scheme?.lowercased() == "stremio",
              var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url }
        parts.scheme = "https"
        return parts.url ?? url
    }

    /// A provider's own link: its repo's, with `#ext=<key>` — what backups keep and restore by.
    static func entryLink(repo: URL, key: String) -> String {
        var parts = URLComponents(url: repo, resolvingAgainstBaseURL: false)
        parts?.fragment = "ext=\(key)"
        return parts?.url?.absoluteString ?? repo.absoluteString
    }

    /// The provider an entry link names.
    static func entryKey(in url: URL) -> String? {
        guard let fragment = url.fragment, fragment.hasPrefix("ext=") else { return nil }
        let key = String(fragment.dropFirst(4))
        return key.isEmpty ? nil : key.removingPercentEncoding ?? key
    }

    /// A link to one SkyStream `.sky` rather than a repo: a repo of just that plugin.
    static func isSingleFile(_ repo: ExtensionRepo) -> Bool {
        repo.kind == .skystream && repo.entries.count + repo.adultKeys.count == 1
            && (repo.entries.first?.fileURL ?? repo.url) == repo.url
    }

    /// Plugin files come from the web only, never from paths on the device.
    private static func web(_ string: String, relativeTo base: URL) -> URL? {
        guard let url = URL(string: string, relativeTo: base)?.absoluteURL,
              ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return nil }
        return url
    }

    /// Where a repo given by its folder or its web page (`…/main/`, `…/main/open.html`) keeps its
    /// index: Vega's `manifest.json`, Mana's `sources.json`. Nil for a link to a file of another kind.
    static func indexCandidates(for url: URL) -> [URL] {
        let ext = url.pathExtension.lowercased()
        guard ext.isEmpty || ext == "html" || ext == "htm" else { return [] }
        let folder = ext.isEmpty ? url : url.deletingLastPathComponent()
        return ["manifest.json", "sources.json"].map { folder.appendingPathComponent($0) }
    }

    /// Mana's `sources.json`: a source's bundle is `sources/<path>.mana`, its icon in `assets/`.
    private static func mana(_ object: [String: Any], url: URL, base: URL) -> ExtensionLink? {
        guard let sources = object["sources"] as? [[String: Any]] else { return nil }
        let adult = Set(sources.filter(ExtensionAdultCheck.isAdult(mana:)).compactMap { $0["id"] as? String })
        let entries = sources.compactMap { s -> ExtensionRepoEntry? in
            // Trackers (MangaUpdates, AniList) aren't sources of chapters.
            guard (s["environment"] as? String ?? "source") == "source", !ExtensionAdultCheck.isAdult(mana: s),
                  let id = s["id"] as? String, let path = s["path"] as? String ?? s["name"] as? String,
                  !path.contains("/"), !path.hasPrefix(".") else { return nil }
            let fileURL = base.appendingPathComponent("sources").appendingPathComponent("\(path).mana")
            let icon = (s["thumbnail"] as? String).flatMap { t -> URL? in
                t.contains("://") ? web(t, relativeTo: base) : base.appendingPathComponent("assets").appendingPathComponent(t)
            }
            let language = (s["supportedLanguages"] as? [String])?.first?.split(separator: "_").first.map(String.init)
            return ExtensionRepoEntry(key: id, name: s["name"] as? String ?? id, version: string(s["version"]),
                                      iconUrl: icon?.absoluteString, language: language,
                                      description: s["description"] as? String, fileURL: fileURL, raw: s)
        }
        return .repo(ExtensionRepo(kind: .mana, name: object["repositoryName"] as? String ?? repoName(url),
                                   url: url, base: base, entries: entries, adultKeys: adult))
    }

    /// Nuvio scrapers are looked up by TMDB, which has shows and films.
    private static func nuvioPlays(_ s: [String: Any]) -> Bool {
        guard let types = s["supportedTypes"] as? [String] else { return true }
        return types.contains { ["tv", "movie", "anime", "series"].contains($0.lowercased()) }
    }

    /// SkyStream plugins that only carry live channels, which Shirox doesn't play.
    private static func skyPlays(_ p: [String: Any]) -> Bool {
        let categories = (p["categories"] as? [String] ?? []).map { $0.lowercased() }
        return categories.isEmpty || categories.contains { !$0.contains("live") }
    }

    static func detect(_ data: Data, url: URL, fetch: Fetch) async throws -> ExtensionLink? {
        var parts = URLComponents(url: url, resolvingAgainstBaseURL: false)
        parts?.fragment = nil
        let url = parts?.url ?? url
        if data.starts(with: [0x50, 0x4b, 0x03, 0x04]) { return sky(data, url: url) }
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
            if object["repositoryName"] != nil || (object["sources"] as? [[String: Any]])?.first?["environment"] != nil {
                return mana(object, url: url, base: base)
            }
            if let scrapers = object["scrapers"] as? [[String: Any]] {
                let adult = Set(scrapers.filter(ExtensionAdultCheck.isAdult(entry:)).compactMap { $0["id"] as? String })
                let entries = scrapers.compactMap { s -> ExtensionRepoEntry? in
                    guard s["enabled"] as? Bool != false, !ExtensionAdultCheck.isAdult(entry: s), nuvioPlays(s),
                          let id = s["id"] as? String, let file = s["filename"] as? String,
                          let fileURL = web(file, relativeTo: base) else { return nil }
                    return ExtensionRepoEntry(key: id, name: s["name"] as? String ?? id, version: string(s["version"]),
                                              iconUrl: s["logo"] as? String, language: (s["contentLanguage"] as? [String])?.first,
                                              description: s["description"] as? String, fileURL: fileURL, raw: s)
                }
                return .repo(ExtensionRepo(kind: .nuvio, name: object["name"] as? String ?? repoName(url),
                                           url: url, base: base, entries: entries, adultKeys: adult))
            }
            if let lists = object["pluginLists"] as? [String] {
                var entries: [ExtensionRepoEntry] = []
                var adult: Set<String> = []
                // CloudStream repos share this layout, with Android `.cs3` plugins in place of `.sky` ones.
                var cloudStream = 0
                for list in lists {
                    guard let listURL = web(list, relativeTo: base),
                          let listData = try? await fetch(listURL),
                          let items = try? JSONSerialization.jsonObject(with: listData) as? [[String: Any]] else { continue }
                    for p in items {
                        if (p["url"] as? String)?.lowercased().hasSuffix(".cs3") == true { cloudStream += 1 }
                        if ExtensionAdultCheck.isAdult(entry: p), let key = p["packageName"] as? String { adult.insert(key) }
                        guard !ExtensionAdultCheck.isAdult(entry: p), skyPlays(p), let key = p["packageName"] as? String,
                              let file = p["url"] as? String, let fileURL = web(file, relativeTo: listURL),
                              !entries.contains(where: { $0.key == key }) else { continue }
                        entries.append(ExtensionRepoEntry(key: key, name: p["name"] as? String ?? key, version: string(p["version"]),
                                                          iconUrl: p["iconUrl"] as? String, language: (p["languages"] as? [String])?.first,
                                                          description: p["description"] as? String, fileURL: fileURL, raw: p))
                    }
                }
                if entries.isEmpty, adult.isEmpty, cloudStream > 0 { throw ModuleLinkError.cloudStream }
                return .repo(ExtensionRepo(kind: .skystream, name: object["name"] as? String ?? repoName(url),
                                           url: url, base: base, entries: entries, adultKeys: adult))
            }
        }
        if let array = json as? [[String: Any]], !array.isEmpty,
           array.allSatisfy({ $0["value"] is String && $0["display_name"] is String }) {
            let adult = Set(array.filter(ExtensionAdultCheck.isAdult(entry:)).compactMap { $0["value"] as? String })
            let entries = array.compactMap { p -> ExtensionRepoEntry? in
                guard p["disabled"] as? Bool != true, !ExtensionAdultCheck.isAdult(entry: p),
                      let value = p["value"] as? String,
                      let dir = URL(string: "dist/\(value)/", relativeTo: base)?.absoluteURL else { return nil }
                return ExtensionRepoEntry(key: value, name: p["display_name"] as? String ?? value, version: string(p["version"]),
                                          iconUrl: p["icon"] as? String, language: nil,
                                          description: nil, fileURL: dir, raw: p)
            }
            return .repo(ExtensionRepo(kind: .vega, name: repoName(url), url: url, base: base, entries: entries, adultKeys: adult))
        }
        return nil
    }

    /// A single `.sky`, described by its own plugin.json.
    private static func sky(_ zip: Data, url: URL) -> ExtensionLink? {
        guard let json = ZipReader.file(named: "plugin.json", in: zip),
              let p = try? JSONSerialization.jsonObject(with: json) as? [String: Any],
              let key = p["packageName"] as? String else { return nil }
        let adult = ExtensionAdultCheck.isAdult(entry: p)
        let entry = ExtensionRepoEntry(key: key, name: p["name"] as? String ?? key, version: string(p["version"]),
                                       iconUrl: p["iconUrl"] as? String, language: (p["languages"] as? [String])?.first,
                                       description: p["description"] as? String, fileURL: url, raw: p)
        return .repo(ExtensionRepo(kind: .skystream, name: entry.name, url: url, base: url.deletingLastPathComponent(),
                                   entries: adult ? [] : [entry], adultKeys: adult ? [key] : []))
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
