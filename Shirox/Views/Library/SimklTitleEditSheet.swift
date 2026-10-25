import SwiftUI

/// Whether a Simkl catalog load has finished.
enum SimklLoadState: Equatable {
    case loading, loaded, failed
}

/// The edit sheet for a Simkl TV show or movie: status, "watched up to" for a show, score, Remove.
struct SimklTitleEditSheet: View {
    let entry: LibraryEntry
    let kind: MediaKind
    /// Called once a save or removal is in the copy, so the caller can reload it.
    let onChange: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var status: MediaListStatus
    @State private var score: Double
    @State private var episodes: [SimklEpisode] = []
    @State private var episodesState: SimklLoadState = .loading
    @State private var season: Int?
    @State private var upTo: SimklEpisodeRef?
    @State private var initialUpTo: SimklEpisodeRef?
    @State private var isSaving = false
    @State private var errorMessage: String?
    @State private var confirmRemove = false

    init(entry: LibraryEntry, kind: MediaKind, onChange: @escaping () -> Void) {
        self.entry = entry
        self.kind = kind
        self.onChange = onChange
        _status = State(initialValue: entry.status)
        _score = State(initialValue: entry.score)
    }

    private var watched: Set<SimklEpisodeRef> {
        SimklEpisodePlanner.watched(status: entry.status, recorded: entry.watchedEpisodes, episodes: episodes)
    }

    var body: some View {
        sheetBody.macGroupedForms()
    }

    @ViewBuilder private var sheetBody: some View {
        NavigationStack {
            Form {
                Section("library.status") {
                    Picker("library.status", selection: $status) {
                        ForEach(LibrarySource.simkl.statuses(in: MediaListStatus.allCases, for: kind)) { option in
                            Text(option.displayName).tag(option)
                        }
                    }
                    .pickerStyle(.menu)
                }
                if kind.hasSimklEpisodes, status != .completed {
                    progressSection
                }
                Section("library.score") {
                    ScoreInputView(score: $score, format: .point10)
                }
                Section {
                    Button("library.remove_from_simkl", role: .destructive) { confirmRemove = true }
                } footer: {
                    if let errorMessage {
                        Text(errorMessage).foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle(entry.media.title.displayTitle)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("common.cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("common.save") { Task { await save() } }
                        .disabled(isSaving)
                }
            }
            .alert("library.remove_from_simkl", isPresented: $confirmRemove) {
                Button("common.remove", role: .destructive) { Task { await remove() } }
                Button("common.cancel", role: .cancel) {}
            } message: {
                Text("library.this_removes_from_your_simkl \(entry.media.title.displayTitle)")
            }
            .task { await loadEpisodes() }
        }
    }

    @ViewBuilder
    private var progressSection: some View {
        Section("library.watched_up_to") {
            switch episodesState {
            case .loading:
                ProgressView()
            case .failed:
                Text("library.couldnt_load_the_episode_list")
                    .foregroundStyle(.secondary)
            case .loaded:
                Picker("library.season", selection: $season) {
                    Text("library.nothing_yet").tag(Int?.none)
                    ForEach(SimklEpisodePlanner.regularSeasons(in: episodes), id: \.self) { number in
                        Text("library.season_number \(number)").tag(Int?.some(number))
                    }
                }
                if let season {
                    Picker("library.episode", selection: $upTo) {
                        ForEach(airedEpisodes(in: season)) { episode in
                            Text(label(episode)).tag(episode.ref)
                        }
                    }
                }
            }
        }
        .onChangeOf(season) { newSeason in
            // A new season starts at its last aired episode; "Nothing yet" clears progress.
            guard let newSeason else {
                upTo = nil
                return
            }
            if upTo?.season != newSeason { upTo = airedEpisodes(in: newSeason).last?.ref }
        }
    }

    private func airedEpisodes(in season: Int) -> [SimklEpisode] {
        episodes.filter { $0.aired && $0.ref?.season == season }
            .sorted { ($0.episode ?? 0) < ($1.episode ?? 0) }
    }

    private func label(_ episode: SimklEpisode) -> String {
        let number = String(localized: "library.episode_number \(episode.episode ?? 0)")
        guard let title = episode.title, !title.isEmpty else { return number }
        return "\(number) · \(title)"
    }

    private func loadEpisodes() async {
        guard kind.hasSimklEpisodes, episodesState != .loaded else { return }
        do {
            episodes = try await SimklCatalog.loadEpisodes(simklID: entry.id)
            let furthest = SimklEpisodePlanner.furthest(watched)
            initialUpTo = furthest
            upTo = furthest
            season = furthest?.season
            episodesState = .loaded
        } catch {
            episodesState = .failed
        }
    }

    private func save() async {
        guard !SimklAuthManager.shared.needsReauthorization else {
            errorMessage = SimklError.readOnly.localizedDescription
            return
        }
        isSaving = true
        defer { isSaving = false }
        let plan = kind.hasSimklEpisodes && episodesState == .loaded
            ? SimklEpisodePlanner.edit(status: status, watched: watched, upTo: upTo,
                                       initialUpTo: initialUpTo, episodes: episodes)
            : nil
        do {
            let delivered = try await SimklLibraryService.shared.saveTitle(
                entry.id, kind: kind, status: status, score: score, episodes: plan)
            onChange()
            if SimklAuthManager.shared.needsReauthorization {
                errorMessage = SimklError.readOnly.localizedDescription
                return
            }
            if !delivered { SimklNotice.queued() }
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func remove() async {
        guard !SimklAuthManager.shared.needsReauthorization else {
            errorMessage = SimklError.readOnly.localizedDescription
            return
        }
        do {
            try await SimklLibraryService.shared.removeTitle(entry.id, kind: kind)
            onChange()
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
