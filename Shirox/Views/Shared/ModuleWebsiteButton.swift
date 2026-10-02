import SwiftUI

/// A page to open in the browser, named for the menu.
struct WebLink: Equatable {
    let name: String
    let url: URL
}

/// The title's pages on AniList, MyAnimeList and Simkl, for the ids that are known.
enum TrackerWebLinks {
    static func links(anilist: Int?, mal: Int?, simkl: Int?, isManga: Bool = false) -> [WebLink] {
        let kind = isManga ? "manga" : "anime"
        var links: [WebLink] = []
        if let anilist, let url = URL(string: "https://anilist.co/\(kind)/\(anilist)") {
            links.append(WebLink(name: "AniList", url: url))
        }
        if let mal, let url = URL(string: "https://myanimelist.net/\(kind)/\(mal)") {
            links.append(WebLink(name: "MyAnimeList", url: url))
        }
        // Simkl lists anime only, not manga.
        if !isManga, let simkl, let url = URL(string: "https://simkl.com/anime/\(simkl)") {
            links.append(WebLink(name: "Simkl", url: url))
        }
        return links
    }
}

/// Opens the title's page on the web: its module's site — to check what the site lists (episodes
/// left, next airing) or browse around it — and its AniList, MyAnimeList and Simkl pages. One
/// page is a plain button, several a menu. Hidden when there's none.
struct ModuleWebsiteButton: View {
    /// The module's `href` for the title, if the page has one.
    var href: String?
    var moduleId: String?
    /// The trackers' pages, listed after the module's site.
    var trackers: [WebLink] = []

    @Environment(\.openURL) private var openURL

    private var moduleLink: WebLink? {
        guard let href else { return nil }
        let modules = ModuleManager.shared.modules
        // A removed module stays nil: its relative hrefs mean nothing on another module's site,
        // but an absolute href still opens.
        let module = moduleId.map { id in modules.first { $0.id == id } } ?? ModuleManager.shared.activeModule
        let url: URL?
        // An id-style href (Seanime providers) opens the page its search result reported.
        if let id = moduleId ?? module?.id, let page = ModuleWebLinks.shared.url(moduleId: id, href: href) {
            url = page
        } else if let module {
            url = module.webURL(forHref: href)
        } else {
            url = ModuleDefinition.webURL(forHref: href, baseUrl: nil)
        }
        guard let url else { return nil }
        return WebLink(name: module?.sourceName ?? url.host ?? "Website", url: url)
    }

    private var links: [WebLink] { (moduleLink.map { [$0] } ?? []) + trackers }

    var body: some View {
        #if !os(tvOS)
        let links = links
        if links.count == 1, let only = links.first {
            Button { openURL(only.url) } label: { label }
                .accessibilityLabel("Open on \(only.name)")
        } else if !links.isEmpty {
            Menu {
                ForEach(links, id: \.url) { link in
                    Button { openURL(link.url) } label: {
                        Label("Open on \(link.name)", systemImage: "safari")
                    }
                }
            } label: { label }
                .accessibilityLabel("Open Website")
        }
        #endif
    }

    private var label: some View {
        Image(systemName: "safari")
            .font(.system(size: 17, weight: .medium))
            .foregroundStyle(.primary)
    }
}
