import XCTest
import AVFoundation
import UniformTypeIdentifiers
@testable import Shirox

/// Test media made on the spot.
enum TestVideo {
    /// An H.264 clip of changing grey frames, ten a second, 320×180, in the temporary directory.
    /// The caller removes it.
    static func make(seconds: Int) async throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("test-video-\(UUID().uuidString).mp4")
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        try await write(seconds: seconds, keyframeEvery: nil, to: writer)
        return url
    }

    /// The same clip as a downloaded HLS episode: a folder of fMP4 segments with the playlist
    /// `HLSDownloader` writes for one, `playlist.m3u8`. The caller removes the folder.
    static func makeHLS(seconds: Int, segmentSeconds: Int) async throws -> URL {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("test-hls-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let writer = AVAssetWriter(contentType: .mpeg4Movie)
        writer.outputFileTypeProfile = .mpeg4AppleHLS
        writer.preferredOutputSegmentInterval = CMTime(value: CMTimeValue(segmentSeconds), timescale: 1)
        writer.initialSegmentStartTime = .zero
        let segments = SegmentCollector()
        writer.delegate = segments
        // A keyframe a second, so every segment can start on one.
        try await write(seconds: seconds, keyframeEvery: 10, to: writer)

        let initData = try XCTUnwrap(segments.initialization, "the writer produced no init segment")
        try initData.write(to: folder.appendingPathComponent("init.mp4"))
        for (index, segment) in segments.media.enumerated() {
            try segment.data.write(to: folder.appendingPathComponent("seg_\(index).m4s"))
        }
        let playlist = HLSManifestParser.localManifest(durations: segments.media.map(\.duration),
                                                       segmentExtension: "m4s", initFileName: "init.mp4")
        try playlist.write(to: folder.appendingPathComponent("playlist.m3u8"), atomically: true, encoding: .utf8)
        return folder
    }

    private static func write(seconds: Int, keyframeEvery: Int?, to writer: AVAssetWriter) async throws {
        var settings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: 320,
            AVVideoHeightKey: 180,
        ]
        if let keyframeEvery {
            settings[AVVideoCompressionPropertiesKey] = [AVVideoMaxKeyFrameIntervalKey: keyframeEvery]
        }
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: 320,
            kCVPixelBufferHeightKey as String: 180,
        ])
        writer.add(input)
        XCTAssertTrue(writer.startWriting())
        writer.startSession(atSourceTime: .zero)
        for frame in 0..<(seconds * 10) {
            while !input.isReadyForMoreMediaData { try await Task.sleep(nanoseconds: 1_000_000) }
            var buffer: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, try XCTUnwrap(adaptor.pixelBufferPool), &buffer)
            let pixels = try XCTUnwrap(buffer)
            CVPixelBufferLockBaseAddress(pixels, [])
            memset(CVPixelBufferGetBaseAddress(pixels), Int32(40 + frame * 3 % 200), CVPixelBufferGetDataSize(pixels))
            CVPixelBufferUnlockBaseAddress(pixels, [])
            adaptor.append(pixels, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: 10))
        }
        input.markAsFinished()
        await writer.finishWriting()
        XCTAssertEqual(writer.status, .completed, String(describing: writer.error))
    }

    /// Collects what an HLS-profile writer hands its delegate: one init segment, then media.
    private final class SegmentCollector: NSObject, AVAssetWriterDelegate {
        var initialization: Data?
        var media: [(data: Data, duration: Double)] = []

        func assetWriter(_ writer: AVAssetWriter, didOutputSegmentData segmentData: Data,
                         segmentType: AVAssetSegmentType, segmentReport: AVAssetSegmentReport?) {
            switch segmentType {
            case .initialization:
                initialization = segmentData
            case .separable:
                let duration = segmentReport?.trackReports.first?.duration.seconds ?? 0
                media.append((segmentData, duration))
            @unknown default:
                break
            }
        }
    }
}
