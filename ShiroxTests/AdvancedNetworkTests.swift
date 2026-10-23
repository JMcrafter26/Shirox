import XCTest
@testable import Shirox

/// Answers per host with a status, content type and body; a host it has no answer for fails as
/// a blocked one does.
private final class DiagnosticsStub: URLProtocol {
    struct Answer { let status: Int; let type: String; let body: Data }
    nonisolated(unsafe) static var answers: [String: Answer] = [:]
    nonisolated(unsafe) static var seen: [URL] = []

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let url = request.url!
        Self.seen.append(url)
        guard let answer = Self.answers[url.host ?? ""] else {
            client?.urlProtocol(self, didFailWithError: URLError(.timedOut))
            return
        }
        let response = HTTPURLResponse(url: url, statusCode: answer.status, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": answer.type])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: answer.body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

/// The proxy for all traffic, the User-Agent, the reset and the connection test of Settings ›
/// Advanced Network.
@MainActor
final class AdvancedNetworkTests: XCTestCase {
    override func setUp() {
        DiagnosticsStub.answers = [:]
        DiagnosticsStub.seen = []
        NetworkProxy.resetForTesting()
    }

    override func tearDown() { NetworkProxy.resetForTesting() }

    // MARK: - Proxy settings

    private func proxy(_ host: String = "proxy.test", port: String = "1080", username: String = "",
                       password: String = "", kind: NetworkProxySettings.Kind = .socks5) -> NetworkProxySettings {
        NetworkProxySettings(enabled: true, kind: kind, host: host, port: port, username: username, password: password)
    }

    func testAUsableProxy() {
        XCTAssertEqual(proxy(" 10.0.0.2 ", port: " 8080", kind: .http).server,
                       NetworkProxy.Server(kind: .http, host: "10.0.0.2", port: 8080, username: nil, password: nil))
        XCTAssertEqual(proxy(username: "me", password: "secret").server?.username, "me")
    }

    func testAnUnusableProxyIsNoProxy() {
        XCTAssertNil(NetworkProxySettings(enabled: false, host: "proxy.test", port: "1080").server)
        XCTAssertNil(proxy("").server)
        XCTAssertNil(proxy("socks5://proxy.test").server, "A bare host, not a URL")
        XCTAssertNil(proxy("me@proxy.test").server)
        XCTAssertNil(proxy(port: "").server)
        XCTAssertNil(proxy(port: "0").server)
        XCTAssertNil(proxy(port: "70000").server)
        XCTAssertNil(proxy(username: "me").server, "A username needs its password")
        XCTAssertNil(proxy(password: "secret").server)
    }

    func testTheProxyIsAppliedOnceAtLaunchWhenUsable() {
        var applied: [NetworkProxy.Server] = []
        NetworkProxy.applyAtLaunch(proxy()) { applied.append($0) }
        NetworkProxy.applyAtLaunch(proxy("other.test")) { applied.append($0) }
        if NetworkProxy.isSupported {
            XCTAssertEqual(applied.map(\.host), ["proxy.test"], "A change counts from the next launch")
            XCTAssertEqual(NetworkProxy.active?.host, "proxy.test")
        } else {
            XCTAssertEqual(applied, [], "Before iOS 17 there's no proxy for all traffic")
        }
    }

    func testNoProxyAppliedWhenOffOrUnusable() {
        var applied = 0
        NetworkProxy.applyAtLaunch(NetworkProxySettings()) { _ in applied += 1 }
        NetworkProxy.resetForTesting()
        NetworkProxy.applyAtLaunch(proxy(port: "")) { _ in applied += 1 }
        XCTAssertEqual(applied, 0)
        XCTAssertNil(NetworkProxy.active)
    }

    func testThePortFollowsTheType() {
        XCTAssertEqual(NetworkProxySettings.Kind.socks5.defaultPort, "1080")
        XCTAssertEqual(NetworkProxySettings.Kind.http.defaultPort, "8080")
    }

    func testTheSettingsAreReadFromDefaultsAndTheKeychain() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "AdvancedNetworkTests"))
        defer { defaults.removePersistentDomain(forName: "AdvancedNetworkTests") }
        defaults.set(true, forKey: NetworkProxySettings.enabledKey)
        defaults.set("http", forKey: NetworkProxySettings.kindKey)
        defaults.set("proxy.test", forKey: NetworkProxySettings.hostKey)
        defaults.set("3128", forKey: NetworkProxySettings.portKey)
        defaults.set("me", forKey: NetworkProxySettings.usernameKey)
        let server = NetworkProxySettings.current(defaults, password: { "secret" }).server
        XCTAssertEqual(server, NetworkProxy.Server(kind: .http, host: "proxy.test", port: 3128, username: "me", password: "secret"))
    }

    // MARK: - User-Agent

    func testTheUserAgentIsShiroxsOwnUnlessACustomOneIsOn() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "AdvancedNetworkUATests"))
        defer { defaults.removePersistentDomain(forName: "AdvancedNetworkUATests") }
        XCTAssertEqual(NetworkUserAgent.current(defaults), NetworkUserAgent.standard)
        defaults.set("Mozilla/5.0 Custom", forKey: NetworkUserAgent.valueKey)
        XCTAssertEqual(NetworkUserAgent.current(defaults), NetworkUserAgent.standard, "Off, the text is ignored")
        defaults.set(true, forKey: NetworkUserAgent.enabledKey)
        XCTAssertEqual(NetworkUserAgent.current(defaults), "Mozilla/5.0 Custom")
        defaults.set("   ", forKey: NetworkUserAgent.valueKey)
        XCTAssertNil(NetworkUserAgent.custom(defaults), "An empty one is Shirox's own")
    }

    func testShiroxsOwnIsTheOneItAlwaysSent() {
        XCTAssertEqual(NetworkUserAgent.standard,
                       "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36")
    }

    // MARK: - Reset

    func testResetForgetsTheMirror() async throws {
        let hosts = TMDBHosts(settings: { TMDBHostSettings() })
        let url = try XCTUnwrap(URL(string: "https://api.themoviedb.org/3/configuration"))
        _ = try await hosts.send(URLRequest(url: url)) { request -> Int in
            if request.url?.host == TMDBHosts.apiHost { throw URLError(.timedOut) }
            return 200
        }
        XCTAssertEqual(hosts.candidates(for: url).first?.host, TMDBHosts.apiMirrorHost)
        hosts.forgetMirror()
        XCTAssertEqual(hosts.candidates(for: url).first?.host, TMDBHosts.apiHost)
    }

    // MARK: - Connection test

    private var session: URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [DiagnosticsStub.self]
        return URLSession(configuration: config)
    }

    private func diagnostics(dns: SecureDNSSettings = SecureDNSSettings(), dnsInUse: SecureDNS.Resolver? = nil,
                             proxy: NetworkProxySettings = NetworkProxySettings(), proxyInUse: NetworkProxy.Server? = nil,
                             tmdb: TMDBHostSettings = TMDBHostSettings()) -> NetworkDiagnostics {
        NetworkDiagnostics(session: session, hosts: TMDBHosts(settings: { tmdb }), dns: dns, dnsInUse: dnsInUse,
                           proxy: proxy, proxyInUse: proxyInUse, proxySupported: true)
    }

    private func answer(_ status: Int = 200, type: String = "text/plain", _ body: String = "") -> DiagnosticsStub.Answer {
        DiagnosticsStub.Answer(status: status, type: type, body: Data(body.utf8))
    }

    func testTMDBPassesThroughTheMirrorAndSaysWhichHostAnswered() async {
        DiagnosticsStub.answers = ["api.tmdb.org": answer(401), "image.tmdb.org": answer(404)]
        let checks = await diagnostics().run()
        XCTAssertEqual(checks.map(\.title), ["TMDB API", "TMDB Images", "Encrypted DNS", "Proxy"])
        XCTAssertEqual(checks[0].outcome, .passed, "Any answer means it's reachable; 401 is TMDB without a key")
        XCTAssertTrue(checks[0].detail.hasPrefix("api.tmdb.org answered"), checks[0].detail)
        XCTAssertEqual(checks[1].outcome, .passed)
        XCTAssertEqual(checks[2], NetworkCheck(title: "Encrypted DNS", outcome: .skipped, detail: "Off"))
        XCTAssertEqual(checks[3], NetworkCheck(title: "Proxy", outcome: .skipped, detail: "Off"))
    }

    func testTMDBFailsWhenUnreachableOrWithoutAProxy() async {
        let unreachable = await diagnostics().checkTMDBAPI()
        XCTAssertEqual(unreachable.outcome, .failed)
        DiagnosticsStub.seen = []
        let noProxy = await diagnostics(tmdb: TMDBHostSettings(useProxies: true)).run()
        XCTAssertEqual(noProxy[0].outcome, .failed)
        XCTAssertEqual(noProxy[1], NetworkCheck(title: "TMDB Images", outcome: .failed, detail: "No valid custom image address"))
        XCTAssertFalse(DiagnosticsStub.seen.contains { $0.host?.hasSuffix("tmdb.org") == true || $0.host == TMDBHosts.apiHost },
                       "Nothing goes to TMDB while its proxies are on")
    }

    private let cloudflare = SecureDNSSettings(enabled: true, serverURL: "https://cloudflare-dns.com/dns-query",
                                               serverAddresses: "1.1.1.1")

    func testTheDNSServerIsAskedARealQuery() async throws {
        DiagnosticsStub.answers = ["cloudflare-dns.com": answer(type: "application/dns-message", String(repeating: "\0", count: 40))]
        let check = await diagnostics(dns: cloudflare, dnsInUse: cloudflare.resolver).checkDNS()
        XCTAssertEqual(check.outcome, .passed)
        XCTAssertTrue(check.detail.hasSuffix(", in use"), check.detail)
        let url = try XCTUnwrap(DiagnosticsStub.seen.first)
        XCTAssertEqual(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first?.value,
                       NetworkDiagnostics.dnsQuery(for: "example.com"))

        let notYet = await diagnostics(dns: cloudflare).checkDNS()
        XCTAssertTrue(notYet.detail.hasSuffix("in use from the next start"), notYet.detail)
    }

    func testADNSServerThatDoesntAnswerDNSFails() async {
        DiagnosticsStub.answers = ["cloudflare-dns.com": answer(type: "text/html", "<html>")]
        let check = await diagnostics(dns: cloudflare).checkDNS()
        XCTAssertEqual(check.outcome, .failed)
        let unusable = await diagnostics(dns: SecureDNSSettings(enabled: true)).checkDNS()
        XCTAssertEqual(unusable.outcome, .failed)
    }

    func testTheDNSQueryIsAWireFormatALookup() throws {
        let encoded = NetworkDiagnostics.dnsQuery(for: "example.com")
        XCTAssertFalse(encoded.contains("=") || encoded.contains("+") || encoded.contains("/"), "base64url without padding")
        var base64 = encoded.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
        let bytes = try [UInt8](XCTUnwrap(Data(base64Encoded: base64)))
        XCTAssertEqual(bytes, [0, 0, 1, 0, 0, 1, 0, 0, 0, 0, 0, 0,
                               7] + Array("example".utf8) + [3] + Array("com".utf8) + [0, 0, 1, 0, 1])
    }

    func testTheProxySaysWhichAddressSitesSee() async {
        DiagnosticsStub.answers = ["www.cloudflare.com": answer(200, "fl=1\nip=203.0.113.7\nts=1\n")]
        let settings = proxy()
        let inUse = await diagnostics(proxy: settings, proxyInUse: settings.server).checkProxy()
        XCTAssertEqual(inUse.outcome, .passed)
        XCTAssertTrue(inUse.detail.hasPrefix("Sites see 203.0.113.7"), inUse.detail)

        let notYet = await diagnostics(proxy: settings).checkProxy()
        XCTAssertEqual(notYet.outcome, .skipped)
        XCTAssertEqual(notYet.detail, "In use from the next start. Without it, sites see 203.0.113.7")
    }

    func testADeadProxyFailsAndAnUnusableOneSaysWhy() async {
        let settings = proxy()
        let dead = await diagnostics(proxy: settings, proxyInUse: settings.server).checkProxy()
        XCTAssertEqual(dead.outcome, .failed)
        XCTAssertTrue(dead.detail.hasPrefix("Through proxy.test:1080: "), dead.detail)
        let unusable = await diagnostics(proxy: proxy(port: "")).checkProxy()
        XCTAssertEqual(unusable.outcome, .failed)
    }

    func testTheTracesAddress() {
        XCTAssertEqual(NetworkDiagnostics.traceAddress("fl=1\r\nh=www.cloudflare.com\r\nip=2001:db8::1\r\n"), "2001:db8::1")
        XCTAssertNil(NetworkDiagnostics.traceAddress("<html>"))
    }
}
