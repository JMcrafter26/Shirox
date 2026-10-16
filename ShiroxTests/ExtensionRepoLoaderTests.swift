import XCTest
@testable import Shirox

final class ExtensionRepoLoaderTests: XCTestCase {
    func testModuleRoundTripsExtensionInfo() throws {
        let json = #"{"sourceName":"A","version":"1","scriptUrl":"https://x/a.js","type":"anime","#
            + #""ext":{"kind":"nuvio","repoUrl":"https://x/manifest.json","key":"a","config":"{}"}}"#
        let module = try JSONDecoder().decode(ModuleDefinition.self, from: Data(json.utf8))
        XCTAssertEqual(module.ext?.kind, .nuvio)
        let again = try JSONDecoder().decode(ModuleDefinition.self, from: JSONEncoder().encode(module))
        XCTAssertEqual(again.ext, module.ext)
        XCTAssertEqual(ExtensionKind.skystream.badge, "SkyStream")
    }

    private func load(_ object: Any, url: String, extra: [String: Any] = [:]) async throws -> ExtensionLink? {
        let data = try JSONSerialization.data(withJSONObject: object)
        return try await ExtensionRepoLoader.detect(data, url: URL(string: url)!) { u in
            guard let v = extra[u.absoluteString] else { throw URLError(.fileDoesNotExist) }
            return try JSONSerialization.data(withJSONObject: v)
        }
    }

    func testStremioManifest() async throws {
        let m: [String: Any] = ["id": "org.x", "name": "X", "version": "1.2.0", "resources": ["stream"], "types": ["series"]]
        guard case .stremio(let s)? = try await load(m, url: "https://x.test/cfg/manifest.json") else { return XCTFail() }
        XCTAssertEqual(s.name, "X"); XCTAssertEqual(s.version, "1.2.0")
    }

    func testStremioSchemeBecomesHTTPS() {
        XCTAssertEqual(ExtensionRepoLoader.normalized(URL(string: "stremio://x.test/manifest.json")!).absoluteString,
                       "https://x.test/manifest.json")
    }

    func testNuvioRepo() async throws {
        let m: [String: Any] = ["name": "R", "scrapers": [
            ["id": "a", "name": "A", "version": "1.0.0", "filename": "providers/a.js", "supportedTypes": ["tv"], "enabled": true],
            ["id": "off", "name": "Off", "version": "1", "filename": "providers/off.js", "enabled": false]]]
        guard case .repo(let r)? = try await load(m, url: "https://raw.test/o/r/main/manifest.json") else { return XCTFail() }
        XCTAssertEqual(r.kind, .nuvio)
        XCTAssertEqual(r.entries.map(\.key), ["a"])
        XCTAssertEqual(r.entries[0].fileURL.absoluteString, "https://raw.test/o/r/main/providers/a.js")
    }

    func testVegaRepo() async throws {
        let m: [[String: Any]] = [["display_name": "V", "value": "v", "version": "2.1", "type": "global", "disabled": false],
                                  ["display_name": "D", "value": "d", "version": "1", "disabled": true]]
        guard case .repo(let r)? = try await load(m, url: "https://raw.githubusercontent.com/o/vega/main/manifest.json") else { return XCTFail() }
        XCTAssertEqual(r.kind, .vega)
        XCTAssertEqual(r.entries.map(\.key), ["v"])
        XCTAssertEqual(r.entries[0].fileURL.absoluteString, "https://raw.githubusercontent.com/o/vega/main/dist/v/")
        XCTAssertEqual(r.name, "o/vega")
    }

    func testSkyStreamRepoFollowsPluginLists() async throws {
        let repo: [String: Any] = ["name": "Stars", "packageName": "p", "pluginLists": ["https://raw.test/list.json"]]
        let list: [[String: Any]] = [["packageName": "p.a", "name": "A", "version": 3, "baseUrl": "https://a.test",
                                      "languages": ["en"], "categories": ["Movie"], "url": "https://raw.test/a.sky"]]
        guard case .repo(let r)? = try await load(repo, url: "https://raw.test/repo.json", extra: ["https://raw.test/list.json": list])
        else { return XCTFail() }
        XCTAssertEqual(r.kind, .skystream)
        XCTAssertEqual(r.entries.map(\.version), ["3"])
    }

    func testRepoListHidesAdultEntries() async throws {
        let nuvio: [String: Any] = ["name": "R", "scrapers": [
            ["id": "ok", "name": "AnimeOK", "version": "1", "filename": "a.js"],
            ["id": "hanime", "name": "HAnime", "version": "1", "filename": "b.js", "description": "hentai streams"],
            ["id": "x", "name": "XXX Flix", "version": "1", "filename": "c.js"]]]
        guard case .repo(let r)? = try await load(nuvio, url: "https://raw.test/manifest.json") else { return XCTFail() }
        XCTAssertEqual(r.entries.map(\.key), ["ok"])

        let sky: [String: Any] = ["name": "S", "pluginLists": ["https://raw.test/l.json"]]
        let list: [[String: Any]] = [["packageName": "p.ok", "name": "Ok", "version": 1, "url": "https://raw.test/ok.sky", "categories": ["Anime"]],
                                     ["packageName": "p.n", "name": "Night", "version": 1, "url": "https://raw.test/n.sky", "categories": ["NSFW"]]]
        guard case .repo(let s)? = try await load(sky, url: "https://raw.test/repo.json", extra: ["https://raw.test/l.json": list])
        else { return XCTFail() }
        XCTAssertEqual(s.entries.map(\.key), ["p.ok"])
    }

