import Foundation
import Combine
import ImageIO
import UniformTypeIdentifiers
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

/// The device's profiles: who they are, which is active, and switching between them.
///
/// Switching happens in place: the data is swapped on disk (`ProfileSwap`), every store that
/// holds some in memory reads it again, and the screens are rebuilt (`generation`).
@MainActor
final class ProfileManager: ObservableObject {
    static let shared = ProfileManager()

    @Published private(set) var registry: ProfileRegistry

    /// How a new profile gets its modules.
    enum ModuleChoice: Hashable {
        /// None to start with.
        case own
        /// A copy of another profile's, changed separately from then on.
        case copy(from: UUID)
        /// The same modules as another profile: adding or removing one changes both.
        case share(with: UUID)
    }

    var profiles: [AppProfile] { registry.profiles }
    var active: AppProfile? { registry.active }

    private let swap: ProfileSwap
    private var cancellables = Set<AnyCancellable>()

    private init() {
        swap = ProfileSwap()
        if let saved = Self.loadRegistry(swap.env) {
            registry = saved
        } else {
            let first = AppProfile(
                id: UUID(), name: Self.firstProfileName(),
                colorHex: ProfilePalette.pick(avoiding: []), moduleGroup: UUID())
            registry = ProfileRegistry(profiles: [first], activeID: first.id)
            save()
        }
        followAccountAvatars()
    }

    // MARK: - Launch

    /// Swaps in the profile the user switched to, before anything has read the old one's data.
    /// Called first thing at launch. A launch that can't read the Keychain (the device is locked
    /// and iOS woke the app for a download) leaves the switch for the next one.
    static func applyPendingSwitch(_ env: ProfileSwap.Environment = .live) {
        guard var registry = loadRegistry(env), let pending = registry.pendingID else { return }
        defer { saveRegistry(registry, env) }
        guard pending != registry.activeID,
              let outgoing = registry.active,
              let incoming = registry.profiles.first(where: { $0.id == pending }) else {
            registry.pendingID = nil
            return
        }
        do {
            try ProfileSwap(env).switchProfile(from: outgoing, to: incoming)
            registry.activeID = incoming.id
            registry.pendingID = nil
            Logger.shared.log("[Profiles] Switched from \(outgoing.name) to \(incoming.name)", type: "Info")
        } catch {
            Logger.shared.log("[Profiles] Keychain locked; the switch to \(incoming.name) waits for the next launch", type: "Info")
        }
    }

    // MARK: - Managing

    @discardableResult
    func create(name: String, photo: Data?, colorHex: String? = nil, modules: ModuleChoice) -> AppProfile {
        var group = UUID()
        switch modules {
        case .own:
            break
        case .share(let otherID):
            if let other = profiles.first(where: { $0.id == otherID }) { group = other.moduleGroup }
        case .copy(let otherID):
            if let other = profiles.first(where: { $0.id == otherID }) {
                swap.copyModules(from: other, sourceIsLive: other.id == registry.activeID, into: group)
            }
        }
        var profile = AppProfile(
            id: UUID(), name: Self.cleaned(name),
            colorHex: colorHex ?? ProfilePalette.pick(avoiding: profiles.map(\.colorHex)),
            moduleGroup: group)
        if let photo, savePhoto(photo, for: profile.id) { profile.hasPhoto = true }
        registry.profiles.append(profile)
        save()
        return profile
    }

    func rename(_ id: UUID, to name: String) {
        update(id) { $0.name = Self.cleaned(name) }
    }

    func setColor(_ id: UUID, hex: String) {
        update(id) { $0.colorHex = hex }
    }

    /// A picture for the profile, or nil to go back to its account's or the coloured initial.
    func setPhoto(_ data: Data?, for id: UUID) {
        if let data {
            let saved = savePhoto(data, for: id)
            update(id) { $0.hasPhoto = saved }
        } else {
            try? FileManager.default.removeItem(at: photoURL(for: id))
            update(id) { $0.hasPhoto = false }
        }
        photoVersion += 1
    }

    /// Bumped when a picture changes, so views showing the file read it again.
    @Published private(set) var photoVersion = 0

