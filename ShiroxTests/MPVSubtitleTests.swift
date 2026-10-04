import XCTest
import AVFoundation
@testable import Shirox

/// mpv drawing subtitles: the tracks inside a file, and ASS scripts handed to it.
@MainActor
final class MPVSubtitleTests: XCTestCase {

    /// Two seconds of silence with two ASS tracks: "English" (default) and "Signs". Made with
    /// ffmpeg: `-f lavfi -t 2 -i anullsrc=r=8000:cl=mono -i en.ass -i signs.ass -map 0:a -map 1
    /// -map 2 -c:a libopus -b:a 6k -c:s ass`, titles and default disposition set per track.
    private static let mkv = Data(base64Encoded: "GkXfo6NChoEBQveBAULygQRC84EIQoKIbWF0cm9za2FCh4EEQoWBAhhTgGcBAAAAAAAMexFNm3TAv4TA8tN1TbuLU6uEFUmpZlOsgaFNu4tTq4QWVK5rU6yB7027jFOrhBJUw2dTrIIF7U27jFOrhBxTu2tTrIIMP+wBAAAAAAAAUwAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAFUmpZsm/hOyy4TAq17GDD0JATYCMTGF2ZjYxLjcuMTAwV0GMTGF2ZjYxLjcuMTAwc6SQ3lpLkHgwEnoCiwEj7hSXqUSJiECfYAAAAAAAFlSua0T4v4SGJozhrgEAAAAAAABg14EBc8WI6aswKRJg/OScgQAitZyDdW5kiIEAhoZBX09QVVNWqoNjLqBWu4QExLQAg4EC4ZGfgQG1iEC/QAAAAAAAYmSBEFXugQBjopNPcHVzSGVhZAEBOAFAHwAAAAAArgEAAAAAAAI714ECc8WIt+vNGdqJPRucgQBTbodFbmdsaXNoIrWcg2VuZ4aKU19URVhUL0FTU4OBEVXugQBjokICW1NjcmlwdCBJbmZvXQpTY3JpcHRUeXBlOiB2NC4wMCsKUGxheVJlc1g6IDY0MApQbGF5UmVzWTogMzYwCgpbVjQrIFN0eWxlc10KRm9ybWF0OiBOYW1lLCBGb250bmFtZSwgRm9udHNpemUsIFByaW1hcnlDb2xvdXIsIFNlY29uZGFyeUNvbG91ciwgT3V0bGluZUNvbG91ciwgQmFja0NvbG91ciwgQm9sZCwgSXRhbGljLCBVbmRlcmxpbmUsIFN0cmlrZU91dCwgU2NhbGVYLCBTY2FsZVksIFNwYWNpbmcsIEFuZ2xlLCBCb3JkZXJTdHlsZSwgT3V0bGluZSwgU2hhZG93LCBBbGlnbm1lbnQsIE1hcmdpbkwsIE1hcmdpblIsIE1hcmdpblYsIEVuY29kaW5nClN0eWxlOiBEZWZhdWx0LEhlbHZldGljYSwzMiwmSDAwRkZGRkZGLCZIMDAwMDAwRkYsJkgwMDAwMDAwMCwmSDAwMDAwMDAwLDAsMCwwLDAsMTAwLDEwMCwwLDAsMSwyLDAsMiwxMCwxMCwyMCwxCgpbRXZlbnRzXQpGb3JtYXQ6IExheWVyLCBTdGFydCwgRW5kLCBTdHlsZSwgTmFtZSwgTWFyZ2luTCwgTWFyZ2luUiwgTWFyZ2luViwgRWZmZWN0LCBUZXh0Cq4BAAAAAAACPNeBA3PFiBRDVdqjUGR6nIEAU26FU2lnbnMitZyDZW5niIEAhopTX1RFWFQvQVNTg4ERVe6BAGOiQgJbU2NyaXB0IEluZm9dClNjcmlwdFR5cGU6IHY0LjAwKwpQbGF5UmVzWDogNjQwClBsYXlSZXNZOiAzNjAKCltWNCsgU3R5bGVzXQpGb3JtYXQ6IE5hbWUsIEZvbnRuYW1lLCBGb250c2l6ZSwgUHJpbWFyeUNvbG91ciwgU2Vjb25kYXJ5Q29sb3VyLCBPdXRsaW5lQ29sb3VyLCBCYWNrQ29sb3VyLCBCb2xkLCBJdGFsaWMsIFVuZGVybGluZSwgU3RyaWtlT3V0LCBTY2FsZVgsIFNjYWxlWSwgU3BhY2luZywgQW5nbGUsIEJvcmRlclN0eWxlLCBPdXRsaW5lLCBTaGFkb3csIEFsaWdubWVudCwgTWFyZ2luTCwgTWFyZ2luUiwgTWFyZ2luViwgRW5jb2RpbmcKU3R5bGU6IERlZmF1bHQsSGVsdmV0aWNhLDMyLCZIMDBGRkZGRkYsJkgwMDAwMDBGRiwmSDAwMDAwMDAwLCZIMDAwMDAwMDAsMCwwLDAsMCwxMDAsMTAwLDAsMCwxLDIsMCwyLDEwLDEwLDIwLDEKCltFdmVudHNdCkZvcm1hdDogTGF5ZXIsIFN0YXJ0LCBFbmQsIFN0eWxlLCBOYW1lLCBNYXJnaW5MLCBNYXJnaW5SLCBNYXJnaW5WLCBFZmZlY3QsIFRleHQKElTDZ0Euv4Q3t6Afc3OfY8CAZ8iZRaOHRU5DT0RFUkSHjExhdmY2MS43LjEwMHNz12PAi2PFiOmrMCkSYPzkZ8iiRaOHRU5DT0RFUkSHlUxhdmM2MS4xOS4xMDEgbGlib3B1c2fIoUWjiERVUkFUSU9ORIeTMDA6MDA6MDIuMDA4MDAwMDAwAHNz02PAi2PFiLfrzRnaiT0bZ8ieRaOHRU5DT0RFUkSHkUxhdmM2MS4xOS4xMDEgYXNzZ8ihRaOIRFVSQVRJT05Eh5MwMDowMDowMi4wMDAwMDAwMDAAc3PTY8CLY8WIFENV2qNQZHpnyJ5Fo4dFTkNPREVSRIeRTGF2YzYxLjE5LjEwMSBhc3NnyKFFo4hEVVJBVElPTkSHkzAwOjAwOjAyLjAwMDAwMDAwMAAfQ7Z1RRi/hGsc6dDngQCji4EAAIAIC+Y7I6tgoKOhnYIAAAAwLDAsRGVmYXVsdCwsMCwwLDAsLEhlbGxvm4IH0KCioZyDAAAAMCwwLERlZmF1bHQsLDAsMCwwLCxTSUdOm4IH0KOKgQAVgAgIrLMOxqOKgQApgAgIrLMOxqOKgQA9gAgIrLMOxqOKgQBRgAgIrLMOxqOKgQBlgAgIrLMOxqOKgQB5gAgIrLMOxqOKgQCNgAgIrLMOxqOKgQChgAgIrLMOxqOKgQC1gAgIrLMOxqOKgQDJgAgIrLMOxqOKgQDdgAgIrLMOxqOKgQDxgAgIrLMOxqOKgQEFgAgIrLMOxqOKgQEZgAgIrLMOxqOKgQEtgAgIrLMOxqOKgQFBgAgIrLMOxqOKgQFVgAgIrLMOxqOKgQFpgAgIrLMOxqOKgQF9gAgIrLMOxqOKgQGRgAgIrLMOxqOKgQGlgAgIrLMOxqOKgQG5gAgIrLMOxqOKgQHNgAgIrLMOxqOKgQHhgAgIrLMOxqOKgQH1gAgIrLMOxqOKgQIJgAgIrLMOxqOKgQIdgAgIrLMOxqOKgQIxgAgIrLMOxqOKgQJFgAgIrLMOxqOKgQJZgAgIrLMOxqOKgQJtgAgIrLMOxqOKgQKBgAgIrLMOxqOKgQKVgAgIrLMOxqOKgQKpgAgIrLMOxqOKgQK9gAgIrLMOxqOKgQLRgAgIrLMOxqOKgQLlgAgIrLMOxqOKgQL5gAgIrLMOxqOKgQMNgAgIrLMOxqOKgQMhgAgIrLMOxqOKgQM1gAgIrLMOxqOKgQNJgAgIrLMOxqOKgQNdgAgIrLMOxqOKgQNxgAgIrLMOxqOKgQOFgAgIrLMOxqOKgQOZgAgIrLMOxqOKgQOtgAgIrLMOxqOKgQPBgAgIrLMOxqOKgQPVgAgIrLMOxqOKgQPpgAgIrLMOxqOKgQP9gAgIrLMOxqOKgQQRgAgIrLMOxqOKgQQlgAgIrLMOxqOKgQQ5gAgIrLMOxqOKgQRNgAgIrLMOxqOKgQRhgAgIrLMOxqOKgQR1gAgIrLMOxqOKgQSJgAgIrLMOxqOKgQSdgAgIrLMOxqOKgQSxgAgIrLMOxqOKgQTFgAgIrLMOxqOKgQTZgAgIrLMOxqOKgQTtgAgIrLMOxqOKgQUBgAgIrLMOxqOKgQUVgAgIrLMOxqOKgQUpgAgIrLMOxqOKgQU9gAgIrLMOxqOKgQVRgAgIrLMOxqOKgQVlgAgIrLMOxqOKgQV5gAgIrLMOxqOKgQWNgAgIrLMOxqOKgQWhgAgIrLMOxqOKgQW1gAgIrLMOxqOKgQXJgAgIrLMOxqOKgQXdgAgIrLMOxqOKgQXxgAgIrLMOxqOKgQYFgAgIrLMOxqOKgQYZgAgIrLMOxqOKgQYtgAgIrLMOxqOKgQZBgAgIrLMOxqOKgQZVgAgIrLMOxqOKgQZpgAgIrLMOxqOKgQZ9gAgIrLMOxqOKgQaRgAgIrLMOxqOKgQalgAgIrLMOxqOKgQa5gAgIrLMOxqOKgQbNgAgIrLMOxqOKgQbhgAgIrLMOxqOKgQb1gAgIrLMOxqOKgQcJgAgIrLMOxqOKgQcdgAgIrLMOxqOKgQcxgAgIrLMOxqOKgQdFgAgIrLMOxqOKgQdZgAgIrLMOxqOKgQdtgAgIrLMOxqOKgQeBgAgIrLMOxqOKgQeVgAgIrLMOxqOKgQepgAgIrLMOxqOKgQe9gAgIrLMOxqCToYqBB9EACAissw7GdaKEAM3+YBxTu2u3v4TnV2AMu6+zgQC3iveBAfGCByHwgQm3jveBAvGCByHwgRayggfQt473gQPxggch8IE7soIH0A==")!

