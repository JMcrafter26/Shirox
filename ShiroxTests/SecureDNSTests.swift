import XCTest
@testable import Shirox

/// When the app turns on encrypted DNS, and with what server. Whether lookups really go out
/// encrypted can't be seen from a unit test; that's checked on a device.
@MainActor
final class SecureDNSTests: XCTestCase {
    private func settings(_ enabled: Bool = true, url: String = "https://cloudflare-dns.com/dns-query",
                          addresses: String = "1.1.1.1, 1.0.0.1") -> SecureDNSSettings {
        SecureDNSSettings(enabled: enabled, serverURL: url, serverAddresses: addresses)
    }

    override func setUp() { SecureDNS.resetForTesting() }
    override func tearDown() { SecureDNS.resetForTesting() }

    func testAServerWithItsAddresses() {
        XCTAssertEqual(settings().resolver,
                       SecureDNS.Resolver(url: URL(string: "https://cloudflare-dns.com/dns-query")!, addresses: ["1.1.1.1", "1.0.0.1"]))
        XCTAssertEqual(settings(url: "https://dns.google/dns-query", addresses: "8.8.8.8\n2001:4860:4860::8888").resolver?.addresses,
                       ["8.8.8.8", "2001:4860:4860::8888"])
    }

    func testThePrefilledServerIsCloudflaresAndUsable() {
        let prefilled = settings(url: SecureDNSSettings.defaultServerURL, addresses: SecureDNSSettings.defaultServerAddresses)
        XCTAssertEqual(prefilled.resolver?.url.host, "cloudflare-dns.com")
        XCTAssertEqual(prefilled.resolver?.addresses, ["1.1.1.1", "1.0.0.1"])
    }

    func testOffOrUnusableIsNoServer() {
        XCTAssertNil(settings(false).resolver)
        XCTAssertNil(settings(url: "http://cloudflare-dns.com/dns-query").resolver, "Not https")
        XCTAssertNil(settings(url: "").resolver)
        XCTAssertNil(settings(addresses: "").resolver, "Its own name can't be looked up first")
        XCTAssertNil(settings(addresses: "1.1.1.1, cloudflare-dns.com").resolver, "Every address an IP")
    }

    func testAppliedOnceAtLaunchWhenUsable() {
        var applied: [SecureDNS.Resolver] = []
        SecureDNS.applyAtLaunch(settings()) { applied.append($0) }
        SecureDNS.applyAtLaunch(settings(url: "https://dns.google/dns-query", addresses: "8.8.8.8")) { applied.append($0) }
        XCTAssertEqual(applied.map(\.url.host), ["cloudflare-dns.com"], "A change counts from the next launch")
    }

    func testNothingAppliedWhenOffOrUnusable() {
        var applied = 0
        SecureDNS.applyAtLaunch(settings(false)) { _ in applied += 1 }
        SecureDNS.resetForTesting()
        SecureDNS.applyAtLaunch(settings(addresses: "")) { _ in applied += 1 }
        XCTAssertEqual(applied, 0)
    }

    func testTheSettingsAreReadFromDefaults() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "SecureDNSTests"))
        defer { defaults.removePersistentDomain(forName: "SecureDNSTests") }
        defaults.set(true, forKey: SecureDNSSettings.enabledKey)
        defaults.set("https://dns.google/dns-query", forKey: SecureDNSSettings.serverURLKey)
        defaults.set("8.8.8.8", forKey: SecureDNSSettings.serverAddressesKey)
        XCTAssertEqual(SecureDNSSettings.current(defaults).resolver?.url.absoluteString, "https://dns.google/dns-query")
    }
}
