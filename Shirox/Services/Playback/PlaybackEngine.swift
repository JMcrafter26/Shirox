import Foundation

/// How exactly a seek must land.
enum SeekPrecision: Equatable {
    /// The engine's default tolerance: a nearby keyframe, cheap on streams.
    case fast
    /// Frame-exact.
    case exact
    /// Within this many seconds either side.
    case within(Double)
}

/// Whether the timeline is moving, stopped, or waiting on the network.
enum PlaybackTimeControl: Equatable {
    case playing, paused, waiting
}

/// One audio track a source offers.
struct PlaybackAudioOption: Identifiable, Equatable {
    let id: Int
    let title: String
}

/// A subtitle track inside the file, which the engine draws itself.
struct PlaybackSubtitleOption: Identifiable, Equatable {
    let id: Int
    let title: String
}

/// What is playing, for the player's Video Details panel: what the engine can tell, nil for the rest.
struct PlaybackStats: Equatable {
    var videoCodec: String?
    var width: Int?
    var height: Int?
    var frameRate: Double?
    /// Bits per second, of the video alone.
    var videoBitrate: Double?
    /// The stream variant's own bitrate, as its playlist declares it.
    var streamBitrate: Double?
    var audioCodec: String?
    var audioChannels: Int?
    var sampleRate: Double?
    var audioBitrate: Double?
    /// How fast the network is delivering it, in bits per second.
    var throughput: Double?
    var droppedFrames: Int?
    /// The engine, and on mpv the decoder.
    var player: String?

    /// A codec's name from its four-character code: "avc1" is H.264, "aac " AAC.
    static func codecName(fourCC: FourCharCode) -> String {
        let bytes = [24, 16, 8, 0].map { UInt8((fourCC >> $0) & 0xFF) }
        let code = String(repairingUTF8: bytes)
        return codecName(code.trimmingCharacters(in: .whitespaces))
    }

    /// A codec's name from a four-character code or an FFmpeg codec name ("h264", "hevc", "aac").
    static func codecName(_ code: String) -> String {
        switch code.lowercased() {
        case "avc1", "avc3", "h264": return "H.264"
        case "hvc1", "hev1", "hevc", "h265": return "HEVC"
        case "dvh1", "dvhe": return "HEVC (Dolby Vision)"
        case "av01", "av1": return "AV1"
        case "vp09", "vp9": return "VP9"
        case "aac", "mp4a": return "AAC"
        case "aach": return "HE-AAC"
        case "aacp": return "HE-AACv2"
        case "ac-3", "ac3": return "AC-3"
        case "ec-3", "eac3": return "E-AC-3"
        case "opus": return "Opus"
        case ".mp3", "mp3": return "MP3"
        case "flac", "flac ": return "FLAC"
        case "alac": return "ALAC"
        case "": return String(localized: "shared.unknown")
        default: return code.uppercased()
        }
    }

    var resolutionText: String? {
        guard let width, let height, width > 0, height > 0 else { return nil }
        return "\(width) × \(height) (\(height)p)"
    }

    var frameRateText: String? {
        guard let frameRate, frameRate > 0 else { return nil }
        // "23.976 fps", "29.97 fps", "24 fps".
        var digits = String(format: "%.3f", frameRate)
        while digits.hasSuffix("0") { digits.removeLast() }
        if digits.hasSuffix(".") { digits.removeLast() }
        return digits + " fps"
    }

    var channelsText: String? {
        switch audioChannels {
        case nil, 0?: return nil
        case 1?: return String(localized: "shared.mono")
        case 2?: return String(localized: "shared.stereo")
        case 6?: return "5.1"
        case 8?: return "7.1"
        case let count?: return "\(count) channels"
        }
    }

    var sampleRateText: String? {
        guard let sampleRate, sampleRate > 0 else { return nil }
        return String(format: "%g kHz", (sampleRate / 100).rounded() / 10)
    }

    /// "4.2 Mbps", "128 kbps".
    static func bitrateText(_ bitsPerSecond: Double?) -> String? {
        guard let bitsPerSecond, bitsPerSecond > 0 else { return nil }
        if bitsPerSecond >= 1_000_000 { return String(format: "%.1f Mbps", bitsPerSecond / 1_000_000) }
        return String(format: "%.0f kbps", bitsPerSecond / 1_000)
    }
}

/// What to play.
struct PlaybackSource: Equatable {
    let url: URL
    /// Sent with every request for the stream; empty for a file or an already-proxied URL.
    var headers: [String: String] = [:]
    /// Start on Japanese audio when the source offers a choice — a subbed stream.
    var prefersJapaneseAudio = false
    /// The key its playlists are scrambled with (see ``HLSPlaylistCipher``), when they are.
    /// Such a stream is only playable through the app's proxy, which unscrambles them.
    var playlistKey: String?
    /// Turn on the stream's own subtitle rendition — the one the proxy adds for AirPlay.
    var selectsSubtitles = false
}

/// What an engine reports while it plays. Each is only ever about the item loaded now: an event
/// from one it has swapped out is dropped by the engine, so listeners needn't check.
struct PlaybackEngineEvents {
    var timeControlChanged: (PlaybackTimeControl) -> Void = { _ in }
    /// Twice a second while the clock runs.
    var tick: () -> Void = {}
    var itemReady: () -> Void = {}
    var itemFailed: (Error?) -> Void = { _ in }
    var playedToEnd: () -> Void = {}
    var failedToPlayToEnd: (Error?) -> Void = { _ in }
    var audioOptionsChanged: () -> Void = {}
    /// The file's own subtitle tracks changed. Only MPV draws them, so only MPV sends it.
    var subtitleOptionsChanged: () -> Void = {}
}

/// The player behind the player screen. `PlayerView` drives playback only through this, so the
/// same controls, menus and gestures work over any engine.
@MainActor
protocol PlaybackEngine: AnyObject {
    /// Setting these the first time also starts the clock and the play/pause reports.
    var events: PlaybackEngineEvents { get set }

    /// Plays `source` from now on in place of whatever was loaded. Doesn't start playback.
    func load(_ source: PlaybackSource)
    /// Pauses and stops reporting, for good.
    func stop()

    var currentTime: Double { get }
    /// nil until known.
    var duration: Double? { get }
    /// How far the buffer reaches, in seconds of timeline.
    var bufferedUntil: Double { get }
    var timeControl: PlaybackTimeControl { get }
    var isItemReady: Bool { get }
    var isItemFailed: Bool { get }

    /// Above 0 plays at that speed; 0 pauses.
    var rate: Float { get set }
    var volume: Float { get set }
    /// Plays at the engine's default rate.
    func play()
    func pause()
    /// Plays at `rate` without waiting to build a buffer first.
    func playImmediately(atRate rate: Float)

    func seek(to seconds: Double, precision: SeekPrecision, completion: ((Bool) -> Void)?)
    func seek(to seconds: Double, precision: SeekPrecision) async

    /// Hold playback until a network-sized buffer is built. Off for files on disk and while scrubbing.
    var waitsToMinimizeStalling: Bool { get set }
    /// Caps the stream's bitrate; nil lets it adapt.
    func setPeakBitRate(_ bitsPerSecond: Int?)

    var audioOptions: [PlaybackAudioOption] { get }
    var selectedAudioOption: PlaybackAudioOption.ID? { get }
    func selectAudioOption(_ id: PlaybackAudioOption.ID)

    /// What is playing now, read fresh on each call.
    func stats() async -> PlaybackStats
}
