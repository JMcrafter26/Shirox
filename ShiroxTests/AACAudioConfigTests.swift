#if !os(tvOS)
import XCTest
import AVFoundation
@testable import Shirox

/// Reported: downloads from AnimePahe played silent on the native player and fine on MPV. Its
/// streams' ADTS headers say "AAC Main" (config 0B 08), which went into the MP4 as it was; the
/// audio is really HE-AAC v2, and Apple's decoder refuses Main outright ('fmt?').
final class AACAudioConfigTests: XCTestCase {
    func testReadsAnimePahesConfigAsMain() throws {
        let config = try XCTUnwrap(AACAudioConfig(audioSpecificConfig: [0x0B, 0x08]))
        XCTAssertEqual(config, AACAudioConfig(objectType: 1, sampleRate: 24000, channelConfiguration: 1, extensionSampleRate: nil))
    }

    func testAMonoCoreAtTwiceTheRateIsHEAACv2() throws {
        let current = try XCTUnwrap(AACAudioConfig(audioSpecificConfig: [0x0B, 0x08]))
        let fixed = current.explicit(decodedRate: 48000)
        XCTAssertEqual(fixed.objectType, 29)
        XCTAssertEqual(fixed.extensionSampleRate, 48000)
        // 29 | 24 kHz | mono | 48 kHz | LC | GASpecificConfig
        XCTAssertEqual(fixed.bytes, [0xEB, 0x09, 0x88, 0x00])
        XCTAssertTrue(current.needsReplacing(by: fixed))
        XCTAssertEqual(AACAudioConfig(audioSpecificConfig: fixed.bytes), fixed)
    }

    func testSBRAloneIsHEAAC() {
        let current = AACAudioConfig(objectType: 2, sampleRate: 22050, channelConfiguration: 2, extensionSampleRate: nil)
        let fixed = current.explicit(decodedRate: 44100)
        XCTAssertEqual(fixed.objectType, 5)
        XCTAssertEqual(fixed.extensionSampleRate, 44100)
        XCTAssertTrue(current.needsReplacing(by: fixed))
    }

    func testPlainLCIsLeftAlone() throws {
        // 2 | 48 kHz | stereo: the config of nearly every download.
        let current = try XCTUnwrap(AACAudioConfig(audioSpecificConfig: [0x11, 0x90]))
        let fixed = current.explicit(decodedRate: 48000)
        XCTAssertEqual(fixed, current)
        XCTAssertEqual(fixed.bytes, [0x11, 0x90])
        XCTAssertFalse(current.needsReplacing(by: fixed))
    }

    func testMainWithoutSBRBecomesLC() {
        let current = AACAudioConfig(objectType: 1, sampleRate: 44100, channelConfiguration: 2, extensionSampleRate: nil)
        let fixed = current.explicit(decodedRate: 44100)
        XCTAssertEqual(fixed.objectType, 2)
        XCTAssertTrue(current.needsReplacing(by: fixed))
    }

    func testReadsAnADTSHeader() throws {
        // Main, 24 kHz, mono, no CRC — as AnimePahe's segments have it.
        let header: [UInt8] = [0xFF, 0xF1, 0x18, 0x40, 0x1F, 0xFF, 0xFC]
        let parsed = try XCTUnwrap(ADTSHeader(header))
        XCTAssertEqual(parsed.profile, 0)
        XCTAssertEqual(parsed.length, 7)
        XCTAssertEqual(parsed.extraRawBlocks, 0)
        XCTAssertEqual(AACAudioConfig(adtsHeader: header),
                       AACAudioConfig(objectType: 1, sampleRate: 24000, channelConfiguration: 1, extensionSampleRate: nil))
        XCTAssertNil(ADTSHeader([0x47, 0x40, 0x11, 0x10, 0x00, 0x00, 0x00]), "a TS packet isn't one")
    }

    /// End to end: a download whose segments carry HE-AAC v2 under ADTS headers that say Main,
    /// made into one file, plays on Apple's decoder.
    func testAMislabelledHEAACv2DownloadPlaysOnTheNativeDecoder() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("aac-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        // 6 s of tone made with `afconvert -f adts -d aacp@48000 -b 32000`: HE-AAC v2 on a
        // 24 kHz mono core, as AnimePahe's audio is. The simulator has no encoder for it.
        let fixture = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "he-aac-v2-tone", withExtension: "aac"))
        let segment = folder.appendingPathComponent("seg_0.aac")
        try FileManager.default.copyItem(at: fixture, to: segment)
        try Self.relabelAsMain(segment)
        let playlist = HLSManifestParser.localManifest(durations: [6], segmentExtension: "aac", initFileName: nil)
        try playlist.write(to: folder.appendingPathComponent("playlist.m3u8"), atomically: true, encoding: .utf8)

        let output = try MediaRemuxer.remux(input: folder.appendingPathComponent("playlist.m3u8"),
                                            toStem: folder.appendingPathComponent("episode"))
        XCTAssertEqual(output.pathExtension, "mp4")
        let decoded = try await Self.decode(output)
        XCTAssertGreaterThan(decoded.frames, 48000 * 4, "about 6 s at 48 kHz")
        XCTAssertGreaterThan(decoded.peak, 1000, "audible")
        XCTAssertEqual(decoded.rate, 48000)
    }

    // MARK: - Fixture

    /// Sets every ADTS header's profile to Main, as AnimePahe's are.
    static func relabelAsMain(_ url: URL) throws {
        var bytes = [UInt8](try Data(contentsOf: url))
        var offset = 0
        var frames = 0
        while offset + 7 <= bytes.count, let header = ADTSHeader(Array(bytes[offset..<offset + 7])) {
            bytes[offset + 2] &= 0x3F
            offset += max(header.frameLength, 7)
            frames += 1
        }
        XCTAssertGreaterThan(frames, 100)
        try Data(bytes).write(to: url)
    }

    static func channels(_ url: URL) async throws -> UInt32 {
        let track = try await AVURLAsset(url: url).loadTracks(withMediaType: .audio).first
        let format = try await track?.load(.formatDescriptions).first
        return format.flatMap { CMAudioFormatDescriptionGetStreamBasicDescription($0)?.pointee.mChannelsPerFrame } ?? 0
    }

    static func decode(_ url: URL) async throws -> (frames: Int, peak: Int16, rate: Double) {
        let asset = AVURLAsset(url: url)
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        let track = try XCTUnwrap(tracks.first)
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false,
        ])
        reader.add(output)
        reader.startReading()
        var frames = 0, peak: Int16 = 0, rate = 0.0
        while let buffer = output.copyNextSampleBuffer() {
            if let format = CMSampleBufferGetFormatDescription(buffer),
               let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee {
                rate = asbd.mSampleRate
            }
            frames += CMSampleBufferGetNumSamples(buffer)
            guard let block = CMSampleBufferGetDataBuffer(buffer) else { continue }
            var length = 0
            var pointer: UnsafeMutablePointer<CChar>?
            CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &length, dataPointerOut: &pointer)
            pointer?.withMemoryRebound(to: Int16.self, capacity: length / 2) { samples in
                for i in 0..<(length / 2) { peak = max(peak, samples[i] == .min ? .max : abs(samples[i])) }
            }
        }
        XCTAssertEqual(reader.status, .completed, "\(String(describing: reader.error))")
        return (frames, peak, rate)
    }
}
#endif
