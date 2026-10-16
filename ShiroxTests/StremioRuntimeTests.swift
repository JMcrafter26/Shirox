import JavaScriptCore
import XCTest
@testable import Shirox

@MainActor
final class StremioRuntimeTests: XCTestCase {
    let base = "https://addon.test/cfg"
    let kitsu = "https://anime-kitsu.strem.fun"
    let cinemeta = "https://v3-cinemeta.strem.io"

    private func ctx(manifest: [String: Any], media: [String: Any]? = nil, routes: [String: Any]) -> JSContext {
        ExtensionJSHarness.context(kind: "stremio", key: "\(base)/manifest.json",
                                   config: ["manifestUrl": "\(base)/manifest.json", "base": base, "manifest": manifest],
                                   media: media, routes: routes)
    }
    private let kitsuStreams: [String: Any] = ["id": "x", "resources": ["stream"], "types": ["series"], "idPrefixes": ["kitsu"]]

    func testSearchUsesKitsuWhenAddonTakesKitsuIds() throws {
        let c = ctx(manifest: kitsuStreams, routes: [
            "\(kitsu)/catalog/anime/kitsu-anime-list/search=frieren.json": ["metas": [
                ["id": "kitsu:1", "type": "series", "name": "Frieren", "poster": "p.jpg", "genres": ["Adventure"]],
                ["id": "kitsu:2", "type": "series", "name": "Bad", "poster": "b.jpg", "genres": ["Hentai"]]]]])
        let r = try ExtensionJSHarness.call(c, "searchResults", ["frieren"]).get()
        let items = ExtensionJSHarness.json(r) as! [[String: Any]]
        XCTAssertEqual(items.map { $0["title"] as? String }, ["Frieren"])
        XCTAssertTrue((items[0]["href"] as! String).hasPrefix("stremio:"))
    }