    func testAdultStremioManifest() {
        XCTAssertTrue(ExtensionAdultCheck.isAdult(stremio: ["name": "X", "behaviorHints": ["adult": true]]))
        XCTAssertTrue(ExtensionAdultCheck.isAdult(stremio: ["name": "X", "catalogs": [["name": "Hentai Top", "type": "movie", "id": "h"]]]))
        XCTAssertTrue(ExtensionAdultCheck.isAdult(stremio: ["name": "X", "catalogs": [["name": "Top", "type": "movie", "id": "t",
            "extra": [["name": "genre", "options": ["Action", "Hentai"]]]]]]))
        XCTAssertFalse(ExtensionAdultCheck.isAdult(stremio: ["name": "Anime Kitsu", "catalogs": [["name": "Trending", "type": "anime", "id": "k"]]]))
    }

    func testUnknownJSONIsNotAnExtension() async throws {
        let none = try await load(["sourceName": "Sora", "version": "1", "scriptUrl": "x", "type": "anime"], url: "https://x/m.json")
        XCTAssertNil(none)
    }

    func testEntryLinkNamesItsProvider() async throws {
        let url = "https://raw.test/o/r/main/manifest.json#ext=a"
        XCTAssertEqual(ExtensionRepoLoader.entryKey(in: URL(string: url)!), "a")
        XCTAssertNil(ExtensionRepoLoader.entryKey(in: URL(string: "https://raw.test/manifest.json")!))
        let m: [String: Any] = ["name": "R", "scrapers": [["id": "a", "name": "A", "version": "1", "filename": "a.js"]]]
        guard case .repo(let r)? = try await load(m, url: url) else { return XCTFail() }
        XCTAssertEqual(r.url.absoluteString, "https://raw.test/o/r/main/manifest.json")
    }

    // printf '{"packageName":"p.one","name":"One","version":4,"baseUrl":"https://one.test","categories":["Anime"]}' > plugin.json,
    // a one-line plugin.js, then zip -X one.sky plugin.json plugin.js && base64 -i one.sky
    static let oneSky = "UEsDBBQAAAAIADgFUF2YY9S9WgAAAGQAAAALAAAAcGx1Z2luLmpzb26rVipITM5OTE/1S8xNVbJSKtDLz0tV0lHKg3D9wZyy1KLizPw8JSsTHaWkxOLU0KIcoFxGSUlBsZW+PlCDXklqcQlQYXJiSWp6flFmarGSVbSSY14m0JDYWgBQSwMECgAAAAAAOAVQXYlGGx5LAAAASwAAAAkAAABwbHVnaW4uanNnbG9iYWxUaGlzLnNlYXJjaCA9IGZ1bmN0aW9uIChxLCBjYikgeyBjYih7IHN1Y2Nlc3M6IHRydWUsIGRhdGE6IFtdIH0pOyB9OwpQSwECHgMUAAAACAA4BVBdmGPUvVoAAABkAAAACwAAAAAAAAABAAAApIEAAAAAcGx1Z2luLmpzb25QSwECHgMKAAAAAAA4BVBdiUYbHksAAABLAAAACQAAAAAAAAABAAAApIGDAAAAcGx1Z2luLmpzUEsFBgAAAAACAAIAcAAAAPUAAAAAAA=="

    func testASingleSkyFileIsAOneEntryRepo() async throws {
        let url = URL(string: "https://raw.test/dist/one.sky")!
        let link = try await ExtensionRepoLoader.detect(Data(base64Encoded: Self.oneSky)!, url: url) { _ in Data() }
        guard case .repo(let r)? = link else { return XCTFail("not detected") }
        XCTAssertEqual(r.kind, .skystream)
        XCTAssertEqual(r.entries.map(\.key), ["p.one"])
        XCTAssertEqual(r.entries.first?.version, "4")
        XCTAssertEqual(r.entries.first?.fileURL, url)
        XCTAssertTrue(ExtensionRepoLoader.isSingleFile(r))
    }

    func testOnlyWebLinksAndPlayableTypes() async throws {
        let m: [String: Any] = ["name": "R", "scrapers": [
            ["id": "ok", "name": "Ok", "version": "1", "filename": "a.js", "supportedTypes": ["tv"]],
            ["id": "local", "name": "Local", "version": "1", "filename": "file:///etc/hosts"],
            ["id": "books", "name": "Books", "version": "1", "filename": "b.js", "supportedTypes": ["book"]]]]
        guard case .repo(let r)? = try await load(m, url: "https://raw.test/manifest.json") else { return XCTFail() }
        XCTAssertEqual(r.entries.map(\.key), ["ok"])

        let sky: [String: Any] = ["name": "S", "pluginLists": ["https://raw.test/l.json"]]
        let list: [[String: Any]] = [["packageName": "p.tv", "name": "TV", "version": 1, "url": "https://raw.test/a.sky", "categories": ["Livestream"]],
                                     ["packageName": "p.ok", "name": "Ok", "version": 1, "url": "https://raw.test/b.sky", "categories": ["Movie", "Livestream"]],
                                     ["packageName": "p.f", "name": "F", "version": 1, "url": "file:///tmp/x.sky"]]
        guard case .repo(let s)? = try await load(sky, url: "https://raw.test/repo.json", extra: ["https://raw.test/l.json": list])
        else { return XCTFail() }
        XCTAssertEqual(s.entries.map(\.key), ["p.ok"])
    }

    func testLinkErrorNamesTheExtensionFormats() {
        XCTAssertTrue(ModuleLinkError.notAModule.localizedDescription.contains("Stremio"))
    }
}
