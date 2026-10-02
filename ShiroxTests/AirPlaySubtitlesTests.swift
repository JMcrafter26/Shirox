import XCTest
@testable import Shirox

/// Soft subtitles for AirPlay: the receiver only draws a WebVTT rendition named in the stream,
/// so the proxy adds one built from the player's cues.
final class AirPlaySubtitlesTests: XCTestCase {

    func testDialogueComesOutOfAnASSScriptAndSignsDont() {
        let cues = AirPlaySubtitles.cues(fromASS: """
        [Script Info]
        Title: x

        [V4+ Styles]
        Format: Name, Fontname, Fontsize
        Style: Default,Arial,20

        [Events]
        Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text
        Dialogue: 0,0:00:05.00,0:00:06.00,Default,,0,0,0,,Second
        Dialogue: 0,0:00:01.50,0:00:03.25,Default,,0,0,0,,{\\an8\\i1}Hello, world\\Nnext line
        Dialogue: 0,0:00:02.00,0:00:04.00,Sign,,0,0,0,,{\\p1}m 0 0 l 100 0 100 100{\\p0}
        Comment: 0,0:00:01.00,0:00:02.00,Default,,0,0,0,,not shown
        """)
        XCTAssertEqual(cues.map(\.text), ["Hello, world\nnext line", "Second"])
        XCTAssertEqual(cues.first?.start, 1.5)
        XCTAssertEqual(cues.first?.end, 3.25)
    }

    func testCuesBecomeWebVTTMappedOntoTheStream() {
        let vtt = AirPlaySubtitles.webVTT(cues: [
            SubtitleCue(start: 61.5, end: 63, text: "Line one\n\nline two"),
            SubtitleCue(start: 70, end: 69, text: "backwards, dropped"),
            SubtitleCue(start: 3725.001, end: 3726, text: "an --> arrow"),
        ], firstTimestamp: 126_000)
        XCTAssertEqual(vtt, """
        WEBVTT
        X-TIMESTAMP-MAP=MPEGTS:126000,LOCAL:00:00:00.000

        00:01:01.500 --> 00:01:03.000
        Line one
        line two

        01:02:05.001 --> 01:02:06.000
        an → arrow

        """)
    }

