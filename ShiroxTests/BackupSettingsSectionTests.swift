import XCTest
@testable import Shirox

@MainActor
final class BackupSettingsSectionTests: XCTestCase {

    private var savedDefaults: [String: Any] = [:]
    private var allKeys: [String] {
        SettingsBackupSection.boolKeys + SettingsBackupSection.intKeys
            + SettingsBackupSection.doubleKeys + SettingsBackupSection.stringKeys
            + SettingsBackupSection.stringListKeys
            + ["subtitle.enabled", "subtitle.fontSize", "subtitle.shadowRadius",
               "subtitle.backgroundEnabled", "subtitle.bottomPadding", "subtitle.delay",
               "subtitle.color.r", "subtitle.color.g", "subtitle.color.b", "subtitle.color.a"]
    }

    override func setUp() {
        super.setUp()
        for key in allKeys {
            if let value = UserDefaults.standard.object(forKey: key) { savedDefaults[key] = value }
        }
    }

    override func tearDown() {
        for key in allKeys {
            if let value = savedDefaults[key] {
                UserDefaults.standard.set(value, forKey: key)
            } else {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }
        savedDefaults = [:]
        super.tearDown()
    }

    func testSectionIdIsSettings() {
        XCTAssertEqual(SettingsBackupSection.id, BackupSectionID.settings)
    }

    func testTypedPreferencesRoundTrip() async throws {
        UserDefaults.standard.set(true, forKey: "autoNextEpisode")
        UserDefaults.standard.set(7, forKey: "maxConcurrentDownloads")
        UserDefaults.standard.set(77.5, forKey: "watchedPercentage")
        UserDefaults.standard.set("1080p", forKey: "preferredQuality")

        let section = SettingsBackupSection()
        let payload = try XCTUnwrap(section.export())

        UserDefaults.standard.set(false, forKey: "autoNextEpisode")
        UserDefaults.standard.set(1, forKey: "maxConcurrentDownloads")
        UserDefaults.standard.set(10.0, forKey: "watchedPercentage")
        UserDefaults.standard.set("auto", forKey: "preferredQuality")

        _ = try await section.apply(payload)

        XCTAssertTrue(UserDefaults.standard.bool(forKey: "autoNextEpisode"))
        XCTAssertEqual(UserDefaults.standard.integer(forKey: "maxConcurrentDownloads"), 7)
        XCTAssertEqual(UserDefaults.standard.double(forKey: "watchedPercentage"), 77.5)
        XCTAssertEqual(UserDefaults.standard.string(forKey: "preferredQuality"), "1080p")
    }

    func testDeviceLocalAndOnboardingKeysAreNotBackedUp() {
        let excluded = ["hasCompletedOnboarding", "hasRequestedDownloadNotifications",
                        "lastLandscapeOrientation", "orientation", "drawsBackground"]
        for key in excluded {
            XCTAssertFalse(SettingsBackupSection.boolKeys.contains(key), "\(key) must not be backed up")
            XCTAssertFalse(SettingsBackupSection.intKeys.contains(key), "\(key) must not be backed up")
            XCTAssertFalse(SettingsBackupSection.doubleKeys.contains(key), "\(key) must not be backed up")
            XCTAssertFalse(SettingsBackupSection.stringKeys.contains(key), "\(key) must not be backed up")
        }
    }

    func testLocalLibraryKeysLiveOnlyInTheLocalLibrarySection() {
        for key in ["localScoreFormat", "localAutoTrackEnabled"] {
            XCTAssertFalse(SettingsBackupSection.stringKeys.contains(key))
            XCTAssertFalse(SettingsBackupSection.boolKeys.contains(key))
        }
    }

    func testUnsetKeysAreOmittedAndNotForcedToDefaultsOnRestore() async throws {
        UserDefaults.standard.removeObject(forKey: "preferredQuality")
        let section = SettingsBackupSection()
        let payload = try XCTUnwrap(section.export())
        XCTAssertNil(payload.strings["preferredQuality"])

        UserDefaults.standard.set("1080p", forKey: "preferredQuality")
        _ = try await section.apply(payload)
        XCTAssertEqual(UserDefaults.standard.string(forKey: "preferredQuality"), "1080p")
    }

    func testSubtitleSettingsRestoreIntoPublishedStateNotJustDefaults() async throws {
        let manager = SubtitleSettingsManager.shared
        manager.fontSize = 42
        manager.enabled = false
        manager.delaySeconds = 1.5

        let section = SettingsBackupSection()
        let payload = try XCTUnwrap(section.export())

        manager.fontSize = 12
        manager.enabled = true
        manager.delaySeconds = 0

        _ = try await section.apply(payload)

        // Published state, not just the key — a direct UserDefaults write would leave
        // these stale and the player would keep using 12pt.
        XCTAssertEqual(manager.fontSize, 42)
        XCTAssertFalse(manager.enabled)
        XCTAssertEqual(manager.delaySeconds, 1.5)
        XCTAssertEqual(UserDefaults.standard.double(forKey: "subtitle.fontSize"), 42)
    }

    func testAllowlistsAreDisjoint() {
        let all = SettingsBackupSection.boolKeys + SettingsBackupSection.intKeys
            + SettingsBackupSection.doubleKeys + SettingsBackupSection.stringKeys
        XCTAssertEqual(all.count, Set(all).count, "A key must appear in exactly one type list")
    }

    func testSimklTrackingAndSyncTargetsAreBackedUp() {
        XCTAssertTrue(SettingsBackupSection.boolKeys.contains("simklTrackingEnabled"))
        XCTAssertTrue(SettingsBackupSection.stringKeys.contains(SyncTargets.key))
    }

    /// A backup from before `syncTargets` carries only `dualSync`. Restoring it must restore that
    /// choice, not leave whatever set this device already had.
    func testAnOldBackupReseedsSyncTargetsFromDualSync() async throws {
        SyncTargets.save([.anilist, .simkl])
        let payload = SettingsBackupPayload(bools: ["dualSync": true], ints: [:], doubles: [:],
                                            strings: [:], subtitles: nil)
        _ = try await SettingsBackupSection().apply(payload)
        XCTAssertEqual(SyncTargets.load(), [.anilist, .mal])
    }

    func testANewBackupRestoresSyncTargetsAsIs() async throws {
        let payload = SettingsBackupPayload(bools: ["dualSync": false], ints: [:], doubles: [:],
                                            strings: [SyncTargets.key: "anilist,simkl"], subtitles: nil)
        _ = try await SettingsBackupSection().apply(payload)
        XCTAssertEqual(SyncTargets.load(), [.anilist, .simkl])
    }

    func testManualTrackingTitlesAndHoldActionRoundTrip() async throws {
        UserDefaults.standard.set(["anilist-1", "mal-2"], forKey: AniListMappingManager.manualTrackingKey)
        UserDefaults.standard.set("saveFrame", forKey: "playerHoldAction")
        let section = SettingsBackupSection()
        let payload = try XCTUnwrap(section.export())

        UserDefaults.standard.removeObject(forKey: AniListMappingManager.manualTrackingKey)
        UserDefaults.standard.set("speed", forKey: "playerHoldAction")
        _ = try await section.apply(payload)

        XCTAssertEqual(UserDefaults.standard.stringArray(forKey: AniListMappingManager.manualTrackingKey),
                       ["anilist-1", "mal-2"])
        XCTAssertEqual(UserDefaults.standard.string(forKey: "playerHoldAction"), "saveFrame")
    }

    private func media(_ id: Int, _ provider: ProviderType, type: String? = nil) -> Media {
        Media(id: id, idMal: nil, provider: provider, title: MediaTitle(romaji: nil, english: "T", native: nil),
              coverImage: MediaCoverImage(large: nil, extraLarge: nil), bannerImage: nil, description: nil,
              episodes: nil, status: nil, averageScore: nil, genres: nil, season: nil, seasonYear: nil,
              nextAiringEpisode: nil, relations: nil, type: type, format: nil)
    }

    /// The edit sheet writes what the player reads: AniList and MAL ids, a Simkl anime by its MAL id.
    func testManualTrackingIsStoredUnderTheIdsThePlayerChecks() {
        let manager = AniListMappingManager.shared
        let cases: [(Media, ProviderType, Int)] = [
            (media(9_000_001, .anilist), .anilist, 9_000_001),
            (media(9_000_002, .mal), .mal, 9_000_002),
            (media(9_000_003, .simkl), .mal, 9_000_003),
        ]
        for (title, provider, id) in cases {
            XCTAssertTrue(manager.canToggleAutomaticTracking(for: title))
            manager.setAutomaticTracking(false, for: title)
            XCTAssertFalse(manager.automaticTrackingEnabled(for: title))
            XCTAssertFalse(manager.automaticTrackingEnabled(provider: provider, mediaId: id))
            manager.setAutomaticTracking(true, for: title)
            XCTAssertTrue(manager.automaticTrackingEnabled(provider: provider, mediaId: id))
        }
        XCTAssertFalse(manager.canToggleAutomaticTracking(for: media(1, .simkl, type: Media.simklTVType)))
        XCTAssertFalse(manager.canToggleAutomaticTracking(for: media(1, .local)))
    }
}
