import XCTest
@testable import Shirox

/// Serves each URL its own canned status, headers and body; a URL it has no answer for fails
/// with a network error, as an unreachable host does.
private final class RouteProtocol: URLProtocol {
    struct Route { let status: Int; let headers: [String: String]; let body: Data }
    nonisolated(unsafe) static var routes: [String: Route] = [:]
    nonisolated(unsafe) static var seenHeaders: [String: [String: String]] = [:]

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let url = request.url!.absoluteString
        Self.seenHeaders[url] = request.allHTTPHeaderFields ?? [:]
        guard let route = Self.routes[url] else {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotConnectToHost))
            return
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: route.status, httpVersion: "HTTP/1.1", headerFields: route.headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: route.body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

final class StreamProbeTests: XCTestCase {
    private var session: URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [RouteProtocol.self]
        return URLSession(configuration: config)
    }

    private func stream(_ url: String, headers: [String: String] = [:]) -> StreamResult {
        StreamResult(title: url, url: URL(string: url)!, headers: headers)
    }

    override func setUp() {
        RouteProtocol.routes = [
            "https://a.test/video.mkv": .init(status: 206, headers: ["Content-Type": "application/octet-stream"], body: Data([0x1a, 0x45, 0xdf, 0xa3, 0, 0, 0, 0])),
            "https://a.test/master.m3u8": .init(status: 200, headers: ["Content-Type": "text/plain"], body: Data("#EXTM3U\n#EXT-X-VERSION:3\n".utf8)),
            "https://a.test/dead": .init(status: 404, headers: ["Content-Type": "text/plain"], body: Data("Unable to find".utf8)),
            "https://a.test/page": .init(status: 200, headers: ["Content-Type": "text/html; charset=utf-8"], body: Data("<!DOCTYPE html><html>".utf8)),
            "https://a.test/untyped-page": .init(status: 200, headers: [:], body: Data("  \n<html><body>download</body>".utf8)),
            "https://a.test/episode.zip": .init(status: 206, headers: ["Content-Type": "application/x-zip"], body: Data([0x50, 0x4b, 0x03, 0x04, 0x2d, 0])),
            "https://a.test/needs-referer": .init(status: 200, headers: ["Content-Type": "video/mp4"], body: Data([0, 0, 0, 0x20, 0x66, 0x74, 0x79, 0x70])),
        ]
        RouteProtocol.seenHeaders = [:]
    }

    func testVideoAndPlaylistsAreKept() async {
        let video = await StreamProbe.verdict(for: stream("https://a.test/video.mkv"), session: session)
        let hls = await StreamProbe.verdict(for: stream("https://a.test/master.m3u8"), session: session)
        XCTAssertEqual(video, .playable)
        XCTAssertEqual(hls, .playable)
    }

    func testDeadLinksPagesAndArchivesAreNot() async {
        for url in ["https://a.test/dead", "https://a.test/page", "https://a.test/untyped-page", "https://a.test/episode.zip"] {
            let verdict = await StreamProbe.verdict(for: stream(url), session: session)
            XCTAssertEqual(verdict, .notVideo, url)
        }
    }

    func testAnUnreachableHostIsUnknownNotDropped() async {
        let verdict = await StreamProbe.verdict(for: stream("https://down.test/x.mp4"), session: session)
        XCTAssertEqual(verdict, .unknown)
    }

    func testTheStreamsOwnHeadersAreSentAndOnlyTheStartIsAsked() async {
        _ = await StreamProbe.verdict(for: stream("https://a.test/needs-referer", headers: ["Referer": "https://site.test/"]), session: session)
        let sent = RouteProtocol.seenHeaders["https://a.test/needs-referer"] ?? [:]
        XCTAssertEqual(sent["Referer"], "https://site.test/")
        XCTAssertEqual(sent["Range"], "bytes=0-63")
    }

    func testFilterKeepsOrderAndUnknowns() async {
        let input = ["https://a.test/page", "https://a.test/video.mkv", "https://down.test/x.mp4", "https://a.test/dead", "https://a.test/master.m3u8"].map { stream($0) }
        let kept = await StreamProbe.playable(input, session: session)
        XCTAssertEqual(kept.map(\.url.absoluteString), ["https://a.test/video.mkv", "https://down.test/x.mp4", "https://a.test/master.m3u8"])
    }
}

/// Answers only the a.test host, for whatever session asks — the runner checks streams with the
/// shared one.
private final class ATestProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "a.test" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let page = request.url!.path == "/page"
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": page ? "text/html" : "video/x-matroska"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: page ? Data("<html>".utf8) : Data([0x1a, 0x45, 0xdf, 0xa3]))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@MainActor
final class ExtensionStreamCheckTests: XCTestCase {
    func testAnExtensionsStreamsAreCheckedBeforeTheyreOffered() async throws {
        URLProtocol.registerClass(ATestProtocol.self)
        defer { URLProtocol.unregisterClass(ATestProtocol.self) }
        let plugin = """
        globalThis.loadStreams = function (url, cb) {
          cb({ success: true, data: [new StreamResult({ url: "https://a.test/page", quality: "1080p" }),
                                     new StreamResult({ url: "https://a.test/video.mkv", quality: "1080p" })] });
        };
        """
        let json = #"{"sourceName":"P","version":"1","scriptUrl":"https://raw.test/p.sky","type":"anime","ext":{"kind":"skystream","repoUrl":"https://raw.test/repo.json","key":"p","config":"{\"manifest\":{\"name\":\"P\"}}"}}"#
        var module = try JSONDecoder().decode(ModuleDefinition.self, from: Data(json.utf8))
        module.scriptContent = ExtensionInstaller.wrapSkyStream(plugin)
        let runner = ModuleJSRunner()
        try await runner.load(module: module)
        let streams = try await runner.fetchStreams(episodeUrl: "/e/1")
        XCTAssertEqual(streams.map(\.url.absoluteString), ["https://a.test/video.mkv"])
    }

    /// Fetching a debrid addon's link adds the torrent to the account, so a Stremio addon's
    /// streams are listed unchecked; the scraper kinds' are still checked.
    func testStremioStreamsAreNotFetchedBeforeOneIsPicked() {
        XCTAssertFalse(StreamProbe.checks(.stremio))
        XCTAssertFalse(StreamProbe.checks(nil))
        for kind in [ExtensionKind.nuvio, .vega, .skystream] {
            XCTAssertTrue(StreamProbe.checks(kind))
        }
    }

    func testStreamDetailsAreParsed() {
        let streams = parseStreamResults(from: ["streams": [
            ["title": "FHD • TB ⚡ON", "details": "WEB-DL AVC\nAAC 2.0 🇬🇧 • 🇯🇵 Dubbed\n1.44 GB", "streamUrl": "https://a.example/1"],
            ["title": "Plain", "streamUrl": "https://a.example/2"],
        ]])
        XCTAssertEqual(streams.map(\.title), ["FHD • TB ⚡ON", "Plain"])
        XCTAssertEqual(streams[0].details, "WEB-DL AVC\nAAC 2.0 🇬🇧 • 🇯🇵 Dubbed\n1.44 GB")
        XCTAssertNil(streams[1].details)
    }
}
