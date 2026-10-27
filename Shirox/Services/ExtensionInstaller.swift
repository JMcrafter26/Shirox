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
            let files = ListFormatter.localizedString(byJoining: names.map { $0 + ".js" })
            return String(localized: "modules.this_provider_is_missing \(files)")
        case .noPlugin: return String(localized: "modules.this_plugin_file_has_no")
        case .nothingToSearch: return String(localized: "modules.this_addon_has_nothing_shirox")
        case .adult: return ModuleLinkError.adult.localizedDescription
        }
    }
}

/// A Stremio addon, or one provider of a Nuvio, Vega, SkyStream or Mana repo, as a Shirox module.
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
            let source = String(repairingUTF8: try await fetch(entry.fileURL))
            guard isJavaScript(source) else { throw ExtensionInstallError.noPlugin }
            let config: [String: Any] = ["supportedTypes": entry.raw["supportedTypes"] as? [String] ?? ["movie", "tv"]]
            return try make(kind: .nuvio, name: entry.name, version: entry.version, scriptUrl: entry.fileURL.absoluteString,
                            repoUrl: repo.url.absoluteString, key: entry.key, icon: entry.iconUrl, language: entry.language,
                            baseUrl: nil, config: config, script: wrap("main", source))
        case .vega:
            var parts: [String] = [], missing: [String] = []
            for name in vegaFiles {
                let text: String?
                do {
                    text = String(data: try await fetch(entry.fileURL.appendingPathComponent("\(name).js")), encoding: .utf8)
                } catch where isMissing(error) {
                    text = nil
                }
                if let text, isJavaScript(text) {
                    parts.append(wrap(name, text))
                } else if vegaRequired.contains(name) {
                    missing.append(name)
                }
            }
            guard missing.isEmpty else { throw ExtensionInstallError.missingFiles(missing) }
            // The provider's current site, from the repo's urls.json: kept as its baseUrl so the
            // adult host check sees where it really goes.
            let site = (try? await fetch(repo.base.appendingPathComponent("urls.json")))
                .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
                .flatMap { $0[entry.key] }
                .flatMap { ($0 as? String) ?? ($0 as? [String: Any])?["url"] as? String }
            let config: [String: Any] = ["repoBase": repo.base.absoluteString, "value": entry.key]
            return try make(kind: .vega, name: entry.name, version: entry.version, scriptUrl: entry.fileURL.absoluteString,
                            repoUrl: repo.url.absoluteString, key: entry.key, icon: entry.iconUrl, language: nil,
                            baseUrl: site, config: config, script: parts.joined(separator: "\n"))
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
                            baseUrl: manifest["baseUrl"] as? String, config: ["manifest": manifest], script: wrapSkyStream(js))
        case .mana:
            let source = String(repairingUTF8: try await fetch(entry.fileURL))
            guard isJavaScript(source), let info = manaInfo(source) else { throw ExtensionInstallError.noPlugin }
            // The source's own rating and name, not only the repo's word for them.
            if ExtensionAdultCheck.isAdult(mana: info) || (info["rating"] == nil && ExtensionAdultCheck.isAdult(mana: entry.raw)) {
                throw ExtensionInstallError.adult
            }
            let site = info["website"] as? String ?? entry.raw["website"] as? String
            return try make(kind: .mana, name: entry.name, version: entry.version, scriptUrl: entry.fileURL.absoluteString,
                            repoUrl: repo.url.absoluteString, key: entry.key, icon: entry.iconUrl, language: entry.language,
                            baseUrl: site, config: ["id": entry.key], script: source, type: "manga")
        case .stremio:
            throw ExtensionInstallError.noPlugin
        }
    }

    /// A Mana bundle's `Target.info` — id, name, rating, website — read by running the bundle,
    /// with the runtime, in a context of its own. Nil when it declares no source.
    static func manaInfo(_ source: String) -> [String: Any]? {
        guard let runtime = ExtensionScripts.runtimeSource else { return nil }
        let context = JSContext.forModule()
        context.exceptionHandler = { _, _ in }
        context.setObject(["kind": "mana", "name": "", "key": "", "config": [String: Any](), "adultWords": [String]()],
                          forKeyedSubscript: "__ext" as NSString)
        context.evaluateScript(runtime)
        context.evaluateScript(source)
        let json = context.evaluateScript("""
        (function () {
          try { var T = globalThis.Target; var s = typeof T === "function" ? new T() : T; return s && s.info ? JSON.stringify(s.info) : ""; }
          catch (e) { return ""; }
        })()
        """)?.toString() ?? ""
        return (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any]
    }

    /// An installed extension fetched again from its own link, as at install — for Revert, after
    /// its script was edited.
    static func reinstall(_ module: ModuleDefinition, fetch: Fetch) async throws -> ModuleDefinition {
        guard let ext = module.ext, let link = module.jsonUrl.flatMap(URL.init(string:)),
              var parts = URLComponents(url: link, resolvingAgainstBaseURL: false) else { throw ExtensionInstallError.noPlugin }
        parts.fragment = nil
        let url = parts.url ?? link
        switch try await ExtensionRepoLoader.detect(try await fetch(url), url: url, fetch: fetch) {
        case .stremio(let manifest)?:
            return try self.module(stremio: manifest)
        case .repo(let repo)?:
            guard let entry = repo.entries.first(where: { $0.key == ext.key }) else { throw ExtensionInstallError.noPlugin }
            return try await self.module(entry: entry, repo: repo, fetch: fetch)
        case nil:
            throw ExtensionInstallError.noPlugin
        }
    }

    /// A file that isn't there (as opposed to the network failing): an optional Vega file left out.
    private static func isMissing(_ error: Error) -> Bool {
        if (error as? URLError)?.code == .fileDoesNotExist { return true }
        if case .unreachable(let status)? = error as? ModuleLinkError { return status == 404 || status == 403 }
        return false
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

    /// A SkyStream plugin in its own scope: its top-level names can't collide with the engine's
    /// globals, and entry points it declares with `const`/`let` are still found.
    static func wrapSkyStream(_ source: String) -> String {
        let entries = ["search", "load", "loadStreams", "getHome"].map { name in
            "try { if (typeof \(name) === \"function\" && typeof globalThis.\(name) !== \"function\") globalThis.\(name) = \(name); } catch (e) {}"
        }.joined(separator: "\n")
        return "(function () {\n\(source)\n;\n\(entries)\n})();"
    }

    /// A CommonJS file, kept apart from its neighbours: each gets its own `module`, `exports` and scope.
    static func wrap(_ name: String, _ source: String) -> String {
        "__extDefine(\"\(name)\", function (module, exports, require) {\n\(source)\n});"
    }

    private static func make(kind: ExtensionKind, name: String, version: String, scriptUrl: String, repoUrl: String,
                             key: String, icon: String?, language: String?, baseUrl: String?,
                             config: [String: Any], script: String, type: String = "anime") throws -> ModuleDefinition {
        var object: [String: Any] = ["sourceName": name, "version": version, "scriptUrl": scriptUrl, "type": type]
        if let icon, !icon.isEmpty { object["iconUrl"] = icon }
        if let language, !language.isEmpty { object["language"] = language }
        if let baseUrl, !baseUrl.isEmpty { object["baseUrl"] = baseUrl }
        var module = try JSONDecoder().decode(ModuleDefinition.self, from: JSONSerialization.data(withJSONObject: object))
        // A repo's providers each get their own link, so a backup restores each by itself.
        module.jsonUrl = kind == .stremio ? repoUrl
            : URL(string: repoUrl).map { ExtensionRepoLoader.entryLink(repo: $0, key: key) } ?? repoUrl
        module.scriptContent = script
        let configJSON = String(repairingUTF8: try JSONSerialization.data(withJSONObject: config))
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

/// What an update check means for an installed extension module.
enum ExtensionUpdate: Equatable {
    case keep, update, remove

    /// `link` is what the module's link holds now. An entry or addon that has turned adult is
    /// removed rather than left running at the version installed before.
    static func decide(_ module: ModuleDefinition, link: ExtensionLink) -> ExtensionUpdate {
        guard let ext = module.ext else { return .keep }
        switch link {
        case .stremio(let manifest):
            if ExtensionAdultCheck.isAdult(stremio: manifest.raw) { return .remove }
            return manifest.version != module.version ? .update : .keep
        case .repo(let repo):
            if repo.adultKeys.contains(ext.key) { return .remove }
            guard let entry = repo.entries.first(where: { $0.key == ext.key }) else { return .keep }
            return entry.version != module.version ? .update : .keep
        }
    }
}
