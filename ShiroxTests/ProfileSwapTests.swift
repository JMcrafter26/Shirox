import XCTest
@testable import Shirox

@MainActor
final class ProfileSwapTests: XCTestCase {
    private final class FakeKeychain: ProfileKeychain {
        var items: [String: Data] = [:]
        var locked = false
        func read(_ account: String) throws -> Data? {
            if locked { throw ProfileSwap.SwapError.keychainLocked }
            return items[account]
        }
        func write(_ data: Data, account: String) { items[account] = data }
        func delete(_ account: String) { items.removeValue(forKey: account) }
    }

    private var root: URL!
    private var suite: String!
    private var defaults: UserDefaults!
    private var keychain: FakeKeychain!
    private var env: ProfileSwap.Environment!

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("profiles-\(UUID().uuidString)")
        let support = root.appendingPathComponent("support"), caches = root.appendingPathComponent("caches")
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: caches, withIntermediateDirectories: true)
        suite = "ProfileSwapTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
        keychain = FakeKeychain()
        env = ProfileSwap.Environment(support: support, caches: caches, defaults: defaults,
                                      domainName: suite, keychain: keychain)
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: root)
    }

    private func profile(_ name: String, group: UUID = UUID()) -> AppProfile {
        AppProfile(id: UUID(), name: name, colorHex: "#E5484D", moduleGroup: group)
    }

    private func write(_ text: String, _ name: String, in dir: URL? = nil) throws {
        try Data(text.utf8).write(to: (dir ?? env.support).appendingPathComponent(name))
    }

    private func read(_ name: String, in dir: URL? = nil) -> String? {
        (try? Data(contentsOf: (dir ?? env.support).appendingPathComponent(name))).map { String(decoding: $0, as: UTF8.self) }
    }

    /// One person's things: a library file, progress and a setting, a sign-in, a cached Simkl list.
    private func fillAsAlice() throws {
        try write("alice library", "local_library.json")
        try write("alice simkl", "simkl-only-anime.json", in: env.caches)
        defaults.set(["alice cw"], forKey: "continueWatchingItems")
        defaults.set(42, forKey: "playerSkipLong")
        defaults.set(["link"], forKey: "com.shirox.tracking_links")
        keychain.items["anilist_access_token"] = Data("alice-token".utf8)
    }

    func testANewProfileStartsEmptyAndTheOldOneComesBackWhole() throws {
        let alice = profile("Alice"), bob = profile("Bob")
        try fillAsAlice()
        let swap = ProfileSwap(env)

        try swap.switchProfile(from: alice, to: bob)
        XCTAssertNil(read("local_library.json"))
        XCTAssertNil(read("simkl-only-anime.json", in: env.caches))
        XCTAssertNil(defaults.object(forKey: "continueWatchingItems"))
        XCTAssertNil(defaults.object(forKey: "playerSkipLong"))
        XCTAssertNil(defaults.object(forKey: "com.shirox.tracking_links"))
        XCTAssertNil(keychain.items["anilist_access_token"], "Bob isn't signed in to Alice's AniList")

        // Bob uses the app a little.
        try write("bob library", "local_library.json")
        defaults.set(10, forKey: "playerSkipLong")

        try swap.switchProfile(from: bob, to: alice)
        XCTAssertEqual(read("local_library.json"), "alice library")
        XCTAssertEqual(read("simkl-only-anime.json", in: env.caches), "alice simkl")
        XCTAssertEqual(defaults.stringArray(forKey: "continueWatchingItems"), ["alice cw"])
        XCTAssertEqual(defaults.integer(forKey: "playerSkipLong"), 42)
        XCTAssertEqual(defaults.stringArray(forKey: "com.shirox.tracking_links"), ["link"])
        XCTAssertEqual(keychain.items["anilist_access_token"], Data("alice-token".utf8))
        XCTAssertEqual(keychain.items.count, 1, "nothing of either left under a stashed name: \(keychain.items.keys)")

        try swap.switchProfile(from: alice, to: bob)
        XCTAssertEqual(read("local_library.json"), "bob library")
        XCTAssertEqual(defaults.integer(forKey: "playerSkipLong"), 10)
    }

    func testTheDevicesThingsStayPut() throws {
        try FileManager.default.createDirectory(at: env.support.appendingPathComponent("Downloads"), withIntermediateDirectories: true)
        try write("manifest", "downloads_manifest.json")
        try write("ids", "id-mappings.json")
        defaults.set(true, forKey: "com.shirox.hasLaunchedSinceInstall")
        defaults.set(true, forKey: "hasCompletedOnboarding")
        defaults.set(["en"], forKey: "AppleLanguages")
        keychain.items["jellyfin_device_id"] = Data("device".utf8)

        try ProfileSwap(env).switchProfile(from: profile("A"), to: profile("B"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: env.support.appendingPathComponent("Downloads").path))
        XCTAssertEqual(read("downloads_manifest.json"), "manifest")
        XCTAssertEqual(read("id-mappings.json"), "ids")
        XCTAssertTrue(defaults.bool(forKey: "com.shirox.hasLaunchedSinceInstall"))
        XCTAssertTrue(defaults.bool(forKey: "hasCompletedOnboarding"))
        XCTAssertEqual(defaults.stringArray(forKey: "AppleLanguages"), ["en"])
        XCTAssertEqual(keychain.items["jellyfin_device_id"], Data("device".utf8))
    }

    func testSharedModulesFollowTheGroupAndOwnOnesDont() throws {
        let group = UUID()
        let alice = profile("Alice", group: group), bob = profile("Bob", group: group), carol = profile("Carol")
        try write("shared modules", "modules.json")
        defaults.set("module-1", forKey: "activeModuleId")
        defaults.set(true, forKey: "seanime_dub_x")
        let swap = ProfileSwap(env)

        try swap.switchProfile(from: alice, to: bob)
        XCTAssertEqual(read("modules.json"), "shared modules")
        XCTAssertEqual(defaults.string(forKey: "activeModuleId"), "module-1")
        XCTAssertTrue(defaults.bool(forKey: "seanime_dub_x"))
        // Bob adds one; Alice sees it too.
        try write("shared modules + 1", "modules.json")

        try swap.switchProfile(from: bob, to: carol)
        XCTAssertNil(read("modules.json"), "Carol has her own, none yet")
        XCTAssertNil(defaults.object(forKey: "activeModuleId"))

        try swap.switchProfile(from: carol, to: alice)
        XCTAssertEqual(read("modules.json"), "shared modules + 1")
    }

    func testCopiedModulesStartTheSameAndThenDiverge() throws {
        let alice = profile("Alice"), dave = profile("Dave")
        try write("alice modules", "modules.json")
        defaults.set("module-a", forKey: "activeModuleId")
        let swap = ProfileSwap(env)
        swap.copyModules(from: alice, sourceIsLive: true, into: dave.moduleGroup)

        try swap.switchProfile(from: alice, to: dave)
        XCTAssertEqual(read("modules.json"), "alice modules")
        XCTAssertEqual(defaults.string(forKey: "activeModuleId"), "module-a")
        try write("dave modules", "modules.json")

        try swap.switchProfile(from: dave, to: alice)
        XCTAssertEqual(read("modules.json"), "alice modules")
    }

    func testALockedKeychainMovesNothing() throws {
        try fillAsAlice()
        keychain.locked = true
        XCTAssertThrowsError(try ProfileSwap(env).switchProfile(from: profile("Alice"), to: profile("Bob")))
        XCTAssertEqual(read("local_library.json"), "alice library")
        XCTAssertEqual(defaults.integer(forKey: "playerSkipLong"), 42)
    }

    func testAPendingSwitchIsAppliedAtLaunch() throws {
        let alice = profile("Alice"), bob = profile("Bob")
        try fillAsAlice()
        ProfileManager.saveRegistry(ProfileRegistry(profiles: [alice, bob], activeID: alice.id, pendingID: bob.id), env)

        ProfileManager.applyPendingSwitch(env)
        let registry = try XCTUnwrap(ProfileManager.loadRegistry(env))
        XCTAssertEqual(registry.activeID, bob.id)
        XCTAssertNil(registry.pendingID)
        XCTAssertNil(read("local_library.json"))
        XCTAssertNotNil(read("registry.json", in: env.profilesRoot), "the registry itself isn't swapped")
    }

    func testRemovingAProfileDeletesWhatItKept() throws {
        let alice = profile("Alice"), bob = profile("Bob")
        try fillAsAlice()
        let swap = ProfileSwap(env)
        try swap.switchProfile(from: alice, to: bob)
        swap.remove(alice, groupStillUsed: false)
        XCTAssertFalse(FileManager.default.fileExists(atPath: swap.profileFolder(alice.id).path))
        XCTAssertTrue(keychain.items.isEmpty)
    }

    // MARK: Colours

    func testNewProfilesGetAColourNoOtherHas() {
        var used: [String] = []
        for _ in ProfilePalette.colors {
            let picked = ProfilePalette.pick(avoiding: used)
            XCTAssertFalse(used.contains(picked))
            used.append(picked)
        }
        XCTAssertEqual(Set(used), Set(ProfilePalette.colors))
        let extra = ProfilePalette.pick(avoiding: used)
        XCTAssertFalse(used.contains(extra), "a thirteenth still differs: \(extra)")
        XCTAssertNotNil(ProfilePalette.rgb(extra))
    }
}
