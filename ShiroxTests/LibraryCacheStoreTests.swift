import XCTest
@testable import Shirox

@MainActor
final class LibraryCacheStoreTests: XCTestCase {

    private func tempDir() -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func makeEntry(id: Int, title: String) -> LibraryEntry {
        let media = Media(
            id: id, idMal: nil, provider: .anilist,
            title: MediaTitle(romaji: title, english: title, native: nil),
            coverImage: MediaCoverImage(large: nil, extraLarge: nil),
            bannerImage: nil, description: nil, episodes: 12,
            status: nil, averageScore: nil, genres: nil,
            season: nil, seasonYear: nil, nextAiringEpisode: nil,
            relations: nil, type: nil, format: nil)
        return LibraryEntry(
            id: id, media: media, status: .current, progress: 3, score: 8,
            updatedAt: nil, customListName: nil, timesRewatched: nil)
    }

    func testSaveThenLoadRoundTrips() {
        let dir = tempDir()
        let store = LibraryCacheStore(directory: dir)
        store.save(entries: [makeEntry(id: 1, title: "A"), makeEntry(id: 2, title: "B")],
                   provider: .anilist, mediaType: .anime)

        // A fresh instance over the same directory must read the persisted snapshot back.
        let reopened = LibraryCacheStore(directory: dir)
        let snap = reopened.snapshot(provider: .anilist, mediaType: .anime)
        XCTAssertEqual(snap?.entries.map(\.id), [1, 2])
        XCTAssertNotNil(snap?.syncedAt)
    }

    func testKeysAreIsolatedByProviderAndMediaType() {
        let dir = tempDir()
        let store = LibraryCacheStore(directory: dir)
        store.save(entries: [makeEntry(id: 1, title: "AniAnime")], provider: .anilist, mediaType: .anime)
        store.save(entries: [makeEntry(id: 2, title: "MalAnime")], provider: .mal, mediaType: .anime)
        store.save(entries: [makeEntry(id: 3, title: "AniManga")], provider: .anilist, mediaType: .manga)

        XCTAssertEqual(store.snapshot(provider: .anilist, mediaType: .anime)?.entries.map(\.id), [1])
        XCTAssertEqual(store.snapshot(provider: .mal, mediaType: .anime)?.entries.map(\.id), [2])
        XCTAssertEqual(store.snapshot(provider: .anilist, mediaType: .manga)?.entries.map(\.id), [3])
        XCTAssertNil(store.snapshot(provider: .mal, mediaType: .manga))
    }

    func testCorruptFileLoadsAsEmpty() throws {
        let dir = tempDir()
        try "not json".data(using: .utf8)!.write(to: dir.appendingPathComponent("library-cache.json"))
        let store = LibraryCacheStore(directory: dir)
        XCTAssertNil(store.snapshot(provider: .anilist, mediaType: .anime))
    }

    /// Reported: an entry made private showed as public again after reopening the app, while
    /// AniList still had it private. The library's saved copy never heard of the change.
    func testAPrivacyChangeReachesTheSavedCopyAndSurvivesAReopen() {
        let dir = tempDir()
        let store = LibraryCacheStore(directory: dir)
        store.save(entries: [makeEntry(id: 1, title: "A"), makeEntry(id: 2, title: "B")],
                   provider: .anilist, mediaType: .manga)
        let syncedAt = store.snapshot(provider: .anilist, mediaType: .manga)?.syncedAt

        store.apply(AniListEntryExtrasChange(mediaId: 2, isPrivate: true))

        let reopened = LibraryCacheStore(directory: dir).snapshot(provider: .anilist, mediaType: .manga)
        XCTAssertEqual(reopened?.entries.map(\.isPrivate), [false, true])
        // Still as old as its last fetch, so the next load asks AniList as it would have.
        XCTAssertEqual(reopened?.syncedAt, syncedAt)
    }