    /// Six seconds of a 32×32 black picture and silence as HLS: three 2 s segments, and a WebVTT
    /// subtitle playlist of three segments with one line each ("Line 0" at 0.2–0.9 s, and so on).
    /// Made with ffmpeg: `-f lavfi -i color=c=black:s=32x32:r=2:d=6 -f lavfi -i anullsrc=r=8000
    /// -t 6 -c:v libx264 -g 2 -c:a aac -b:a 8k -f hls -hls_time 2 -hls_playlist_type vod`.
    private static let hlsSegments = [
        "R0AREABC8CUAAcEAAP8B/wAB/IAUSBIBBkZGbXBlZwlTZXJ2aWNlMDF3fEPK//////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////9HQAAQAACwDQABwQAAAAHwACqxBLL//////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////0dQABAAArAXAAHBAADhAPAAG+EA8AAP4QHwAC9EuZv/////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////R0EAMAdQAACRjH4AAAAB4AAAgIAFIQAJMmEAAAABCfAAAAABZ0LACtolsBEAAAMAAQAAAwAEDxImoAAAAAFozg/IAAABBgX//03cRem95tlIt5Ys2CDZI+7veDI2NCAtIGNvcmUgMTY0IHIzMTA4IDMxZTE5ZjkgLSBILjI2NC9NUEVHLTQgQVZDIGNvZGVjIC0gQ29weWxlZnQgMjAwMy0yMDIzIC0gaHR0cDovL3d3dy52aWRlb2xhbi5HAQARb3JnL3gyNjQuaHRtbCAtIG9wdGlvbnM6IGNhYmFjPTAgcmVmPTEgZGVibG9jaz0wOjA6MCBhbmFseXNlPTA6MCBtZT1kaWEgc3VibWU9MCBwc3k9MSBwc3lfcmQ9MS4wMDowLjAwIG1peGVkX3JlZj0wIG1lX3JhbmdlPTE2IGNocm9tYV9tZT0xIHRyZWxsaXM9MCA4eDhkY3Q9MCBjcW09MCBkZWFkem9uZT0yMSwxMSBmYXN0X0cBABJwc2tpcD0xIGNocm9tYV9xcF9vZmZzZXQ9MCB0aHJlYWRzPTEgbG9va2FoZWFkX3RocmVhZHM9MSBzbGljZWRfdGhyZWFkcz0wIG5yPTAgZGVjaW1hdGU9MSBpbnRlcmxhY2VkPTAgYmx1cmF5X2NvbXBhdD0wIGNvbnN0cmFpbmVkX2ludHJhPTAgYmZyYW1lcz0wIHdlaWdodHA9MCBrZXlpbnQ9MiBrZXlpbnRfbWluPTEgc2NlRwEAMz0A////////////////////////////////////////////////////////////////////////////////bmVjdXQ9MCBpbnRyYV9yZWZyZXNoPTAgcmM9Y3JmIG1idHJlZT0wIGNyZj0yMy4wIHFjb21wPTAuNjAgcXBtaW49MCBxcG1heD02OSBxcHN0ZXA9NCBpcF9yYXRpbz0xLjQwIGFxPTAAgAAAAAFliIQ6JigACQLJ115HQQEwd0D/////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////AAABwAA6gIAFIQAH2GH/8WxAA5/83gIATGF2YzYxLjE5LjEwMQACMEAO//FsQAF//AEYIAf/8WxAAX/8ARggB0dBADSZEAAA6XB+AP//////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////AAAB4AAAgIAFIQALkfEAAAABCfAAAAABQZogEqLAR0EBMYhA////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////AAABwAApgIAFIQAJ5mH/8WxAAX/8ARggB//xbEABf/wBGCAH//FsQAF//AEYIAdHQAARAACwDQABwQAAAAHwACqxBLL//////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////0dQABEAArAXAAHBAADhAPAAG+EA8AAP4QHwAC9EuZv/////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////R0EANXBQAAFBVH4A////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////AAAB4AAAgIAFIQAN8YEAAAABCfAAAAABZ0LACtolsBEAAAMAAQAAAwAEDxImoAAAAAFozg/IAAAAAWWIggMomKAALC8nXXhHQQEyiED///////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////8AAAHAACmAgAUhAAv0Yf/xbEABf/wBGCAH//FsQAF//AEYIAf/8WxAAX/8ARggB0dBATOIQP///////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////wAAAcAAKYCABSEADwJh//FsQAF//AEYIAf/8WxAAX/8ARggB//xbEABf/wBGCAHR0EANpkQAAGZOH4A//////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////8AAAHgAACAgAUhABFREQAAAAEJ8AAAAAFBmiASosBHQQE0iED///////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////8AAAHAACmAgAUhABEQYf/xbEABf/wBGCAH//FsQAF//AEYIAf/8WxAAX/8ARggB0dBATWTQP//////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////AAABwAAegIAFIQATHmH/8WxAAX/8ARggB//xbEABf/wBGCAH",
        "R0AREQBC8CUAAcEAAP8B/wAB/IAUSBIBBkZGbXBlZwlTZXJ2aWNlMDF3fEPK//////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////9HQAASAACwDQABwQAAAAHwACqxBLL//////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////0dQABIAArAXAAHBAADhAPAAG+EA8AAP4QHwAC9EuZv/////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////R0EAN3BQAAHxHH4A////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////AAAB4AAAgIAFIQATsKEAAAABCfAAAAABZ0LACtolsBEAAAMAAQAAAwAEDxImoAAAAAFozg/IAAAAAWWIhA6iYoAAvvyddeBHQQE2iED///////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////8AAAHAACmAgAUhABPSYf/xbEABf/wBGCAH//FsQAF//AEYIAf/8WxAAX/8ARggB0dBADiZEAACSQB+AP//////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////AAAB4AAAgIAFIQAXEDEAAAABCfAAAAABQZogEqLAR0EBN4hA////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////AAABwAApgIAFIQAV4GH/8WxAAX/8ARggB//xbEABf/wBGCAH//FsQAF//AEYIAdHQAATAACwDQABwQAAAAHwACqxBLL//////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////0dQABMAArAXAAHBAADhAPAAG+EA8AAP4QHwAC9EuZv/////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////R0EAOXBQAAKg5H4A////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////AAAB4AAAgIAFIQAZb8EAAAABCfAAAAABZ0LACtolsBEAAAMAAQAAAwAEDxImoAAAAAFozg/IAAAAAWWIggEKJigADQbJ115HQQE4iED///////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////8AAAHAACmAgAUhABfuYf/xbEABf/wBGCAH//FsQAF//AEYIAf/8WxAAX/8ARggB0dBADqZEAAC+Mh+AP//////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////AAAB4AAAgIAFIQAbz1EAAAABCfAAAAABQZogEqLAR0EBOYhA////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////AAABwAApgIAFIQAZ/GH/8WxAAX/8ARggB//xbEABf/wBGCAH//FsQAF//AEYIAdHQQE6iED///////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////8AAAHAACmAgAUhAB0KYf/xbEABf/wBGCAH//FsQAF//AEYIAf/8WxAAX/8ARggB0dBATueQP////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////8AAAHAABOAgAUhAB8YYf/xbEABf/wBGCAH",
        "R0AREgBC8CUAAcEAAP8B/wAB/IAUSBIBBkZGbXBlZwlTZXJ2aWNlMDF3fEPK//////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////9HQAAUAACwDQABwQAAAAHwACqxBLL//////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////0dQABQAArAXAAHBAADhAPAAG+EA8AAP4QHwAC9EuZv/////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////R0EAO3BQAANQrH4A////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////AAAB4AAAgIAFIQAfLuEAAAABCfAAAAABZ0LACtolsBEAAAMAAQAAAwAEDxImoAAAAAFozg/IAAAAAWWIhAQomKAANBsnXXhHQQE8iED///////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////8AAAHAACmAgAUhAB9yYf/xbEABf/wBGCAH//FsQAF//AEYIAf/8WxAAX/8ARggB0dBADyZEAADqJB+AP//////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////AAAB4AAAgIAFIQAhjnEAAAABCfAAAAABQZogEqLAR0EBPYhA////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////AAABwAApgIAFIQAhgGH/8WxAAX/8ARggB//xbEABf/wBGCAH//FsQAF//AEYIAdHQAAVAACwDQABwQAAAAHwACqxBLL//////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////0dQABUAArAXAAHBAADhAPAAG+EA8AAP4QHwAC9EuZv/////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////R0EAPXBQAAQAdH4A////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////AAAB4AAAgIAFIQAj7gEAAAABCfAAAAABZ0LACtolsBEAAAMAAQAAAwAEDxImoAAAAAFozg/IAAAAAWWIggEaJigADYjJ115HQQE+iED///////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////8AAAHAACmAgAUhACOOYf/xbEABf/wBGCAH//FsQAF//AEYIAf/8WxAAX/8ARggB0dBAD6ZEAAEWFh+AP//////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////AAAB4AAAgIAFIQAnTZEAAAABCfAAAAABQZogEqLAR0EBP4hA////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////AAABwAApgIAFIQAlnGH/8WxAAX/8ARggB//xbEABf/wBGCAH//FsQAF//AEYIAdHQQEwiED///////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////8AAAHAACmAgAUhACeqYf/xbEABf/wBGCAH//FsQAF//AEYIAf/8WxAAX/8ARggBw==",
    ]

