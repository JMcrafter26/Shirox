#if os(iOS)
import XCTest
@testable import Shirox

/// The headers a download goes out with. Modules often hand over a bare URL — AniWorld's VOE
/// and Doodstream extractors do — and the player gets away with that where URLSession didn't.
final class DownloadRequestHeadersTests: XCTestCase {

    /// VOE mints its link for the browser the module fetched the embed with, and turns away a
    /// non-mobile agent when that was a phone — URLSession's own "Shirox/… CFNetwork/…" got 403.
    /// Doodstream's CDN redirects a request without a Referer to a host that refuses connections.
    func testABareStreamGetsAMobileBrowserAndItsOwnOriginAsReferer() {
        let url = URL(string: "https://rcsd1159td.cloudatacdn.com/u5kj/q50~AbC?token=t&expiry=1")!
        let headers = DownloadManager.requestHeaders(for: url, streamHeaders: [:])
        XCTAssertEqual(headers["User-Agent"], BrowserImpersonator.safariIOSUA)
        XCTAssertEqual(headers["Referer"], "https://rcsd1159td.cloudatacdn.com/")
    }

    func testTheModulesOwnHeadersWin() {
        let url = URL(string: "https://cdn.example/v.m3u8")!
        let headers = DownloadManager.requestHeaders(for: url, streamHeaders: [
            "User-Agent": "Module UA", "Referer": "https://embed.example/", "Cookie": "a=b",
        ])
        XCTAssertEqual(headers, ["User-Agent": "Module UA", "Referer": "https://embed.example/", "Cookie": "a=b"])
    }

    /// Header names are case-insensitive: a module's `referer` must not be joined by a second one.
    func testAModuleHeaderInAnotherCaseIsNotDuplicated() {
        let url = URL(string: "https://cdn.example/v.mp4")!
        let headers = DownloadManager.requestHeaders(for: url, streamHeaders: [
            "user-agent": "Module UA", "referer": "https://embed.example/",
        ])
        XCTAssertEqual(headers, ["user-agent": "Module UA", "referer": "https://embed.example/"])
    }

    func testAPortStaysInTheReferer() {
        let url = URL(string: "http://127.0.0.1:8080/v.mp4")!
        XCTAssertEqual(DownloadManager.requestHeaders(for: url, streamHeaders: [:])["Referer"],
                       "http://127.0.0.1:8080/")
    }
}
#endif
