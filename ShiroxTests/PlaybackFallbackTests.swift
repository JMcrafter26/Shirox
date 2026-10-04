import XCTest
import AVFoundation
@testable import Shirox

/// Which engine plays a stream, and what happens when one fails.
final class PlaybackFallbackTests: XCTestCase {

    private func url(_ string: String) -> URL { URL(string: string)! }

    // MARK: - Starting engine

    func testTheChosenEngineIsUsed() {
        XCTAssertEqual(PlaybackFallback.initialEngine(preferred: .native, url: url("https://cdn.example/ep1.m3u8")), .native)
        XCTAssertEqual(PlaybackFallback.initialEngine(preferred: .mpv, url: url("https://cdn.example/ep1.m3u8")), .mpv)
    }

    /// Containers AVPlayer can't open go straight to MPV, whatever the setting says.
    func testAFileAVPlayerCantOpenStartsOnMPV() {
        XCTAssertEqual(PlaybackFallback.initialEngine(preferred: .native, url: url("https://cdn.example/ep1.mkv")), .mpv)
        XCTAssertEqual(PlaybackFallback.initialEngine(preferred: .native, url: url("file:///tmp/Episode%201.MKV")), .mpv)
        XCTAssertEqual(PlaybackFallback.initialEngine(preferred: .native, url: url("https://cdn.example/a.webm?token=1")), .mpv)
        XCTAssertEqual(PlaybackFallback.initialEngine(preferred: .native, url: url("https://cdn.example/ep1.mp4")), .native)
    }

    // MARK: - Format errors

    private func avError(_ code: AVError.Code) -> NSError {
        NSError(domain: AVFoundationErrorDomain, code: code.rawValue)
    }

    func testAVFoundationsFormatErrorsAreRecognised() {
        for code in [AVError.fileFormatNotRecognized, .failedToParse, .decodeFailed, .decoderNotFound, .formatUnsupported] {
            XCTAssertTrue(PlaybackFallback.isUnsupportedFormat(avError(code)), "\(code)")
        }
    }

