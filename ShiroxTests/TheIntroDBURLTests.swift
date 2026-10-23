import XCTest
@testable import Shirox

/// Which TheIntroDB v4 URL a skip-times lookup asks for.
final class TheIntroDBURLTests: XCTestCase {

    private func url(tvdb: Int? = 81_797, tmdb: Int? = 37_854, season: Int = 1, episode: Int = 3,
                     movie: Bool = false) -> String? {
        SkipTimestampsService.theIntroDBURL(tvdbID: tvdb, tmdbID: tmdb, season: season, episode: episode,
                                            isMovie: movie)?.absoluteString
    }

    func testAnEpisodeIsAskedForByItsTVDBId() {
        XCTAssertEqual(url(), "https://api.theintrodb.org/v4/media?tvdb_id=81797&season=1&episode=3",
                       "The season and episode are TVDB's default order, so the TVDB id wins over TMDB")
    }

    func testAnEpisodeWithoutATVDBMappingFallsBackToTMDB() {
        XCTAssertEqual(url(tvdb: nil), "https://api.theintrodb.org/v4/media?tmdb_id=37854&season=1&episode=3")
    }

    func testAMovieIsAskedForByTMDBWithoutSeasonOrEpisode() {
        XCTAssertEqual(url(movie: true), "https://api.theintrodb.org/v4/media?tmdb_id=37854",
                       "The mapping's TVDB id is a series, never the movie")
    }

    func testNoIdIsNoRequest() {
        XCTAssertNil(url(tvdb: nil, tmdb: nil))
        XCTAssertNil(url(tvdb: 81_797, tmdb: nil, movie: true))
    }

    func testNeverAnOlderAPIVersion() {
        for movie in [false, true] {
            XCTAssertEqual(URL(string: url(movie: movie) ?? "")?.path, "/v4/media")
        }
    }
}
