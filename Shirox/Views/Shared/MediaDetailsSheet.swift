import SwiftUI

/// What the Details sheet shows beyond the synopsis the page already has.
struct MediaDetailsExtras {
    struct Trailer: Decodable {
        let id: String
        /// "youtube" or "dailymotion".
        let site: String
        let thumbnail: String?
    }

    /// Someone the user follows, and where they stand on the title.
    struct Follower: Identifiable {
        let id: Int
        let name: String
        let avatar: String?
        let status: MediaListStatus?
        /// Out of 10; 0 when they haven't scored it.
        let score: Double
        let progress: Int?
    }

    let trailer: Trailer?
    let following: [Follower]
}

/// The detail page's "more" sheet: the people the user follows on AniList, the full synopsis,
/// and the trailer. Opened from the synopsis, which on the page itself stays a few lines long.
struct MediaDetailsSheet: View {
    /// AniList's id for the title; nil (a title only MAL knows) leaves just the synopsis.
    let aniListID: Int?
    let synopsis: String

    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @State private var extras: MediaDetailsExtras?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    if let following = extras?.following, !following.isEmpty {
                        followingSection(following)
                    }
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Synopsis").font(.title3.weight(.bold))
                        Text(synopsis)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineSpacing(2)
                            .fixedSize(horizontal: false, vertical: true)
                            #if !os(tvOS)
                            .textSelection(.enabled)
                            #endif
                    }
                    if let trailer = extras?.trailer {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Trailer").font(.title3.weight(.bold))
                            trailerView(trailer)
                        }
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .navigationTitle("Details")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .modifier(DetailsSheetDetents())
        .task(id: aniListID) {
            guard let aniListID else { return }
            do {
                extras = try await AniListSocialService.shared.fetchDetailsExtras(mediaId: aniListID)
            } catch {
                Logger.shared.log("[Details] Couldn't load trailer/following for \(aniListID): \(error)", type: "Error")
            }
        }
    }

    private func followingSection(_ following: [MediaDetailsExtras.Follower]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Following").font(.title3.weight(.bold))
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 20) {
                    ForEach(following) { follower in
                        HStack(spacing: 10) {
                            CachedAsyncImage(urlString: follower.avatar ?? "")
                                .aspectRatio(contentMode: .fill)
                                .frame(width: 44, height: 44)
                                .background(Color.secondary.opacity(0.15))
                                .clipShape(Circle())
                            VStack(alignment: .leading, spacing: 1) {
                                Text(follower.name)
                                    .font(.caption.weight(.semibold))
                                    .lineLimit(1)
                                if let status = follower.status {
                                    Text(status.displayName)
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                                if follower.score > 0 {
                                    Text("\(Self.score(follower.score))/10")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    /// 9 and 9.5, not 9.0.
    private static func score(_ value: Double) -> String {
        value == value.rounded() ? String(Int(value)) : String(format: "%.1f", value)
    }

    @ViewBuilder
    private func trailerView(_ trailer: MediaDetailsExtras.Trailer) -> some View {
        if trailer.site.lowercased() == "youtube" {
            MarkdownMediaEmbed(type: "youtube", source: trailer.id)
        } else if let url = URL(string: "https://www.dailymotion.com/video/\(trailer.id)") {
            Button { openURL(url) } label: {
                ZStack {
                    CachedAsyncImage(urlString: trailer.thumbnail ?? "")
                        .aspectRatio(16 / 9, contentMode: .fit)
                        .background(Color.black)
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    Image(systemName: "play.circle.fill")
                        .font(.system(size: 44))
                        .foregroundStyle(.white)
                        .shadow(color: .black.opacity(0.45), radius: 8)
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Watch the trailer")
        }
    }
}

/// Half height to start, as in the design, pulled up for the rest.
private struct DetailsSheetDetents: ViewModifier {
    func body(content: Content) -> some View {
        #if os(iOS)
        if #available(iOS 16, *) {
            content.presentationDetents([.medium, .large]).presentationDragIndicator(.visible)
        } else {
            content
        }
        #else
        content
        #endif
    }
}
