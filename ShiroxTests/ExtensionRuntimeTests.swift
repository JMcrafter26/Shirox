import JavaScriptCore
import XCTest
@testable import Shirox

@MainActor
final class ExtensionRuntimeTests: XCTestCase {
    private func ctx(_ routes: [String: Any] = [:]) -> JSContext {
        ExtensionJSHarness.context(kind: "none", routes: routes)
    }

    func testPolyfillsExist() {
        let c = ctx()
        let r = c.evaluateScript("""
        [typeof URL, typeof URLSearchParams, typeof TextEncoder, typeof AbortController, typeof CryptoJS,
         new URL("/a?b=1", "https://x.com/c").href, atob(btoa("\\u00ff\\u0001")) === "\\u00ff\\u0001"].join(",")
        """)!.toString()
        XCTAssertEqual(r, "function,function,function,function,object,https://x.com/a?b=1,true")
    }

    func testRequireKnownAndUnknown() {
        let c = ctx()
        XCTAssertEqual(c.evaluateScript("typeof require('cheerio-without-node-native').load")!.toString(), "function")
        XCTAssertEqual(c.evaluateScript("typeof require('crypto-js').MD5")!.toString(), "function")
        XCTAssertEqual(c.evaluateScript("(() => { try { require('zlib'); return 'no'; } catch (e) { return e.message; } })()")!.toString(),
                       "This plugin needs \"zlib\", which Shirox doesn't provide.")
    }

    func testExtDefineKeepsFilesApart() {
        let c = ctx()
        c.evaluateScript("""
        __extDefine("a", function (module, exports, require) { const BASE = 1; exports.v = BASE; });
        __extDefine("b", function (module, exports, require) { const BASE = 2; module.exports = { v: BASE }; });
        """)
        XCTAssertEqual(c.evaluateScript("__extModule('a').v + ',' + __extModule('b').v")!.toString(), "1,2")
    }

    func testAxiosGetParsesJSONAndSendsParams() {
        let c = ctx(["https://api.test/x?q=a+b": #"{"ok":true}"#])
        let r = ExtensionJSHarness.call(c, "(() => axios.get('https://api.test/x', { params: { q: 'a b' } }).then(r => r.data.ok))")
        XCTAssertEqual(r, .success("true"))
    }

    func testAxiosRejectsOnErrorStatus() {
        let c = ctx(["https://api.test/x": [500, "boom"]])
        let r = ExtensionJSHarness.call(c, "(() => axios.get('https://api.test/x'))")
        XCTAssertEqual(r, .failure(.init(message: "Request failed with status code 500")))
    }

    func testAxiosPostsJSON() {
        let c = ctx(["https://api.test/p": "ok"])
        _ = ExtensionJSHarness.call(c, "(() => axios.post('https://api.test/p', { a: 1 }))")
        let req = ExtensionJSHarness.requests(c).last!
        XCTAssertEqual(req["method"] as? String, "POST")
        XCTAssertEqual(req["body"] as? String, #"{"a":1}"#)
        XCTAssertEqual((req["headers"] as? [String: String])?["Content-Type"], "application/json")
    }

    func testHttpGetAcceptsBothHeaderShapes() {
        let c = ctx(["https://s.test/": "<p>hi</p>"])
        _ = ExtensionJSHarness.call(c, "(() => http_get('https://s.test/', { Referer: 'r1' }))")
        _ = ExtensionJSHarness.call(c, "(() => http_get('https://s.test/', { headers: { Referer: 'r2' } }))")
        let refs = ExtensionJSHarness.requests(c).map { ($0["headers"] as? [String: String])?["Referer"] }
        XCTAssertEqual(refs, ["r1", "r2"])
        XCTAssertEqual(ExtensionJSHarness.call(c, "(() => http_get('https://s.test/').then(r => r.body))"), .success("<p>hi</p>"))
    }

    func testParseHtmlDOM() {
        let c = ctx()
        let r = c.evaluateScript("""
        (() => { const d = parseHtml('<div id="a" data-x-y="1"><a href="/h" class="t">One</a><a href="/i">Two</a></div>');
          return [d.querySelector('a.t').textContent, d.querySelectorAll('a').length,
                  d.querySelector('#a').getAttribute('data-x-y'), d.querySelector('a').getAttribute('nope'),
                  d.querySelector('a').parentElement.id, d.querySelector('#a').dataset.xY].join('|'); })()
        """)!.toString()
        XCTAssertEqual(r, "One|2|1||a|1")
    }
}