    /// Deletes an inactive profile and all it kept. The active one can't be deleted.
    func delete(_ id: UUID) {
        guard id != registry.activeID, let profile = profiles.first(where: { $0.id == id }) else { return }
        registry.profiles.removeAll { $0.id == id }
        if registry.pendingID == id { registry.pendingID = nil }
        let groupStillUsed = registry.profiles.contains { $0.moduleGroup == profile.moduleGroup }
        swap.remove(profile, groupStillUsed: groupStillUsed)
        try? FileManager.default.removeItem(at: photoURL(for: id))
        save()
    }

    /// Deletes any profile but the last. The active one is switched away from first, to the
    /// first of the others, and kept if that switch fails.
    func deleteSwitchingAway(_ id: UUID) async {
        if id == registry.activeID {
            guard let other = profiles.first(where: { $0.id != id }) else { return }
            await switchTo(other.id)
            guard registry.activeID != id else { return }
        }
        delete(id)
    }

    /// Who shares modules with a profile.
    func moduleSharers(of profile: AppProfile) -> [AppProfile] {
        profiles.filter { $0.id != profile.id && $0.moduleGroup == profile.moduleGroup }
    }

    // MARK: - Switching

    /// The profile picker, over everything: at launch, and from Settings.
    @Published var isPickerShown = false
    /// While a switch is under way, the profile being switched to.
    @Published private(set) var switchingTo: AppProfile?
    /// Changes on every switch; the app's screens are rebuilt for it, so none keeps state from
    /// the last profile.
    @Published private(set) var generation = UUID()

    /// Whether the picker opens at launch, when there's more than one profile.
    static let askAtLaunchKey = "profilesAskAtLaunch"

    /// Shows the picker at launch when there's a choice to make.
    func presentAtLaunchIfNeeded() {
        let ask = UserDefaults.standard.object(forKey: Self.askAtLaunchKey) as? Bool ?? true
        if ask, profiles.count > 1 { isPickerShown = true }
    }

    /// Switches profile in place: the outgoing profile's data goes aside, the incoming one's
    /// comes in, every store reloads from it, and the screens are built again.
    func switchTo(_ id: UUID) async {
        guard id != registry.activeID, switchingTo == nil,
              let outgoing = active, let incoming = profiles.first(where: { $0.id == id }) else { return }
        switchingTo = incoming
        defer { switchingTo = nil }
        // Lets the switching cover come up before the work starts.
        try? await Task.sleep(nanoseconds: 350_000_000)
        UserDefaults.standard.synchronize()
        do {
            try swap.switchProfile(from: outgoing, to: incoming)
        } catch {
            Logger.shared.log("[Profiles] Couldn't switch to \(incoming.name): \(error)", type: "Error")
            #if os(iOS)
            ToastManager.shared.show(message: "Couldn't switch profiles. Unlock your device and try again.", type: .error)
            #endif
            return
        }
        registry.activeID = incoming.id
        registry.pendingID = nil
        save()
        Self.reloadStores()
        generation = UUID()
        Logger.shared.log("[Profiles] Switched from \(outgoing.name) to \(incoming.name)", type: "Info")
        try? await Task.sleep(nanoseconds: 300_000_000)
        isPickerShown = false
    }

    /// Every store that keeps a profile's data in memory, reading it again after a switch.
    private static func reloadStores() {
        ContinueWatchingManager.shared.reloadForProfileSwitch()
        MangaProgressManager.shared.reloadForProfileSwitch()
        WatchHistoryService.shared.reloadForProfileSwitch()
        LocalLibraryManager.shared.reloadForProfileSwitch()
        MangaMatchManager.shared.reloadForProfileSwitch()
        LibraryCacheStore.shared.reloadForProfileSwitch()
        HomeCacheStore.shared.reloadForProfileSwitch()
        ProfileCacheStore.shared.reloadForProfileSwitch()
        PendingWriteQueue.shared.reloadForProfileSwitch()
        SubtitleSettingsManager.shared.reloadForProfileSwitch()
        TrackingLinkStore.shared.reloadForProfileSwitch()
        ModuleWebLinks.shared.reloadForProfileSwitch()
        AniListMappingManager.shared.reloadForProfileSwitch()
        NewEpisodeTracker.shared.reloadForProfileSwitch()
        #if !os(tvOS)
        SimklOnlyAnimeStore.shared.reloadForProfileSwitch()
        SimklModulePages.shared.reloadForProfileSwitch()
        SimklLibraryService.shared.reloadForProfileSwitch()
        SimklAuthManager.shared.reloadForProfileSwitch()
        DiscoverySource.shared.reloadForProfileSwitch()
        #endif
        AniListAuthManager.shared.reloadForProfileSwitch()
        MALAuthManager.shared.reloadForProfileSwitch()
        JellyfinAuthManager.shared.reloadForProfileSwitch()
        ProviderManager.shared.reloadForProfileSwitch()
        ModuleManager.shared.reloadForProfileSwitch()
    }

