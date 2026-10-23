import JavaScriptCore
import XCTest

/// The bundled extension runtime in a bare `JSContext`, with a fake `fetch` answering from a
/// table, and a way to call its async functions. The fakes never wait — timers never fire — so
/// promises settle before `evaluateScript` returns.
@MainActor
enum ExtensionJSHarness {
    struct Failure: Error, Equatable { let message: String }

    static var runtimeSource: String {
        let url = Bundle.main.url(forResource: "ExtensionRuntime", withExtension: "js")!
        return try! String(contentsOf: url, encoding: .utf8)
    }

    /// `routes`: URL → body (status 200), or URL → [status, body]. Requests are recorded in
    /// `__requests` as { url, method, headers, body }.
    static func context(kind: String, key: String = "test", config: Any = [String: Any](),
                        media: [String: Any]? = nil, routes: [String: Any] = [:],
                        script: String = "", tmdbKey: String = "TMDBKEY") -> JSContext {
        let context = JSContext()!
        context.exceptionHandler = { _, e in XCTFail("JS exception: \(e?.toString() ?? "?")") }
        context.setObject(routes, forKeyedSubscript: "__routes" as NSString)
        context.evaluateScript("""
        var __requests = [];
        function setTimeout(fn) { return 0; }
        function clearTimeout() {}
        function fetch(url, opts) {
          opts = opts || {};
          __requests.push({ url: url, method: opts.method || "GET", headers: opts.headers || {}, body: opts.body || null,
                            base64Body: !!opts.base64Body });
          var r = __routes[url];
          if (r === undefined) return Promise.resolve({ status: 404, headers: {}, url: url, text: function () { return Promise.resolve(""); } });
          var status = Array.isArray(r) ? r[0] : 200, body = Array.isArray(r) ? r[1] : r;
          if (typeof body !== "string") body = JSON.stringify(body);
          return Promise.resolve({ status: status, headers: { "content-type": "text/plain" }, url: url,
                                   text: function () { return Promise.resolve(body); } });
        }
        """)
        let ext: [String: Any] = ["kind": kind, "name": "Test", "key": key, "config": config,
                                  "tmdbKey": tmdbKey, "adultWords": ["hentai", "porn", "xxx", "adult", "nsfw"]]
        context.setObject(ext, forKeyedSubscript: "__ext" as NSString)
        context.setObject(media ?? NSNull(), forKeyedSubscript: "__shiroxMedia" as NSString)
        context.evaluateScript(runtimeSource)
        context.evaluateScript(script)
        context.evaluateScript("if (globalThis.__extFunctions) Object.assign(globalThis, globalThis.__extFunctions);")
        return context
    }

    /// What a global function's promise resolves to — strings as they are, anything else as JSON.
    static func call(_ context: JSContext, _ function: String, _ arguments: [Any] = []) -> Result<String, Failure> {
        var outcome: Result<String, Failure> = .failure(Failure(message: "never settled"))
        let done: @convention(block) (String) -> Void = { outcome = .success($0) }
        let fail: @convention(block) (String) -> Void = { outcome = .failure(Failure(message: $0)) }
        context.setObject(done, forKeyedSubscript: "__testDone" as NSString)
        context.setObject(fail, forKeyedSubscript: "__testFail" as NSString)
        context.setObject(arguments, forKeyedSubscript: "__testArguments" as NSString)
        context.evaluateScript("""
        Promise.resolve().then(() => \(function).apply(null, __testArguments)).then(
          r => __testDone(typeof r === "string" ? r : JSON.stringify(r)),
          e => __testFail(String((e && e.message) || e)))
        """)
        return outcome
    }

    static func json(_ string: String) -> Any? {
        try? JSONSerialization.jsonObject(with: Data(string.utf8), options: [.fragmentsAllowed])
    }

    static func requests(_ context: JSContext) -> [[String: Any]] {
        context.objectForKeyedSubscript("__requests").toArray() as? [[String: Any]] ?? []
    }
}