    func testTheRenditionIsAddedAndEveryVariantPointsAtIt() {
        let tag = AirPlaySubtitles.mediaTag(uri: "http://h/subs.m3u8?id=1", name: "English \"CC\"")
        XCTAssertEqual(tag, #"#EXT-X-MEDIA:TYPE=SUBTITLES,GROUP-ID="shirox-subs",NAME="English 'CC'",LANGUAGE="en",DEFAULT=YES,AUTOSELECT=YES,FORCED=NO,URI="http://h/subs.m3u8?id=1""#)
        XCTAssertFalse(AirPlaySubtitles.mediaTag(uri: "u", name: "Subtitles").contains("LANGUAGE="))
        let out = AirPlaySubtitles.inject(into: """
        #EXTM3U
        #EXT-X-STREAM-INF:BANDWIDTH=1,SUBTITLES="theirs",AUDIO="a"
        v1.m3u8
        #EXT-X-STREAM-INF:BANDWIDTH=2
        v2.m3u8
        """, mediaTag: tag)
        XCTAssertEqual(out.components(separatedBy: "\n"), [
            "#EXTM3U",
            tag,
            #"#EXT-X-STREAM-INF:BANDWIDTH=1,SUBTITLES="shirox-subs",AUDIO="a""#,
            "v1.m3u8",
            #"#EXT-X-STREAM-INF:BANDWIDTH=2,SUBTITLES="shirox-subs""#,
            "v2.m3u8",
        ])
    }

    func testTheLanguageComesFromTheTrackName() {
        XCTAssertEqual(AirPlaySubtitles.languageCode(forName: "English"), "en")
        XCTAssertEqual(AirPlaySubtitles.languageCode(forName: "English [CC]"), "en")
        XCTAssertEqual(AirPlaySubtitles.languageCode(forName: "Español (Latino)"), "es")
        XCTAssertEqual(AirPlaySubtitles.languageCode(forName: "Portuguese - Brazil"), "pt")
        XCTAssertEqual(AirPlaySubtitles.languageCode(forName: "pt-BR"), "pt")
        XCTAssertEqual(AirPlaySubtitles.languageCode(forName: "jpn"), "ja")
        XCTAssertEqual(AirPlaySubtitles.languageCode(forName: "Arabic"), "ar")
        XCTAssertNil(AirPlaySubtitles.languageCode(forName: "Subtitles"))
        XCTAssertNil(AirPlaySubtitles.languageCode(forName: "Default"))
    }

    func testAMediaPlaylistIsWrappedInAMaster() {
        let out = AirPlaySubtitles.wrap(mediaPlaylistURL: "http://h/proxy?url=x", mediaTag: "#TAG")
        XCTAssertEqual(out, "#EXTM3U\n#EXT-X-VERSION:3\n#TAG\n#EXT-X-STREAM-INF:BANDWIDTH=2000000,SUBTITLES=\"shirox-subs\"\nhttp://h/proxy?url=x")
        let playlist = AirPlaySubtitles.subtitlePlaylist(vttURL: "http://h/subs.vtt", duration: 1420.4)
        XCTAssertTrue(playlist.contains("#EXT-X-TARGETDURATION:1421"))
        XCTAssertTrue(playlist.contains("#EXTINF:1420.400,\nhttp://h/subs.vtt\n#EXT-X-ENDLIST"))
    }

    func testTheFirstTimestampOfATransportStream() {
        func packet(pts: Int64, adaptation: Bool) -> [UInt8] {
            var p = [UInt8](repeating: 0xFF, count: 188)
            p[0] = 0x47; p[1] = 0x41; p[2] = 0x00; p[3] = adaptation ? 0x30 : 0x10
            var at = 4
            if adaptation { p[4] = 7; at = 12 }
            let pes: [UInt8] = [0, 0, 1, 0xE0, 0, 0, 0x80, 0x80, 5]
            for (i, b) in pes.enumerated() { p[at + i] = b }
            let q = at + 9
            p[q] = UInt8(0x21 | ((pts >> 29) & 0x0E)); p[q + 1] = UInt8((pts >> 22) & 0xFF)
            p[q + 2] = UInt8(((pts >> 14) & 0xFE) | 1); p[q + 3] = UInt8((pts >> 7) & 0xFF)
            p[q + 4] = UInt8(((pts << 1) & 0xFE) | 1)
            return p
        }
        var nonStart = [UInt8](repeating: 0, count: 188); nonStart[0] = 0x47
        let data = Data(packet(pts: 133_200, adaptation: true) + nonStart + packet(pts: 126_000, adaptation: false))
        XCTAssertEqual(AirPlaySubtitles.firstTimestamp(transportStream: data), 126_000)
        XCTAssertNil(AirPlaySubtitles.firstTimestamp(transportStream: Data(nonStart)))
    }

    func testTheFirstTimestampOfAFragmentedMP4() {
        func box(_ type: String, _ payload: [UInt8]) -> [UInt8] {
            let n = UInt32(8 + payload.count)
            return [UInt8(n >> 24), UInt8(n >> 16 & 0xFF), UInt8(n >> 8 & 0xFF), UInt8(n & 0xFF)] + Array(type.utf8) + payload
        }
        // Timescale 16000 (version 0 mdhd); decode time 32000 → 2 s → 180000 at 90 kHz.
        let mdhd = box("mdhd", [0, 0, 0, 0] + [UInt8](repeating: 0, count: 8) + [0, 0, 0x3E, 0x80] + [0, 0, 0, 0])
        let initData = Data(box("ftyp", [0, 0, 0, 0]) + box("moov", box("mvhd", [0, 0, 0, 0]) + box("trak", box("mdia", mdhd))))
        let v0 = Data(box("styp", []) + box("moof", box("mfhd", [0, 0, 0, 0, 0, 0, 0, 1])
            + box("traf", box("tfhd", [0, 0, 0, 0]) + box("tfdt", [0, 0, 0, 0, 0, 0, 0x7D, 0x00]))))
        XCTAssertEqual(AirPlaySubtitles.firstTimestamp(fragmentedInit: initData, segment: v0), 180_000)
        // A 64-bit (version 1) tfdt.
        let v1 = Data(box("moof", box("traf", box("tfdt", [1, 0, 0, 0] + [0, 0, 0, 0, 0, 0, 0x7D, 0x00]))))
        XCTAssertEqual(AirPlaySubtitles.firstTimestamp(fragmentedInit: initData, segment: v1), 180_000)
        XCTAssertNil(AirPlaySubtitles.firstTimestamp(fragmentedInit: Data(), segment: v0))
    }
}

/// The libass overlay asked for a frame 30 times a second, paused or not, and between lines.
final class AssRendererSkipTests: XCTestCase {
    private let script = """
    [Script Info]
    ScriptType: v4.00+
    PlayResX: 640
    PlayResY: 360

    [V4+ Styles]
    Format: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, OutlineColour, BackColour, Bold, Italic, Underline, StrikeOut, ScaleX, ScaleY, Spacing, Angle, BorderStyle, Outline, Shadow, Alignment, MarginL, MarginR, MarginV, Encoding
    Style: Default,Helvetica,28,&H00FFFFFF,&H000000FF,&H00000000,&H00000000,0,0,0,0,100,100,0,0,1,2,0,2,10,10,10,1

    [Events]
    Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text
    Dialogue: 0,0:00:01.00,0:00:03.00,Default,,0,0,0,,{\\move(0,0,600,300)}Moving line
    Dialogue: 0,0:00:10.00,0:00:12.00,Default,,0,0,0,,Later line
    """
    private let canvas = CGSize(width: 640, height: 360)

