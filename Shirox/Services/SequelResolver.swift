import Foundation

struct SequelResolver {
    static func searchResults(
        title: String,
        module: ModuleDefinition,
        runner: ModuleJSRunner
    ) async throws -> [SearchItem] {
        try await runner.search(keyword: title)
    }

    struct NoSequel: Error {}

    /// The anime sequel among `edges`: a released or airing one over an announced one, and never
    /// a manga or novel. Taking the first SEQUEL edge picked a light-novel continuation on some
    /// shows, so the source searched for a title it doesn't carry and Next found nothing.
    static func animeSequel(in edges: [AniListRelationEdge]) -> AniListMedia? {
        let sequels = edges.filter { $0.relationType == "SEQUEL" && ($0.node.type ?? "ANIME") == "ANIME" }.map(\.node)
        return sequels.first { $0.status != "NOT_YET_RELEASED" } ?? sequels.first
    }

    /// A sequel loader for playback that started without its show's relations to hand: resuming
    /// from Continue Watching or a module page's Continue button. Those passed no loader at all,
    /// so the last episode of a season had nowhere to go even when a sequel was out. The
    /// relations are fetched only once the player asks.
    static func loader(aniListID: Int?, moduleId: String?) -> SequelLoader? {
        guard let aniListID else { return nil }
        return { @MainActor in
            let media = try await AniListService.shared.detail(id: aniListID)
            guard let sequel = animeSequel(in: media.relations?.edges ?? []) else { throw NoSequel() }
            let module = moduleId.flatMap { id in ModuleManager.shared.modules.first { $0.id == id } }
                ?? ModuleManager.shared.activeModule
            guard let module else { throw NoSequel() }
            let runner = ModuleJSRunner()
            try await runner.load(module: module)
            let items = try await searchResults(title: sequel.title.displayTitle, module: module, runner: runner)
            return (items: items, mediaID: sequel.id)
        }
    }
}
