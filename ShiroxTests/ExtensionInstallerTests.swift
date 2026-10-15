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
}
