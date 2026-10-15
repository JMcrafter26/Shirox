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
/// Switching restarts the app: the new profile's data is swapped in at the next launch, before
/// any of it is read (`applyPendingSwitch`), so nothing already loaded can mix two people's.
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

    /// Who shares modules with a profile.
    func moduleSharers(of profile: AppProfile) -> [AppProfile] {
        profiles.filter { $0.id != profile.id && $0.moduleGroup == profile.moduleGroup }
    }

    // MARK: - Switching

    /// Remembers the switch and restarts the app, which swaps the profiles in at launch.
    func switchTo(_ id: UUID) {
        guard id != registry.activeID, profiles.contains(where: { $0.id == id }) else { return }
        registry.pendingID = id
        save()
        AppRelauncher.relaunch()
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

/// Restarts the app, for a profile switch.
enum AppRelauncher {
    @MainActor static func relaunch() {
        UserDefaults.standard.synchronize()
        #if os(macOS)
        // Opened again once this process has gone, so the two never touch the data at once.
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", "while kill -0 \(ProcessInfo.processInfo.processIdentifier) 2>/dev/null; do sleep 0.2; done; /usr/bin/open \"\(Bundle.main.bundleURL.path)\""]
        try? task.run()
        NSApp.terminate(nil)
        #elseif os(iOS)
        // An app can't open itself again on iOS: it goes to the Home Screen and quits, and opens
        // as the new profile next time.
        UIApplication.shared.perform(NSSelectorFromString("suspend"))
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { exit(0) }
        #else
        exit(0)
        #endif
    }
}
