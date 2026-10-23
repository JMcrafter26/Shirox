import XCTest
@testable import Shirox

/// Answers per host: an error, as a blocked host gives, or a status and body. Records every URL.
private final class HostStub: URLProtocol {
    enum Answer { case fail(URLError.Code), answer(Int, String) }
    nonisolated(unsafe) static var answers: [String: Answer] = [:]
    nonisolated(unsafe) static var seen: [String] = []

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let url = request.url!
        Self.seen.append(url.absoluteString)
        switch Self.answers[url.host ?? ""] ?? .fail(.cannotConnectToHost) {
        case .fail(let code):
            client?.urlProtocol(self, didFailWithError: URLError(code))
        case .answer(let status, let body):
            let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(body.utf8))
            client?.urlProtocolDidFinishLoading(self)
        }
    }
    override func stopLoading() {}
}

/// Where TMDB requests go: TMDB's mirror when its API is blocked, the user's proxies when set,
/// and nowhere when the proxy is on without a usable address.
@MainActor
final class TMDBHostsTests: XCTestCase {
    private let api = URL(string: "https://api.themoviedb.org/3/movie/550?api_key=KEY&language=en")!
    private let image = URL(string: "https://image.tmdb.org/t/p/w500/poster.jpg")!

    private func hosts(proxies: Bool = false, api: String = "", image: String = "") -> TMDBHosts {
        let settings = TMDBHostSettings(useProxies: proxies, apiBase: api, imageBase: image)
        return TMDBHosts(settings: { settings })
    }

    private func strings(_ urls: [URL]) -> [String] { urls.map(\.absoluteString) }

    override func setUp() {
        HostStub.answers = [:]
        HostStub.seen = []
    }

    // MARK: - Off: TMDB, then its mirror

    func testTheAPIFallsBackToTheMirror() {
        XCTAssertEqual(strings(hosts().candidates(for: api)), [
            "https://api.themoviedb.org/3/movie/550?api_key=KEY&language=en",
            "https://api.tmdb.org/3/movie/550?api_key=KEY&language=en",
        ])
    }

    func testImagesAndOtherHostsStayAsTheyAre() {
        XCTAssertEqual(strings(hosts().candidates(for: image)), [image.absoluteString], "TMDB has no image mirror")
        let other = URL(string: "https://example.com/3/movie/550")!
        XCTAssertEqual(hosts().candidates(for: other), [other])
        XCTAssertEqual(hosts(proxies: true, api: "https://p.test", image: "https://i.test").candidates(for: other), [other])
    }

    // MARK: - On: the proxies and nothing else

    func testTheProxyTakesTheOriginAndKeepsPathAndQuery() {
        let proxying = hosts(proxies: true, api: "https://proxy.test/tmdb", image: "https://img.test/")
        XCTAssertEqual(strings(proxying.candidates(for: api)), ["https://proxy.test/tmdb/3/movie/550?api_key=KEY&language=en"])
        XCTAssertEqual(strings(proxying.candidates(for: image)), ["https://img.test/t/p/w500/poster.jpg"])
        let mirror = URL(string: "https://api.tmdb.org/3/tv/1")!
        XCTAssertEqual(strings(proxying.candidates(for: mirror)), ["https://proxy.test/tmdb/3/tv/1"], "A module asking the mirror is proxied too")
    }

    func testThePrefilledBasesAreTMDBsOwnAndChangeNothing() {
        let prefilled = hosts(proxies: true, api: TMDBHostSettings.defaultAPIBase, image: TMDBHostSettings.defaultImageBase)
        XCTAssertEqual(prefilled.candidates(for: api), [api], "TMDB itself, with no mirror to fall back to")
        XCTAssertEqual(prefilled.candidates(for: image), [image])
    }

    func testOnWithoutAUsableProxyNothingIsSent() {
        for base in ["", "proxy.test", "http://proxy.test", "https://proxy.test?x=1", "ftp://proxy.test"] {
            XCTAssertEqual(hosts(proxies: true, api: base).candidates(for: api), [], "\(base)")
            XCTAssertNil(hosts(proxies: true, image: base).rewritten(image), "\(base)")
        }
        XCTAssertNil(hosts(proxies: true).rewritten(urlString: api.absoluteString))
        XCTAssertEqual(hosts(proxies: true).rewritten(urlString: "not a url"), "not a url")
        XCTAssertEqual(hosts(proxies: true).rewritten(urlString: "https://example.com/a b?q=x y"), "https://example.com/a b?q=x y",
                       "Another host's address is passed on as the module wrote it")
    }

    // MARK: - Failover

