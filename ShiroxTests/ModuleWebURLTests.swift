import XCTest
@testable import Shirox

final class ModuleWebURLTests: XCTestCase {
    private func module(baseUrl: String?, local: Bool = false, jellyfin: Bool = false) throws -> ModuleDefinition {
        let base = baseUrl.map { "\"\($0)\"" } ?? "null"
        let json = """
        {"sourceName":"Test","version":"1.0","baseUrl":\(base),
         "scriptUrl":"https://example.com/x.js","type":"anime",
         "supportsLocalPlayback":\(local),"supportsJellyfin":\(jellyfin)}
        """
        return try JSONDecoder().decode(ModuleDefinition.self, from: Data(json.utf8))
    }

    func testAbsoluteHrefIsUsedAsIs() throws {
        let url = try module(baseUrl: "https://site.to").webURL(forHref: "https://site.to/anime/frieren-123")
        XCTAssertEqual(url?.absoluteString, "https://site.to/anime/frieren-123")
    }

    func testRootRelativeHrefResolvesAgainstBaseUrl() throws {
        let url = try module(baseUrl: "https://site.to/").webURL(forHref: "/anime/frieren-123")
        XCTAssertEqual(url?.absoluteString, "https://site.to/anime/frieren-123")
    }

    func testPathWithoutLeadingSlashResolvesAgainstBaseUrl() throws {
        // Anikuro gives "anime/147864".
        let url = try module(baseUrl: "https://anikuro.to").webURL(forHref: "anime/147864")
        XCTAssertEqual(url?.absoluteString, "https://anikuro.to/anime/147864")
    }

    func testProtocolRelativeHrefGetsHTTPS() throws {
        let url = try module(baseUrl: nil).webURL(forHref: "//site.to/anime/frieren")
        XCTAssertEqual(url?.absoluteString, "https://site.to/anime/frieren")
    }

    func testBareIdentifierIsNotAWebPage() throws {
        // Seanime providers and some modules pass ids, not paths; guessing a URL would open junk.
        XCTAssertNil(try module(baseUrl: "https://site.to").webURL(forHref: "frieren-123"))
    }

    func testRelativeHrefWithoutBaseUrlIsNil() throws {
        XCTAssertNil(try module(baseUrl: nil).webURL(forHref: "/anime/frieren"))
    }

    func testNonWebSchemeIsNil() throws {
        XCTAssertNil(try module(baseUrl: "https://site.to").webURL(forHref: "file:///tmp/video.mkv"))
    }

    func testWithoutModuleOnlyAbsoluteHrefsResolve() {
        XCTAssertEqual(ModuleDefinition.webURL(forHref: "https://animepahe.com/anime/x", baseUrl: nil)?.absoluteString,
                       "https://animepahe.com/anime/x")
        XCTAssertNil(ModuleDefinition.webURL(forHref: "anime/x", baseUrl: nil))
    }

    func testLocalAndJellyfinModulesHaveNoWebPage() throws {
        XCTAssertNil(try module(baseUrl: "https://site.to", local: true).webURL(forHref: "https://site.to/a"))
        XCTAssertNil(try module(baseUrl: "http://192.168.1.2:8096", jellyfin: true)
            .webURL(forHref: "http://192.168.1.2:8096/Items/abc"))
    }
}

final class ModuleWebLinksTests: XCTestCase {
    private func makeStore() -> ModuleWebLinks {
        let name = "ModuleWebLinksTests-\(UUID().uuidString)"
        return ModuleWebLinks(defaults: UserDefaults(suiteName: name)!)
    }

    func testSeanimeResultPageIsRememberedForItsId() {
        let store = makeStore()
        store.record([["title": "Frieren", "href": "mdkytdqp", "pageUrl": "https://anizone.to/anime/mdkytdqp"]],
                     moduleId: "anizone")
        XCTAssertEqual(store.url(moduleId: "anizone", href: "mdkytdqp")?.absoluteString,
                       "https://anizone.to/anime/mdkytdqp")
        XCTAssertNil(store.url(moduleId: "other", href: "mdkytdqp"))
    }

    func testMangaResultsKeyedByTheirId() {
        let store = makeStore()
        store.record([["title": "M", "id": "abc", "pageUrl": "https://site.to/manga/abc"]], hrefKey: "id", moduleId: "m")
        XCTAssertEqual(store.url(moduleId: "m", href: "abc")?.absoluteString, "https://site.to/manga/abc")
    }

    func testLinkHrefsAndNonWebPagesAreNotStored() {
        let store = makeStore()
        store.record([["href": "https://site.to/a", "pageUrl": "https://site.to/b"],
                      ["href": "slug", "pageUrl": "not a url"]], moduleId: "m")
        XCTAssertNil(store.url(moduleId: "m", href: "https://site.to/a"))
        XCTAssertNil(store.url(moduleId: "m", href: "slug"))
    }

    func testLinksSurviveRelaunch() {
        let defaults = UserDefaults(suiteName: "ModuleWebLinksTests-\(UUID().uuidString)")!
        ModuleWebLinks(defaults: defaults).record([["href": "x", "pageUrl": "https://site.to/x"]], moduleId: "m")
        XCTAssertEqual(ModuleWebLinks(defaults: defaults).url(moduleId: "m", href: "x")?.absoluteString, "https://site.to/x")
    }
}

final class SimklSearchIDTests: XCTestCase {
    func testFirstMatchGivesSimklID() {
        let json = #"[{"type":"anime","title":"Sousou no Frieren","ids":{"simkl":2213640,"slug":"sousou-no-frieren","mal":"52991"}}]"#
        XCTAssertEqual(SimklCatalog.decodeSearchID(Data(json.utf8)), 2213640)
    }

    func testNoMatchIsNil() {
        XCTAssertNil(SimklCatalog.decodeSearchID(Data("[]".utf8)))
    }

    func testLoneObjectAndStringID() {
        let json = #"{"type":"anime","ids":{"simkl_id":"42"}}"#
        XCTAssertEqual(SimklCatalog.decodeSearchID(Data(json.utf8)), 42)
    }

    func testLookupPrefersMAL() {
        XCTAssertEqual(SimklCatalog.lookupKey(mal: 5, anilist: 9), "mal:5")
        XCTAssertEqual(SimklCatalog.lookupKey(mal: nil, anilist: 9), "anilist:9")
        XCTAssertNil(SimklCatalog.lookupKey(mal: nil, anilist: nil))
    }
}

