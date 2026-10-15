import Foundation
import JavaScriptCore

enum ExtensionInstallError: LocalizedError, Equatable {
    case missingFiles([String])
    case noPlugin
    case nothingToSearch
    case adult

    var errorDescription: String? {
        switch self {
        case .missingFiles(let names):
            return "This provider is missing \(ListFormatter.localizedString(byJoining: names.map { "\($0).js" }))."
        case .noPlugin: return "This plugin file has no script Shirox can run."
        case .nothingToSearch: return "This addon has nothing Shirox can search: it needs a search catalog, or Kitsu or IMDb ids."
        case .adult: return ModuleLinkError.adult.localizedDescription
        }
    }
}

/// A Stremio addon, or one provider of a Nuvio, Vega or SkyStream repo, as a Shirox module.
@MainActor
enum ExtensionInstaller {
    typealias Fetch = (URL) async throws -> Data

    static let vegaFiles = ["posts", "meta", "stream", "catalog", "episodes"]
    private static let vegaRequired = ["posts", "meta", "stream"]

    static func module(stremio manifest: StremioManifest) throws -> ModuleDefinition {
        if ExtensionAdultCheck.isAdult(stremio: manifest.raw) { throw ExtensionInstallError.adult }
        guard StremioSupport.canSearch(manifest.raw) else { throw ExtensionInstallError.nothingToSearch }
        let base = manifest.url.absoluteString.replacingOccurrences(of: #"/manifest\.json.*$"#, with: "", options: .regularExpression)
        let config: [String: Any] = ["manifestUrl": manifest.url.absoluteString, "base": base, "manifest": manifest.raw]
        return try make(kind: .stremio, name: manifest.name, version: manifest.version, scriptUrl: manifest.url.absoluteString,
                        repoUrl: manifest.url.absoluteString, key: manifest.url.absoluteString, icon: manifest.logo,
                        language: nil, baseUrl: base, config: config, script: "")
    }

    static func module(entry: ExtensionRepoEntry, repo: ExtensionRepo, fetch: Fetch) async throws -> ModuleDefinition {
        if ExtensionAdultCheck.isAdult(entry: entry.raw) || AdultModuleCheck.hasAdultName(entry.name)
            || AdultModuleCheck.hasAdultName(entry.key) { throw ExtensionInstallError.adult }
        switch repo.kind {
        case .nuvio:
            let source = String(decoding: try await fetch(entry.fileURL), as: UTF8.self)
            guard isJavaScript(source) else { throw ExtensionInstallError.noPlugin }
            let config: [String: Any] = ["supportedTypes": entry.raw["supportedTypes"] as? [String] ?? ["movie", "tv"]]
            return try make(kind: .nuvio, name: entry.name, version: entry.version, scriptUrl: entry.fileURL.absoluteString,
                            repoUrl: repo.url.absoluteString, key: entry.key, icon: entry.iconUrl, language: entry.language,
                            baseUrl: nil, config: config, script: wrap("main", source))
        case .vega:
            var parts: [String] = [], missing: [String] = []
            for name in vegaFiles {
                if let data = try? await fetch(entry.fileURL.appendingPathComponent("\(name).js")),
                   let text = String(data: data, encoding: .utf8), isJavaScript(text) {
                    parts.append(wrap(name, text))
                } else if vegaRequired.contains(name) {
                    missing.append(name)
                }
            }
            guard missing.isEmpty else { throw ExtensionInstallError.missingFiles(missing) }
            let config: [String: Any] = ["repoBase": repo.base.absoluteString, "value": entry.key]
            return try make(kind: .vega, name: entry.name, version: entry.version, scriptUrl: entry.fileURL.absoluteString,
                            repoUrl: repo.url.absoluteString, key: entry.key, icon: entry.iconUrl, language: nil,
                            baseUrl: nil, config: config, script: parts.joined(separator: "\n"))
        case .skystream:
            let zip = try await fetch(entry.fileURL)
            guard let js = ZipReader.file(named: "plugin.js", in: zip).flatMap({ String(data: $0, encoding: .utf8) }), isJavaScript(js)
            else { throw ExtensionInstallError.noPlugin }
            var manifest = ZipReader.file(named: "plugin.json", in: zip)
                .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? entry.raw
            if manifest["baseUrl"] == nil { manifest["baseUrl"] = entry.raw["baseUrl"] }
            if ExtensionAdultCheck.isAdult(entry: manifest) { throw ExtensionInstallError.adult }
            return try make(kind: .skystream, name: entry.name, version: entry.version, scriptUrl: entry.fileURL.absoluteString,
                            repoUrl: repo.url.absoluteString, key: entry.key, icon: entry.iconUrl, language: entry.language,
                            baseUrl: manifest["baseUrl"] as? String, config: ["manifest": manifest], script: js)
        case .stremio:
            throw ExtensionInstallError.noPlugin
        }
    }

    /// Downloads a plugin file; an error page (GitHub's "404: Not Found") is an error, not a script.
    static func download(_ url: URL) async throws -> Data {
        let (data, response) = try await URLSession.shared.data(from: url)
        if let status = (response as? HTTPURLResponse)?.statusCode, status >= 400 { throw ModuleLinkError.unreachable(status) }
        return data
    }

    /// Whether `source` parses as JavaScript. Saved parts are evaluated as one script, so a part
    /// that doesn't parse would stop all of them from loading.
    static func isJavaScript(_ source: String) -> Bool {
        guard !source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let context = JSContext.forModule().jsGlobalContextRef else { return false }
        let script = JSStringCreateWithUTF8CString(source)
        defer { JSStringRelease(script) }
        return JSCheckScriptSyntax(context, script, nil, 1, nil)
    }

    /// A CommonJS file, kept apart from its neighbours: each gets its own `module`, `exports` and scope.
    static func wrap(_ name: String, _ source: String) -> String {
        "__extDefine(\"\(name)\", function (module, exports, require) {\n\(source)\n});"
    }

    private static func make(kind: ExtensionKind, name: String, version: String, scriptUrl: String, repoUrl: String,
                             key: String, icon: String?, language: String?, baseUrl: String?,
                             config: [String: Any], script: String) throws -> ModuleDefinition {
        var object: [String: Any] = ["sourceName": name, "version": version, "scriptUrl": scriptUrl, "type": "anime"]
        if let icon, !icon.isEmpty { object["iconUrl"] = icon }
        if let language, !language.isEmpty { object["language"] = language }
        if let baseUrl, !baseUrl.isEmpty { object["baseUrl"] = baseUrl }
        var module = try JSONDecoder().decode(ModuleDefinition.self, from: JSONSerialization.data(withJSONObject: object))
        // A repo's providers each get their own link, so a backup restores each by itself.
        module.jsonUrl = kind == .stremio ? repoUrl
            : URL(string: repoUrl).map { ExtensionRepoLoader.entryLink(repo: $0, key: key) } ?? repoUrl
        module.scriptContent = script
        let configJSON = String(decoding: try JSONSerialization.data(withJSONObject: config), as: UTF8.self)
        module.ext = ExtensionInfo(kind: kind, repoUrl: repoUrl, key: key, config: configJSON)
        return module
    }
}

/// What a Stremio addon offers Shirox — the same rules the runtime's stremio.js applies.
enum StremioSupport {
    static func canSearch(_ raw: [String: Any]) -> Bool {
        let catalogs = raw["catalogs"] as? [[String: Any]] ?? []
        let searchable = catalogs.contains { c in
            ["anime", "series", "movie"].contains(c["type"] as? String ?? "")
                && (c["extra"] as? [[String: Any]] ?? []).contains { $0["name"] as? String == "search" }
        }
        if searchable && hasResource("meta", raw) { return true }
        guard let prefixes = streamPrefixes(raw) else { return hasResource("stream", raw) }
        return prefixes.contains { $0.hasPrefix("kitsu") || $0 == "tt" }
    }

    static func hasResource(_ name: String, _ raw: [String: Any]) -> Bool {
        (raw["resources"] as? [Any] ?? []).contains { ($0 as? String) == name || ($0 as? [String: Any])?["name"] as? String == name }
    }

    /// The id prefixes the stream resource accepts; nil when it accepts any id.
    static func streamPrefixes(_ raw: [String: Any]) -> [String]? {
        for r in raw["resources"] as? [Any] ?? [] {
            if let d = r as? [String: Any], d["name"] as? String == "stream" {
                return d["idPrefixes"] as? [String] ?? raw["idPrefixes"] as? [String]
            }
        }
        return raw["idPrefixes"] as? [String]
    }
}
