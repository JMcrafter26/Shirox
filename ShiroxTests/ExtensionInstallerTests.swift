import XCTest
@testable import Shirox

@MainActor
final class ExtensionInstallerTests: XCTestCase {
    private func entry(_ key: String, _ file: String, raw: [String: Any] = [:]) -> ExtensionRepoEntry {
        ExtensionRepoEntry(key: key, name: key.capitalized, version: "1.0", iconUrl: nil, language: "en",
                           description: nil, fileURL: URL(string: file)!, raw: raw)
    }
    private func repo(_ kind: ExtensionKind, _ entries: [ExtensionRepoEntry]) -> ExtensionRepo {
        ExtensionRepo(kind: kind, name: "R", url: URL(string: "https://raw.test/o/r/main/manifest.json")!,
                      base: URL(string: "https://raw.test/o/r/main/")!, entries: entries)
    }
    private func fetcher(_ files: [String: String]) -> ExtensionInstaller.Fetch {
        { url in guard let s = files[url.absoluteString] else { throw URLError(.fileDoesNotExist) }; return Data(s.utf8) }
    }

    func testNuvioScriptIsWrapped() async throws {
        let e = entry("a", "https://raw.test/o/r/main/providers/a.js", raw: ["supportedTypes": ["tv"]])
        let m = try await ExtensionInstaller.module(entry: e, repo: repo(.nuvio, [e]),
                                                     fetch: fetcher([e.fileURL.absoluteString: "module.exports = { getStreams };"]))
        XCTAssertEqual(m.ext?.kind, .nuvio)
        XCTAssertEqual(m.ext?.key, "a")
        XCTAssertEqual(m.jsonUrl, "https://raw.test/o/r/main/manifest.json#ext=a")
        XCTAssertEqual(m.ext?.repoUrl, "https://raw.test/o/r/main/manifest.json")
        XCTAssertEqual(m.scriptUrl, e.fileURL.absoluteString)
        XCTAssertTrue(m.scriptContent!.hasPrefix("__extDefine(\"main\", function (module, exports, require) {\n"))
        XCTAssertEqual(m.type, "anime")
    }

    func testVegaFilesWrappedSeparately() async throws {
        let e = entry("v", "https://raw.test/o/r/main/dist/v/")
        let files = ["posts", "meta", "stream"].reduce(into: [String: String]()) {
            $0["https://raw.test/o/r/main/dist/v/\($1).js"] = "const BASE = 1; exports.x = BASE;"
        }
        let m = try await ExtensionInstaller.module(entry: e, repo: repo(.vega, [e]), fetch: fetcher(files))
        let script = m.scriptContent!
        for name in ["posts", "meta", "stream"] { XCTAssertTrue(script.contains("__extDefine(\"\(name)\", function")) }
        XCTAssertFalse(script.contains("__extDefine(\"episodes\""))
        XCTAssertTrue(m.ext!.config.contains("https:\\/\\/raw.test\\/o\\/r\\/main\\/") || m.ext!.config.contains("https://raw.test/o/r/main/"))
    }

    func testVegaMissingRequiredFile() async {
        let e = entry("v", "https://raw.test/o/r/main/dist/v/")
        do {
            _ = try await ExtensionInstaller.module(entry: e, repo: repo(.vega, [e]),
                                                     fetch: fetcher(["https://raw.test/o/r/main/dist/v/posts.js": "x"]))
            XCTFail("installed")
        } catch { XCTAssertEqual(error as? ExtensionInstallError, .missingFiles(["meta", "stream"])) }
    }

    func testSkyStreamUnzipsPlugin() async throws {
        // zip of plugin.js only (20 lines of `globalThis.search = 1;`), from ZipReaderTests.
        let zip = Data(base64Encoded: ZipReaderTests().deflated)!
        let e = entry("p.a", "https://raw.test/a.sky", raw: ["baseUrl": "https://a.test", "name": "A"])
        let m = try await ExtensionInstaller.module(entry: e, repo: repo(.skystream, [e])) { _ in zip }
        XCTAssertTrue(m.scriptContent!.hasPrefix("globalThis.search = 1;"))
        XCTAssertEqual(m.baseUrl, "https://a.test")
        XCTAssertEqual(m.ext?.key, "p.a")
    }

    func testStremioNeedsSomethingToSearch() throws {
        let raw: [String: Any] = ["id": "x", "name": "X", "version": "1", "resources": ["stream"], "types": ["movie"], "idPrefixes": ["yt"]]
        let s = StremioManifest(url: URL(string: "https://x.test/manifest.json")!, id: "x", name: "X", version: "1",
                                description: nil, logo: nil, raw: raw)
        XCTAssertThrowsError(try ExtensionInstaller.module(stremio: s)) { XCTAssertEqual($0 as? ExtensionInstallError, .nothingToSearch) }
        var kitsu = raw; kitsu["idPrefixes"] = ["kitsu"]
        let ok = try ExtensionInstaller.module(stremio: StremioManifest(url: s.url, id: "x", name: "X", version: "1",
                                                                       description: nil, logo: nil, raw: kitsu))
        XCTAssertEqual(ok.scriptUrl, "https://x.test/manifest.json")
        XCTAssertEqual(ok.baseUrl, "https://x.test")
    }

    func testStremioAdultRefused() {
        let raw: [String: Any] = ["id": "x", "name": "X", "version": "1", "resources": ["stream"], "types": ["movie"],
                                  "idPrefixes": ["tt"], "behaviorHints": ["adult": true]]
        let s = StremioManifest(url: URL(string: "https://x.test/manifest.json")!, id: "x", name: "X", version: "1",
                                description: nil, logo: nil, raw: raw)
        XCTAssertThrowsError(try ExtensionInstaller.module(stremio: s)) { XCTAssertEqual($0 as? ExtensionInstallError, .adult) }
    }

