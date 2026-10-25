import Foundation
import Network
import Security

#if os(tvOS)
    import FakeWebKit
#else
    import WebKit
#endif

// MARK: - Proxy for all traffic

/// The expert setting that sends the whole app through one HTTP CONNECT or SOCKS5 proxy
/// (Settings › Advanced Network). The password is kept in the Keychain.
struct NetworkProxySettings: Equatable, Sendable {
    enum Kind: String, CaseIterable, Sendable {
        case socks5, http

        var title: String { self == .http ? "HTTP CONNECT" : "SOCKS5" }
        /// What an empty port starts as.
        var defaultPort: String { self == .http ? "8080" : "1080" }
    }

    static let enabledKey = "networkProxyEnabled"
    static let kindKey = "networkProxyKind"
    static let hostKey = "networkProxyHost"
    static let portKey = "networkProxyPort"
    static let usernameKey = "networkProxyUsername"
    static let passwordAccount = "network_proxy_password"

    var enabled = false
    var kind: Kind = .socks5
    var host = ""
    var port = ""
    var username = ""
    var password = ""

    static func current(_ defaults: UserDefaults = .standard,
                        password: () -> String? = { ProxyKeychain.read(passwordAccount) }) -> NetworkProxySettings {
        NetworkProxySettings(enabled: defaults.bool(forKey: enabledKey),
                             kind: Kind(rawValue: defaults.string(forKey: kindKey) ?? "") ?? .socks5,
                             host: defaults.string(forKey: hostKey) ?? "",
                             port: defaults.string(forKey: portKey) ?? "",
                             username: defaults.string(forKey: usernameKey) ?? "",
                             password: password() ?? "")
    }

    /// What the system is told, or nil when it's off or not usable: a bare host name or IP, and
    /// a port. A username without a password, or the other way round, isn't usable either.
    var server: NetworkProxy.Server? {
        guard enabled else { return nil }
        let host = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !host.isEmpty, !host.contains(where: { $0 == "/" || $0 == " " || $0 == "@" }), !host.contains("://"),
              let port = UInt16(port.trimmingCharacters(in: .whitespaces)), port > 0 else { return nil }
        let username = username.trimmingCharacters(in: .whitespaces)
        guard username.isEmpty == password.isEmpty else { return nil }
        return NetworkProxy.Server(kind: kind, host: host, port: port,
                                   username: username.isEmpty ? nil : username,
                                   password: password.isEmpty ? nil : password)
    }
}

/// One proxy for every connection the app makes itself, through Network's default privacy
/// context (iOS 17, macOS 14, tvOS 17), and for its web views. Video playback isn't covered:
/// AVPlayer runs in a system process, and MPV opens its own sockets. Nothing falls back to a
/// direct connection when the proxy is down.
enum NetworkProxy {
    struct Server: Equatable, Sendable {
        let kind: NetworkProxySettings.Kind
        let host: String
        let port: UInt16
        let username: String?
        let password: String?
    }

    static var isSupported: Bool {
        if #available(iOS 17.0, macOS 14.0, tvOS 17.0, *) { return true }
        return false
    }

    /// The proxy in use this run, if any.
    @MainActor private(set) static var active: Server?
    @MainActor private static var applied = false

    /// Once, at launch, before any request, as `SecureDNS` is. `apply` is the system call;
    /// tests pass their own.
    @MainActor
    static func applyAtLaunch(_ settings: NetworkProxySettings = .current(), apply: (Server) -> Void = useProxy) {
        guard !applied else { return }
        applied = true
        guard let server = settings.server else {
            if settings.enabled { Logger.shared.log("[Proxy] The proxy is on but not usable; left off", type: "Error") }
            return
        }
        guard isSupported else {
            Logger.shared.log("[Proxy] A proxy for all traffic needs iOS 17, macOS 14 or tvOS 17", type: "Error")
            return
        }
        apply(server)
        active = server
        Logger.shared.log("[Proxy] All traffic through \(server.kind.title) \(server.host):\(server.port)", type: "Info")
    }

    @MainActor
    static func useProxy(_ server: Server) {
        guard #available(iOS 17.0, macOS 14.0, tvOS 17.0, *) else { return }
        let configuration = configuration(for: server)
        NWParameters.PrivacyContext.default.proxyConfigurations = [configuration]
        #if !os(tvOS)
        WKWebsiteDataStore.default().proxyConfigurations = [configuration]
        #endif
    }

    /// The Cloudflare sheet's own data store gets the proxy too.
    @MainActor
    static func apply(to store: WKWebsiteDataStore) {
        #if !os(tvOS)
        guard #available(iOS 17.0, macOS 14.0, *), let active else { return }
        store.proxyConfigurations = [configuration(for: active)]
        #endif
    }

