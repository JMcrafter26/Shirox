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
    /// The most the panel may take up and down. On a phone in landscape it's far taller than
    /// the screen, and the fields below the first few ran off it; past this they scroll.
    var maxHeight: CGFloat = .infinity
    @State private var stats = PlaybackStats()
    /// The fields' own height, so the panel hugs them when they fit and scrolls when they don't.
    @State private var fieldsHeight: CGFloat = 0
    @State private var headerHeight: CGFloat = 0

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
            .background(GeometryReader { geo in
                Color.clear.preference(key: InfoPanelHeaderHeightKey.self, value: geo.size.height)
            })
            ScrollView(showsIndicators: true) {
                fields
                    .background(GeometryReader { geo in
                        Color.clear.preference(key: InfoPanelFieldsHeightKey.self, value: geo.size.height)
                    })
            }
            .frame(height: fieldsFrameHeight)
        }
        .onPreferenceChange(InfoPanelFieldsHeightKey.self) { fieldsHeight = $0 }
        .onPreferenceChange(InfoPanelHeaderHeightKey.self) { headerHeight = $0 }
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

    /// The fields' own height, or what's left of `maxHeight` under the header if that's less.
    private var fieldsFrameHeight: CGFloat {
        let padding: CGFloat = (isPad ? 20 : 14) * 2
        let spacing: CGFloat = isPad ? 16 : 12
        let room = maxHeight - padding - headerHeight - spacing
        return max(min(fieldsHeight, room), 60)
    }

    private var fields: some View {
        VStack(alignment: .leading, spacing: isPad ? 16 : 12) {
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
        .frame(maxWidth: .infinity, alignment: .leading)
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

private struct InfoPanelFieldsHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

private struct InfoPanelHeaderHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}
