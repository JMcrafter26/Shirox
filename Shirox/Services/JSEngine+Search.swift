import Combine
import Foundation

extension JSEngine {
    func search(keyword: String) async throws -> [SearchItem] {
        let json = try await callAsyncJS("searchResults", args: [keyword])
        guard let data = json.data(using: .utf8),
              let array = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            throw JSEngineError.parseError(String(localized: "search.could_not_parse_search_results"))
        }
        ModuleWebLinks.shared.record(array, moduleId: ModuleManager.shared.activeModule?.id)
        return array.compactMap { item in
            guard let title = item["title"] as? String,
                  let image = item["image"] as? String,
                  let href = item["href"] as? String else { return nil }
            return SearchItem(title: title, image: image, href: href)
        }
    }
}
