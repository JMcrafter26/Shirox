import SwiftUI

struct LibraryEntryEditSheet: View {
    let entry: LibraryEntry?
    let media: Media
    let onSave: (MediaListStatus, Int, Double) -> Void
    var onDelete: (() -> Void)? = nil
    var scoreFormatOverride: ScoreFormat? = nil
    var progressUnit: String = "episode"

    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var anilistAuth = AniListAuthManager.shared
    @ObservedObject private var local = LocalLibraryManager.shared
    @State private var automaticTracking: Bool
    @State private var status: MediaListStatus
    @State private var progress: Int

    /// The most progress this title can take — its episode or chapter count when known.
    private var maxProgress: Int { media.episodes ?? 9999 }

    /// What typing into the progress field sets progress to: digits only, never past `max`.
    static func typedProgress(_ text: String, max: Int) -> Int {
        let digits = text.filter { $0.isASCII && $0.isNumber }
        return min(Int(digits) ?? 0, max)
    }

    /// The statuses the picker offers. A free Simkl account can't record a rewatch, so a Simkl
    /// entry is never offered Rewatching.
    static func statuses(for provider: ProviderType) -> [MediaListStatus] {
        provider == .simkl ? MediaListStatus.allCases.filter { $0 != .repeating } : MediaListStatus.allCases
    }
    @State private var score: Double
    @State private var isPrivate: Bool
    @State private var notes: String
    @State private var showDeleteConfirmation = false
    @State private var showNewCollection = false
    @State private var newCollectionName = ""
    @StateObject private var editor = CollectionEditor()
    @ObservedObject private var malAuth = MALAuthManager.shared
    /// Rewatches, dates and custom lists as the service had them when the sheet opened, and as
    /// edited. Nil until they've loaded; only what changed between the two is written.
    @State private var loadedExtras: LibraryEntryExtras?
    @State private var extras = LibraryEntryExtras()
    @State private var extrasFailed = false

    private var scoreFormat: ScoreFormat {
        if let scoreFormatOverride { return scoreFormatOverride }
        return media.provider == .anilist ? anilistAuth.scoreFormat : .point10
    }

    private func normalizeScoreIfNeeded() {
        guard score > 0, scoreFormat.maxScore < 100, score > scoreFormat.maxScore else { return }
        score = (score / 100.0) * scoreFormat.maxScore
    }

    init(entry: LibraryEntry?, media: Media,
         scoreFormatOverride: ScoreFormat? = nil,
         progressUnit: String = "episode",
         onSave: @escaping (MediaListStatus, Int, Double) -> Void,
         onDelete: (() -> Void)? = nil) {
        self.entry = entry
        self.media = media
        self.onSave = onSave
        self.onDelete = onDelete
        self.scoreFormatOverride = scoreFormatOverride
        self.progressUnit = progressUnit
        _automaticTracking = State(initialValue: AniListMappingManager.shared.automaticTrackingEnabled(for: media))
        _status = State(initialValue: entry?.status ?? .planning)
        _progress = State(initialValue: entry?.progress ?? 0)
        // Local entries convert from their canonical score into the active format;
        // provider entries (override nil) fall back to their stored account score.
        _score = State(initialValue: entry?.displayScore(in: scoreFormatOverride ?? .point10) ?? 0)
        _isPrivate = State(initialValue: entry?.isPrivate ?? false)
        _notes = State(initialValue: entry?.notes ?? "")
    }

    private enum ExtrasService { case anilist, mal }

    /// Where rewatches, dates and custom lists are read from and written to: the signed-in
    /// AniList or MyAnimeList account the entry is on. Not local or Simkl entries.
    private var extrasService: ExtrasService? {
        guard scoreFormatOverride == nil else { return nil }
        switch media.provider {
        case .anilist where anilistAuth.isLoggedIn: return .anilist
        case .mal where malAuth.isLoggedIn: return .mal
        default: return nil
        }
    }

    private var isManga: Bool { progressUnit == "chapter" }

