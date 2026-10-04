import XCTest
@testable import Shirox

/// A module that defines its own `soraFetch` and falls back to `fetch` when a request fails.
///
/// HydraHD does exactly that. Shirox's `fetch` called the global `soraFetch` — the module's, once
/// the module had defined one — so a host that kept failing bounced between the two forever, one
/// real request per bounce. `vidsrc.hair` stopped resolving, and after one HydraHD extraction
/// the runner sent ~1,700 requests a second for as long as it lived: two cores busy, a DNS
/// lookup each time, the promise chain growing past a gigabyte. Phones ran hot through whole
/// films after the module picker had been used.
@MainActor
final class ModuleFetchAliasTests: XCTestCase {
    /// `searchResults("start")` makes one request to a host that never resolves, through the
    /// module's own `soraFetch`; "count" reports how many times that `soraFetch` has run since;
    /// "stop" makes it give up, so a loop (the bug) unwinds instead of outliving the test.
    private let script = """
    var calls = 0;
    var stopped = false;
    async function soraFetch(url, options) {
        if (stopped) return null;
        calls++;
        try { const r = await fetchv2(url, {}, 'GET', null); if (r) return r; } catch (e) {}
        try { const r = await fetch(url, options); if (r) return r; } catch (e) {}
        return null;
    }
    async function searchResults(keyword) {
        if (keyword === 'start') soraFetch('https://shirox-fetch-loop.invalid/');
        if (keyword === 'stop') stopped = true;
        return JSON.stringify([{ title: String(calls), image: '', href: '' }]);
    }
    """

    private var module: ModuleDefinition {
        get throws {
            let json: [String: Any] = [
                "sourceName": "Fetch Loop", "version": "1", "type": "anime",
                "scriptUrl": "https://example.com/fetch-loop.js", "scriptContent": script,
            ]
            return try JSONDecoder().decode(ModuleDefinition.self,
                                            from: JSONSerialization.data(withJSONObject: json))
        }
    }

    func testTheRunnersFetchDoesNotCallBackIntoTheModulesSoraFetch() async throws {
        let runner = ModuleJSRunner()
        try await runner.load(module: try module)
        _ = try await runner.search(keyword: "start")
        try await Task.sleep(nanoseconds: 2_000_000_000)
        let calls = try await runner.search(keyword: "count").first?.title
        _ = try await runner.search(keyword: "stop")
        XCTAssertEqual(calls, "1")
    }

    func testTheEnginesFetchDoesNotCallBackIntoTheModulesSoraFetch() async throws {
        try await JSEngine.shared.loadModule(try module)
        _ = try await JSEngine.shared.callAsyncJS("searchResults", args: ["start"])
        try await Task.sleep(nanoseconds: 2_000_000_000)
        let json = try await JSEngine.shared.callAsyncJS("searchResults", args: ["count"])
        _ = try await JSEngine.shared.callAsyncJS("searchResults", args: ["stop"])
        let items = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [[String: Any]]
        XCTAssertEqual(items?.first?["title"] as? String, "1")
    }
}
