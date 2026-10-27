#if !os(tvOS)
import Foundation
@preconcurrency import JavaScriptCore
import WebKit

/// Mana's `WebViewPage`: a web view a source opens for one call — to let a Cloudflare check
/// clear, or to read a page that only renders in a browser — then closes. It sends the app's
/// User-Agent, and its cookies are handed to URLSession, so the source's own requests that
/// follow go through on the clearance the page earned. Pages on adult sites aren't opened.
@MainActor
final class ManaWebPages: NSObject {
    private var pages: [Int: Page] = [:]
    private var nextID = 1

    /// `__shiroxWebView(op, payload, resolve, reject)` in `context`, for kinds/mana.js.
    static func install(in context: JSContext) {
        let host = ManaWebPages()
        let call: @convention(block) (String, JSValue, JSValue, JSValue) -> Void = { [host] op, payload, resolve, reject in
            let input = payload.toDictionary() as? [String: Any] ?? [:]
            Task { @MainActor in
                do {
                    let result = try await host.perform(op, input)
                    resolve.call(withArguments: [result])
                } catch {
                    reject.call(withArguments: [error.localizedDescription])
                }
            }
        }
        context.setObject(call, forKeyedSubscript: "__shiroxWebView" as NSString)
    }

    enum Failure: LocalizedError {
        case closed, badURL(String), blocked(String), timedOut(Double), unknown(String), script(String)
        var errorDescription: String? {
            switch self {
            case .closed: return String(localized: "shared.the_page_was_already_closed")
            case .badURL(let url): return String(localized: "shared.url_isnt_a_web_page \(url)")
            case .blocked(let host): return String(localized: "shared.blocked_host_named \(host)")
            case .timedOut(let seconds): return String(localized: "shared.the_page_didnt_answer_in \(Int(seconds))")
            case .unknown(let op): return String(localized: "shared.unknown_web_view_call \(op)")
            case .script(let message): return String(localized: "shared.the_pages_script_failed \(message)")
            }
        }
    }

    func perform(_ op: String, _ input: [String: Any]) async throws -> Any {
        let id = (input["id"] as? NSNumber)?.intValue ?? 0
        let timeout = max(1, (input["timeout"] as? NSNumber)?.doubleValue ?? 30)
        switch op {
        case "create":
            let page = Page()
            let pageID = nextID
            nextID += 1
            pages[pageID] = page
            return pageID
        case "goto":
            guard let page = pages[id] else { throw Failure.closed }
            guard let url = URL(string: input["url"] as? String ?? ""),
                  ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { throw Failure.badURL(input["url"] as? String ?? "") }
            if HostBlocklist.shared.isBlocked(url) { throw Failure.blocked(url.host ?? "") }
            try await page.load(url, domContentLoaded: input["waitUntil"] as? String == "domcontentloaded", timeout: timeout)
            await page.shareCookies()
            return NSNull()
        case "eval":
            guard let page = pages[id] else { throw Failure.closed }
            let args = (input["args"] as? String).flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) } ?? []
            let json = try await page.evaluate(input["script"] as? String ?? "", args: args, timeout: timeout)
            await page.shareCookies()
            return json
        case "close":
            if let page = pages.removeValue(forKey: id) {
                await page.shareCookies()
                page.close()
            }
            return NSNull()
        default:
            throw Failure.unknown(op)
        }
    }

    /// One page: its web view and the load it is waiting on.
    @MainActor
    final class Page: NSObject, WKNavigationDelegate {
        let webView: WKWebView
        private var loading: CheckedContinuation<Void, Error>?
        private var waitsForDOM = false

        override init() {
            let config = WKWebViewConfiguration()
            config.websiteDataStore = .default()
            webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 390, height: 844), configuration: config)
            super.init()
            // The cookie a check grants is bound to the browser that earned it.
            webView.customUserAgent = NetworkUserAgent.current()
            webView.navigationDelegate = self
        }

        func load(_ url: URL, domContentLoaded: Bool, timeout: Double) async throws {
            finish(.failure(CancellationError()))
            waitsForDOM = domContentLoaded
            try await withTimeout(timeout) {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    self.loading = continuation
                    self.webView.load(URLRequest(url: url))
                }
            }
        }

        /// The script's answer as JSON. `args` is in scope for it, as Mana promises; its last
        /// value is the answer, awaited when it's a promise.
        func evaluate(_ script: String, args: Any, timeout: Double) async throws -> String {
            nonisolated(unsafe) let args = args
            return try await withTimeout(timeout) {
                let value: Any?
                do {
                    value = try await self.webView.callAsyncJavaScript("return await eval(__script);",
                                                                       arguments: ["__script": script, "args": args],
                                                                       contentWorld: .page)
                } catch {
                    // WebKit's own words are "A JavaScript exception occurred"; the page's are in the error.
                    let info = (error as NSError).userInfo
                    if let message = info["WKJavaScriptExceptionMessage"] as? String { throw Failure.script(message) }
                    throw error
                }
                let json = try? JSONSerialization.data(withJSONObject: value ?? NSNull(), options: [.fragmentsAllowed])
                return json.flatMap { String(bytes: $0, encoding: .utf8) } ?? "null"
            }
        }

        /// The page's cookies, for the requests the source makes next.
        func shareCookies() async {
            let cookies = await webView.configuration.websiteDataStore.httpCookieStore.allCookies()
            for cookie in cookies { HTTPCookieStorage.shared.setCookie(cookie) }
        }

        func close() {
            finish(.failure(CancellationError()))
            webView.stopLoading()
            webView.navigationDelegate = nil
        }

        private func finish(_ result: Result<Void, Error>) {
            guard let loading else { return }
            self.loading = nil
            loading.resume(with: result)
        }

        private func withTimeout<T: Sendable>(_ seconds: Double, _ work: @escaping @MainActor () async throws -> T) async throws -> T {
            try await withThrowingTaskGroup(of: T.self) { group in
                group.addTask { try await work() }
                group.addTask {
                    try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                    throw Failure.timedOut(seconds)
                }
                defer { group.cancelAll() }
                // Both tasks end by returning or throwing, so the first result is always there.
                guard let first = try await group.next() else { throw Failure.timedOut(seconds) }
                return first
            }
        }

        nonisolated func webView(_ webView: WKWebView, didCommit navigation: WKNavigation?) {
            Task { @MainActor in
                guard self.waitsForDOM else { return }
                // WebKit has no DOMContentLoaded callback: the document's readyState says it.
                while self.loading != nil {
                    let state = try? await webView.evaluateJavaScript("document.readyState") as? String
                    if let state, state != "loading" { self.finish(.success(())); return }
                    try? await Task.sleep(nanoseconds: 50_000_000)
                }
            }
        }

        nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation?) {
            Task { @MainActor in self.finish(.success(())) }
        }

        nonisolated func webView(_ webView: WKWebView, didFail navigation: WKNavigation?, withError error: Error) {
            Task { @MainActor in if !Self.isRedirectCancel(error) { self.finish(.failure(error)) } }
        }

        nonisolated func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation?, withError error: Error) {
            Task { @MainActor in if !Self.isRedirectCancel(error) { self.finish(.failure(error)) } }
        }

        /// A navigation the page replaced with another (a challenge's redirect) isn't a failure.
        nonisolated static func isRedirectCancel(_ error: Error) -> Bool {
            (error as NSError).domain == NSURLErrorDomain && (error as NSError).code == NSURLErrorCancelled
        }
    }
}
#endif