    private func loadExtras() async {
        guard let service = extrasService, loadedExtras == nil else { return }
        do {
            let fetched: LibraryEntryExtras
            switch service {
            case .anilist:
                fetched = try await AniListLibraryService.shared.fetchExtras(mediaId: media.id,
                                                                            type: isManga ? .manga : .anime)
            case .mal:
                fetched = try await MALLibraryService.shared.fetchExtras(malId: media.id, manga: isManga)
                    ?? LibraryEntryExtras()
            }
            loadedExtras = fetched
            extras = fetched
        } catch {
            Logger.shared.log("[Library] Couldn't load entry details: \(error)", type: "Error")
            extrasFailed = true
        }
    }

    private func saveExtras() {
        guard let service = extrasService, let old = loadedExtras, old != extras else { return }
        let new = extras
        let id = media.id
        let manga = isManga
        Task {
            // After the entry itself, which may be new: a write of these alone would put the
            // title on the list with AniList's default status.
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            do {
                switch service {
                case .anilist: try await AniListLibraryService.shared.saveExtras(mediaId: id, from: old, to: new)
                case .mal: try await MALLibraryService.shared.saveExtras(malId: id, manga: manga, from: old, to: new)
                }
            } catch {
                Logger.shared.log("[Library] Couldn't save entry details: \(error)", type: "Error")
                #if !os(tvOS)
                ToastManager.shared.show(message: String(localized: "library.couldnt_save_rewatches_dates_or"), type: .error)
                #endif
            }
        }
    }

