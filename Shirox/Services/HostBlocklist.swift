import Foundation

/// App-scoped blocklist of adult hosts. Enforced at every request chokepoint the app
/// controls (fetchv2 bridges, WKWebView scrapers, Cloudflare bypass, player). This is a
/// deliberate alternative to a system hosts file / DNS reconfiguration, which would be
/// system-wide.
final class HostBlocklist {
    nonisolated(unsafe) static let shared = HostBlocklist()

    private var hosts = HostSet()
    private(set) var isLoaded = false

    private init() {}

    // MARK: - Pure decision logic (testable)

    /// Parses a bare-host or hosts-file (`0.0.0.0 host` / `127.0.0.1 host`) list. Skips
    /// comments, blank lines, `localhost`, and tokens without a dot.
    ///
    /// Read as bytes and kept as hashes: it runs on every launch over some 40,000 lines, and
    /// none of them ever becomes a String.
    static func parse(_ contents: Data) -> HostSet {
        contents.withUnsafeBytes(parse(bytes:))
    }

    static func parse(_ contents: String) -> HostSet {
        var contents = contents
        return contents.withUTF8 { parse(bytes: UnsafeRawBufferPointer($0)) }
    }

    private static func parse(bytes contents: UnsafeRawBufferPointer) -> HostSet {
        let isSpace = { (byte: UInt8) in byte == 0x20 || byte == 0x09 || byte == 0x0D }
        var hashes: [UInt64] = []
        hashes.reserveCapacity(contents.count / 16)
        var line = contents.startIndex
        while line < contents.endIndex {
            let end = contents[line...].firstIndex(of: UInt8(ascii: "\n")) ?? contents.endIndex
            defer { line = end < contents.endIndex ? contents.index(after: end) : end }
            let uncommented = contents[line..<end].prefix { $0 != UInt8(ascii: "#") }
            // The last whitespace-separated token: the host, with or without an address before it.
            guard let last = uncommented.lastIndex(where: { !isSpace($0) }) else { continue }
            let hostEnd = uncommented.index(after: last)
            let hostStart = uncommented[..<hostEnd].lastIndex(where: isSpace).map(uncommented.index(after:))
                ?? uncommented.startIndex
            let host = uncommented[hostStart..<hostEnd]
            guard host.contains(UInt8(ascii: ".")), !host.elementsEqual("localhost".utf8) else { continue }
            hashes.append(HostSet.hash(host))
        }
        return HostSet(unsorted: hashes)
    }

    /// True if `host` exactly matches, or is a subdomain of, any entry in `set`.
    /// Only checks suffixes with ≥2 labels so a stray bare-TLD entry can't over-block.
    static func isHostBlocked(_ host: String, in set: HostSet) -> Bool {
        set.containsHostOrParent(host)
    }

    // MARK: - Instance API

    func isBlocked(_ url: URL) -> Bool {
        guard let host = url.host else { return false }
        return isBlocked(host: host)
    }

    func isBlocked(host: String) -> Bool {
        Self.isHostBlocked(host, in: hosts)
    }

    /// Loads the bundled snapshot once, off the main thread. Safe to call at launch.
    /// `then` runs on the main queue once the list is in (at once if it already is).
    func loadIfNeeded(then loaded: (@Sendable () -> Void)? = nil) {
        guard !isLoaded else { loaded?(); return }
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let url = Bundle.main.url(forResource: "adult_hosts", withExtension: "txt"),
                  let contents = try? Data(contentsOf: url, options: .alwaysMapped) else {
                DispatchQueue.main.async { self?.isLoaded = true; loaded?() }   // fail-open if missing
                return
            }
            let parsed = Self.parse(contents)
            DispatchQueue.main.async {
                self?.hosts = parsed
                self?.isLoaded = true
                loaded?()
            }
        }
    }

    /// Test seam: injects a host set synchronously.
    static func loadForTesting(_ set: HostSet) {
        shared.hosts = set
        shared.isLoaded = true
    }
}

/// A set of lowercase hosts kept as a sorted array of 64-bit hashes: 8 bytes a host, one
/// allocation, and a lookup that hashes and binary-searches without building any String.
/// With ~40,000 entries the odds of an unlisted host colliding with one are about 1 in 10^14.
struct HostSet: Equatable, ExpressibleByArrayLiteral {
    private let hashes: [UInt64]

    init() { hashes = [] }

    init<S: Sequence<String>>(_ hosts: S) {
        self.init(unsorted: hosts.map { Self.hash($0.utf8) })
    }

    init(arrayLiteral hosts: String...) {
        self.init(hosts)
    }

    fileprivate init(unsorted: [UInt64]) {
        var hashes: [UInt64] = []
        hashes.reserveCapacity(unsorted.count)
        for hash in unsorted.sorted() where hash != hashes.last { hashes.append(hash) }
        self.hashes = hashes
    }

    var count: Int { hashes.count }

    func contains(_ host: String) -> Bool {
        contains(hash: Self.hash(host.utf8))
    }

    /// True for `host` itself, or any parent of it with at least two labels.
    ///
    /// Hashes the host back to front, so the running hash at each dot is already the hash of
    /// the suffix after it; one pass covers every candidate.
    func containsHostOrParent(_ host: String) -> Bool {
        var bytes = host.utf8[...]
        if bytes.last == UInt8(ascii: ".") { bytes = bytes.dropLast() }   // fully qualified form
        var hash = Self.offsetBasis
        var sawDot = false
        for byte in bytes.reversed() {
            if byte == UInt8(ascii: ".") {
                if sawDot, contains(hash: hash) { return true }
                sawDot = true
            }
            hash = Self.mix(hash, byte)
        }
        return contains(hash: hash)
    }

    private func contains(hash: UInt64) -> Bool {
        var low = 0, high = hashes.count
        while low < high {
            let mid = (low + high) / 2
            if hashes[mid] < hash { low = mid + 1 } else { high = mid }
        }
        return low < hashes.count && hashes[low] == hash
    }

    // FNV-1a over the host's ASCII-lowercased bytes, last byte first.

    private static let offsetBasis: UInt64 = 0xcbf2_9ce4_8422_2325

    fileprivate static func hash<Bytes: BidirectionalCollection<UInt8>>(_ host: Bytes) -> UInt64 {
        host.reversed().reduce(offsetBasis, mix)
    }

    private static func mix(_ hash: UInt64, _ byte: UInt8) -> UInt64 {
        let lower = byte &- UInt8(ascii: "A") < 26 ? byte | 0x20 : byte
        return (hash ^ UInt64(lower)) &* 0x100_0000_01b3
    }
}
