import Foundation

extension JSEngine {
    func fetchDetails(url: String, title: String, image: String) async throws -> MediaDetail {
        let json = try await callAsyncJS("extractDetails", args: [url])
        guard let data = json.data(using: .utf8),
              let array = try JSONSerialization.jsonObject(with: data) as? [[String: Any]],
              let first = array.first else {
            throw JSEngineError.parseError(String(localized: "detail.could_not_parse_details"))
        }
        return MediaDetail(
            title: title,
            image: image,
            description: first["description"] as? String ?? String(localized: "detail.n_a"),
            aliases: first["aliases"] as? String ?? String(localized: "detail.n_a"),
            airdate: first["airdate"] as? String ?? String(localized: "detail.n_a"),
            episodes: []
        )
    }

    func fetchEpisodes(url: String) async throws -> [EpisodeLink] {
        let json = try await callAsyncJS("extractEpisodes", args: [url])
        guard let data = json.data(using: .utf8),
              let array = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            throw JSEngineError.parseError(String(localized: "detail.could_not_parse_episodes"))
        }
        return array.compactMap { item in
            guard let href = item["href"] as? String else { return nil }
            let number: Double
            if let n = item["number"] as? Double {
                number = n
            } else if let n = item["number"] as? Int {
                number = Double(n)
            } else {
                number = 0
            }
            return EpisodeLink(number: number, href: href)
        }
    }
}
