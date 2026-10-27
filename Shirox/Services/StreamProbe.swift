import Foundation

/// Whether a stream link is video before it's offered. Scrapers often list links that answer
/// 404, download or link-shortener pages, or ZIP archives; each one only fails once tapped.
/// The first bytes are fetched with the stream's own headers, and anything that clearly isn't
/// video is left out. A link that can't be reached in time is kept: that's the player's to try.
enum StreamProbe {
    enum Verdict: Equatable { case playable, notVideo, unknown }

    static let timeout: TimeInterval = 6

    /// Whether a kind's streams are checked before they're listed. Not a Stremio addon's: its
    /// links are a catalogue, not a scrape, and a debrid one (AIOStreams, Torrentio and the
    /// rest with TorBox, Real-Debrid…) is a request: fetching it adds the torrent to the
    /// account. Checking every link filled a TorBox library with each one on the list before
    /// anything was picked. Those links are fetched only when one is played or downloaded.
    static func checks(_ kind: ExtensionKind?) -> Bool {
        guard let kind else { return false }
        return kind != .stremio
    }

    static func verdict(for stream: StreamResult, session: URLSession = .shared) async -> Verdict {
        var request = URLRequest(url: stream.url, timeoutInterval: timeout)
        for (key, value) in stream.headers { request.setValue(value, forHTTPHeaderField: key) }
        request.setValue("bytes=0-63", forHTTPHeaderField: "Range")
        do {
            let (bytes, response) = try await session.bytes(for: request)
            guard let http = response as? HTTPURLResponse else { return .unknown }
            if http.statusCode >= 400 { return .notVideo }
            var head = [UInt8]()
            for try await byte in bytes {
                head.append(byte)
                if head.count >= 64 { break }
            }
            return judge(contentType: http.value(forHTTPHeaderField: "Content-Type"), head: head)
        } catch {
            return .unknown
        }
    }

    /// The first bytes decide: a playlist, or anything that isn't a web page or an archive.
    static func judge(contentType: String?, head: [UInt8]) -> Verdict {
        let text = String(repairingUTF8: head).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if text.hasPrefix("#extm3u") { return .playable }
        if head.starts(with: [0x50, 0x4b, 0x03, 0x04]) { return .notVideo }
        if (contentType ?? "").lowercased().contains("text/html") || text.hasPrefix("<") { return .notVideo }
        return .playable
    }

    /// `streams` without the ones that aren't video, in their order, checked all at once.
    static func playable(_ streams: [StreamResult], session: URLSession = .shared) async -> [StreamResult] {
        let verdicts = await withTaskGroup(of: (Int, Verdict).self) { group in
            for (i, stream) in streams.enumerated() {
                group.addTask { (i, await verdict(for: stream, session: session)) }
            }
            var out = [Int: Verdict]()
            for await (i, v) in group { out[i] = v }
            return out
        }
        return streams.enumerated().filter { verdicts[$0.offset] != .notVideo }.map(\.element)
    }
}
