import JavaScriptCore
import XCTest
@testable import Shirox

@MainActor
final class VegaRuntimeTests: XCTestCase {
    private func provider(meta: String, stream: String = "exports.getStream = async () => [];", episodes: String? = nil) -> String {
        var s = """
        __extDefine("posts", function (module, exports, require) { const BASE = "https://v.test";
          exports.getSearchPosts = async ({ searchQuery, providerContext }) => {
            const r = await providerContext.axios.get(BASE + "/s?q=" + searchQuery, { headers: providerContext.commonHeaders });
            const $ = providerContext.cheerio.load(r.data);
            return $("a").toArray().map(a => ({ title: $(a).text(), link: $(a).attr("href"), image: "i.jpg" }));
          };
          exports.getPosts = async () => [];
        });
        __extDefine("meta", function (module, exports, require) { const BASE = "dup"; \(meta) });
        __extDefine("stream", function (module, exports, require) { \(stream) });
        """
        if let episodes { s += "\n__extDefine(\"episodes\", function (module, exports, require) { \(episodes) });" }
        return s
    }
    private func ctx(_ script: String, routes: [String: Any] = [:]) -> JSContext {
        ExtensionJSHarness.context(kind: "vega", key: "v", config: ["repoBase": "https://raw.test/o/r/main/", "value": "v"],
                                   routes: routes, script: script)
    }

    func testSearchThroughProviderContext() throws {
        let c = ctx(provider(meta: "exports.getMeta = async () => ({});"),
                    routes: ["https://v.test/s?q=one": #"<a href="/one">One</a><a href="/hentai">Hentai Show</a>"#])
        let items = ExtensionJSHarness.json(try ExtensionJSHarness.call(c, "searchResults", ["one"]).get()) as! [[String: Any]]
        XCTAssertEqual(items.map { $0["href"] as? String }, ["/one"])
    }

    func testSeriesEpisodesFromLinkListPerSeason() throws {
        let meta = """
        exports.getMeta = async ({ link }) => ({ title: "S", synopsis: "syn", type: "series", linkList: [
          { title: "Season 1 1080p", directLinks: [{ title: "Episode 1", link: "s1e1" }, { title: "Episode 2", link: "s1e2" }] },
          { title: "Season 1 720p",  directLinks: [{ title: "Episode 1", link: "low1" }] },
          { title: "Season 2 1080p", episodesLink: "s2" } ] });
        """
        let eps = "exports.getEpisodes = async ({ url }) => [{ title: \"Episode 1\", link: url + \"e1\" }];"
        let c = ctx(provider(meta: meta, episodes: eps))
        let list = ExtensionJSHarness.json(try ExtensionJSHarness.call(c, "extractEpisodes", ["/show"]).get()) as! [[String: Any]]
        XCTAssertEqual(list.map { $0["number"] as? Int }, [1, 2, 3])
        XCTAssertTrue((list[2]["href"] as! String).contains("s2e1"))
        let details = ExtensionJSHarness.json(try ExtensionJSHarness.call(c, "extractDetails", ["/show"]).get()) as! [[String: Any]]
        XCTAssertEqual(details[0]["description"] as? String, "syn")
    }

    func testMovieIsOneEpisodeAndStreamsKeepType() throws {
        let meta = "exports.getMeta = async () => ({ title: \"M\", type: \"movie\", linkList: [{ title: \"1080p\", directLinks: [{ title: \"Movie\", link: \"m1\" }] }] });"
        let stream = """
        exports.getStream = async ({ link, type }) => { globalThis.__got = link + "|" + type;
          return [{ server: "Srv", link: "https://cdn.test/m.mp4", type: "mp4", quality: "1080", headers: { Referer: "r" },
                    subtitles: [{ title: "English", language: "en", type: "text/vtt", uri: "https://s.test/en.vtt" }] },
                  { server: "Tor", link: "magnet:?xt=1", type: "torrent" }]; };
        """
        let c = ctx(provider(meta: meta, stream: stream))
        let list = ExtensionJSHarness.json(try ExtensionJSHarness.call(c, "extractEpisodes", ["/m"]).get()) as! [[String: Any]]
        XCTAssertEqual(list.count, 1)
        let s = ExtensionJSHarness.json(try ExtensionJSHarness.call(c, "extractStreamUrl", [list[0]["href"] as! String]).get()) as! [String: Any]
        XCTAssertEqual(c.evaluateScript("__got")!.toString(), "m1|movie")
        XCTAssertEqual((s["streams"] as! [[String: Any]]).map { $0["title"] as? String }, ["Srv · 1080p"])
        XCTAssertEqual(s["subtitle"] as? String, "https://s.test/en.vtt")
    }

    func testVegaErrorCarriesMessage() {
        let c = ctx(provider(meta: "exports.getMeta = async () => { throw new Error(\"site changed\"); };"))
        XCTAssertEqual(ExtensionJSHarness.call(c, "extractEpisodes", ["/x"]), .failure(.init(message: "Test: site changed")))
    }

    func testOpenWebViewRejects() {
        let c = ctx(provider(meta: "exports.getMeta = async ({ providerContext }) => providerContext.openWebView(\"https://x\", {});"))
        XCTAssertEqual(ExtensionJSHarness.call(c, "extractEpisodes", ["/x"]),
                       .failure(.init(message: "Test: Shirox can't open a challenge page for this provider.")))
    }
}
