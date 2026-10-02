import Foundation

/// Site pages that modules report beside an id-style href — a Seanime provider's search result
/// carries `url` while its href is a slug — so the website button can open a title whose href
/// isn't a link. Recorded from search results, keyed by module and href, newest kept.
final class ModuleWebLinks: @unchecked Sendable {
    static let shared = ModuleWebLinks()

    private static let storageKey = "com.shirox.module_web_links"
    private static let limit = 500

    private let defaults: UserDefaults
    private let lock = NSLock()
    /// Oldest first; each entry is [key, url].
    private var entries: [[String]]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        entries = (defaults.array(forKey: Self.storageKey) as? [[String]])?.filter { $0.count == 2 } ?? []
    }

    private static func key(moduleId: String, href: String) -> String { "\(moduleId)\n\(href)" }

    /// Records the `pageUrl` of each search result that has one. `hrefKey` names the field the
    /// app uses as the href (manga results lead with `id`). Results whose href is already a link
    /// need nothing stored.
    func record(_ results: [[String: Any]], hrefKey: String = "href", moduleId: String?) {
        guard let moduleId else { return }
        let found: [(String, String)] = results.compactMap { item in
            guard let href = (item[hrefKey] as? String) ?? (item["href"] as? String) ?? (item["id"] as? String),
                  let page = item["pageUrl"] as? String,
                  page != href, ModuleDefinition.webURL(forHref: page, baseUrl: nil) != nil,
                  ModuleDefinition.webURL(forHref: href, baseUrl: nil) == nil else { return nil }
            return (Self.key(moduleId: moduleId, href: href), page)
        }
        guard !found.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }
        let keys = Set(found.map(\.0))
        entries.removeAll { keys.contains($0[0]) }
        entries.append(contentsOf: found.map { [$0.0, $0.1] })
        if entries.count > Self.limit { entries.removeFirst(entries.count - Self.limit) }
        defaults.set(entries, forKey: Self.storageKey)
    }

    func url(moduleId: String, href: String) -> URL? {
        let key = Self.key(moduleId: moduleId, href: href)
        lock.lock()
        let page = entries.last { $0[0] == key }?[1]
        lock.unlock()
        return page.flatMap { ModuleDefinition.webURL(forHref: $0, baseUrl: nil) }
    }
}
