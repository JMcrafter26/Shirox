import SwiftUI

extension MediaKind {
    /// Its name on Simkl's Home, Search and Upcoming.
    var simklKindTitle: String {
        switch self {
        case .anime: return "Anime"
        case .manga: return "Manga"
        case .tv:    return "Shows"
        case .movie: return "Movies"
        }
    }

    /// Its symbol in Simkl's kind menu.
    var simklKindSymbol: String {
        switch self {
        case .anime: return "sparkles"
        case .manga: return "book"
        case .tv:    return "tv"
        case .movie: return "film"
        }
    }
}

/// Anime / Shows / Movies pills, on Simkl's Search.
struct SimklKindPicker: View {
    @Binding var kind: MediaKind

    var body: some View {
        Picker("Kind", selection: $kind) {
            ForEach(MediaKind.simklKinds, id: \.self) { kind in
                Text(kind.simklKindTitle).tag(kind)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .frame(maxWidth: 260)
    }
}

/// Anime / Shows / Movies as a menu, in the navigation bar like the provider menu beside it — where
/// Home's pills crowded the title spot between the calendar and the provider menu.
struct SimklKindMenu: View {
    @Binding var kind: MediaKind
    /// The label for the chosen kind; just its name unless the screen says more.
    var title: (MediaKind) -> String = { $0.simklKindTitle }

    var body: some View {
        Menu {
            Picker("Kind", selection: $kind) {
                ForEach(MediaKind.simklKinds, id: \.self) { kind in
                    Label(kind.simklKindTitle, systemImage: kind.simklKindSymbol).tag(kind)
                }
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: kind.simklKindSymbol)
                    .font(.subheadline.weight(.semibold))
                    .symbolReplaceTransition()
                Text(title(kind))
                    .font(.subheadline.weight(.semibold))
                Image(systemName: "chevron.down").font(.caption2)
            }
            .foregroundStyle(.primary)
            .animation(.spring(response: 0.35, dampingFraction: 0.8), value: kind)
        }
    }
}

private extension View {
    /// One symbol morphs into the next, from iOS 17; before that it just changes.
    @ViewBuilder
    func symbolReplaceTransition() -> some View {
        if #available(iOS 17, macOS 14, tvOS 17, *) {
            contentTransition(.symbolEffect(.replace))
        } else {
            self
        }
    }
}
