import Foundation

/// One kind's `/sync/activities` timestamps.
struct SimklActivityStamps: Codable, Equatable {
    var all: String?
    var removed: String?
}

/// Decoding for Simkl's TV and movie library reads, `/sync/activities`, and ids-only reads.
///
/// Pure, so the real response shapes can be tested without a network. Ids, years and runtimes go
/// through `FlexibleID`: Simkl sends numbers as strings often enough that a strict decode would
/// fail a whole library over one of them.
enum SimklTitleReads {
    typealias FlexibleID = SimklLibraryService.FlexibleID

    // MARK: - TV

    private struct ShowsResponse: Decodable {
        let shows: [ShowsItem]?
    }

    private struct ShowsItem: Decodable {
        let show: Show?
        let status: String?
        let watched_episodes_count: Int?
        let total_episodes_count: Int?
        let user_rating: Int?
        /// With `extended=full&include_all_episodes=original`: the episodes the user recorded,
        /// for every status.
        let seasons: [ShowSeason]?
    }

    private struct Show: Decodable {
        let title: String?
        let poster: String?
        let year: FlexibleID?
        let runtime: FlexibleID?
        let ids: TitleIDs?
    }

    private struct ShowSeason: Decodable {
        let number: Int?
        let episodes: [ShowEpisode]?
    }

    private struct ShowEpisode: Decodable { let number: Int? }

    /// The `ids` object of a show or a movie; only the Simkl id is read.
    private struct TitleIDs: Decodable { let simkl: FlexibleID? }

    static func decodeShows(from data: Data) throws -> [LibraryEntry] {
        (try JSONDecoder().decode(ShowsResponse.self, from: data).shows ?? []).compactMap(showEntry(from:))
    }

    private static func showEntry(from item: ShowsItem) -> LibraryEntry? {
        guard let show = item.show, let simklID = show.ids?.simkl?.value else { return nil }
        let watched = item.watched_episodes_count ?? 0
        let total = item.total_episodes_count
        let status = SimklLibraryService.status(from: item.status, progress: watched, total: total)
        var entry = LibraryEntry(
            id: simklID,
            media: titleMedia(simklID: simklID, kind: .tv, title: show.title,
                              posterURL: show.poster.map(SimklCatalogItem.posterURLString(_:)),
                              year: show.year?.value, runtime: show.runtime?.value, episodes: total),
            status: status,
            progress: SimklLibraryService.progress(watched: watched, total: total, status: status),
            score: SimklPayloadBuilder.score(fromRating: item.user_rating, format: .point10),
            timesRewatched: nil)
        entry.watchedEpisodes = (item.seasons ?? []).compactMap { season -> SimklSeasonWatch? in
            guard let number = season.number else { return nil }
            let episodes = Array(Set((season.episodes ?? []).compactMap(\.number))).sorted()
            return episodes.isEmpty ? nil : SimklSeasonWatch(season: number, episodes: episodes)
        }
        .sorted { $0.season < $1.season }
        return entry
    }

    // MARK: - Movies

    private struct MoviesResponse: Decodable {
        let movies: [MoviesItem]?
    }

    private struct MoviesItem: Decodable {
        let movie: Movie?
        let status: String?
        let user_rating: Int?
    }

    private struct Movie: Decodable {
        let title: String?
        let poster: String?
        let year: FlexibleID?
        let runtime: FlexibleID?
        let ids: TitleIDs?
    }

    static func decodeMovies(from data: Data) throws -> [LibraryEntry] {
        (try JSONDecoder().decode(MoviesResponse.self, from: data).movies ?? []).compactMap(movieEntry(from:))
    }

    private static func movieEntry(from item: MoviesItem) -> LibraryEntry? {
        guard let movie = item.movie, let simklID = movie.ids?.simkl?.value else { return nil }
        return LibraryEntry(
            id: simklID,
            media: titleMedia(simklID: simklID, kind: .movie, title: movie.title,
                              posterURL: movie.poster.map(SimklCatalogItem.posterURLString(_:)),
                              year: movie.year?.value, runtime: movie.runtime?.value, episodes: nil),
            status: movieStatus(item.status), progress: 0,
            score: SimklPayloadBuilder.score(fromRating: item.user_rating, format: .point10),
            timesRewatched: nil)
    }

    /// Movies have three lists — Simkl has no Watching or On Hold for them. Older registrations
    /// receive `notinteresting` where newer ones get `dropped`.
    static func movieStatus(_ raw: String?) -> MediaListStatus {
        switch raw {
        case "completed":                 return .completed
        case "dropped", "notinteresting": return .dropped
        default:                          return .planning
        }
    }

    /// The `Media` of a Simkl show or movie. Its `id` is the Simkl id.
    static func titleMedia(simklID: Int, kind: MediaKind, title: String?, posterURL: String?,
                           year: Int?, runtime: Int?, episodes: Int?) -> Media {
        Media(
            id: simklID, idMal: nil, provider: .simkl,
            title: MediaTitle(romaji: title, english: title, native: nil),
            coverImage: MediaCoverImage(large: posterURL, extraLarge: posterURL),
            bannerImage: nil, description: nil, episodes: episodes, status: nil,
            averageScore: nil, genres: nil, season: nil, seasonYear: year,
            nextAiringEpisode: nil, relations: nil,
            type: kind == .movie ? Media.simklMovieType : kind == .anime ? Media.simklAnimeType : Media.simklTVType,
            format: nil,
            runtime: runtime)
    }

    // MARK: - Ids only and activities

    /// Every Simkl id in an `extended=simkl_ids_only` read, whichever array it arrived in.
    static func decodeSimklIDs(from data: Data) throws -> Set<Int> {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }
        var ids = Set<Int>()
        for key in ["anime", "shows", "movies"] {
            for item in json[key] as? [[String: Any]] ?? [] {
                let object = (item["show"] ?? item["movie"]) as? [String: Any]
                let raw = (object?["ids"] as? [String: Any])?["simkl"]
                if let id = raw as? Int {
                    ids.insert(id)
                } else if let text = raw as? String, let id = Int(text) {
                    ids.insert(id)
                }
            }
        }
        return ids
    }

    /// Each kind's `all` and `removed_from_list`. A group missing from the answer is absent here.
    static func activityStamps(from data: Data) -> [MediaKind: SimklActivityStamps] {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        var result: [MediaKind: SimklActivityStamps] = [:]
        for kind in MediaKind.simklKinds {
            guard let group = json[kind.simklActivitiesKey] as? [String: Any] else { continue }
            result[kind] = SimklActivityStamps(all: group["all"] as? String,
                                               removed: group["removed_from_list"] as? String)
        }
        return result
    }
}