    /// The AniList manga list was read without its privacy and notes, so every manga came back
    /// public after each reload whatever AniList said.
    func testAnAniListMangaEntryKeepsItsPrivacyAndNotes() {
        let media = AniListMedia(
            id: 30, idMal: nil,
            title: AniListTitle(romaji: "Berserk", english: nil, native: nil),
            coverImage: AniListCoverImage(large: nil, extraLarge: nil),
            bannerImage: nil, description: nil, episodes: nil, chapters: 380,
            status: nil, averageScore: nil, genres: nil, season: nil, seasonYear: nil,
            nextAiringEpisode: nil, relations: nil, type: "MANGA", format: nil)
        let raw = AniListRawEntry(id: 9, media: media, status: .current, progress: 12, score: 0,
                                  updatedAt: nil, customListName: nil, repeat: 0,
                                  isPrivate: true, notes: "reread arc 3")
        let entry = LibraryViewModel.aniListMangaEntry(raw)
        XCTAssertTrue(entry.isPrivate)
        XCTAssertEqual(entry.notes, "reread arc 3")
        XCTAssertTrue(entry.media.isManga)
        XCTAssertEqual(entry.media.episodes, 380)
    }

    func testAChangeSetsOnlyWhatChangedOnTheMatchingAniListEntry() {
        var entry = makeEntry(id: 5, title: "E")
        entry.notes = "kept"
        AniListEntryExtrasChange(mediaId: 5, isPrivate: true).apply(to: &entry)
        XCTAssertTrue(entry.isPrivate)
        XCTAssertEqual(entry.notes, "kept")

        AniListEntryExtrasChange(mediaId: 5, notes: "").apply(to: &entry)
        XCTAssertNil(entry.notes, "an empty note clears it")
        XCTAssertTrue(entry.isPrivate)

        var other = makeEntry(id: 6, title: "F")
        AniListEntryExtrasChange(mediaId: 5, isPrivate: true).apply(to: &other)
        XCTAssertFalse(other.isPrivate)
        XCTAssertNil(AniListEntryExtrasChange(mediaId: 5, isPrivate: true).apply(to: nil))
    }

    /// MyAnimeList ids overlap AniList's, and MyAnimeList has no privacy.
    func testAChangeLeavesAMyAnimeListEntryWithTheSameIdAlone() {
        let ani = makeEntry(id: 7, title: "G")
        let malMedia = Media(
            id: 7, idMal: 7, provider: .mal,
            title: ani.media.title, coverImage: ani.media.coverImage,
            bannerImage: nil, description: nil, episodes: 12, status: nil, averageScore: nil, genres: nil,
            season: nil, seasonYear: nil, nextAiringEpisode: nil, relations: nil, type: nil, format: nil)
        var mal = LibraryEntry(id: 7, media: malMedia, status: .current, progress: 1, score: 0,
                               updatedAt: nil, customListName: nil, timesRewatched: nil)
        AniListEntryExtrasChange(mediaId: 7, isPrivate: true).apply(to: &mal)
        XCTAssertFalse(mal.isPrivate)
    }

    func testApplyOptimisticUpdateMutatesMatchingEntry() {
        let dir = tempDir()
        let store = LibraryCacheStore(directory: dir)
        store.save(entries: [makeEntry(id: 7, title: "X")], provider: .anilist, mediaType: .anime)

        store.applyOptimisticUpdate(provider: .anilist, mediaType: .anime, mediaId: 7,
                                    status: .completed, progress: 12, score: 9)

        let e = store.snapshot(provider: .anilist, mediaType: .anime)?.entries.first
        XCTAssertEqual(e?.status, .completed)
        XCTAssertEqual(e?.progress, 12)
        XCTAssertEqual(e?.score, 9)
    }

    func testApplyOptimisticDeleteRemovesEntryAcrossUnknownType() {
        let dir = tempDir()
        let store = LibraryCacheStore(directory: dir)
        store.save(entries: [makeEntry(id: 1, title: "keep"), makeEntry(id: 2, title: "drop")],
                   provider: .anilist, mediaType: .manga)

        // entryId == LibraryEntry.id; makeEntry sets id == entry id. mediaType nil → search both.
        store.applyOptimisticDelete(provider: .anilist, mediaType: nil, mediaId: nil, entryId: 2)

        XCTAssertEqual(store.snapshot(provider: .anilist, mediaType: .manga)?.entries.map(\.id), [1])
    }
}
