import JavaScriptCore
import Kingfisher
import UIKit
import XCTest
@testable import Shirox

/// Mana sources: the repo's `sources.json`, the install check of the bundle's own rating, and
/// the runtime's Luna functions over a source's `search`/`getContent`/`getChapters`/`getChapterData`.
@MainActor
final class ManaExtensionTests: XCTestCase {
    private let index: [String: Any] = [
        "repositoryName": "Mana Repo",
        "sources": [
            ["id": "safe", "name": "Safe", "version": "1.2.0", "rating": 0, "thumbnail": "Safe.png",
             "supportedLanguages": ["en_US"], "path": "Safe", "environment": "source"],
            ["id": "mixed", "name": "Mixed Scans", "version": "2.0.0", "rating": 1, "path": "Mixed Scans",
             "thumbnail": "https://cdn.test/m.png", "environment": "source"],
            ["id": "explicit", "name": "Toons", "version": "1", "rating": 2, "path": "Toons", "environment": "source"],
            ["id": "Hentai20", "name": "Hentai20", "version": "1", "rating": 1, "path": "Hentai20", "environment": "source"],
            ["id": "tracker", "name": "MangaUpdates", "version": "1", "rating": 1, "path": "MangaUpdates", "environment": "tracker"],
        ],
    ]

    private func repo() async throws -> ExtensionRepo {
        let data = try JSONSerialization.data(withJSONObject: index)
        guard case .repo(let r)? = try await ExtensionRepoLoader.detect(
            data, url: URL(string: "https://o.github.io/repo/main/sources.json")!, fetch: { _ in Data() }) else {
            throw XCTSkip("not detected")
        }
        return r
    }

    // MARK: - Repo

    func testSourcesJSONIsAManaRepo() async throws {
        let r = try await repo()
        XCTAssertEqual(r.kind, .mana)
        XCTAssertEqual(r.name, "Mana Repo")
        XCTAssertEqual(r.entries.map(\.key), ["safe", "mixed"])
        let safe = r.entries[0]
        XCTAssertEqual(safe.fileURL.absoluteString, "https://o.github.io/repo/main/sources/Safe.mana")
        XCTAssertEqual(safe.iconUrl, "https://o.github.io/repo/main/assets/Safe.png")
        XCTAssertEqual(safe.language, "en")
        XCTAssertEqual(safe.version, "1.2.0")
        XCTAssertEqual(r.entries[1].fileURL.absoluteString, "https://o.github.io/repo/main/sources/Mixed%20Scans.mana")
        XCTAssertEqual(r.entries[1].iconUrl, "https://cdn.test/m.png")
    }

    func testExplicitSourcesAreHiddenAndRemembered() async throws {
        // Explicit by rating, or by an adult name though the repo rates it mixed. Trackers aren't adult, just not sources.
        let adult = try await repo().adultKeys
        XCTAssertEqual(adult, ["explicit", "Hentai20"])
    }

    func testManaAddRepoLinkBecomesTheRepo() {
        let link = URL(string: "mana://add-repo?url=https%3A%2F%2Fo.github.io%2Frepo%2Fmain&name=Repo")!
        XCTAssertEqual(ExtensionRepoLoader.normalized(link).absoluteString, "https://o.github.io/repo/main")
        XCTAssertEqual(ExtensionRepoLoader.normalized(URL(string: "mana://add-repo?url=file%3A%2F%2F%2Fetc")!).scheme, "mana")
    }

    func testARepoFolderOrPageIsLookedUpByItsIndex() {
        XCTAssertEqual(ExtensionRepoLoader.indexCandidates(for: URL(string: "https://o.github.io/repo/main/open.html")!).map(\.absoluteString),
                       ["https://o.github.io/repo/main/manifest.json", "https://o.github.io/repo/main/sources.json"])
        XCTAssertEqual(ExtensionRepoLoader.indexCandidates(for: URL(string: "https://o.github.io/repo/main")!).last?.absoluteString,
                       "https://o.github.io/repo/main/sources.json")
        XCTAssertTrue(ExtensionRepoLoader.indexCandidates(for: URL(string: "https://o.test/a.json")!).isEmpty)
    }

