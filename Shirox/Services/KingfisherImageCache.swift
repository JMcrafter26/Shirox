import Foundation
import Kingfisher

/// Central configuration for the Kingfisher-backed image pipeline and the
/// per-request headers anime CDNs require (browser UA + Referer, plus
/// Cloudflare cookie/UA when a host has been bypassed).
enum KingfisherImageCache {

    static var defaultUserAgent: String { NetworkUserAgent.current() }

    /// Configure the shared Kingfisher cache. Call once at app launch.
    static func configure() {
        let cache = ImageCache.default
        cache.diskStorage.config.sizeLimit = 500 * 1024 * 1024   // 500 MB
        cache.diskStorage.config.expiration = .days(7)
        // Keep original bytes on disk so `CachedAsyncImage.cachedImageData(for:)`
        // can hand decodable data to the snapshot store / provider banner.
        KingfisherManager.shared.defaultOptions = [.cacheOriginalImage]
    }

    /// Where a page's image comes from: its bytes, for a `data:` address (a Mana source's `raw`
    /// page, which Kingfisher's downloader won't take), or the network.
    static func source(for url: URL, cacheKey: String) -> Source {
        if let bytes = dataURLBytes(url) { return .provider(RawImageDataProvider(data: bytes, cacheKey: cacheKey)) }
        return .network(Kingfisher.ImageResource(downloadURL: url, cacheKey: cacheKey))
    }

    /// The bytes of a `data:…;base64,…` address.
    static func dataURLBytes(_ url: URL) -> Data? {
        let string = url.absoluteString
        guard string.hasPrefix("data:"), let comma = string.firstIndex(of: ","),
              string[..<comma].hasSuffix(";base64") else { return nil }
        return Data(base64Encoded: String(string[string.index(after: comma)...]).removingPercentEncoding ?? "")
    }

    /// Browser-like headers for an image fetch. Many anime CDNs hotlink-protect
    /// with a Referer requirement and reject the default URLSession UA. When a
    /// host has been Cloudflare-bypassed, pass its cookie header + the WebView's
    /// UA so the `cf_clearance` binding (UA + cookie) matches.
    /// `refererOverride` replaces the default own-origin Referer — manga CDNs
    /// require the SOURCE SITE's origin, not the image host's.
    static func headers(for url: URL, cookieHeader: String?, bypassUserAgent: String?,
                        refererOverride: String? = nil) -> [String: String] {
        var h: [String: String] = [
            "User-Agent": bypassUserAgent ?? defaultUserAgent,
            "Accept": "image/avif,image/webp,image/png,image/jpeg,*/*",
        ]
        if let refererOverride, !refererOverride.isEmpty {
            h["Referer"] = refererOverride
        } else if let scheme = url.scheme, let host = url.host {
            h["Referer"] = "\(scheme)://\(host)/"
        }
        if let cookieHeader, !cookieHeader.isEmpty {
            h["Cookie"] = cookieHeader
        }
        // A page's own headers, when its module gave some, win — a Seanime provider's Referer.
        // Names compare without case: a source's "referer" replaces the default "Referer" rather
        // than going out beside it, where either could be the one sent.
        if let page = MangaPageHeaders.shared.headers(for: url.absoluteString) {
            for (name, value) in page {
                h.keys.filter { $0.caseInsensitiveCompare(name) == .orderedSame }.forEach { h[$0] = nil }
                h[name] = value
            }
        }
        return h
    }
}
