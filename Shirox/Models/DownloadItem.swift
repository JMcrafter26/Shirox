import Foundation

enum DownloadState: String, Codable {
    case pending
    case downloading
    /// Stopped by the user, keeping whatever has already been fetched. Distinct from `failed`:
    /// nothing went wrong and `processQueue` must leave it alone until it is resumed.
    case paused
    case completed
    case failed
}

/// One of a download's subtitle tracks: where it came from, and its local copy once fetched.
struct DownloadedSubtitle: Codable, Equatable {
    let title: String
    let url: URL
    var headers: [String: String]?
    /// Relative to the downloads folder; nil until fetched.
    var relativePath: String?
}

struct DownloadItem: Identifiable, Codable {
    let id: UUID
    
    // Media Identity
    let mediaTitle: String
    let episodeNumber: Int
    let episodeTitle: String?
    let imageUrl: String
    let aniListID: Int?
    
    // Module Integration
    let moduleId: String?
    let detailHref: String?
    let episodeHref: String
    let streamTitle: String?
    /// nil while the batch-download pipeline is still extracting the stream URL for this
    /// item. processQueue() ignores items where this is nil; a separate task is responsible
    /// for filling it in and then re-triggering the queue.
    var streamURL: URL?
    var headers: [String: String]

    // Subtitles
    var subtitleURL: URL?
    var subtitleHeaders: [String: String]?

    // Status
    var state: DownloadState
    var progress: Double
    var error: String?

    // File Info
    var fileName: String? // Points to the .mp4 or .m3u8 file
    var relativeSubtitlePath: String?
    
    // Timing
    let createdAt: Date
    var completedAt: Date?
    
    // Task Tracking
    var taskIdentifier: Int?
    var retryCount: Int = 0
    /// The key the stream's playlists are scrambled with (see ``HLSPlaylistCipher``), if any.
    var playlistKey: String? = nil
    /// Every subtitle track the stream offered, each saved beside the video once fetched. Only
    /// the default (`subtitleURL`) used to be kept, so offline the other languages were gone.
    var subtitleTracks: [DownloadedSubtitle]? = nil
    
    // Helper to determine if we should use HLS playback
    var isHLS: Bool {
        fileName?.lowercased().hasSuffix(".m3u8") ?? false
    }
}
