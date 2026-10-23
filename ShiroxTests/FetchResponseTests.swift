import XCTest
import JavaScriptCore
@testable import Shirox

/// The response a module's `fetchv2` promise resolves with, and the contexts modules run in.
@MainActor
final class FetchResponseTests: XCTestCase {
    private func response(_ body: String, status: Int = 200, statusText: String? = "OK") -> (JSContext, JSValue) {
        let context = JSContext.forModule()
        context.evaluateScript("var console = { log: function () {} };")
        let response = context.makeFetchResponse(status: status, statusText: statusText, url: "https://example.com/a",
                                                 headers: ["content-type": "application/json"], body: body)
        context.setObject(response, forKeyedSubscript: "res" as NSString)
        return (context, response)
    }

    private func bytes(_ context: JSContext, _ script: String) async -> [Int] {
        let done = expectation(description: "bytes")
        var out: [Int] = []
        let finish: @convention(block) (JSValue) -> Void = { value in
            out = (value.toArray() as? [NSNumber] ?? []).map(\.intValue)
            done.fulfill()
        }
        context.setObject(finish, forKeyedSubscript: "finish" as NSString)
        context.evaluateScript("(\(script)).then(function (b) { finish(Array.from(new Uint8Array(b))); });")
        await fulfillment(of: [done], timeout: 2)
        return out
    }

    func testArrayBufferGivesTheBytesOfABinaryBody() async {
        let data = Data([0x1f, 0x8b, 0x08, 0x00, 0xff, 0x00, 0x80, 0x41])
        let context = JSContext.forModule()
        let res = context.makeFetchResponse(status: 200, statusText: nil, url: "https://example.com/a",
                                            headers: ["content-type": "application/octet-stream"],
                                            body: JSEngine.bodyText(data), data: data)
        context.setObject(res, forKeyedSubscript: "res" as NSString)
        let got = await bytes(context, "res.arrayBuffer()")
        XCTAssertEqual(got, data.map(Int.init))
        let again = await bytes(context, "res.bytes()")
        XCTAssertEqual(again, data.map(Int.init))
    }

    func testArrayBufferOfATextBodyIsItsUTF8() async {
        let text = "a é 😀"
        let (context, _) = response(text)
        let got = await bytes(context, "res.arrayBuffer()")
        XCTAssertEqual(got, Array(text.utf8).map(Int.init))
    }

    func testCarriesStatusUrlAndHeaders() {
        let (context, res) = response("{}", status: 404, statusText: "Not Found")
        XCTAssertEqual(res.forProperty("status").toInt32(), 404)
        XCTAssertFalse(res.forProperty("ok").toBool())
        XCTAssertEqual(res.forProperty("statusText").toString(), "Not Found")
        XCTAssertEqual(res.forProperty("url").toString(), "https://example.com/a")
        XCTAssertEqual(context.evaluateScript("res.headers['content-type']").toString(), "application/json")
    }

    func testStatusTextLeftOutWhenNotGiven() {
        let (context, _) = response("{}", statusText: nil)
        XCTAssertTrue(context.evaluateScript("'statusText' in res").toBool() == false)
        XCTAssertTrue(context.evaluateScript("res.ok").toBool())
    }

    func testTextReturnsTheBodyUnchanged() {
        let body = "line \"one\"\nback\\slash\u{2028}\u{0}end"
        let (context, _) = response(body)
        XCTAssertEqual(context.evaluateScript("res.text()").toString(), body)
    }

    func testJsonParsesTheBody() {
        let (context, _) = response(#"{"items":[1,2,3],"name":"a\nb"}"#)
        XCTAssertEqual(context.evaluateScript("res.json().items.length").toInt32(), 3)
        XCTAssertEqual(context.evaluateScript("res.json().name").toString(), "a\nb")
    }

    func testJsonOfANonJsonBodyIsUndefined() {
        let (context, _) = response("<html>not json</html>")
        XCTAssertTrue(context.evaluateScript("res.json()").isUndefined)
        XCTAssertNil(context.exception)
    }

    func testModuleContextsShareAVirtualMachineButNotGlobals() {
        let a = JSContext.forModule(), b = JSContext.forModule()
        XCTAssertTrue(a.virtualMachine === b.virtualMachine)
        a.evaluateScript("var leaked = 1;")
        XCTAssertTrue(b.evaluateScript("typeof leaked").toString() == "undefined")
    }
}
