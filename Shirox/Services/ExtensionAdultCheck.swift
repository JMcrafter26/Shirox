import Foundation

/// Adult plugins, judged before anything is fetched: by their own flag, their category, or an
/// adult word in their name, id or description. `AdultModuleCheck` runs on the installed module
/// as well (ModuleManager), which also checks the sites its script reaches.
enum ExtensionAdultCheck {
    private static let adultCategories: Set<String> = ["nsfw", "adult", "18+", "hentai", "xxx", "porn"]

    static func isAdult(entry: [String: Any]) -> Bool {
        if entry["nsfw"] as? Bool == true || entry["isNsfw"] as? Bool == true || entry["adult"] as? Bool == true { return true }
        let categories = (entry["categories"] as? [String] ?? []) + (entry["tvTypes"] as? [String] ?? [])
        if categories.contains(where: { adultCategories.contains($0.lowercased()) }) { return true }
        let texts = ["name", "display_name", "id", "value", "packageName", "description", "filename"]
            .compactMap { entry[$0] as? String }
        return texts.contains(where: AdultModuleCheck.hasAdultName)
    }

    /// A Mana source: its catalog rating (0 safe, 1 mixed, 2 explicit) as the repo or the source
    /// itself gives it, then the checks every plugin gets. A mixed one is kept; its explicit titles
    /// are dropped as they come (kinds/mana.js).
    static func isAdult(mana entry: [String: Any]) -> Bool {
        if (entry["rating"] as? NSNumber)?.intValue ?? 0 >= 2 { return true }
        return isAdult(entry: entry)
    }

    static func isAdult(stremio raw: [String: Any]) -> Bool {
        if (raw["behaviorHints"] as? [String: Any])?["adult"] as? Bool == true { return true }
        let texts = ["name", "id", "description"].compactMap { raw[$0] as? String }
        if texts.contains(where: AdultModuleCheck.hasAdultName) { return true }
        for catalog in raw["catalogs"] as? [[String: Any]] ?? [] {
            if let name = catalog["name"] as? String, AdultModuleCheck.hasAdultName(name) { return true }
            for extra in catalog["extra"] as? [[String: Any]] ?? [] {
                if (extra["options"] as? [String] ?? []).contains(where: AdultModuleCheck.hasAdultName) { return true }
            }
            if (catalog["genres"] as? [String] ?? []).contains(where: AdultModuleCheck.hasAdultName) { return true }
        }
        return false
    }
}