    @available(iOS 17.0, macOS 14.0, tvOS 17.0, *)
    private static func configuration(for server: Server) -> ProxyConfiguration {
        let endpoint = NWEndpoint.hostPort(host: NWEndpoint.Host(server.host),
                                           port: NWEndpoint.Port(rawValue: server.port) ?? 1_080)
        var configuration = server.kind == .http
            ? ProxyConfiguration(httpCONNECTProxy: endpoint, tlsOptions: nil)
            : ProxyConfiguration(socksv5Proxy: endpoint)
        if let username = server.username, let password = server.password {
            configuration.applyCredential(username: username, password: password)
        }
        return configuration
    }

    /// For tests: lets `applyAtLaunch` run again.
    @MainActor
    static func resetForTesting() {
        applied = false
        active = nil
    }
}

/// The proxy's password, as a generic password (mirrors `JellyfinKeychain`). Listed in
/// `FreshInstallKeychainPurge`.
enum ProxyKeychain {
    static func read(_ account: String) -> String? {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrAccount: account,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func save(_ value: String, account: String) {
        delete(account)
        guard !value.isEmpty else { return }
        let addQuery: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrAccount: account,
            kSecValueData: Data(value.utf8),
            kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlock
        ]
        SecItemAdd(addQuery as CFDictionary, nil)
    }

    static func delete(_ account: String) {
        SecItemDelete([
            kSecClass: kSecClassGenericPassword,
            kSecAttrAccount: account
        ] as CFDictionary)
    }
}

// MARK: - User-Agent

/// The browser the app says it is: on module requests, images and web views. A module that
/// asks to impersonate a browser, and a request replaying a solved Cloudflare session, keep
/// theirs.
enum NetworkUserAgent {
    static let enabledKey = "customUserAgentEnabled"
    static let valueKey = "customUserAgent"

    /// What Shirox sends unless told otherwise.
    static let standard = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"

    /// The user's, when it's on and not empty.
    static func custom(_ defaults: UserDefaults = .standard) -> String? {
        guard defaults.bool(forKey: enabledKey) else { return nil }
        let value = (defaults.string(forKey: valueKey) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    static func current(_ defaults: UserDefaults = .standard) -> String {
        custom(defaults) ?? standard
    }
}

// MARK: - Reset

/// Forgets what the app has learned about the network: web views' cookies and storage, its
/// own cookies, the HTTP cache, solved Cloudflare challenges, and which TMDB host answered.
/// Settings stay as they are.
enum NetworkReset {
    @MainActor
    static func resetAll() async {
        await CacheManager.shared.clearWebsiteData()
        CacheManager.shared.clearNetworkCache()
        HTTPCookieStorage.shared.removeCookies(since: .distantPast)
        CloudflareBypassManager.shared.invalidateAll()
        TMDBHosts.shared.forgetMirror()
        Logger.shared.log("[Network] Network state reset", type: "Info")
    }
}

// MARK: - Connection test

/// One line of the connection test.
struct NetworkCheck: Identifiable, Equatable, Sendable {
    enum Outcome: Equatable, Sendable { case passed, failed, skipped }

    let title: String
    let outcome: Outcome
    let detail: String
    var id: String { title }
}

/// Settings › Advanced Network's test: TMDB's API and images the way the app reaches them now,
/// the encrypted DNS server, and the proxy, by which address the web sees.
struct NetworkDiagnostics {
    var session: URLSession = NetworkDiagnostics.defaultSession
    var hosts: TMDBHosts = .shared
    var dns: SecureDNSSettings = .current()
    var dnsInUse: SecureDNS.Resolver?
    var proxy: NetworkProxySettings = .current()
    var proxyInUse: NetworkProxy.Server?
    var proxySupported = NetworkProxy.isSupported
    /// Answers with the address it sees a request come from.
    var traceURL = URL(string: "https://www.cloudflare.com/cdn-cgi/trace")!

    static let defaultSession: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 10
        config.timeoutIntervalForResource = 15
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: config)
    }()

    func run() async -> [NetworkCheck] {
        async let api = checkTMDBAPI()
        async let images = checkTMDBImages()
        async let dns = checkDNS()
        async let proxy = checkProxy()
        return await [api, images, dns, proxy]
    }

    // MARK: TMDB

    func checkTMDBAPI() async -> NetworkCheck {
        let title = String(localized: "settings.tmdb_api")
        // Answers 401 without a key: an answer is all this asks for.
        var request = URLRequest(url: URL(string: "https://api.themoviedb.org/3/configuration")!)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let start = Date()
        do {
            let (_, response) = try await hosts.send(request) { try await session.data(for: $0) }
            return NetworkCheck(title: title, outcome: .passed,
                                detail: String(localized: "settings.host_answered_in \(Self.host(response.url)) \(Self.milliseconds(since: start))"))
        } catch {
            return NetworkCheck(title: title, outcome: .failed, detail: Self.describe(error))
        }
    }

    func checkTMDBImages() async -> NetworkCheck {
        let title = String(localized: "settings.tmdb_images")
        guard let url = hosts.rewritten(URL(string: "https://image.tmdb.org/t/p/w92/")!) else {
            return NetworkCheck(title: title, outcome: .failed, detail: String(localized: "settings.no_valid_custom_image_address"))
        }
        let start = Date()
        do {
            _ = try await session.data(for: URLRequest(url: url))
            return NetworkCheck(title: title, outcome: .passed,
                                detail: String(localized: "settings.host_answered_in \(Self.host(url)) \(Self.milliseconds(since: start))"))
        } catch {
            return NetworkCheck(title: title, outcome: .failed, detail: Self.describe(error))
        }
    }

