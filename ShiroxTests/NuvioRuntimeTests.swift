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
        // The name is the title and every line of the scraper's title goes under it; the
        // quality is already among them, so it isn't added again.
        XCTAssertEqual(streams[0]["title"] as? String, "Nuv")
        XCTAssertEqual(streams[0]["details"] as? String, "1080p\nx")
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

    func testMappedShowFirstThenTheSearch() throws {
        let c = ctx(media: ["anilistId": 1, "title": "One", "tmdbId": 7, "tmdbType": "tv"],
                    routes: ["\(tmdb)/tv/7?api_key=TMDBKEY&include_adult=false": ["id": 7, "name": "Mapped"],
                             "\(tmdb)/search/multi?api_key=TMDBKEY&include_adult=false&query=one": ["results": [
                                ["id": 7, "media_type": "tv", "name": "Mapped"], ["id": 8, "media_type": "tv", "name": "Other"]]]])
        let items = ExtensionJSHarness.json(try ExtensionJSHarness.call(c, "searchResults", ["one"]).get()) as! [[String: Any]]
        XCTAssertEqual(items.map { $0["href"] as? String }, ["tmdb:tv:7", "tmdb:tv:8"])
    }

    func testTheShowsOwnIdsAnswerTheScrapersLookups() throws {
        // AnimePahe's scraper asks a Hugging Face service for the MAL id, then Jikan for the
        // title, before it searches; the service is gone. On an anime page Shirox knows both.
        let script = """
        __extDefine("main", function (module, exports, require) {
          async function getStreams(tmdbId, type, season, episode) {
            const map = await (await fetch(`https://id-mapping-api-malid.hf.space/api/resolve?id=tt1&s=${season}&e=${episode}`)).json();
            const anime = await (await fetch(`https://api.jikan.moe/v4/anime/${map.mal_id}`)).json();
            return [{ name: "P", title: anime.data.title + " " + map.mal_episode, url: "https://cdn.test/" + map.mal_id + "/" + map.mal_episode + ".m3u8" }];
          }
          module.exports = { getStreams };
        });
        """
        let c = ExtensionJSHarness.context(kind: "nuvio", key: "animepahe", config: ["supportedTypes": ["tv"]],
                                           media: ["anilistId": 154587, "malId": 52991, "title": "Sousou no Frieren", "englishTitle": "Frieren",
                                                   "imdbId": "tt1", "tmdbId": 7, "tmdbType": "tv", "season": 1, "episodeOffset": 12],
                                           script: script)
        let s = ExtensionJSHarness.json(try ExtensionJSHarness.call(c, "extractStreamUrl", ["tmdb:tv:7:1:13"]).get()) as! [String: Any]
        let first = (s["streams"] as! [[String: Any]])[0]
        XCTAssertEqual(first["streamUrl"] as? String, "https://cdn.test/52991/1.m3u8")
        XCTAssertEqual(first["title"] as? String, "P")
        XCTAssertEqual(first["details"] as? String, "Sousou no Frieren 1")
    }

    func testOtherShowsLookupsGoToTheNetwork() throws {
        // Asked about a show other than the one being opened, the real service answers (here: nothing).
        let script = """
        __extDefine("main", function (module, exports, require) {
          async function getStreams() {
            const res = await fetch("https://api.jikan.moe/v4/anime/1");
            return res.ok ? [{ name: "X", url: "https://cdn.test/x.m3u8" }] : [];
          }
          module.exports = { getStreams };
        });
        """
        let c = ExtensionJSHarness.context(kind: "nuvio", key: "x", config: ["supportedTypes": ["tv"]],
                                           media: ["anilistId": 1, "malId": 52991, "title": "T", "tmdbId": 7, "tmdbType": "tv"], script: script)
        XCTAssertEqual(ExtensionJSHarness.call(c, "extractStreamUrl", ["tmdb:tv:7:1:1"]),
                       .failure(.init(message: "Test found no playable streams for this episode.")))
    }
}