    private func isFrame(_ r: AssRenderer.Rendered) -> Bool { if case .frame(.some) = r { return true }; return false }
    private func isUnchanged(_ r: AssRenderer.Rendered) -> Bool { if case .unchanged = r { return true }; return false }

    func testPausedOnAMovingLineDrawsOnce() throws {
        let renderer = try XCTUnwrap(AssRenderer(script: script))
        XCTAssertTrue(isFrame(renderer.render(at: 2, frameSize: canvas)))
        XCTAssertTrue(isUnchanged(renderer.render(at: 2, frameSize: canvas)), "the same instant again")
        XCTAssertTrue(isFrame(renderer.render(at: 2.1, frameSize: canvas)), "the line moves")
    }

    func testTheGapBetweenLinesIsSkippedAndTheNextLineStillAppears() throws {
        let renderer = try XCTUnwrap(AssRenderer(script: script))
        XCTAssertTrue(isFrame(renderer.render(at: 2, frameSize: canvas)))
        guard case .frame(nil) = renderer.render(at: 4, frameSize: canvas) else { return XCTFail("the line should clear") }
        XCTAssertTrue(isUnchanged(renderer.render(at: 5, frameSize: canvas)))
        XCTAssertTrue(isUnchanged(renderer.render(at: 9.9, frameSize: canvas)))
        XCTAssertTrue(isFrame(renderer.render(at: 10.5, frameSize: canvas)))
        XCTAssertTrue(isFrame(renderer.render(at: 1.5, frameSize: canvas)), "seeking back")
    }

    func testAForcedRedrawStillDraws() throws {
        let renderer = try XCTUnwrap(AssRenderer(script: script))
        XCTAssertTrue(isFrame(renderer.render(at: 2, frameSize: canvas)))
        XCTAssertTrue(isFrame(renderer.render(at: 2, frameSize: canvas, force: true)))
    }
}

/// Imported videos are copied in as `<UUID>-<name>`; the player titled them with the UUID.
final class LocalImportTitleTests: XCTestCase {
    func testTheImportPrefixIsDropped() {
        let dir = URL(fileURLWithPath: "/tmp/LocalImports")
        XCTAssertEqual(LocalPlaybackCoordinator.displayTitle(
            for: dir.appendingPathComponent("B0071143-E426-42CF-98DD-1003BB40A526-BigBuckBunny 512kb.mp4")),
                       "BigBuckBunny 512kb")
        XCTAssertEqual(LocalPlaybackCoordinator.displayTitle(for: dir.appendingPathComponent("My Show - 01.mkv")), "My Show - 01")
        XCTAssertEqual(LocalPlaybackCoordinator.displayTitle(
            for: dir.appendingPathComponent("NOT-A-UUID-AT-ALL-0000-000000000000-x.mp4")),
                       "NOT-A-UUID-AT-ALL-0000-000000000000-x")
        XCTAssertEqual(LocalPlaybackCoordinator.displayTitle(
            for: dir.appendingPathComponent("B0071143-E426-42CF-98DD-1003BB40A526.mp4")),
                       "B0071143-E426-42CF-98DD-1003BB40A526", "nothing after the UUID: keep it")
    }
}
