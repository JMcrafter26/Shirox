import XCTest
@testable import Shirox

/// Answers every request with its own URL as the body; records every URL.
private final class EchoStub: URLProtocol {
    nonisolated(unsafe) static var seen: [String] = []
    nonisolated(unsafe) static var failingHosts: Set<String> = []

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let url = request.url!
        Self.seen.append(url.absoluteString)
        if Self.failingHosts.contains(url.host ?? "") {
            client?.urlProtocol(self, didFailWithError: URLError(.timedOut))
            return
        }
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": "text/plain"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(url.absoluteString.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

/// Every way a module's JavaScript can make a request ends in the engines' `fetchv2Native`,
/// so TMDB traffic from all of them goes to the user's proxy, or to TMDB's mirror when TMDB is
/// blocked. Through the real engines and the real extension runtime, with only the network faked.
@MainActor
final class JSTMDBRewriteTests: XCTestCase {
    private let tmdb = "https://api.themoviedb.org/3/movie/550?api_key=KEY"
    private let proxied = "https://proxy.test/tmdb/3/movie/550?api_key=KEY"

    /// `probe(style, url)` makes one request the way `style` does and gives back the body.
    private let script = """
    async function probe(style, url) {
        switch (style) {
        case 'fetchv2': return (await fetchv2(url, {}, 'GET', null)).text();
        case 'soraFetch': return (await soraFetch(url)).text();
        case 'fetch': return (await fetch(url)).text();
        case 'axios': return (await axios.get(url)).data;
        case 'http_get': return (await http_get(url)).body;
        case 'XMLHttpRequest':
            return await new Promise((resolve, reject) => {
                const xhr = new XMLHttpRequest();
                xhr.open('GET', url);
                xhr.onload = () => resolve(xhr.responseText);
                xhr.onerror = reject;
                xhr.send();
            });
        }
        throw new Error('unknown style ' + style);
    }
    """

    private var configuration: URLSessionConfiguration {
        let config = JSEngine.sessionConfiguration()
        config.protocolClasses = [EchoStub.self]
        return config
    }

    private func module(extension kind: ExtensionKind?) throws -> ModuleDefinition {
        var json: [String: Any] = ["sourceName": "TMDB Probe", "version": "1", "type": "anime",
                                   "scriptUrl": "https://example.com/probe.js", "scriptContent": script]
        if let kind {
            json["ext"] = ["kind": kind.rawValue, "repoUrl": "https://example.com/repo.json", "key": "probe", "config": "{}"]
        }
        return try JSONDecoder().decode(ModuleDefinition.self, from: JSONSerialization.data(withJSONObject: json))
    }

    private func engine(_ settings: TMDBHostSettings, extension kind: ExtensionKind? = .skystream) async throws -> JSEngine {
        let engine = JSEngine(configuration: configuration, hosts: TMDBHosts(settings: { settings }))
        try await engine.loadModule(try module(extension: kind))
        return engine
    }

    override func setUp() {
        EchoStub.seen = []
        EchoStub.failingHosts = []
    }

    private let proxy = TMDBHostSettings(useProxies: true, apiBase: "https://proxy.test/tmdb", imageBase: "")

    func testEveryExtensionRequestStyleGoesToTheProxy() async throws {
        let engine = try await engine(proxy)
        for style in ["fetchv2", "soraFetch", "fetch", "axios", "http_get", "XMLHttpRequest"] {
            EchoStub.seen = []
            let body = try await engine.callAsyncJS("probe", args: [style, tmdb], timeout: 10)
            XCTAssertEqual(body, proxied, style)
            XCTAssertEqual(EchoStub.seen, [proxied], "\(style) reached TMDB itself")
        }
    }

    func testAPlainModulesFetchGoesToTheProxy() async throws {
        let engine = try await engine(proxy, extension: nil)
        for style in ["fetchv2", "soraFetch", "fetch"] {
            EchoStub.seen = []
            let body = try await engine.callAsyncJS("probe", args: [style, tmdb], timeout: 10)
            XCTAssertEqual(body, proxied, style)
            XCTAssertEqual(EchoStub.seen, [proxied], style)
        }
    }

    func testTheRunnersFetchGoesToTheProxyToo() async throws {
        let runner = ModuleJSRunner(configuration: configuration,
                                    hosts: TMDBHosts(settings: { [proxy] in proxy }))
        // `searchResults` is all a runner calls; this one reports what its request was answered with.
        let search = script + """
        async function searchResults(keyword) {
            return JSON.stringify([{ title: await probe(keyword, '\(tmdb)'), image: '', href: '' }]);
        }
        """
        let json: [String: Any] = ["sourceName": "TMDB Probe", "version": "1", "type": "anime",
                                   "scriptUrl": "https://example.com/probe.js", "scriptContent": search]
        try await runner.load(module: JSONDecoder().decode(ModuleDefinition.self, from: JSONSerialization.data(withJSONObject: json)))
        let items = try await runner.search(keyword: "fetch")
        XCTAssertEqual(items.first?.title, proxied)
        XCTAssertEqual(EchoStub.seen, [proxied])
    }

    func testABlockedTMDBIsRetriedOnTheMirrorFromJS() async throws {
        EchoStub.failingHosts = ["api.themoviedb.org"]
        let engine = try await engine(TMDBHostSettings())
        let body = try await engine.callAsyncJS("probe", args: ["axios", tmdb], timeout: 10)
        XCTAssertEqual(body, "https://api.tmdb.org/3/movie/550?api_key=KEY")
        XCTAssertEqual(EchoStub.seen, [tmdb, "https://api.tmdb.org/3/movie/550?api_key=KEY"])
    }

    func testOnWithoutAProxyJSGetsAnErrorAndNothingIsSent() async throws {
        let engine = try await engine(TMDBHostSettings(useProxies: true))
        do {
            _ = try await engine.callAsyncJS("probe", args: ["fetch", tmdb], timeout: 10)
            XCTFail("A TMDB request went out without a proxy")
        } catch {}
        XCTAssertEqual(EchoStub.seen, [])
    }

    func testOtherHostsAreUntouched() async throws {
        let engine = try await engine(proxy)
        let other = "https://example.com/3/movie/550"
        let body = try await engine.callAsyncJS("probe", args: ["fetch", other], timeout: 10)
        XCTAssertEqual(body, other)
    }

    func testWebViewLoadsAreRewrittenToo() {
        let hosts = TMDBHosts(settings: { [proxy] in proxy })
        XCTAssertEqual(hosts.rewritten(urlString: tmdb), proxied, "networkFetch and fetchv2's webview mode load this")
    }
}