    /// Rewatches and the start and finish dates, from the account the entry is on.
    @ViewBuilder
    private var detailsSections: some View {
        if extrasService != nil {
            if loadedExtras == nil {
                Section("library.details") {
                    if extrasFailed {
                        Text("library.couldnt_load_rewatches_and_dates")
                            .foregroundStyle(.secondary)
                    } else {
                        HStack {
                            ProgressView().controlSize(.small)
                            Text("common.loading").foregroundStyle(.secondary)
                        }
                    }
                }
            } else {
                Section("library.details") {
                    #if !os(tvOS)
                    Stepper(value: $extras.repeats, in: 0...999) {
                        HStack {
                            Text(isManga ? String(localized: "library.total_rereads") : String(localized: "library.total_rewatches"))
                            Spacer()
                            Text("\(extras.repeats)")
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                        }
                    }
                    #endif
                    dateRow(String(localized: "library.started"), date: $extras.startedAt)
                    dateRow(String(localized: "shared.finished"), date: $extras.completedAt)
                }
                if !extras.customLists.isEmpty {
                    Section {
                        ForEach($extras.customLists) { $list in
                            Button {
                                list.isMember.toggle()
                            } label: {
                                HStack {
                                    Text(list.name).foregroundStyle(.primary)
                                    Spacer()
                                    if list.isMember {
                                        Image(systemName: "checkmark").foregroundStyle(.tint)
                                    }
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    } header: {
                        Text("library.custom_lists")
                    } footer: {
                        Text("library.make_new_lists_in_your")
                    }
                }
            }
        }
    }

    /// A date that may not be set: a switch to set or clear it, and the day once it's set.
    @ViewBuilder
    private func dateRow(_ title: String, date: Binding<Date?>) -> some View {
        #if os(tvOS)
        HStack {
            Text(title)
            Spacer()
            Text(date.wrappedValue.map { $0.formatted(date: .abbreviated, time: .omitted) } ?? "—")
                .foregroundStyle(.secondary)
        }
        #else
        Toggle(title, isOn: Binding(
            get: { date.wrappedValue != nil },
            set: { date.wrappedValue = $0 ? Calendar.current.startOfDay(for: .now) : nil }))
            .switchTint()
        if let day = date.wrappedValue {
            DatePicker(String(localized: "library.on \(title)"), selection: Binding(get: { day }, set: { date.wrappedValue = $0 }),
                       in: ...Date.now, displayedComponents: .date)
        }
        #endif
    }

    /// Privacy is an AniList feature. Local entries (`scoreFormatOverride` set) and MAL entries
    /// have nowhere to send it.
    private var showsPrivacyToggle: Bool {
        media.provider == .anilist && scoreFormatOverride == nil && anilistAuth.isLoggedIn
    }

    /// Notes go to the same place, and under the same conditions — see `setNotes`. Offering the
    /// field where it can't be saved would lose whatever someone typed into it.
    private var showsNotes: Bool { showsPrivacyToggle }

    /// Only send a note when it actually changed, so opening and saving an entry doesn't write
    /// a note nobody touched. Whitespace-trimmed, so a stray newline isn't a "change".
    private var trimmedNotes: String {
        notes.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var notesChanged: Bool {
        trimmedNotes != (entry?.notes ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// AniList-only: MyAnimeList has no equivalent flag, and a toggle that silently did
    /// nothing there would be worse than not offering it.
    @ViewBuilder
    private var privacySection: some View {
        if showsPrivacyToggle {
            Section {
                Toggle("library.private", isOn: $isPrivate)
                    .switchTint()
                Text("library.hides_this_entry_from_your")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var notesSection: some View {
        if showsNotes {
            Section("library.notes") {
                // The growing multi-line field is iOS 16 / macOS 13; this still ships to
                // iOS 15, where a plain single-line field takes the same text perfectly well.
                #if os(tvOS)
                TextField("library.add_a_note", text: $notes)
                #else
                if #available(iOS 16.0, macOS 13.0, *) {
                    TextField("library.add_a_note", text: $notes, axis: .vertical)
                        .lineLimit(3...8)
                } else {
                    TextField("library.add_a_note", text: $notes)
                }
                #endif
                Text("library.saved_to_this_entry_on")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    var body: some View {
        sheetBody.macGroupedForms()
    }

    @ViewBuilder private var sheetBody: some View {
        NavigationStack {
            Form {
                Section("library.status") {
                    Picker("library.status", selection: $status) {
                        ForEach(Self.statuses(for: media.provider)) { s in
                            Text(s.displayName).tag(s)
                        }
                    }
                    .pickerStyle(.menu)
                }

                if status != .completed {
                    Section("settings.progress") {
                        #if !os(tvOS)
                        HStack {
                            // Typed as well as stepped: stepping through 200 episodes was 200 taps.
                            // Parsed on every keystroke, so Save right after typing takes the value.
                            TextField("0", text: Binding(
                                get: { String(progress) },
                                set: { progress = Self.typedProgress($0, max: maxProgress) }))
                                #if os(iOS)
                                .keyboardType(.numberPad)
                                #endif
                                .textFieldStyle(.roundedBorder)
                                .multilineTextAlignment(.center)
                                .frame(width: 72)
                            progressUnit == "chapter"
                                ? Text(LocalizedStringKey(progress == 1 ? "library.chapter_read" : "library.chapters_read"))
                                : Text(LocalizedStringKey(progress == 1 ? "library.episode_watched" : "library.episodes_watched"))
                            Spacer()
                            Stepper("settings.progress", value: $progress, in: 0...maxProgress)
                                .labelsHidden()
                        }
                        #endif
                        if let total = media.episodes {
                            Text("library.of_total \(total)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                Section("library.score") {
                    ScoreInputView(score: $score, format: scoreFormat)
                }

                if progressUnit == "episode", AniListMappingManager.shared.canToggleAutomaticTracking(for: media) {
                    Section("library.tracking") {
                        Toggle("library.automatically_track", isOn: $automaticTracking)
                            .switchTint()
                        Text("library.update_online_progress_as_you")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                detailsSections
                privacySection
                notesSection

                if scoreFormatOverride != nil {
                    Section("library.collections") {
                        ForEach(local.collections) { collection in
                            Button {
                                let member = collection.mediaUniqueIds.contains(media.uniqueId)
                                local.setMembership(uniqueId: media.uniqueId, media: media,
                                                    inCollection: collection.id, member: !member)
                            } label: {
                                HStack {
                                    Text(collection.name).foregroundStyle(.primary)
                                    Spacer()
                                    if collection.mediaUniqueIds.contains(media.uniqueId) {
                                        Image(systemName: "checkmark").foregroundStyle(.tint)
                                    }
                                }
                            }
                            #if !os(tvOS)
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                Button(role: .destructive) {
                                    editor.requestDelete(collection)
                                } label: {
                                    Label("common.delete", systemImage: "trash")
                                }
                                .tint(.red)
                            }
                            .swipeActions(edge: .leading) {
                                Button {
                                    editor.beginRename(collection)
                                } label: {
                                    Label("library.rename", systemImage: "pencil")
                                }
                                .tint(.blue)
                            }
                            #endif
                            .contextMenu {
                                Button {
                                    editor.beginRename(collection)
                                } label: {
                                    Label("library.rename", systemImage: "pencil")
                                }
                                Button(role: .destructive) {
                                    editor.requestDelete(collection)
                                } label: {
                                    Label("common.delete", systemImage: "trash")
                                }
                            }
                        }
                        Button {
                            showNewCollection = true
                        } label: {
                            Label("library.new_collection", systemImage: "plus")
                        }
                    }
                }

                if entry != nil, onDelete != nil {
                    Section {
                        Button(role: .destructive) {
                            showDeleteConfirmation = true
                        } label: {
                            Label("library.remove_from_library", systemImage: "trash")
                        }
                    }
                }
            }
            .softScrollEdges()
            .navigationTitle(entry == nil ? String(localized: "library.add_to_library") : String(localized: "library.edit_entry"))
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("common.cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("common.save") {
                        if progressUnit == "episode", AniListMappingManager.shared.canToggleAutomaticTracking(for: media) {
                            AniListMappingManager.shared.setAutomaticTracking(automaticTracking, for: media)
                        }
                        let finalProgress = status == .completed ? (media.episodes ?? progress) : progress
                        onSave(status, finalProgress, score)
                        saveExtras()
                        // Sent separately from `onSave`, which is the shared write used by both
                        // providers. Only fires when the toggle actually moved.
                        if showsNotes, notesChanged {
                            let mediaId = media.id
                            let newNotes = trimmedNotes
                            let listType: MediaListType = progressUnit == "chapter" ? .manga : .anime
                            Task {
                                do {
                                    try await AniListLibraryService.shared.setNotes(
                                        mediaId: mediaId, notes: newNotes, type: listType)
                                } catch {
                                    Logger.shared.log("[AniList] Could not save entry notes: \(error)", type: "Error")
                                    #if os(iOS)
                                    ToastManager.shared.show(message: String(localized: "library.couldnt_save_note_on_anilist"), type: .error)
                                    #endif
                                }
                            }
                        }
                        if showsPrivacyToggle, isPrivate != (entry?.isPrivate ?? false) {
                            let mediaId = media.id
                            let makePrivate = isPrivate
                            Task {
                                do {
                                    try await AniListLibraryService.shared.setPrivate(
                                        mediaId: mediaId, isPrivate: makePrivate)
                                } catch {
                                    Logger.shared.log("[AniList] Could not change entry privacy: \(error)", type: "Error")
                                    #if os(iOS)
                                    ToastManager.shared.show(message: String(localized: "library.couldnt_change_privacy_on_anilist"), type: .error)
                                    #endif
                                }
                            }
                        }
                        dismiss()
                    }
                }
            }
            .onAppear { normalizeScoreIfNeeded() }
            .task { await loadExtras() }
            .onChangeOf(anilistAuth.scoreFormat) { normalizeScoreIfNeeded() }
            .onChangeOf(status) { newStatus in
                if newStatus == .completed, let total = media.episodes {
                    progress = total
                }
                // As the services' own editors do: finishing fills in the day it was finished.
                if newStatus == .completed, loadedExtras != nil, extras.completedAt == nil {
                    extras.completedAt = Calendar.current.startOfDay(for: .now)
                }
            }
            .alert("library.remove_from_library", isPresented: $showDeleteConfirmation) {
                Button("common.remove", role: .destructive) {
                    onDelete?()
                    dismiss()
                }
                Button("common.cancel", role: .cancel) {}
            } message: {
                Text("library.this_will_remove_from_your \(media.title.displayTitle)")
            }
            .alert("library.new_collection", isPresented: $showNewCollection) {
                TextField("common.name", text: $newCollectionName)
                Button("library.create") {
                    let trimmed = newCollectionName.trimmingCharacters(in: .whitespacesAndNewlines)
                    newCollectionName = ""
                    guard !trimmed.isEmpty else { return }
                    let collection = local.createCollection(name: trimmed)
                    local.setMembership(uniqueId: media.uniqueId, media: media,
                                        inCollection: collection.id, member: true)
                }
                Button("common.cancel", role: .cancel) { newCollectionName = "" }
            } message: {
                Text("library.group_this_title_under_a")
            }
            .collectionEditorAlerts(editor)
        }
    }
}
