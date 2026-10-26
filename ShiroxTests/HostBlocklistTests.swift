import XCTest
@testable import Shirox

final class HostBlocklistTests: XCTestCase {

    func testParseHandlesHostsFileAndBareLinesAndComments() {
        let contents = """
        # a comment
        127.0.0.1 badporn.com
        0.0.0.0 evil-hentai.net
        another-adult.org

        127.0.0.1 localhost
        """
        let set = HostBlocklist.parse(contents)
        XCTAssertTrue(set.contains("badporn.com"))
        XCTAssertTrue(set.contains("evil-hentai.net"))
        XCTAssertTrue(set.contains("another-adult.org"))
        XCTAssertFalse(set.contains("localhost"))   // skipped
        XCTAssertFalse(set.contains(""))            // blank line skipped
    }

    func testParseLowercasesHosts() {
        XCTAssertTrue(HostBlocklist.parse("0.0.0.0 BadPorn.COM").contains("badporn.com"))
    }

    func testParseHandlesInlineCommentsTabsAndCRLF() {
        let set = HostBlocklist.parse("0.0.0.0 first.com # why\r\n0.0.0.0\tsecond.net\t\r\n  third.org  \r\n#0.0.0.0 fourth.com")
        XCTAssertEqual(set, ["first.com", "second.net", "third.org"])
    }

    func testParseSkipsLocalhostAndDotlessTokens() {
        XCTAssertEqual(HostBlocklist.parse("127.0.0.1 localhost\n0.0.0.0 intranet\nok.com"), ["ok.com"])
    }

    /// The shipped list is bare hosts, pruned of subdomains of other entries: every host the
    /// old string parser read from it must still be in, and nothing more.
    func testParseReadsEveryHostOfTheShippedList() throws {
        let url = try XCTUnwrap(Bundle.main.url(forResource: "adult_hosts", withExtension: "txt"))
        let data = try Data(contentsOf: url)
        let contents = try XCTUnwrap(String(data: data, encoding: .utf8))
        let hosts = Self.originalParse(contents)
        let set = HostBlocklist.parse(data)
        XCTAssertGreaterThan(hosts.count, 10_000)
        XCTAssertEqual(set.count, hosts.count)
        XCTAssertEqual(set, HostBlocklist.parse(contents))
        for host in hosts { XCTAssertTrue(set.contains(host), host) }
    }

    private static func originalParse(_ contents: String) -> Set<String> {
        var result = Set<String>()
        contents.enumerateLines { line, _ in
            var s = line
            if let hash = s.firstIndex(of: "#") { s = String(s[..<hash]) }
            s = s.trimmingCharacters(in: .whitespaces)
            guard !s.isEmpty else { return }
            let parts = s.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            let host = (parts.last ?? "").lowercased()
            guard !host.isEmpty, host != "localhost", host.contains(".") else { return }
            result.insert(host)
        }
        return result
    }

    func testExactHostBlocked() {
        let set: HostSet = ["badporn.com"]
        XCTAssertTrue(HostBlocklist.isHostBlocked("badporn.com", in: set))
    }

    func testSubdomainBlocked() {
        let set: HostSet = ["badporn.com"]
        XCTAssertTrue(HostBlocklist.isHostBlocked("cdn.videos.badporn.com", in: set))
    }

    func testLookalikeNotBlocked() {
        let set: HostSet = ["porn.com"]
        XCTAssertFalse(HostBlocklist.isHostBlocked("notporn.com", in: set))
        XCTAssertFalse(HostBlocklist.isHostBlocked("pornial.com", in: set))
    }

    func testUnrelatedHostNotBlocked() {
        let set: HostSet = ["badporn.com"]
        XCTAssertFalse(HostBlocklist.isHostBlocked("anilist.co", in: set))
    }

    func testCaseInsensitiveMatch() {
        let set: HostSet = ["badporn.com"]
        XCTAssertTrue(HostBlocklist.isHostBlocked("CDN.BadPorn.Com", in: set))
    }

    func testFullyQualifiedHostBlocked() {
        let set: HostSet = ["badporn.com"]
        XCTAssertTrue(HostBlocklist.isHostBlocked("www.badporn.com.", in: set))
    }

    func testParentWithTwoLabelsBlocksDeeperSubdomains() {
        let set: HostSet = ["videos.example.co"]
        XCTAssertTrue(HostBlocklist.isHostBlocked("a.b.videos.example.co", in: set))
        XCTAssertFalse(HostBlocklist.isHostBlocked("example.co", in: set))
        XCTAssertFalse(HostBlocklist.isHostBlocked("othervideos.example.co", in: set))
    }

    func testDoesNotBlockBareTLD() {
        let set: HostSet = ["com"]   // pathological entry must not nuke everything
        XCTAssertFalse(HostBlocklist.isHostBlocked("anilist.com", in: set))
    }

    func testLoadForTestingPopulatesIsBlocked() {
        HostBlocklist.loadForTesting(["badporn.com"])
        XCTAssertTrue(HostBlocklist.shared.isBlocked(URL(string: "https://cdn.badporn.com/a.m3u8")!))
        XCTAssertFalse(HostBlocklist.shared.isBlocked(URL(string: "https://anilist.co")!))
    }
}