    // MARK: - Pictures

    func photoURL(for id: UUID) -> URL {
        swap.env.profilesRoot.appendingPathComponent("photos", isDirectory: true)
            .appendingPathComponent("\(id.uuidString).jpg")
    }

    /// Stores a picture scaled to 512 px on its longer side, as JPEG.
    private func savePhoto(_ data: Data, for id: UUID) -> Bool {
        guard let jpeg = Self.normalizedPhoto(data) else { return false }
        let url = photoURL(for: id)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        return (try? jpeg.write(to: url, options: .atomic)) != nil
    }

    nonisolated static func normalizedPhoto(_ data: Data, maxSide: Int = 512) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceCreateThumbnailWithTransform: true,
                  kCGImageSourceThumbnailMaxPixelSize: maxSide,
              ] as CFDictionary) else { return nil }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil)
        else { return nil }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return output as Data
    }

    // MARK: - Account pictures

    /// Keeps the active profile's account picture: AniList's, else MyAnimeList's, else Simkl's.
    private func followAccountAvatars() {
        #if !os(tvOS)
        Publishers.CombineLatest3(AniListAuthManager.shared.$avatarURL,
                                  MALAuthManager.shared.$avatarURL,
                                  SimklAuthManager.shared.$avatarURL)
            .map { anilist, mal, simkl in [anilist, mal, simkl].compactMap { $0 }.first { !$0.isEmpty } }
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] url in
                guard let self, let id = self.active?.id, self.active?.accountAvatarURL != url else { return }
                // Signed in but its picture not loaded yet (a switch, a launch): keep the last one.
                if url == nil, AniListAuthManager.shared.isLoggedIn || MALAuthManager.shared.isLoggedIn
                    || SimklAuthManager.shared.isLoggedIn { return }
                self.update(id) { $0.accountAvatarURL = url }
            }
            .store(in: &cancellables)
        #endif
    }

    // MARK: - Storage

    private func update(_ id: UUID, _ change: (inout AppProfile) -> Void) {
        guard let index = registry.profiles.firstIndex(where: { $0.id == id }) else { return }
        change(&registry.profiles[index])
        save()
    }

    private func save() { Self.saveRegistry(registry, swap.env) }

    nonisolated private static func registryURL(_ env: ProfileSwap.Environment) -> URL {
        env.profilesRoot.appendingPathComponent("registry.json")
    }

    nonisolated static func loadRegistry(_ env: ProfileSwap.Environment) -> ProfileRegistry? {
        guard let data = try? Data(contentsOf: registryURL(env)) else { return nil }
        return try? JSONDecoder().decode(ProfileRegistry.self, from: data)
    }

    nonisolated static func saveRegistry(_ registry: ProfileRegistry, _ env: ProfileSwap.Environment) {
        let url = registryURL(env)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(registry) { try? data.write(to: url, options: .atomic) }
    }

    private static func cleaned(_ name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Profile" : String(trimmed.prefix(30))
    }

    /// The profile everyone already has is named after their account, when they're signed in.
    private static func firstProfileName() -> String {
        #if !os(tvOS)
        let names = [AniListAuthManager.shared.username, MALAuthManager.shared.username, SimklAuthManager.shared.username]
        if let name = names.compactMap({ $0 }).first(where: { !$0.isEmpty }) { return name }
        #endif
        return "Profile 1"
    }
}
