import SwiftUI

/// What's playing, by the numbers: the video's codec, resolution, frame rate and bitrate, the
/// audio's, the subtitles', and how the stream is arriving. Read from the engine every second
/// while it's open.
struct PlayerVideoInfoPanel: View {
    let engine: any PlaybackEngine
    /// The audio track's name, when the source has a choice of them.
    var audioTrack: String?
    /// The subtitle track on screen and where it comes from; nil when none is.
    var subtitle: (name: String, source: String)?
    var onClose: () -> Void
    @State private var stats = PlaybackStats()

    private var isPad: Bool {
        #if os(iOS)
        return UIDevice.current.userInterfaceIdiom == .pad
        #else
        return false
        #endif
    }

    private struct Field: Identifiable {
        let label: String
        let value: String
        var id: String { label }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: isPad ? 16 : 12) {
            HStack {
                Text("Video Details")
                    .font(.system(size: isPad ? 17 : 15, weight: .semibold))
                Spacer()
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .bold))
                        .frame(width: 26, height: 26)
                        .background(Color.white.opacity(0.15), in: Circle())
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Close Video Details")
            }
            section("Video", [
                field("Codec", stats.videoCodec),
                field("Resolution", stats.resolutionText),
                field("Frame Rate", stats.frameRateText),
                field("Bitrate", PlaybackStats.bitrateText(stats.videoBitrate)),
                field("Dropped Frames", stats.droppedFrames.map(String.init)),
            ])
            section("Audio", [
                field("Codec", stats.audioCodec),
                field("Channels", stats.channelsText),
                field("Sample Rate", stats.sampleRateText),
                field("Bitrate", PlaybackStats.bitrateText(stats.audioBitrate)),
                field("Track", audioTrack),
            ])
            if let subtitle {
                section("Subtitle", [field("Name", subtitle.name), field("Source", subtitle.source)])
            }
            section("Stream", [
                field("Player", stats.player),
                field("Stream Bitrate", PlaybackStats.bitrateText(stats.streamBitrate)),
                field("Network", PlaybackStats.bitrateText(stats.throughput)),
            ])
        }
        .foregroundStyle(.white)
        .padding(isPad ? 20 : 14)
        .frame(maxWidth: isPad ? 620 : 520, alignment: .leading)
        .background(Color.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .task {
            while !Task.isCancelled {
                stats = await engine.stats()
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
    }

    private func field(_ label: String, _ value: String?) -> Field? {
        guard let value, !value.isEmpty else { return nil }
        return Field(label: label, value: value)
    }

    /// A heading over its fields, laid out in as many columns as fit; one with nothing known yet
    /// says so rather than vanishing.
    private func section(_ title: String, _ fields: [Field?]) -> some View {
        let known = fields.compactMap { $0 }
        return VStack(alignment: .leading, spacing: 6) {
            Text(title.uppercased())
                .font(.system(size: isPad ? 13 : 11, weight: .bold))
                .tracking(0.8)
                .foregroundStyle(.white.opacity(0.55))
            if known.isEmpty {
                Text("Not known yet")
                    .font(.system(size: isPad ? 15 : 13))
                    .foregroundStyle(.white.opacity(0.7))
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: isPad ? 130 : 104), alignment: .topLeading)],
                          alignment: .leading, spacing: 8) {
                    ForEach(known) { field in
                        VStack(alignment: .leading, spacing: 1) {
                            Text(field.label)
                                .font(.system(size: isPad ? 13 : 11))
                                .foregroundStyle(.white.opacity(0.6))
                            Text(field.value)
                                .font(.system(size: isPad ? 17 : 14, weight: .semibold))
                                .lineLimit(1)
                                .minimumScaleFactor(0.7)
                        }
                    }
                }
            }
        }
    }
}
