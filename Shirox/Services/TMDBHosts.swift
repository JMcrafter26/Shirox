import Foundation

/// The expert setting that sends TMDB traffic through the user's own endpoints (Settings ›
/// Advanced Network). A base replaces TMDB's origin and keeps the path and query, so
/// `https://proxy.example/tmdb` turns `https://api.themoviedb.org/3/movie/1?api_key=…` into
/// `https://proxy.example/tmdb/3/movie/1?api_key=…`.
struct TMDBHostSettings: Equatable, Sendable {
    static let useProxiesKey = "tmdbUseCustomProxies"
    static let apiBaseKey = "tmdbCustomAPIBase"
    static let imageBaseKey = "tmdbCustomImageBase"
    /// What an empty field starts as when the setting is turned on: TMDB itself, a start to edit.
    static let defaultAPIBase = "https://api.themoviedb.org"
    static let defaultImageBase = "https://image.tmdb.org"

    var useProxies = false
    var apiBase = ""
    var imageBase = ""

    static func current(_ defaults: UserDefaults = .standard) -> TMDBHostSettings {
        TMDBHostSettings(useProxies: defaults.bool(forKey: useProxiesKey),
                         apiBase: defaults.string(forKey: apiBaseKey) ?? "",
                         imageBase: defaults.string(forKey: imageBaseKey) ?? "")
    }

    /// The base, when it's an https URL with a host and nothing after the path.
    static func validBase(_ text: String) -> URL? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let components = URLComponents(string: trimmed), components.scheme?.lowercased() == "https",
              let host = components.host, !host.isEmpty,
              components.query == nil, components.fragment == nil,
              let url = components.url else { return nil }
        return url
    }
}

/// Where a request to TMDB goes. Off, the API falls back to TMDB's official mirror
/// `api.tmdb.org` when `api.themoviedb.org` can't be reached (blocked in some countries and by
/// some ISPs); images have no mirror. On, TMDB traffic goes to the user's proxies and nowhere
/// else: a proxy can be there for privacy, which a fallback to TMDB itself would give away. A
/// TMDB request with no valid proxy base isn't sent at all.
final class TMDBHosts: @unchecked Sendable {
    static let shared = TMDBHosts()

    static let apiHost = "api.themoviedb.org"
    static let apiMirrorHost = "api.tmdb.org"
    static let imageHost = "image.tmdb.org"

    private let settings: @Sendable () -> TMDBHostSettings
    private let lock = NSLock()
    private var mirrorWorked = false

    init(settings: @escaping @Sendable () -> TMDBHostSettings = { .current() }) {
        self.settings = settings
    }

    /// The addresses to try for `url`, in order. Empty when it's TMDB's and the proxy for it
    /// isn't usable; `[url]` for anything that isn't TMDB's.
    func candidates(for url: URL) -> [URL] {
        let settings = settings()
        switch url.host?.lowercased() {
        case Self.apiHost?:
            if settings.useProxies { return Self.proxied(url, base: settings.apiBase).map { [$0] } ?? [] }
            guard let mirror = Self.replacingHost(of: url, with: Self.apiMirrorHost) else { return [url] }
            return usesMirror ? [mirror, url] : [url, mirror]
        case Self.apiMirrorHost?:
            if settings.useProxies { return Self.proxied(url, base: settings.apiBase).map { [$0] } ?? [] }
            return [url]
        case Self.imageHost?:
            if settings.useProxies { return Self.proxied(url, base: settings.imageBase).map { [$0] } ?? [] }
            return [url]
        default:
            return [url]
        }
    }

    /// Where `url` is loaded when there's only one try, as in a web view. nil: not at all.
    func rewritten(_ url: URL) -> URL? {
        candidates(for: url).first
    }

    /// `rewritten` for an address a module passed as text. One that isn't TMDB's comes back as
    /// given, character for character: `URL(string:)` percent-encodes what it has to.
    func rewritten(urlString: String) -> String? {
        guard let url = URL(string: urlString) else { return urlString }
        guard let target = rewritten(url) else { return nil }
        return target == url ? urlString : target.absoluteString
    }

    /// `request`, through `perform`, at each of its candidates until one answers. Only an error
    /// that looks like a block moves on; an HTTP error is TMDB's answer and comes back as it is.
    func send<Response>(_ request: URLRequest,
                        perform: (URLRequest) async throws -> Response) async throws -> Response {
        guard let url = request.url else { return try await perform(request) }
        let candidates = candidates(for: url)
        guard !candidates.isEmpty else {
            let host = url.host ?? "TMDB"
            throw URLError(.badURL, userInfo: [NSLocalizedDescriptionKey: String(localized: "settings.no_valid_custom_tmdb_proxy \(host)")])
        }
        for (index, candidate) in candidates.enumerated() {
            var attempt = request
            attempt.url = candidate
            do {
                let response = try await perform(attempt)
                // Two candidates are TMDB and its mirror.
                if candidates.count > 1 { remember(mirror: candidate.host?.lowercased() == Self.apiMirrorHost) }
                return response
            } catch where index < candidates.count - 1 && Self.looksBlocked(error) {
                Logger.shared.log("[TMDB] \(candidate.host ?? "?") unreachable (\((error as? URLError)?.code.rawValue ?? 0)), trying \(candidates[index + 1].host ?? "?")", type: "Debug")
            }
        }
        // The loop returns or throws on its last candidate.
        throw URLError(.unknown)
    }

    /// A timeout, a refused or reset connection, a name that doesn't resolve, or TLS that
    /// fails: what a blocked host looks like. Not being offline, and not a cancel.
    static func looksBlocked(_ error: Error) -> Bool {
        guard let code = (error as? URLError)?.code else { return false }
        switch code {
        case .timedOut, .cannotFindHost, .cannotConnectToHost, .networkConnectionLost, .dnsLookupFailed,
             .secureConnectionFailed, .serverCertificateUntrusted, .serverCertificateHasBadDate,
             .serverCertificateHasUnknownRoot, .serverCertificateNotYetValid:
            return true
        default:
            return false
        }
    }

    private var usesMirror: Bool {
        lock.lock(); defer { lock.unlock() }
        return mirrorWorked
    }

    /// Once the mirror has answered, it's tried first for the rest of the run.
    private func remember(mirror: Bool) {
        lock.lock(); defer { lock.unlock() }
        mirrorWorked = mirror
    }

    /// Back to trying TMDB first (Settings › Advanced Network › Reset Network State).
    func forgetMirror() { remember(mirror: false) }

    private static func replacingHost(of url: URL, with host: String) -> URL? {
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        components?.host = host
        return components?.url
    }

    /// `url`'s path and query on `base`.
    static func proxied(_ url: URL, base: String) -> URL? {
        guard let base = TMDBHostSettings.validBase(base),
              var components = URLComponents(url: base, resolvingAgainstBaseURL: false),
              let original = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        let prefix = components.percentEncodedPath.hasSuffix("/")
            ? String(components.percentEncodedPath.dropLast()) : components.percentEncodedPath
        components.percentEncodedPath = prefix + original.percentEncodedPath
        components.percentEncodedQuery = original.percentEncodedQuery
        return components.url
    }
}
