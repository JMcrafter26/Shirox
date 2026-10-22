import Foundation
import Network

/// The expert setting that resolves the app's names over DNS-over-HTTPS (Settings › Advanced
/// Network), for networks that poison DNS. Off by default, and custom only: the server's URL,
/// and the IP addresses to reach it at, since its own name can't be looked up first.
struct SecureDNSSettings: Equatable, Sendable {
    static let enabledKey = "secureDNSEnabled"
    static let serverURLKey = "secureDNSServerURL"
    static let serverAddressesKey = "secureDNSServerAddresses"
    /// What empty fields start as when the setting is turned on: Cloudflare's resolver.
    static let defaultServerURL = "https://cloudflare-dns.com/dns-query"
    static let defaultServerAddresses = "1.1.1.1, 1.0.0.1"

    var enabled = false
    var serverURL = ""
    var serverAddresses = ""

    static func current(_ defaults: UserDefaults = .standard) -> SecureDNSSettings {
        SecureDNSSettings(enabled: defaults.bool(forKey: enabledKey),
                          serverURL: defaults.string(forKey: serverURLKey) ?? "",
                          serverAddresses: defaults.string(forKey: serverAddressesKey) ?? "")
    }

    /// What the system is told, or nil when it's off or not usable: an https URL with a host,
    /// and at least one address, every one of them an IP.
    var resolver: SecureDNS.Resolver? {
        guard enabled else { return nil }
        let trimmed = serverURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), url.scheme?.lowercased() == "https", url.host?.isEmpty == false else { return nil }
        let addresses = serverAddresses
            .split(whereSeparator: { $0 == "," || $0 == " " || $0.isNewline })
            .map(String.init)
        guard !addresses.isEmpty,
              addresses.allSatisfy({ IPv4Address($0) != nil || IPv6Address($0) != nil }) else { return nil }
        return SecureDNS.Resolver(url: url, addresses: addresses)
    }
}

/// Encrypted DNS for the whole app, through Network's default privacy context: every
/// URLSession (both JavaScript engines' too, so every module's `fetch`), Network connection and
/// `getaddrinfo` in this process. Not what runs in other processes, which is AVPlayer's playback
/// and every WKWebView. A DNS profile or VPN set on the device comes first.
enum SecureDNS {
    struct Resolver: Equatable, Sendable {
        let url: URL
        let addresses: [String]
    }

    private static var applied = false

    /// Once, at launch, before any request: connections already open keep the DNS they had, so
    /// a change in Settings counts from the next launch. `apply` is the system call; tests pass
    /// their own.
    @MainActor
    static func applyAtLaunch(_ settings: SecureDNSSettings = .current(),
                              apply: (Resolver) -> Void = requireEncryptedResolution) {
        guard !applied else { return }
        applied = true
        guard let resolver = settings.resolver else {
            if settings.enabled { Logger.shared.log("[DNS] Encrypted DNS is on but its server isn't usable; left off", type: "Error") }
            return
        }
        apply(resolver)
        Logger.shared.log("[DNS] Encrypted DNS through \(resolver.url.host ?? "?")", type: "Info")
    }

    static func requireEncryptedResolution(_ resolver: Resolver) {
        let endpoints = resolver.addresses.map { NWEndpoint.hostPort(host: NWEndpoint.Host($0), port: 443) }
        NWParameters.PrivacyContext.default.requireEncryptedNameResolution(
            true, fallbackResolver: .https(resolver.url, serverAddresses: endpoints))
    }

    /// For tests: lets `applyAtLaunch` run again.
    @MainActor
    static func resetForTesting() { applied = false }
}
