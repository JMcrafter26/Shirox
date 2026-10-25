import Combine

#if !os(tvOS)
import SwiftUI

struct DownloadRowView: View {
    let item: DownloadItem
    var onTap: () -> Void = {}

    var body: some View {
        HStack(spacing: 12) {
            // Minimal Cover
            CachedAsyncImage(urlString: item.imageUrl)
                .aspectRatio(2/3, contentMode: .fit)
                .frame(width: 50)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .shadow(radius: 2)

            VStack(alignment: .leading, spacing: 4) {
                Text(item.mediaTitle)
                    .font(.subheadline.weight(.bold))
                    .lineLimit(1)

                Text(item.episodeTitle ?? String(localized: "common.episode \(item.episodeNumber)"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                if item.state == .downloading {
                    HStack(spacing: 8) {
                        ProgressView(value: item.progress)
                            .tint(.red)
                            .scaleEffect(x: 1, y: 0.5)
                        
                        Text("\(Int(item.progress * 100))%")
                            .font(.system(size: 10, weight: .bold, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                } else if item.state == .failed {
                    Text(item.error ?? String(localized: "downloads.download_failed"))
                        .font(.caption2)
                        .foregroundStyle(.red)
                        .lineLimit(1)
                } else if item.state == .completed {
                    let fileFormat = (item.fileName as NSString?)?.pathExtension.uppercased() ?? "MP4"
                    HStack(spacing: 4) {
                        IconView(item.isHLS ? "folder.fill" : "play.circle.fill")
                        Text(item.isHLS ? String(localized: "downloads.local_hls") : String(localized: "downloads.format_video \(fileFormat)"))
                    }
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.green.opacity(0.8))
                }
            }

            Spacer()

            statusIcon
        }
        .contentShape(Rectangle())
        .onTapGesture {
            if item.state == .completed { onTap() }
        }
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch item.state {
        case .pending:
            IconView("hourglass").foregroundStyle(.secondary)
        case .downloading:
            ProgressView().controlSize(.small)
        case .paused:
            IconView("pause.circle.fill").foregroundStyle(.secondary)
        case .completed:
            IconView("play.fill")
                .foregroundStyle(Color.primary)
                .colorInvert()
                .font(.system(size: 12))
                .padding(8)
                .background(Color.primary, in: Circle())
        case .failed:
            IconView("exclamationmark.triangle.fill").foregroundStyle(.red)
        }
    }
}
#endif
