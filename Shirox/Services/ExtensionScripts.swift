import Foundation
import JavaScriptCore

/// The show an extension's next search is for, from the anime page's AniList entry, with the
/// ids its metadata sources need.
struct ExtensionSearchMedia: Equatable {
    let anilistId: Int
    let malId: Int?
    let title: String
    let englishTitle: String?
    var tmdbId: Int?
    var tmdbType: String?
    var imdbId: String?
    /// The TVDB season this entry is (TMDB and Cinemeta number nearly all anime the same way).
    var season: Int?
    /// Episodes of that season before this entry — a second cour's offset.
    var episodeOffset: Int = 0
    /// The season's last episode that is still this entry's, when known: where the next cour starts.
    var episodeEnd: Int?

    init(anilistId: Int, malId: Int?, title: String, englishTitle: String?) {
        self.anilistId = anilistId
        self.malId = malId
        self.title = title
        self.englishTitle = englishTitle
    }

    var jsonObject: [String: Any] {
        var o: [String: Any] = ["anilistId": anilistId, "title": title, "episodeOffset": episodeOffset]
        if let malId { o["malId"] = malId }
        if let englishTitle { o["englishTitle"] = englishTitle }
        if let tmdbId { o["tmdbId"] = tmdbId }
        if let tmdbType { o["tmdbType"] = tmdbType }
        if let imdbId { o["imdbId"] = imdbId }
        if let season { o["season"] = season }
        if let episodeEnd { o["episodeEnd"] = episodeEnd }
        return o
    }

    static func resolve(_ media: SeanimeSearchMedia) async -> ExtensionSearchMedia {
        let map = IDMappingService.shared
        var out = ExtensionSearchMedia(anilistId: media.id, malId: media.idMal,
                                       title: media.romajiTitle ?? media.englishTitle ?? "", englishTitle: media.englishTitle)
        if let tmdb = await map.tmdbId(forAnilistId: media.id) {
            out.tmdbId = tmdb.id
            out.tmdbType = tmdb.isMovie ? "movie" : "tv"
        }
        out.imdbId = await map.imdbId(forAnilistId: media.id)
        if let tvdb = map.tvdbId(forAnilistId: media.id),
           let b = bounds(anilistId: media.id, siblings: map.siblings(forTvdbId: tvdb), episodeCount: media.episodeCount) {
            out.season = b.season
            out.episodeOffset = b.offset
            out.episodeEnd = b.end
        }
        return out
    }

    /// Where an AniList entry sits in its TVDB season: the season, the episodes before it, and the
    /// last one that is its own — up to where the next entry in the same season starts, or its
    /// episode count — so a second cour doesn't run on into the third.
    static func bounds(anilistId: Int, siblings: [SiblingSeason], episodeCount: Int?) -> (season: Int, offset: Int, end: Int?)? {
        guard let me = siblings.first(where: { $0.aniListID == anilistId }) else { return nil }
        let next = siblings.filter { $0.tvdbSeason == me.tvdbSeason && $0.tvdbEpoffset > me.tvdbEpoffset }
            .map(\.tvdbEpoffset).min()
        let count = episodeCount ?? me.episodeCount
        return (me.tvdbSeason, me.tvdbEpoffset, next ?? count.map { me.tvdbEpoffset + $0 })
    }
}

/// The bundled extension runtime, and what it's told about the module.
@MainActor
enum ExtensionScripts {
    static let runtimeSource: String? =
        Bundle.main.url(forResource: "ExtensionRuntime", withExtension: "js").flatMap { try? String(contentsOf: $0, encoding: .utf8) }

    private static var tmdbKey: String {
        (Bundle.main.object(forInfoDictionaryKey: "TMDBAPIKey") as? String)?.trimmingCharacters(in: .whitespaces) ?? ""
    }

    /// Before an extension module's script: `__ext`, then the runtime.
    static func prepare(_ context: JSContext, module: ModuleDefinition) {
        guard let ext = module.ext, let runtimeSource else { return }
        let config = (try? JSONSerialization.jsonObject(with: Data(ext.config.utf8))) ?? [String: Any]()
        let words = Array(NSFWContentFilter.blockedKeywords) + AdultModuleCheck.adultStems
        // Only Nuvio looks shows up on TMDB; other plugins aren't handed the app's key.
        let key = ext.kind == .nuvio ? tmdbKey : ""
        let info: [String: Any] = ["kind": ext.kind.rawValue, "name": module.sourceName, "key": ext.key, "config": config,
                                   "tmdbKey": key, "adultWords": words]
        context.setObject(info, forKeyedSubscript: "__ext" as NSString)
        context.setObject(NSNull(), forKeyedSubscript: "__shiroxMedia" as NSString)
        if ext.kind == .nuvio {
            // Nuvio scrapers read these globals.
            context.setObject(key, forKeyedSubscript: "TMDB_API_KEY" as NSString)
            context.evaluateScript("globalThis.SCRAPER_SETTINGS = globalThis.SCRAPER_SETTINGS || {};")
        }
        context.evaluateScript(runtimeSource)
    }

    /// After the module's script: Shirox's functions again, in case the plugin defined globals of those names.
    static func finish(_ context: JSContext, module: ModuleDefinition) {
        guard module.ext != nil else { return }
        context.evaluateScript("if (globalThis.__extFunctions) Object.assign(globalThis, globalThis.__extFunctions);")
    }

    static func setSearchMedia(_ media: ExtensionSearchMedia?, in context: JSContext) {
        context.setObject(media?.jsonObject ?? NSNull(), forKeyedSubscript: "__shiroxMedia" as NSString)
    }
}
