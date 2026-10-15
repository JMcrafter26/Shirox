import Foundation

/// The plugin ecosystems Shirox runs besides Sora modules and Seanime providers.
enum ExtensionKind: String, Codable, Equatable {
    case stremio, nuvio, vega, skystream

    /// The badge in Modules.
    var badge: String {
        switch self {
        case .stremio: return "Stremio"
        case .nuvio: return "Nuvio"
        case .vega: return "Vega"
        case .skystream: return "SkyStream"
        }
    }
}

/// What a module remembers of the plugin it is.
struct ExtensionInfo: Codable, Equatable {
    let kind: ExtensionKind
    /// The link it was installed from: an addon's manifest, or a repo.
    let repoUrl: String
    /// Which entry of that link: the Stremio manifest URL, the Nuvio scraper id, the Vega
    /// provider value, or the SkyStream package name.
    let key: String
    /// JSON handed to the runtime as `__ext.config`.
    let config: String
}

/// A Stremio addon's manifest, the part Shirox reads; `raw` is the whole manifest.
struct StremioManifest: Equatable {
    let url: URL
    let id: String
    let name: String
    let version: String
    let description: String?
    let logo: String?
    let raw: [String: Any]

    static func == (a: Self, b: Self) -> Bool { a.url == b.url && a.id == b.id && a.version == b.version }
}

/// One provider a Nuvio, Vega or SkyStream repo lists.
struct ExtensionRepoEntry: Identifiable, Equatable {
    let key: String
    let name: String
    let version: String
    let iconUrl: String?
    let language: String?
    let description: String?
    /// The Nuvio script, the Vega provider's `dist/<value>/` folder, or the SkyStream `.sky`.
    let fileURL: URL
    /// The entry as the repo lists it (SkyStream's `baseUrl`, Nuvio's `supportedTypes`…).
    let raw: [String: Any]
    var id: String { key }

    static func == (a: Self, b: Self) -> Bool { a.key == b.key && a.version == b.version && a.fileURL == b.fileURL }
}

/// A Nuvio, Vega or SkyStream repo, its adult entries already dropped.
struct ExtensionRepo: Identifiable, Equatable {
    let kind: ExtensionKind
    let name: String
    /// The link the repo was added by — kept as each module's `jsonUrl`.
    let url: URL
    /// Where relative files resolve: the folder holding the manifest.
    let base: URL
    let entries: [ExtensionRepoEntry]
    /// Keys of the entries dropped as adult — an installed one of these is removed on update.
    var adultKeys: Set<String> = []
    var id: String { url.absoluteString }
}

enum ExtensionLink: Equatable {
    case stremio(StremioManifest)
    case repo(ExtensionRepo)
}
