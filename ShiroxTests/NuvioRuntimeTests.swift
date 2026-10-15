import JavaScriptCore
import XCTest
@testable import Shirox

@MainActor
final class NuvioRuntimeTests: XCTestCase {
    let tmdb = "https://api.themoviedb.org/3"
    let scraper = """
    __extDefine("main", function (module, exports, require) {
      const cheerio = require("cheerio-without-node-native");
      function getStreams(tmdbId, type, season, episode) {
        globalThis.__args = [tmdbId, type, season, episode].join(",");
        return Promise.resolve([
          { name: "Nuv", title: "1080p\\nx", url: "https://cdn.test/a.m3u8", quality: "1080p", headers: { Referer: "https://r/" } },
          { name: "Tor", title: "t", url: "magnet:?xt=abc" }]);
      }
      module.exports = { getStreams };
    });
    """

    private func ctx(media: [String: Any]? = nil, routes: [String: Any] = [:]) -> JSContext {
        ExtensionJSHarness.context(kind: "nuvio", key: "s", config: ["supportedTypes": ["tv", "movie"]],
                                   media: media, routes: routes, script: scraper)
    }

    func testSearchFiltersAdultAndTypes() throws {
        let c = ctx(routes: ["\(tmdb)/search/multi?api_key=TMDBKEY&include_adult=false&query=one": ["results": [
            ["id": 1, "media_type": "tv", "name": "One", "poster_path": "/p.jpg"],
            ["id": 2, "media_type": "person", "name": "Someone"],
            ["id": 3, "media_type": "movie", "title": "Two", "adult": true]]]])
        let items = ExtensionJSHarness.json(try ExtensionJSHarness.call(c, "searchResults", ["one"]).get()) as! [[String: Any]]
        XCTAssertEqual(items.map { $0["href"] as? String }, ["tmdb:tv:1"])
        XCTAssertEqual(items[0]["image"] as? String, "https://image.tmdb.org/t/p/w500/p.jpg")
    }

    func testStreamsCallGetStreamsAndDropTorrents() throws {
        let c = ctx()
        let s = ExtensionJSHarness.json(try ExtensionJSHarness.call(c, "extractStreamUrl", ["tmdb:tv:7:2:5"]).get()) as! [String: Any]
        XCTAssertEqual(c.evaluateScript("__args")!.toString(), "7,tv,2,5")
        let streams = s["streams"] as! [[String: Any]]
        XCTAssertEqual(streams.count, 1)
        XCTAssertEqual(streams[0]["title"] as? String, "Nuv · 1080p")
    }

    func testMovieStreams() throws {
        let c = ctx()
        _ = try ExtensionJSHarness.call(c, "extractStreamUrl", ["tmdb:movie:9"]).get()
        XCTAssertEqual(c.evaluateScript("__args")!.toString(), "9,movie,,")
    }

    func testNuvioSeasonOffsetFromMedia() throws {
        let eps: [[String: Any]] = (1...24).map { ["episode_number": $0, "name": "E\($0)"] }
        let c = ctx(media: ["anilistId": 1, "title": "X", "tmdbId": 7, "tmdbType": "tv", "season": 1, "episodeOffset": 12],
                    routes: ["\(tmdb)/tv/7/season/1?api_key=TMDBKEY&include_adult=false": ["episodes": eps]])
        let list = ExtensionJSHarness.json(try ExtensionJSHarness.call(c, "extractEpisodes", ["tmdb:tv:7"]).get()) as! [[String: Any]]
        XCTAssertEqual(list.count, 12)
        XCTAssertEqual(list[0]["href"] as? String, "tmdb:tv:7:1:13")
        XCTAssertEqual(list[0]["number"] as? Int, 1)
    }

    func testSearchTabListsEverySeason() throws {
        let c = ctx(routes: [
            "\(tmdb)/tv/7?api_key=TMDBKEY&include_adult=false": ["seasons": [["season_number": 0], ["season_number": 1], ["season_number": 2]]],
            "\(tmdb)/tv/7/season/1?api_key=TMDBKEY&include_adult=false": ["episodes": [["episode_number": 1], ["episode_number": 2]]],
            "\(tmdb)/tv/7/season/2?api_key=TMDBKEY&include_adult=false": ["episodes": [["episode_number": 1]]]])
        let list = ExtensionJSHarness.json(try ExtensionJSHarness.call(c, "extractEpisodes", ["tmdb:tv:7"]).get()) as! [[String: Any]]
        XCTAssertEqual(list.map { $0["href"] as? String }, ["tmdb:tv:7:1:1", "tmdb:tv:7:1:2", "tmdb:tv:7:2:1"])
        XCTAssertEqual(list.map { $0["number"] as? Int }, [1, 2, 3])
    }

    func testNuvioSecondCourStopsAtTheNextCour() throws {
        let eps: [[String: Any]] = (1...36).map { ["episode_number": $0] }
        let c = ctx(media: ["anilistId": 1, "title": "X", "tmdbId": 7, "tmdbType": "tv", "season": 1, "episodeOffset": 12, "episodeEnd": 24],
                    routes: ["\(tmdb)/tv/7/season/1?api_key=TMDBKEY&include_adult=false": ["episodes": eps]])
        let list = ExtensionJSHarness.json(try ExtensionJSHarness.call(c, "extractEpisodes", ["tmdb:tv:7"]).get()) as! [[String: Any]]
        XCTAssertEqual(list.count, 12)
        XCTAssertEqual(list.last?["href"] as? String, "tmdb:tv:7:1:24")
    }

    func testMissingTMDBSeasonFallsBackToEverySeason() throws {
        let c = ctx(media: ["anilistId": 1, "title": "X", "tmdbId": 7, "tmdbType": "tv", "season": 3, "episodeOffset": 0],
                    routes: [
                        "\(tmdb)/tv/7/season/3?api_key=TMDBKEY&include_adult=false": [404, "{}"],
                        "\(tmdb)/tv/7?api_key=TMDBKEY&include_adult=false": ["seasons": [["season_number": 1]]],
                        "\(tmdb)/tv/7/season/1?api_key=TMDBKEY&include_adult=false": ["episodes": [["episode_number": 1], ["episode_number": 2]]]])
        let list = ExtensionJSHarness.json(try ExtensionJSHarness.call(c, "extractEpisodes", ["tmdb:tv:7"]).get()) as! [[String: Any]]
        XCTAssertEqual(list.map { $0["href"] as? String }, ["tmdb:tv:7:1:1", "tmdb:tv:7:1:2"])
    }
}