    private func perform(_ answers: [String: Result<Int, URLError>], calls: @escaping (String) -> Void)
        -> (URLRequest) async throws -> (Data, URLResponse) {
        { request in
            let url = request.url!
            calls(url.host ?? "")
            switch answers[url.host ?? ""] ?? .failure(URLError(.cannotConnectToHost)) {
            case .success(let status):
                return (Data(), HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!)
            case .failure(let error):
                throw error
            }
        }
    }

    func testABlockedAPIIsRetriedOnTheMirrorAndTheMirrorIsKept() async throws {
        let hosts = hosts()
        var calls: [String] = []
        let send = perform(["api.themoviedb.org": .failure(URLError(.timedOut)), "api.tmdb.org": .success(200)]) { calls.append($0) }
        let (_, response) = try await hosts.send(URLRequest(url: api), perform: send)
        XCTAssertEqual(response.url?.host, "api.tmdb.org")
        XCTAssertEqual(calls, ["api.themoviedb.org", "api.tmdb.org"])

        calls = []
        _ = try await hosts.send(URLRequest(url: api), perform: send)
        XCTAssertEqual(calls, ["api.tmdb.org"], "Once the mirror answered, it goes first")
    }

    func testAnHTTPErrorIsTMDBsAnswerNotABlock() async throws {
        var calls: [String] = []
        let (_, response) = try await hosts().send(URLRequest(url: api),
                                                   perform: perform(["api.themoviedb.org": .success(404)]) { calls.append($0) })
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 404)
        XCTAssertEqual(calls, ["api.themoviedb.org"])
    }

    func testBeingOfflineOrCancelledIsNotRetried() async {
        for code in [URLError.Code.notConnectedToInternet, .cancelled] {
            var calls: [String] = []
            do {
                _ = try await hosts().send(URLRequest(url: api),
                                           perform: perform(["api.themoviedb.org": .failure(URLError(code))]) { calls.append($0) })
                XCTFail("\(code) came back as an answer")
            } catch {
                XCTAssertEqual((error as? URLError)?.code, code)
            }
            XCTAssertEqual(calls, ["api.themoviedb.org"])
        }
    }

    func testAFailingProxyNeverFallsBackToTMDB() async {
        var calls: [String] = []
        do {
            _ = try await hosts(proxies: true, api: "https://proxy.test").send(
                URLRequest(url: api), perform: perform(["proxy.test": .failure(URLError(.timedOut))]) { calls.append($0) })
            XCTFail("A dead proxy answered")
        } catch {
            XCTAssertEqual((error as? URLError)?.code, .timedOut)
        }
        XCTAssertEqual(calls, ["proxy.test"], "A proxy can be there for privacy: TMDB is never asked")
    }

    func testOnWithoutAProxyTheRequestIsRefusedUnsent() async {
        var calls: [String] = []
        do {
            _ = try await hosts(proxies: true).send(URLRequest(url: api), perform: perform([:]) { calls.append($0) })
            XCTFail("Sent without a proxy")
        } catch {
            XCTAssertEqual((error as? URLError)?.code, .badURL)
        }
        XCTAssertEqual(calls, [])
    }

    // MARK: - Through a real session: TMDB logos

    private func logoService(_ hosts: TMDBHosts) -> TMDBLogoService {
        let config = TMDBLogoService.sessionConfiguration()
        config.protocolClasses = [HostStub.self]
        return TMDBLogoService(configuration: config, hosts: hosts, apiKey: "KEY", persists: false)
    }

    private let details = #"{"original_language":"en","images":{"logos":[{"file_path":"/logo.png","iso_639_1":"en","vote_average":5,"width":400,"height":100}]}}"#

    func testALogoLookupSurvivesABlockedTMDB() async {
        HostStub.answers = ["api.themoviedb.org": .fail(.timedOut), "api.tmdb.org": .answer(200, details)]
        let logo = await logoService(hosts()).logo(tmdbID: 550, record: .movie)
        XCTAssertEqual(logo, "https://image.tmdb.org/t/p/w500/logo.png")
        XCTAssertEqual(HostStub.seen.map { URL(string: $0)?.host }, ["api.themoviedb.org", "api.tmdb.org"])
    }

    func testALogoLookupGoesOnlyToTheProxy() async {
        HostStub.answers = ["proxy.test": .answer(200, details)]
        let logo = await logoService(hosts(proxies: true, api: "https://proxy.test/tmdb")).logo(tmdbID: 550, record: .movie)
        XCTAssertEqual(logo, "https://image.tmdb.org/t/p/w500/logo.png", "The image is rewritten when it's loaded")
        XCTAssertEqual(HostStub.seen, ["https://proxy.test/tmdb/3/movie/550?api_key=KEY&append_to_response=images&include_image_language=en,null"])
    }
}