    // MARK: DNS

    func checkDNS() async -> NetworkCheck {
        let title = String(localized: "settings.encrypted_dns")
        guard dns.enabled else { return NetworkCheck(title: title, outcome: .skipped, detail: String(localized: "settings.off")) }
        guard let resolver = dns.resolver else {
            return NetworkCheck(title: title, outcome: .failed, detail: String(localized: "settings.needs_an_https_url_and"))
        }
        guard var components = URLComponents(url: resolver.url, resolvingAgainstBaseURL: false) else {
            return NetworkCheck(title: title, outcome: .failed, detail: String(localized: "settings.not_a_url"))
        }
        components.queryItems = (components.queryItems ?? []) + [URLQueryItem(name: "dns", value: Self.dnsQuery(for: "example.com"))]
        guard let url = components.url else { return NetworkCheck(title: title, outcome: .failed, detail: String(localized: "settings.not_a_url")) }
        var request = URLRequest(url: url)
        request.setValue("application/dns-message", forHTTPHeaderField: "Accept")
        let start = Date()
        do {
            let (data, response) = try await session.data(for: request)
            let http = response as? HTTPURLResponse
            let type = http?.value(forHTTPHeaderField: "Content-Type")?.lowercased() ?? ""
            guard http?.statusCode == 200, type.hasPrefix("application/dns-message"), data.count >= 12 else {
                return NetworkCheck(title: title, outcome: .failed,
                                    detail: String(localized: "settings.host_answered_http_not_dns \(Self.host(resolver.url)) \(http?.statusCode ?? 0)"))
            }
            let answered = String(localized: "settings.host_answered_in \(Self.host(resolver.url)) \(Self.milliseconds(since: start))")
            let use = dnsInUse == resolver ? String(localized: "settings.in_use") : String(localized: "settings.in_use_from_the_next")
            return NetworkCheck(title: title, outcome: .passed, detail: "\(answered), \(use)")
        } catch {
            return NetworkCheck(title: title, outcome: .failed, detail: Self.describe(error))
        }
    }

    /// An RFC 8484 GET query: an A lookup for `name` in DNS wire format, base64url without padding.
    static func dnsQuery(for name: String) -> String {
        var message: [UInt8] = [0, 0, 1, 0, 0, 1, 0, 0, 0, 0, 0, 0]   // id 0, recursion desired, one question
        for label in name.split(separator: ".") {
            let bytes = Array(label.utf8)
            message.append(UInt8(bytes.count))
            message += bytes
        }
        message += [0, 0, 1, 0, 1]   // end of name, type A, class IN
        return Data(message).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    // MARK: Proxy

    func checkProxy() async -> NetworkCheck {
        let title = String(localized: "settings.proxy")
        guard proxy.enabled else { return NetworkCheck(title: title, outcome: .skipped, detail: String(localized: "settings.off")) }
        guard proxySupported else {
            return NetworkCheck(title: title, outcome: .failed, detail: String(localized: "settings.proxy_needs_ios_17"))
        }
        guard let server = proxy.server else {
            return NetworkCheck(title: title, outcome: .failed, detail: String(localized: "settings.needs_a_host_and_a"))
        }
        let start = Date()
        do {
            let (data, _) = try await session.data(for: URLRequest(url: traceURL))
            let address = Self.traceAddress(String(bytes: data, encoding: .utf8) ?? "") ?? "?"
            guard proxyInUse == server else {
                return NetworkCheck(title: title, outcome: .skipped,
                                    detail: String(localized: "settings.in_use_from_the_next \(address)"))
            }
            return NetworkCheck(title: title, outcome: .passed,
                                detail: String(localized: "settings.sites_see_answered_in \(address) \(Self.milliseconds(since: start))"))
        } catch {
            let through = proxyInUse == server ? String(localized: "settings.through \(server.host) \(server.port)") : ""
            return NetworkCheck(title: title, outcome: .failed, detail: through + Self.describe(error))
        }
    }

    /// The `ip=` line of Cloudflare's trace.
    static func traceAddress(_ trace: String) -> String? {
        trace.split(whereSeparator: \.isNewline)
            .first { $0.hasPrefix("ip=") }
            .map { String($0.dropFirst(3)) }
    }

    // MARK: Helpers

    private static func milliseconds(since start: Date) -> String {
        String(localized: "settings.milliseconds \(Int(Date().timeIntervalSince(start) * 1_000))")
    }

    /// The host a check reached, for its line.
    private static func host(_ url: URL?) -> String { url?.host ?? "?" }

    private static func describe(_ error: Error) -> String {
        if let error = error as? URLError, error.code == .badURL, let message = error.userInfo[NSLocalizedDescriptionKey] as? String {
            return message
        }
        return error.localizedDescription
    }
}
