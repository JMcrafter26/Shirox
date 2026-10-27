import Combine

#if !os(tvOS)
import SwiftUI

struct BatchDownloadStreamPickerView: View {
    let mediaTitle: String
    let imageUrl: String
    var aniListID: Int?
    let moduleId: String?
    let episodes: [EpisodeLink]  // full EpisodeLink list so we can match by number
    let episodeNumbers: [Int]    // the selected subset to download
    let onDismiss: () -> Void

    @State private var streams: [StreamResult] = []
    @State private var firstEpisodeHref: String?
    @State private var isLoading = true
    @State private var error: String?
    @State private var cloudflareURL: URL?

    var body: some View {
        NavigationStack {
            Group {
                if isLoading {
                    VStack(spacing: 14) {
                        ProgressView()
                        Text("common.fetching_streams")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if cloudflareURL != nil {
                    CloudflareVerifyView { Task { await verifyCloudflare() } }
                } else if let error {
                    ContentUnavailableView(
                        "downloads.failed_to_load",
                        systemImage: "antenna.radiowaves.left.and.right.slash",
                        description: Text(error)
                    )
                } else {
                    List(streams, id: \.url) { stream in
                        Button {
                            startBatchDownload(streamTitle: stream.title)
                            onDismiss()
                        } label: {
                            HStack(spacing: 12) {
                                IconView("arrow.down.circle.fill")
                                    .font(.system(size: 32))
                                    .foregroundStyle(.primary)
                                StreamRowText(stream: stream)
                                Spacer()
                            }
                            .contentShape(Rectangle())
                            .padding(.vertical, 6)
                        }
                        .buttonStyle(.plain)
                    }
                    .softScrollEdges()
                    #if os(iOS)
                    .listStyle(.insetGrouped)
                    #else
                    .listStyle(.inset)
                    #endif
                }
            }
            .navigationTitle("downloads.download_episodes \(episodeNumbers.count)")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("common.cancel") { onDismiss() }
                }
            }
            .appTint()
        }
        #if os(iOS)
        .adaptivePresentationDetents([.medium, .large])

        #else

        .macSheetFrame()

        #endif
        .task { await loadStreams() }
    }

    private func loadStreams() async {
        isLoading = true
        error = nil
        cloudflareURL = nil
        CloudflareBypassManager.shared.pendingVerificationURL = nil
        guard let firstEpNum = episodeNumbers.first,
              let episode = episodes.first(where: { Int($0.number) == firstEpNum }) else {
            error = String(localized: "downloads.could_not_find_the_episode")
            isLoading = false
            return
        }
        do {
            let result = try await JSEngine.shared.fetchStreams(episodeUrl: episode.href)
            streams = result.sorted { $0.title < $1.title }
            firstEpisodeHref = episode.href
            if streams.isEmpty {
                cloudflareURL = CloudflareBypassManager.shared.pendingVerificationURL
            }
            isLoading = false
        } catch {
            self.error = error.localizedDescription
            isLoading = false
        }
    }

    /// Runs the user-initiated Cloudflare challenge, then reloads streams.
    private func verifyCloudflare() async {
        guard let url = cloudflareURL else { return }
        isLoading = true
        try? await CloudflareBypassManager.shared.triggerBypass(for: url)
        await loadStreams()
    }

    private func startBatchDownload(streamTitle: String) {
        // Pass through the already-fetched first-episode streams so the batch loop
        // doesn't have to call extractStreamUrl again for it (one less call against
        // the stream host's rate limiter).
        let prefetched: (episodeHref: String, streams: [StreamResult])? = firstEpisodeHref
            .map { (episodeHref: $0, streams: streams) }
        DownloadManager.shared.batchDownload(
            mediaTitle: mediaTitle,
            imageUrl: imageUrl,
            aniListID: aniListID,
            moduleId: moduleId,
            detailHref: nil,
            episodes: episodes,
            episodeNumbers: episodeNumbers,
            streamTitle: streamTitle,
            preFetchedFirstEpisode: prefetched
        )
    }
}
#endif
