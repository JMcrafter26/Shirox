import JavaScriptCore
import XCTest
@testable import Shirox

@MainActor
final class SkyStreamRuntimeTests: XCTestCase {
    let plugin = """
    (function () {
      async function search(q, cb) {
        const res = await http_get(manifest.baseUrl + "/s?q=" + q, { "User-Agent": "x" });
        const doc = await parseHtml(res.body);
        cb({ success: true, data: doc.querySelectorAll("a").map(a => new MultimediaItem({
          title: a.textContent, url: a.getAttribute("href"), posterUrl: "p.jpg", type: "series",
          isAdult: a.getAttribute("data-adult") === "1" })) });
      }
      function load(url, cb) {
        if (url === "/bad") return cb({ success: false, error: "gone" });
        cb({ success: true, data: new MultimediaItem({ title: "S", url, posterUrl: "", type: url === "/movie" ? "movie" : "series",
          description: "desc", episodes: url === "/movie" ? [] : [
            new Episode({ name: "S2E1", url: "/e/2/1", season: 2, episode: 1 }),
            new Episode({ name: "S1E2", url: "/e/1/2", season: 1, episode: 2 }),
            new Episode({ name: "S1E1", url: "/e/1/1", season: 1, episode: 1 }) ] }) });
      }
      async function loadStreams(url, cb) {
        cb({ success: true, data: [
          new StreamResult({ url: "https://cdn.test/v.m3u8", quality: "1080p", headers: { Referer: "r" },
                             subtitles: [{ url: "https://s.test/en.vtt", label: "English", lang: "en" }] }),
          new StreamResult({ url: "magnet:?xt=1", quality: "4K" }),
          new StreamResult({ url: "MAGIC_PROXY_v1aGk=", quality: "720p" }),
          new StreamResult({ url: "https://cdn.test/drm.mpd", drmKid: "k", quality: "1080p" }) ] });
      }
      globalThis.search = search; globalThis.load = load; globalThis.loadStreams = loadStreams;
    })();
    """

    private func ctx(routes: [String: Any] = [:]) -> JSContext {
        ExtensionJSHarness.context(kind: "skystream", key: "p.a",
                                   config: ["manifest": ["name": "A", "packageName": "p.a", "baseUrl": "https://a.test"]],
                                   routes: routes, script: plugin)
    }

    func testSearchDropsAdultItems() throws {
        let c = ctx(routes: ["https://a.test/s?q=one": #"<a href="/one">One</a><a href="/x" data-adult="1">X</a>"#])
        let items = ExtensionJSHarness.json(try ExtensionJSHarness.call(c, "searchResults", ["one"]).get()) as! [[String: Any]]
        XCTAssertEqual(items.map { $0["href"] as? String }, ["/one"])
    }

    func testEpisodesSortedAndNumbered() throws {
        let c = ctx()
        let list = ExtensionJSHarness.json(try ExtensionJSHarness.call(c, "extractEpisodes", ["/show"]).get()) as! [[String: Any]]
        XCTAssertEqual(list.map { $0["href"] as? String }, ["/e/1/1", "/e/1/2", "/e/2/1"])
        XCTAssertEqual(list.map { $0["number"] as? Int }, [1, 2, 3])
        let movie = ExtensionJSHarness.json(try ExtensionJSHarness.call(c, "extractEpisodes", ["/movie"]).get()) as! [[String: Any]]
        XCTAssertEqual(movie.map { $0["href"] as? String }, ["/movie"])
    }

    func testStreamsDropTorrentProxyAndDRM() throws {
        let s = ExtensionJSHarness.json(try ExtensionJSHarness.call(ctx(), "extractStreamUrl", ["/e/1/1"]).get()) as! [String: Any]
        let streams = s["streams"] as! [[String: Any]]
        XCTAssertEqual(streams.map { $0["streamUrl"] as? String }, ["https://cdn.test/v.m3u8"])
        XCTAssertEqual(s["subtitle"] as? String, "https://s.test/en.vtt")
    }

    func testSkyStreamFailureCallback() {
        XCTAssertEqual(ExtensionJSHarness.call(ctx(), "extractEpisodes", ["/bad"]), .failure(.init(message: "Test: gone")))
    }

    func testManifestBaseUrlSet() {
        XCTAssertEqual(ctx().evaluateScript("manifest.baseUrl")!.toString(), "https://a.test")
    }
}