    func testAnimePageGoesStraightToTheAniListEntry() throws {
        let c = ctx(manifest: kitsuStreams, media: ["anilistId": 154587, "title": "Sousou no Frieren", "episodeOffset": 0],
                    routes: ["\(kitsu)/meta/anime/anilist:154587.json": ["meta": ["id": "kitsu:46474", "type": "series", "name": "Frieren", "poster": "p"]]])
        let items = ExtensionJSHarness.json(try ExtensionJSHarness.call(c, "searchResults", ["Sousou no Frieren"]).get()) as! [[String: Any]]
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items[0]["title"] as? String, "Frieren")
    }

    func testOwnCatalogPreferredWhenSearchable() throws {
        let m: [String: Any] = ["id": "x", "resources": ["catalog", "meta", "stream"], "types": ["series"],
                                "catalogs": [["type": "series", "id": "c", "extra": [["name": "search"]]]]]
        let c = ctx(manifest: m, routes: ["\(base)/catalog/series/c/search=one.json": ["metas": [["id": "a1", "type": "series", "name": "One", "poster": "p"]]]])
        let items = ExtensionJSHarness.json(try ExtensionJSHarness.call(c, "searchResults", ["one"]).get()) as! [[String: Any]]
        XCTAssertEqual(items.count, 1)
    }

    func testEpisodesFromVideosAndStreams() throws {
        let href = "stremio:" + #"{"s":"kitsu","t":"series","id":"kitsu:1"}"#
        let c = ctx(manifest: kitsuStreams, routes: [
            "\(kitsu)/meta/series/kitsu:1.json": ["meta": ["id": "kitsu:1", "type": "series", "name": "F", "videos": [
                ["id": "kitsu:1:2", "episode": 2, "season": 1], ["id": "kitsu:1:1", "episode": 1, "season": 1]]]],
            "\(base)/stream/series/kitsu:1:1.json": ["streams": [
                ["name": "Srv", "title": "1080p\nsize", "url": "https://cdn.test/1.m3u8",
                 "behaviorHints": ["proxyHeaders": ["request": ["Referer": "https://r.test/"]]]],
                ["name": "T", "infoHash": "abc"],
                ["name": "M", "url": "magnet:?xt=urn:btih:abc"]]]])
        let eps = ExtensionJSHarness.json(try ExtensionJSHarness.call(c, "extractEpisodes", [href]).get()) as! [[String: Any]]
        XCTAssertEqual(eps.map { $0["number"] as? Int }, [1, 2])
        let s = ExtensionJSHarness.json(try ExtensionJSHarness.call(c, "extractStreamUrl", [eps[0]["href"] as! String]).get()) as! [String: Any]
        let streams = s["streams"] as! [[String: Any]]
        XCTAssertEqual(streams.count, 1)
        XCTAssertEqual(streams[0]["title"] as? String, "Srv · 1080p")
        XCTAssertEqual((streams[0]["headers"] as? [String: String])?["Referer"], "https://r.test/")
    }

    func testOnlyTorrentStreamsIsAnError() {
        let c = ctx(manifest: kitsuStreams, routes: ["\(base)/stream/series/kitsu:1:1.json": ["streams": [["infoHash": "abc"]]]])
        let r = ExtensionJSHarness.call(c, "extractStreamUrl", ["stremio-video:" + #"{"t":"series","id":"kitsu:1:1"}"#])
        XCTAssertEqual(r, .failure(.init(message: "This addon has no playable streams for this episode (torrent links are skipped).")))
    }

    func testCinemetaSeasonOffsetFromMedia() throws {
        let m: [String: Any] = ["id": "x", "resources": ["stream"], "types": ["series"], "idPrefixes": ["tt"]]
        let href = "stremio:" + #"{"s":"cinemeta","t":"series","id":"tt1"}"#
        let videos: [[String: Any]] = (1...24).map { ["id": "tt1:1:\($0)", "season": 1, "episode": $0] }
            + [["id": "tt1:0:1", "season": 0, "episode": 1]]
        let c = ctx(manifest: m, media: ["anilistId": 9, "title": "X", "imdbId": "tt1", "season": 1, "episodeOffset": 12],
                    routes: ["\(cinemeta)/meta/series/tt1.json": ["meta": ["id": "tt1", "type": "series", "name": "X", "videos": videos]]])
        let eps = ExtensionJSHarness.json(try ExtensionJSHarness.call(c, "extractEpisodes", [href]).get()) as! [[String: Any]]
        XCTAssertEqual(eps.count, 12)
        XCTAssertEqual(eps.first?["number"] as? Int, 1)
        XCTAssertTrue((eps.first?["href"] as! String).contains("tt1:1:13"))
    }

    func testSearchTabNumbersEverySeasonInOrder() throws {
        let m: [String: Any] = ["id": "x", "resources": ["stream"], "types": ["series"], "idPrefixes": ["tt"]]
        let href = "stremio:" + #"{"s":"cinemeta","t":"series","id":"tt1"}"#
        let videos: [[String: Any]] = [["id": "a", "season": 2, "episode": 1], ["id": "b", "season": 1, "episode": 2],
                                       ["id": "c", "season": 1, "episode": 1], ["id": "z", "season": 0, "episode": 1]]
        let c = ctx(manifest: m, routes: ["\(cinemeta)/meta/series/tt1.json": ["meta": ["id": "tt1", "type": "series", "name": "X", "videos": videos]]])
        let eps = ExtensionJSHarness.json(try ExtensionJSHarness.call(c, "extractEpisodes", [href]).get()) as! [[String: Any]]
        XCTAssertEqual(eps.map { $0["number"] as? Int }, [1, 2, 3])
        XCTAssertTrue((eps[2]["href"] as! String).contains("\"a\""))
    }

    private func cinemetaCtx(media: [String: Any], videos: [[String: Any]], metaId: String = "tt1") -> JSContext {
        let m: [String: Any] = ["id": "x", "resources": ["stream"], "types": ["series"], "idPrefixes": ["tt"]]
        return ctx(manifest: m, media: media,
                   routes: ["\(cinemeta)/meta/series/\(metaId).json": ["meta": ["id": metaId, "type": "series", "name": "X", "videos": videos]]])
    }
    private func episodes(_ c: JSContext, _ id: String = "tt1") throws -> [[String: Any]] {
        let href = "stremio:" + #"{"s":"cinemeta","t":"series","id":"\#(id)"}"#
        return ExtensionJSHarness.json(try ExtensionJSHarness.call(c, "extractEpisodes", [href]).get()) as! [[String: Any]]
    }

    func testSecondCourStopsWhereTheThirdBegins() throws {
        let videos: [[String: Any]] = (1...36).map { ["id": "tt1:1:\($0)", "season": 1, "episode": $0] }
        let c = cinemetaCtx(media: ["anilistId": 9, "title": "X", "imdbId": "tt1", "season": 1, "episodeOffset": 12, "episodeEnd": 24], videos: videos)
        let eps = try episodes(c)
        XCTAssertEqual(eps.count, 12)
        XCTAssertTrue((eps.last?["href"] as! String).contains("tt1:1:24"))
    }

    func testSeasonOffsetOnlyForTheMappedShow() throws {
        let videos: [[String: Any]] = (1...24).map { ["id": "tt9:1:\($0)", "season": 1, "episode": $0] }
        let c = cinemetaCtx(media: ["anilistId": 9, "title": "X", "imdbId": "tt1", "season": 1, "episodeOffset": 12], videos: videos, metaId: "tt9")
        XCTAssertEqual(try episodes(c, "tt9").count, 24)
    }

    func testOffsetPastTheSeasonFallsBackToEveryEpisode() throws {
        let videos: [[String: Any]] = (1...12).map { ["id": "tt1:1:\($0)", "season": 1, "episode": $0] }
        let c = cinemetaCtx(media: ["anilistId": 9, "title": "X", "imdbId": "tt1", "season": 1, "episodeOffset": 12], videos: videos)
        XCTAssertEqual(try episodes(c).count, 12)
    }

    func testKitsuMappedEntryFirstThenTheSearch() throws {
        let c = ctx(manifest: kitsuStreams, media: ["anilistId": 5, "title": "Frieren", "episodeOffset": 0],
                    routes: ["\(kitsu)/meta/anime/anilist:5.json": ["meta": ["id": "kitsu:1", "type": "series", "name": "Frieren"]],
                             "\(kitsu)/catalog/anime/kitsu-anime-list/search=Frieren.json": ["metas": [
                                ["id": "kitsu:1", "type": "series", "name": "Frieren"], ["id": "kitsu:2", "type": "series", "name": "Frieren Mini"]]]])
        let items = ExtensionJSHarness.json(try ExtensionJSHarness.call(c, "searchResults", ["Frieren"]).get()) as! [[String: Any]]
        XCTAssertEqual(items.map { $0["title"] as? String }, ["Frieren", "Frieren Mini"])
    }
}