    // MARK: - Install

    private func bundle(rating: Int, name: String = "Safe") -> String {
        """
        var __exports__ = (() => { class Target { constructor() { this.info = { id: "safe", name: "\(name)", version: "1.2.0",
          rating: \(rating), website: "https://safe.test" }; } } return { Target }; })();
        globalThis.Target = __exports__.Target;
        """
    }

    private func install(_ script: String) async throws -> ModuleDefinition {
        let r = try await repo()
        let e = r.entries[0]
        return try await ExtensionInstaller.module(entry: e, repo: r) { url in
            guard url == e.fileURL else { throw URLError(.fileDoesNotExist) }
            return Data(script.utf8)
        }
    }

    func testInstallMakesAMangaModule() async throws {
        let m = try await install(bundle(rating: 0))
        XCTAssertEqual(m.type, "manga")
        XCTAssertTrue(m.isManga)
        XCTAssertEqual(m.ext?.kind, .mana)
        XCTAssertEqual(m.ext?.key, "safe")
        XCTAssertEqual(m.baseUrl, "https://safe.test")
        XCTAssertEqual(m.version, "1.2.0")
        XCTAssertEqual(m.jsonUrl, "https://o.github.io/repo/main/sources.json#ext=safe")
        XCTAssertEqual(ExtensionKind.mana.badge, "Mana")
    }

    func testInstallRefusesASourceThatRatesItselfExplicit() async {
        // The repo lists it as safe; the bundle says otherwise.
        do { _ = try await install(bundle(rating: 2)); XCTFail("installed") } catch {
            XCTAssertEqual(error as? ExtensionInstallError, .adult)
        }
        do { _ = try await install(bundle(rating: 0, name: "HentaiHaven")); XCTFail("installed") } catch {
            XCTAssertEqual(error as? ExtensionInstallError, .adult)
        }
    }

    func testInstallRefusesABundleWithNoSource() async {
        do { _ = try await install("var x = 1;"); XCTFail("installed") } catch {
            XCTAssertEqual(error as? ExtensionInstallError, .noPlugin)
        }
    }

    func testUpdateRemovesASourceThatTurnedExplicit() async throws {
        let m = try await install(bundle(rating: 0))
        var changed = index
        var sources = changed["sources"] as! [[String: Any]]
        sources[0]["rating"] = 2
        changed["sources"] = sources
        let data = try JSONSerialization.data(withJSONObject: changed)
        guard let link = try await ExtensionRepoLoader.detect(data, url: URL(string: "https://o.github.io/repo/main/sources.json")!,
                                                              fetch: { _ in Data() }) else { return XCTFail() }
        XCTAssertEqual(ExtensionUpdate.decide(m, link: link), .remove)
    }

    func testABodyWithABadByteIsStillText() {
        // ocecomic.com cuts titles off mid-character; the page used to come through empty.
        let text = JSEngine.bodyText(Data("<a>caf".utf8) + Data([0xC3]) + Data("</a>".utf8))
        XCTAssertEqual(text, "<a>caf\u{FFFD}</a>")
        XCTAssertEqual(JSEngine.bodyText(Data("plain".utf8)), "plain")
    }

    func testARawPageLoadsInTheReaderAndDownloads() async throws {
        // A source may hand a page over as bytes (`raw`), which the runtime passes on as a data: address.
        let png = UIGraphicsImageRenderer(size: CGSize(width: 4, height: 4)).image { ctx in
            UIColor.red.setFill(); ctx.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
        }.pngData()!
        let url = URL(string: "data:image/jpeg;base64," + png.base64EncodedString())!
        XCTAssertEqual(KingfisherImageCache.dataURLBytes(url), png)
        XCTAssertNil(KingfisherImageCache.dataURLBytes(URL(string: "https://x.test/1.png")!))
        let result = try await KingfisherManager.shared.retrieveImage(
            with: KingfisherImageCache.source(for: url, cacheKey: url.absoluteString), options: [.forceRefresh])
        XCTAssertEqual(result.image.cgImage?.width, UIImage(data: png)?.cgImage?.width)
    }