    private let script = """
    [Script Info]
    ScriptType: v4.00+

    [Events]
    Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text
    Dialogue: 0,0:00:00.00,0:00:02.00,Default,,0,0,0,,Hello
    """

    private var engine: MPVEngine!
    private var files: [URL] = []

    override func setUp() async throws {
        engine = MPVEngine(output: .none)
    }

    override func tearDown() async throws {
        engine.stop()
        engine = nil
        for file in files { try? FileManager.default.removeItem(at: file) }
    }

    private func mkvFile() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("mpv-sub-\(UUID().uuidString).mkv")
        try Self.mkv.write(to: url)
        files.append(url)
        return url
    }

    private func silence() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("mpv-sub-\(UUID().uuidString).caf")
        let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 88_200)!
        buffer.frameLength = 88_200
        do {
            let file = try AVAudioFile(forWriting: url, settings: format.settings)
            try file.write(from: buffer)
        }
        files.append(url)
        return url
    }

    /// The HLS stream above, written out; returns its master playlist.
    private func hlsWithWebVTT() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mpv-hls-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        files.append(dir)
        func write(_ name: String, _ data: Data) throws { try data.write(to: dir.appendingPathComponent(name)) }
        var media = "#EXTM3U\n#EXT-X-VERSION:3\n#EXT-X-TARGETDURATION:2\n#EXT-X-PLAYLIST-TYPE:VOD\n"
        var subs = media
        for (index, segment) in Self.hlsSegments.enumerated() {
            try write("v\(index).ts", Data(base64Encoded: segment)!)
            try write("s\(index).vtt", Data("""
            WEBVTT
            X-TIMESTAMP-MAP=MPEGTS:126000,LOCAL:00:00:00.000

            00:00:0\(index * 2).200 --> 00:00:0\(index * 2).900
            Line \(index)

            """.utf8))
            media += "#EXTINF:2.0,\nv\(index).ts\n"
            subs += "#EXTINF:2.0,\ns\(index).vtt\n"
        }
        try write("media.m3u8", Data((media + "#EXT-X-ENDLIST\n").utf8))
        try write("subs.m3u8", Data((subs + "#EXT-X-ENDLIST\n").utf8))
        try write("master.m3u8", Data("""
        #EXTM3U
        #EXT-X-MEDIA:TYPE=SUBTITLES,GROUP-ID="subs",NAME="English",LANGUAGE="en",DEFAULT=YES,AUTOSELECT=YES,URI="subs.m3u8"
        #EXT-X-STREAM-INF:BANDWIDTH=100000,SUBTITLES="subs"
        media.m3u8

        """.utf8))
        return dir.appendingPathComponent("master.m3u8")
    }

    private func load(_ url: URL) async {
        let ready = expectation(description: "ready")
        ready.assertForOverFulfill = false
        engine.events.itemReady = { ready.fulfill() }
        engine.load(PlaybackSource(url: url))
        await fulfillment(of: [ready], timeout: 10)
    }

    private func waitUntil(_ seconds: TimeInterval = 5, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return condition()
    }

    func testTheFilesOwnTracksAreListedWithItsDefault() async throws {
        await load(try mkvFile())
        let listed = await waitUntil { self.engine.subtitleOptions.count == 2 }
        XCTAssertTrue(listed)
        XCTAssertEqual(engine.subtitleOptions.map(\.title), ["English", "Signs"])
        XCTAssertEqual(engine.defaultSubtitleOption, engine.subtitleOptions.first?.id)
    }

    /// Nothing is drawn until the player says what to draw.
    func testNothingIsShownUntilAsked() async throws {
        await load(try mkvFile())
        XCTAssertNil(engine.shownSubtitleTrack)
    }

    func testAPickedTrackInTheFileIsShown() async throws {
        await load(try mkvFile())
        _ = await waitUntil { self.engine.subtitleOptions.count == 2 }
        let signs = try XCTUnwrap(engine.subtitleOptions.last).id
        engine.showSubtitles(.embedded(signs))
        XCTAssertEqual(engine.shownSubtitleTrack?.id, signs)
        XCTAssertEqual(engine.shownSubtitleTrack?.isExternal, false)
        engine.showSubtitles(.none)
        XCTAssertNil(engine.shownSubtitleTrack)
    }

    func testAnASSScriptIsHandedToMPV() async throws {
        await load(try silence())
        engine.showSubtitles(.script(script))
        let shown = await waitUntil { self.engine.shownSubtitleTrack?.isExternal == true }
        XCTAssertTrue(shown)
        XCTAssertTrue(engine.subtitleOptions.isEmpty, "a script isn't one of the file's own tracks")
    }

    /// Asked for while the file is still opening, it's drawn once the file has opened.
    func testAScriptAskedForWhileOpeningIsShownOnceOpen() async throws {
        let ready = expectation(description: "ready")
        ready.assertForOverFulfill = false
        engine.events.itemReady = { ready.fulfill() }
        engine.load(PlaybackSource(url: try silence()))
        engine.showSubtitles(.script(script))
        await fulfillment(of: [ready], timeout: 10)
        let shown = await waitUntil { self.engine.shownSubtitleTrack?.isExternal == true }
        XCTAssertTrue(shown)
    }

    /// A quality change reopens the stream; the script comes back with it.
    func testTheScriptSurvivesAReload() async throws {
        let server = try await HLSServer.twoVariants()
        defer { server.stop() }
        await load(server.url(of: "/master.m3u8"))
        engine.showSubtitles(.script(script))
        _ = await waitUntil { self.engine.shownSubtitleTrack?.isExternal == true }
        let reopened = expectation(description: "reopened")
        reopened.assertForOverFulfill = false
        engine.events.itemReady = { reopened.fulfill() }
        // Down from the highest variant, which it opened on.
        engine.setPeakBitRate(600_000)
        await fulfillment(of: [reopened], timeout: 10)
        let back = await waitUntil { self.engine.shownSubtitleTrack?.isExternal == true }
        XCTAssertTrue(back)
    }

    /// An HLS stream's WebVTT lines carry no byte position, which is all mpv tells lines it has
    /// already read apart by: every seek that read a segment again added its lines again, and
    /// "AAH! AAH!" stood seven rows high in The Matrix after a few skips.
    func testAStreamsWebVTTLinesShowOnceAfterSeeking() async throws {
        await load(try hlsWithWebVTT())
        let listed = await waitUntil { !self.engine.subtitleOptions.isEmpty }
        XCTAssertTrue(listed)
        engine.showSubtitles(.embedded(try XCTUnwrap(engine.subtitleOptions.first?.id)))
        var shown: [String] = []
        // Back and forth over every segment, each seek reading one again.
        for target in Array(stride(from: 0.0, through: 5.5, by: 0.25)) + [1, 3, 1, 3] {
            engine.seek(to: target, precision: .exact, completion: nil)
            try await Task.sleep(nanoseconds: 300_000_000)
            if let text = engine.shownSubtitleText, !text.isEmpty { shown.append(text) }
        }
        XCTAssertFalse(shown.isEmpty)
        for text in shown { XCTAssertFalse(text.contains("\n"), "showed \(text.debugDescription)") }
    }
}
