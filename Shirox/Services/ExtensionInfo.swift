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