    func testAWalledMangaCallIsSolvedThenRunOnceMore() async throws {
        // A host the bypass won't open, so no web view is shown here.
        HostBlocklist.loadForTesting(["walled.test"])
        defer { HostBlocklist.loadForTesting([]) }
        let manager = CloudflareBypassManager.shared
        var calls = 0
        let pages = try await manager.pastWall { () async throws -> [String] in
            calls += 1
            if calls == 1 {
                manager.pendingVerificationURL = URL(string: "https://walled.test/chapter/1")
                throw URLError(.userAuthenticationRequired)
            }
            return ["https://walled.test/1.jpg"]
        }
        XCTAssertEqual(pages, ["https://walled.test/1.jpg"])
        XCTAssertEqual(calls, 2)
        XCTAssertNil(manager.pendingVerificationURL)

        // No wall: an error is the call's own, and nothing runs again.
        calls = 0
        do {
            _ = try await manager.pastWall { () async throws -> Int in calls += 1; throw URLError(.badServerResponse) }
            XCTFail("no error")
        } catch { XCTAssertEqual((error as? URLError)?.code, .badServerResponse) }
        XCTAssertEqual(calls, 1)
    }

    // MARK: - Runtime

    /// A source the way a `.mana` bundle declares one, its requests through the host bridge as
    /// the bundled HttpClient makes them.
    private let source = """
    class Headers {
      constructor(init) { this.map = {}; const from = init && init.map ? init.map : init || {}; for (const k in from) this.map[k.toLowerCase()] = from[k]; }
      set(k, v) { this.map[k.toLowerCase()] = v; return this; }
      toJSON() { return { ...this.map }; }
    }
    const get = async (url) => {
      const r = await globalThis.__manaHTTPBridge.send({ operation: 0, url, method: 0, headers: { accept: "text/html" }, timeoutMs: 1000 });
      const body = r.text;
      await globalThis.__manaHTTPBridge.send({ operation: 2, bodyID: r.bodyID });
      return JSON.parse(body);
    };
    globalThis.Target = class {
      constructor() { this.info = { id: "t", name: "T", version: "1", rating: 1, website: "https://t.test" }; }
      async search(request) {
        const ratings = request.context.allowedContentRatings.join(",");
        return { results: await get("https://t.test/search?q=" + request.query + "&r=" + ratings), isLastPage: true };
      }
      async getContent(id, context) { return get("https://t.test/title/" + id); }
      async getChapters(id) { return get("https://t.test/chapters/" + id); }
      async getChapterData(contentId, chapterId, chapter) {
        return { pages: [{ url: "https://img.test/" + contentId + "/" + chapterId + "/1.jpg" }, { raw: "AAA=" }] };
      }
      getPageTransport(request) {
        const client = { headers: new Headers({ referer: "https://t.test/", "accept-encoding": "gzip, br, zstd" }), requests: [], baseURL: undefined };
        client.requests.push(async (req, ctx) => { req.headers.set("x-origin", String(ctx.origin)); return req; });
        return client;
      }
    };
    """

    private func context(_ routes: [String: Any]) -> JSContext {
        ExtensionJSHarness.context(kind: "mana", routes: routes, script: source)
    }

    func testSearchDropsExplicitTitles() {
        // Asked for titles up to mature only.
        // An array route is [status, body] to the harness.
        let c = context(["https://t.test/search?q=x&r=0,1,2": [200, [
            ["id": "a", "title": "Alpha", "cover": "https://img.test/a.jpg", "contentRating": 0],
            ["id": "b", "title": "Beta", "cover": "", "contentRating": 3],
            ["id": "c", "title": "Hentai Club", "cover": ""],
            ["id": "d", "title": "Delta", "cover": "", "noninteractive": true],
        ]]])
        let r = ExtensionJSHarness.call(c, "searchResults", ["x"])
        guard case .success(let json) = r, let items = ExtensionJSHarness.json(json) as? [[String: Any]] else { return XCTFail("\(r)") }
        XCTAssertEqual(items.map { $0["id"] as? String }, ["a"])
        XCTAssertEqual(items[0]["imageURL"] as? String, "https://img.test/a.jpg")
    }

