import SwiftUI

struct EpisodeRowView: View {
    let episode: EpisodeLink
    var progress: Double? = nil
    let onTap: () -> Void
    var onMarkWatched: (() -> Void)? = nil
    var onMarkUnwatched: (() -> Void)? = nil
    var onResetProgress: (() -> Void)? = nil
    var onDownload: (() -> Void)? = nil
    var onDeleteDownload: (() -> Void)? = nil
    /// The finished download's file, for Share and Show in Files.
    var downloadedFile: URL? = nil
    var onTryOtherStream: (() -> Void)? = nil
    var isSelectionMode: Bool = false
    var isSelected: Bool = false
    var downloadState: DownloadState? = nil

    private var isComplete: Bool { (progress ?? 0) >= 0.9 }

    // Adaptive background color that works in both light and dark mode
    private var adaptiveBackground: Color {
        #if os(iOS)
        Color(uiColor: .systemBackground)
        #elseif os(tvOS)
        Color.clear
        #else
        Color(nsColor: .windowBackgroundColor)
        #endif
    }

    var body: some View {
        Button(action: onTap) {
            VStack(spacing: 0) {
                HStack(spacing: 14) {
                    if isSelectionMode {
                        ZStack {
                            Circle()
                                .strokeBorder(isSelected ? Color.primary : Color.secondary.opacity(0.35), lineWidth: 2)
                                .frame(width: 40, height: 40)
                            if isSelected {
                                Circle()
                                    .fill(Color.primary)
                                    .frame(width: 40, height: 40)
                                IconView("checkmark")
                                    .font(.caption2.weight(.bold))
                                    .foregroundStyle(adaptiveBackground)   // ← white → adaptiveBackground
                            }
                        }
                    } else {
                        ZStack {
                            Circle()
                                .fill(isComplete ? Color.green : Color.primary)
                                .frame(width: 40, height: 40)
                            if isComplete {
                                IconView("checkmark")
                                    .font(.caption2.weight(.bold))
                                    .foregroundStyle(.white)   // green is dark enough in both modes
                            } else {
                                Text(episode.displayNumber)
                                    .font(.footnote.weight(.bold))
                                    .foregroundStyle(adaptiveBackground)
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.4)
                                    .frame(width: 34)
                            }
                        }
                        .shadow(color: (isComplete ? Color.green : Color.primary).opacity(0.3),
                                radius: 4, y: 2)
                    }

                    Text("common.episode \(episode.displayNumber)")
                        .font(.callout.weight(.medium))
                        .foregroundStyle(.primary)

                    // Selection mode swaps the numbered circle for a checkbox and hides both
                    // the progress bar and the trailing status icons — which left the batch
                    // screens with no way to tell watched episodes from unwatched ones while
                    // picking. Restore that cue next to the title, where it doesn't collide
                    // with the checkbox.
                    if isSelectionMode {
                        if isComplete {
                            IconView("checkmark.circle.fill")
                                .font(.caption)
                                .foregroundStyle(.green)
                                .accessibilityLabel("detail.watched")
                        } else if let p = progress, p > 0 {
                            Text("\(Int(p * 100))%")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.secondary)
                                .accessibilityLabel("detail.percent_watched \(Int(p * 100))")
                        }
                    }

                    Spacer()

                    if !isSelectionMode {
                        HStack(spacing: 8) {
                            if let state = downloadState {
                                Group {
                                    switch state {
                                    case .completed:
                                        IconView("checkmark.circle.fill")
                                            .foregroundStyle(.green)
                                    case .downloading:
                                        ProgressView().controlSize(.small)
                                    case .pending:
                                        IconView("hourglass")
                                            .foregroundStyle(.secondary)
                                    case .paused:
                                        IconView("pause.circle.fill")
                                            .foregroundStyle(.secondary)
                                    case .failed:
                                        IconView("exclamationmark.circle.fill")
                                            .foregroundStyle(.red)
                                    }
                                }
                                .font(.system(size: 16))
                            }

                            IconView("play.fill")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.primary)
                                .padding(8)
                                .background(Color.primary.opacity(0.1), in: Circle())
                        }
                    }
                }
                .padding(.horizontal, 14)
                .padding(.top, 12)
                .padding(.bottom, (progress ?? 0) > 0 && !isComplete && !isSelectionMode ? 6 : 12)

                if let p = progress, p > 0, !isComplete, !isSelectionMode {
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Color.secondary.opacity(0.15))
                            Capsule()
                                .fill(Color.primary)
                                .frame(width: geo.size.width * p)
                        }
                        .frame(height: 3)
                    }
                    .frame(height: 3)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 8)
                }
            }
            .background(
                isSelectionMode && isSelected
                    ? Color.primary.opacity(0.08)
                    : Color.secondary.opacity(0.07),
                in: RoundedRectangle(cornerRadius: 14)
            )
            .contentShape(RoundedRectangle(cornerRadius: 14))
            .opacity(isSelectionMode && (downloadState == .completed || downloadState == .downloading || downloadState == .pending) ? 0.5 : 1.0)
        }
        .buttonStyle(EpisodePressStyle())
        .contextMenu {
            if !isSelectionMode {
                if isComplete {
                    Button { onMarkUnwatched?() } label: {
                        Label("detail.mark_as_unwatched", icon: "xmark.circle")
                    }
                } else {
                    Button { onMarkWatched?() } label: {
                        Label("detail.mark_as_watched", icon: "checkmark.circle")
                    }
                }
                if let onTryOtherStream {
                    Divider()
                    Button { onTryOtherStream() } label: {
                        Label("detail.try_other_stream", icon: "arrow.triangle.2.circlepath")
                    }
                }
                if let onResetProgress, progress != nil {
                    Divider()
                    Button(role: .destructive) { onResetProgress() } label: {
                        Label("detail.reset_progress", icon: "arrow.counterclockwise")
                    }
                }
                if let onDownload {
                    Divider()
                    Button { onDownload() } label: {
                        Label("detail.download_episode", icon: "arrow.down.circle")
                    }
                    .disabled(downloadState == .completed || downloadState == .downloading || downloadState == .pending)
                }
                #if !os(tvOS)
                if let downloadedFile {
                    Divider()
                    DownloadFileMenuItems(file: downloadedFile)
                }
                #endif
                if let onDeleteDownload {
                    Divider()
                    Button(role: .destructive) { onDeleteDownload() } label: {
                        Label("detail.delete_download", icon: "trash")
                    }
                }
            }
        }
    }
}

private struct EpisodePressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1.0)
            .opacity(configuration.isPressed ? 0.92 : 1.0)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}