    func testAdultEntryRefused() async {
        let e = entry("hentaiz", "https://raw.test/h.js")
        do {
            _ = try await ExtensionInstaller.module(entry: e, repo: repo(.nuvio, [e]), fetch: fetcher([:]))
            XCTFail("installed")
        } catch { XCTAssertEqual(error as? ExtensionInstallError, .adult) }
    }

    func testVegaSkipsAnOptionalFileThatIsntJavaScript() async throws {
        // GitHub answers a missing file with a "404: Not Found" page; taken as a script part, its
        // syntax error stopped the whole provider from loading.
        let e = entry("v", "https://raw.test/o/r/main/dist/v/")
        var files = ["posts", "meta", "stream"].reduce(into: [String: String]()) {
            $0["https://raw.test/o/r/main/dist/v/\($1).js"] = "exports.x = 1;"
        }
        files["https://raw.test/o/r/main/dist/v/episodes.js"] = "404: Not Found"
        let m = try await ExtensionInstaller.module(entry: e, repo: repo(.vega, [e]), fetch: fetcher(files))
        XCTAssertFalse(m.scriptContent!.contains("__extDefine(\"episodes\""))

        files["https://raw.test/o/r/main/dist/v/meta.js"] = "404: Not Found"
        do {
            _ = try await ExtensionInstaller.module(entry: e, repo: repo(.vega, [e]), fetch: fetcher(files))
            XCTFail("installed")
        } catch { XCTAssertEqual(error as? ExtensionInstallError, .missingFiles(["meta"])) }
    }

    func testNuvioScriptThatIsntJavaScriptIsRefused() async {
        let e = entry("a", "https://raw.test/a.js")
        do {
            _ = try await ExtensionInstaller.module(entry: e, repo: repo(.nuvio, [e]), fetch: fetcher(["https://raw.test/a.js": "404: Not Found"]))
            XCTFail("installed")
        } catch { XCTAssertEqual(error as? ExtensionInstallError, .noPlugin) }
    }

    // MARK: - Updates

    private func installed(_ kind: ExtensionKind, key: String, version: String = "1.0") -> ModuleDefinition {
        let json = #"{"sourceName":"A","version":"\#(version)","scriptUrl":"https://raw.test/\#(key)","type":"anime","ext":{"kind":"\#(kind.rawValue)","repoUrl":"https://raw.test/o/r/main/manifest.json","key":"\#(key)","config":"{}"}}"#
        return try! JSONDecoder().decode(ModuleDefinition.self, from: Data(json.utf8))
    }

    func testUpdateDecisions() {
        let e = entry("a", "https://raw.test/a.js")
        var r = repo(.nuvio, [e])
        XCTAssertEqual(ExtensionUpdate.decide(installed(.nuvio, key: "a", version: "1.0"), link: .repo(r)), .keep)
        XCTAssertEqual(ExtensionUpdate.decide(installed(.nuvio, key: "a", version: "0.9"), link: .repo(r)), .update)
        XCTAssertEqual(ExtensionUpdate.decide(installed(.nuvio, key: "gone"), link: .repo(r)), .keep)
        // The repo now flags it adult: it was dropped from the list, and the installed one goes too.
        r = ExtensionRepo(kind: .nuvio, name: "R", url: r.url, base: r.base, entries: [], adultKeys: ["a"])
        XCTAssertEqual(ExtensionUpdate.decide(installed(.nuvio, key: "a"), link: .repo(r)), .remove)
    }

    func testStremioUpdateThatTurnsAdultRemoves() {
        let url = URL(string: "https://x.test/manifest.json")!
        let module = installed(.stremio, key: url.absoluteString)
        let raw: [String: Any] = ["id": "x", "name": "X", "version": "2", "resources": ["stream"], "types": ["series"], "behaviorHints": ["adult": true]]
        let m = StremioManifest(url: url, id: "x", name: "X", version: "2", description: nil, logo: nil, raw: raw)
        XCTAssertEqual(ExtensionUpdate.decide(module, link: .stremio(m)), .remove)
    }

    func testDetectRemembersTheAdultEntriesItHid() async throws {
        let data = try JSONSerialization.data(withJSONObject: ["name": "R", "scrapers": [
            ["id": "ok", "name": "Ok", "version": "1", "filename": "a.js"],
            ["id": "h", "name": "Nightly", "version": "1", "filename": "b.js", "categories": ["NSFW"]]]])
        guard case .repo(let r)? = try await ExtensionRepoLoader.detect(data, url: URL(string: "https://raw.test/m.json")!, fetch: { _ in Data() })
        else { return XCTFail() }
        XCTAssertEqual(r.entries.map(\.key), ["ok"])
        XCTAssertEqual(r.adultKeys, ["h"])
    }

    func testRevertReinstallsFromTheModulesOwnLink() async throws {
        // Reverting an edited script re-fetches it through the installer, wrapped as at install —
        // not by downloading scriptUrl raw (for Vega that's a folder).
        let manifest = #"{"name":"R","scrapers":[{"id":"a","name":"A","version":"2","filename":"a.js"}]}"#
        let files = ["https://raw.test/o/r/main/manifest.json": manifest, "https://raw.test/o/r/main/a.js": "module.exports = {};"]
        var module = installed(.nuvio, key: "a", version: "1.0")
        module.jsonUrl = "https://raw.test/o/r/main/manifest.json#ext=a"
        module.scriptContent = "edited"
        let fresh = try await ExtensionInstaller.reinstall(module, fetch: fetcher(files))
        XCTAssertTrue(fresh.scriptContent!.hasPrefix("__extDefine(\"main\""))
        XCTAssertEqual(fresh.version, "2")
    }
}