    func testDetailsRefuseAnExplicitTitle() {
        let c = context(["https://t.test/title/a": ["title": "A", "cover": "", "summary": "s",
                                                     "tags": [["id": "g", "title": "Genres", "tags": [["id": "h", "title": "Hentai", "contentRating": 3]]]]]])
        guard case .failure(let f) = ExtensionJSHarness.call(c, "extractDetails", ["a"]) else { return XCTFail() }
        XCTAssertTrue(f.message.contains("adult"), f.message)
    }

    func testChaptersAreLunasShapeInReadingOrder() {
        let c = context([
            "https://t.test/title/a": ["title": "A", "cover": "", "summary": "Sum", "tags": [["id": "x", "title": "Action"]]],
            "https://t.test/chapters/a": [200, [
                ["chapterId": "c2", "number": 2, "index": 1, "language": "en_US", "title": "Two", "provider": ["id": "g", "name": "Group"]],
                ["chapterId": "c1", "number": 1, "index": 0, "language": "en_US"],
                ["chapterId": "c2b", "number": 2, "index": 2, "language": "en_US"],
                ["chapterId": "fr1", "number": 1, "index": 3, "language": "fr_FR"],
            ]],
        ])
        guard case .success(let d) = ExtensionJSHarness.call(c, "extractDetails", ["a"]),
              let details = ExtensionJSHarness.json(d) as? [String: Any] else { return XCTFail() }
        XCTAssertEqual(details["description"] as? String, "Sum")
        XCTAssertEqual(details["tags"] as? [String], ["Action"])

        guard case .success(let json) = ExtensionJSHarness.call(c, "extractChapters", ["a"]) else { return XCTFail() }
        let chapters = JSEngine.parseMangaChapters(ExtensionJSHarness.json(json) as Any)
        XCTAssertEqual(chapters.map(\.number), [1, 2])
        XCTAssertEqual(chapters.map(\.language), ["en", "en"])
        XCTAssertEqual(chapters[1].title, "Two")
        XCTAssertEqual(chapters[1].group, "Group")
        XCTAssertEqual(chapters[0].href, #"mana:["a","c1"]"#)
    }

    func testImagesCarryThePageTransportsHeaders() {
        let c = context(["https://t.test/title/a": ["title": "A", "cover": ""],
                         "https://t.test/chapters/a": [200, [["chapterId": "c1", "number": 1, "index": 0, "language": "en"]]]])
        guard case .success(let json) = ExtensionJSHarness.call(c, "extractImages", [#"mana:["a","c1"]"#]),
              let pages = ExtensionJSHarness.json(json) as? [Any] else { return XCTFail() }
        let parsed = JSEngine.parseMangaPages(pages)
        XCTAssertEqual(parsed.map(\.url), ["https://img.test/a/c1/1.jpg", "data:image/jpeg;base64,AAA="])
        XCTAssertEqual(parsed[0].headers, ["referer": "https://t.test/", "x-origin": "2"])
        // The bridge's requests went out through the engine's fetch, with the source's headers.
        let sent = ExtensionJSHarness.requests(c).map { $0["url"] as? String }
        XCTAssertEqual(sent, ["https://t.test/title/a", "https://t.test/chapters/a"])
    }

    func testWebViewPagesGoThroughTheAppAndCloseWithTheCall() {
        // The app's side, faked: it records the calls and answers an eval with its script's length.
        let c = ExtensionJSHarness.context(kind: "mana", script: """
        var __webCalls = [];
        globalThis.__manaSerializedFunctionPrelude = "var __helper = 1;";
        globalThis.__shiroxWebView = function (op, payload, resolve, reject) {
          __webCalls.push(op + (payload.waitUntil ? ":" + payload.waitUntil : "") + (payload.args ? ":" + payload.args : ""));
          if (op === "create") resolve(7);
          else if (op === "eval") resolve(JSON.stringify({ hasPrelude: payload.script.indexOf("var __helper = 1;") === 0,
            callsFn: payload.script.indexOf("(function probe(a, b) { return a + b; })(...args)") > 0 }));
          else resolve(null);
        };
        globalThis.Target = class {
          constructor() { this.info = { id: "w", name: "W", version: "1", rating: 0, website: "https://w.test" }; }
          async search(request) {
            const page = await WebViewPage.create({ timeout: 5 });
            await page.goto("https://w.test/", { waitUntil: "domcontentloaded" });
            const r = await page.evaluate(function probe(a, b) { return a + b; }, 1, "x");
            return { results: [{ id: JSON.stringify(r), title: "T", cover: "" }], isLastPage: true };
          }
        };
        """)
        guard case .success(let json) = ExtensionJSHarness.call(c, "searchResults", ["q"]),
              let items = ExtensionJSHarness.json(json) as? [[String: Any]] else { return XCTFail() }
        XCTAssertEqual(items.first?["id"] as? String, #"{"hasPrelude":true,"callsFn":true}"#)
        // The page the source left open was closed when the search ended.
        XCTAssertEqual(c.evaluateScript("__webCalls.join(' ')")?.toString(),
                       #"create goto:domcontentloaded eval:[1,"x"] close"#)
    }

    func testAdultCookiesAreNotSent() {
        // Madara sources ask the site for its 18+ titles with cookies; those never go out.
        let c = context(["https://t.test/c": "ok", "https://t.test/d": "ok"])
        _ = ExtensionJSHarness.call(c, """
        (async () => {
          const b = globalThis.__manaHTTPBridge;
          await b.send({ operation: 0, url: "https://t.test/c", method: 0,
                         headers: { cookie: "wpmanga-adault=1; session=abc; toonily-mature=1", referer: "https://t.test/" } });
          await b.send({ operation: 0, url: "https://t.test/d", method: 0, headers: { Cookie: "wpmanga-adault=1" } });
        })
        """)
        let sent = ExtensionJSHarness.requests(c).map { $0["headers"] as? [String: String] ?? [:] }
        XCTAssertEqual(sent.first, ["cookie": "session=abc", "referer": "https://t.test/"])
        XCTAssertEqual(sent.last, [:])
    }

    func testOnlyTheLatestBodiesAreKept() {
        let c = context(["https://t.test/b": "x"])
        let r = ExtensionJSHarness.call(c, """
        (async () => {
          const b = globalThis.__manaHTTPBridge, ids = [];
          for (let i = 0; i < 40; i++) ids.push((await b.send({ operation: 0, url: "https://t.test/b", method: 0, headers: {} })).bodyID);
          const read = (id) => b.send({ operation: 1, bodyID: id, reader: 0 }).then((v) => v.value, (e) => "gone");
          return (await read(ids[0])) + "," + (await read(ids[39]));
        })
        """)
        XCTAssertEqual(r, .success("gone,x"))
    }

    func testABase64ReadFetchesTheBodyAsBytes() {
        let c = context(["https://t.test/bin": "text"])
        let r = ExtensionJSHarness.call(c, """
        (async () => {
          const b = globalThis.__manaHTTPBridge;
          const res = await b.send({ operation: 0, url: "https://t.test/bin", method: 0, headers: {} });
          const v = await b.send({ operation: 1, bodyID: res.bodyID, reader: 1 });
          return v.value + "|" + JSON.stringify(__requests[1] && __requests[1].base64Body);
        })
        """)
        // The harness's fetch ignores the option and answers text; what matters is that it was asked.
        XCTAssertEqual(r, .success("text|true"))
    }
}