    func testOtherErrorsAreNotFormatErrors() {
        XCTAssertFalse(PlaybackFallback.isUnsupportedFormat(NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut)))
        XCTAssertFalse(PlaybackFallback.isUnsupportedFormat(avError(.contentIsUnavailable)))
        XCTAssertFalse(PlaybackFallback.isUnsupportedFormat(nil))
    }

    /// AVFoundation often wraps the real reason one or two levels down.
    func testAFormatErrorUnderneathAnotherIsFound() {
        let wrapped = NSError(domain: AVFoundationErrorDomain, code: AVError.unknown.rawValue, userInfo: [
            NSUnderlyingErrorKey: NSError(domain: "CoreMediaErrorDomain", code: -1, userInfo: [
                NSUnderlyingErrorKey: avError(.fileFormatNotRecognized),
            ]),
        ])
        XCTAssertTrue(PlaybackFallback.isUnsupportedFormat(wrapped))
    }

    // MARK: - Decisions

    private let network = NSError(domain: NSURLErrorDomain, code: NSURLErrorBadServerResponse)

    func testNativeOnAFormatErrorSwitchesToMPVAtOnce() {
        XCTAssertEqual(PlaybackFallback.decision(after: avError(.fileFormatNotRecognized), engine: .native,
                                                 canRefetch: true, hasRefetched: false), .switchToMPV)
    }

    func testNativeOnAnyOtherFailureRefetchesFirst() {
        XCTAssertEqual(PlaybackFallback.decision(after: network, engine: .native,
                                                 canRefetch: true, hasRefetched: false), .refetch)
    }

    /// A fresh URL that fails too, or one there's no way to get, is MPV's turn.
    func testNativeAfterARefetchOrWithoutOneSwitchesToMPV() {
        XCTAssertEqual(PlaybackFallback.decision(after: network, engine: .native,
                                                 canRefetch: true, hasRefetched: true), .switchToMPV)
        XCTAssertEqual(PlaybackFallback.decision(after: network, engine: .native,
                                                 canRefetch: false, hasRefetched: false), .switchToMPV)
    }

    func testMPVRefetchesOnceThenGivesUp() {
        XCTAssertEqual(PlaybackFallback.decision(after: network, engine: .mpv,
                                                 canRefetch: true, hasRefetched: false), .refetch)
        XCTAssertEqual(PlaybackFallback.decision(after: network, engine: .mpv,
                                                 canRefetch: true, hasRefetched: true), .giveUp)
        XCTAssertEqual(PlaybackFallback.decision(after: network, engine: .mpv,
                                                 canRefetch: false, hasRefetched: false), .giveUp)
    }

    // MARK: - Waiting

    /// mpv gives up on a dead source by itself, so while it's opening a stream the wait is left
    /// to it: a far-away server took 15 s, and Retry came up just before it would have played.
    func testMPVOpeningIsLeftToFinish() {
        XCTAssertTrue(PlaybackFallback.waitIsOpening(engine: .mpv, isItemReady: false, isItemFailed: false))
        XCTAssertFalse(PlaybackFallback.waitIsOpening(engine: .mpv, isItemReady: true, isItemFailed: false))
        XCTAssertFalse(PlaybackFallback.waitIsOpening(engine: .mpv, isItemReady: false, isItemFailed: true))
        XCTAssertNotNil(PlaybackFallback.openingPatience(for: .mpv))
    }

    /// AVPlayer can wait forever on a wedged request, so its waits stay the watchdog's.
    func testAVPlayerOpeningIsStillWatched() {
        XCTAssertFalse(PlaybackFallback.waitIsOpening(engine: .native, isItemReady: false, isItemFailed: false))
        XCTAssertNil(PlaybackFallback.openingPatience(for: .native))
    }

    /// A wait is a stall only if nothing moved: a moved playhead is a seek landing, a grown
    /// buffer a slow connection catching up.
    func testAWaitIsAStallOnlyIfNothingMoved() {
        XCTAssertTrue(PlaybackFallback.isStalled(playheadMoved: 0, bufferGrew: 0))
        XCTAssertTrue(PlaybackFallback.isStalled(playheadMoved: 0.2, bufferGrew: 0.2))
        XCTAssertFalse(PlaybackFallback.isStalled(playheadMoved: 0, bufferGrew: 3))
        XCTAssertFalse(PlaybackFallback.isStalled(playheadMoved: 12, bufferGrew: 0))
        XCTAssertFalse(PlaybackFallback.isStalled(playheadMoved: -12, bufferGrew: 0))
    }

    // MARK: - Segment failures

    /// mpv skipping failed segments to EOF looked like the episode ending: the player advanced
    /// from the middle of episode 207 after a phone call.
    func testRepeatedSegmentFailuresMeanADeadStream() {
        var watch = SegmentFailureWatch()
        let start = Date()
        let line = "[ffmpeg/demuxer] hls: Failed to open segment 412 of playlist 0"
        XCTAssertFalse(watch.record(line, position: 830, at: start))
        XCTAssertFalse(watch.record(line, position: 836, at: start.addingTimeInterval(1)))
        XCTAssertTrue(watch.record(line, position: 842, at: start.addingTimeInterval(2)))
        // The viewer goes back to where it started failing, not where the skipping got to.
        XCTAssertEqual(watch.positionBeforeFailures, 830)
        XCTAssertTrue(watch.endIsFailure(at: start.addingTimeInterval(5)))
    }

    /// One bad segment in a healthy stream isn't a dead stream, and a later real ending is real.
    func testAnOldSingleFailureDoesntSpoilTheEnding() {
        var watch = SegmentFailureWatch()
        let start = Date()
        XCTAssertFalse(watch.record("[ffmpeg/demuxer] hls: Failed to open segment 3 of playlist 0", position: 20, at: start))
        XCTAssertFalse(watch.record("[cplayer] some other warning", position: 30, at: start))
        XCTAssertFalse(watch.endIsFailure(at: start.addingTimeInterval(1400)))
        // A new run of failures much later starts counting from its own position.
        XCTAssertFalse(watch.record("[ffmpeg/demuxer] hls: Failed to open segment 300 of playlist 0", position: 1200, at: start.addingTimeInterval(1200)))
        XCTAssertEqual(watch.positionBeforeFailures, 1200)
    }

    /// A few corrupt packets at a stream's start failed VideoToolbox three frames running, and
    /// mpv decoded the rest of the film in software: ~45% CPU at 1080p on an iPhone 16.
    func testSoftwareDecodingTriesHardwareAgainTenSecondsOn() {
        var retry = HardwareDecodeRetry()
        retry.decoderChanged(toHardware: false, at: 494)
        XCTAssertFalse(retry.shouldRetry(at: 500))
        XCTAssertTrue(retry.shouldRetry(at: 504))
        // Once per fallback, not on every tick after.
        XCTAssertFalse(retry.shouldRetry(at: 505))
    }

    /// A file VideoToolbox can't decode at all fails the retry at once: give up on it then,
    /// rather than interrupting it every ten seconds.
    func testARetryThatFailsAtOnceGivesUpOnTheFile() {
        var retry = HardwareDecodeRetry()
        retry.decoderChanged(toHardware: false, at: 0)
        XCTAssertTrue(retry.shouldRetry(at: 10))
        retry.decoderChanged(toHardware: false, at: 10.2)
        XCTAssertFalse(retry.shouldRetry(at: 25))
        XCTAssertFalse(retry.shouldRetry(at: 600))
    }

    /// A retry that worked doesn't use up the next one: corruption later in the film is retried too.
    func testALaterFallbackAfterAWorkingRetryIsRetried() {
        var retry = HardwareDecodeRetry()
        retry.decoderChanged(toHardware: false, at: 494)
        XCTAssertTrue(retry.shouldRetry(at: 504))
        retry.decoderChanged(toHardware: true, at: 504.3)
        retry.decoderChanged(toHardware: false, at: 1300)
        XCTAssertTrue(retry.shouldRetry(at: 1310))
    }

    /// The wait is playback time: no retry while paused, or after seeking back before the fallback.
    func testTheWaitIsPlaybackTime() {
        var retry = HardwareDecodeRetry()
        retry.decoderChanged(toHardware: false, at: 494)
        XCTAssertFalse(retry.shouldRetry(at: 494))
        XCTAssertFalse(retry.shouldRetry(at: 100))
        XCTAssertTrue(retry.shouldRetry(at: 504))
    }

    /// Hardware decoding from the start never retries, and a new file starts with a clean slate.
    func testHardwareDecodingNeverRetriesAndANewFileStartsOver() {
        var retry = HardwareDecodeRetry()
        retry.decoderChanged(toHardware: true, at: 0)
        XCTAssertFalse(retry.shouldRetry(at: 60))
        retry.decoderChanged(toHardware: false, at: 0)
        XCTAssertTrue(retry.shouldRetry(at: 10))
        retry.decoderChanged(toHardware: false, at: 10.1)
        retry.reset()
        retry.decoderChanged(toHardware: false, at: 0)
        XCTAssertTrue(retry.shouldRetry(at: 10))
    }
}
