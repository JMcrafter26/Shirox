import Foundation
import Security

/// Moves one profile's data out of the places the app reads it and another's in.
///
/// Nothing else in the app knows about profiles: every store keeps reading UserDefaults, its
/// files in Application Support and its Keychain items as before. The swap runs at launch,
/// before any of them has loaded (see `ProfileManager.applyPendingSwitch`), so they all come up
/// with the new profile's data.
///
/// What belongs to a profile is everything except what belongs to the device: downloads (files
/// on this device, whoever watches them), caches that aren't anyone's, the profiles themselves,
/// and the frameworks' own keys. A profile's modules are kept by its module group, so profiles
/// that share a group share them.
struct ProfileSwap {
    struct Environment {
        var support: URL
        var caches: URL
        var defaults: UserDefaults
        var domainName: String
        var keychain: ProfileKeychain

        var profilesRoot: URL { support.appendingPathComponent(ProfileSwap.profilesFolder, isDirectory: true) }

        static var live: Environment {
            Environment(
                support: AppDirectories.applicationSupport,
                caches: FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0],
                defaults: .standard,
                domainName: Bundle.main.bundleIdentifier ?? "com.shirox.app",
                keychain: SystemProfileKeychain())
        }
    }

    enum SwapError: Error, Equatable {
        /// The Keychain can't be read: a launch while the device is locked. Nothing was moved.
        case keychainLocked
    }

    static let profilesFolder = "Profiles"

    /// Every credential the app keeps, as `FreshInstallKeychainPurge` lists them, but the
    /// device's own Jellyfin id.
    static var keychainAccounts: [String] {
        FreshInstallKeychainPurge.accounts.filter { $0 != "jellyfin_device_id" }
    }

    /// Application Support items that are the device's, not a profile's. On a Mac the downloads
    /// live in the same folder.
    static let deviceFiles: Set<String> = [
        profilesFolder, "Downloads", "MangaDownloads", "downloads_manifest.json",
        "manga_downloads_manifest.json", "logs.txt",
        "id-mappings.json", "id-media-mappings.json", "id-tvdb-groups.json"
    ]

    /// Files in Caches that are an account's rather than a cache anyone could rebuild the same.
    static let profileCaches = ["simkl-only-anime.json", "simkl-module-pages.json"]

    static let moduleFiles: Set<String> = ["modules.json"]
    static let moduleKeys: Set<String> = ["activeModuleId", "lastUsedModuleId", "moduleCheckResults", "savedModules"]
    static let moduleKeyPrefixes = ["seanime_dub_"]

    /// Keys every profile shares: one-time migrations and markers about this install, and
    /// anything the system frameworks write (they start with a capital or an underscore; the
    /// app's own never do).
    static let deviceKeys: Set<String> = [
        "com.shirox.hasLaunchedSinceInstall", "hasCompletedOnboarding",
        "movedFilesIntoSupportFolder", "movedFilesOutOfDocuments",
        "downloadsNotRemuxed", "downloadsAudioConfigChecked", "jellyfin_device_id",
        "downloadsAudioRestoreChecked", "downloadsAudioRestoreTries", "profilesAskAtLaunch", "profilesPickerColor"
    ]

    static func isDeviceKey(_ key: String) -> Bool {
        guard let first = key.first else { return true }
        // `com.shirox.` keys are the app's own, mostly a person's (tracking links, manual
        // tracking): only the install marker among them is the device's.
        return deviceKeys.contains(key) || first.isUppercase || first == "_" || key.hasPrefix("com.apple.")
    }

    static func isModuleKey(_ key: String) -> Bool {
        moduleKeys.contains(key) || moduleKeyPrefixes.contains { key.hasPrefix($0) }
    }

    let env: Environment
    private let fm = FileManager.default

    init(_ env: Environment = .live) { self.env = env }

    func profileFolder(_ id: UUID) -> URL { env.profilesRoot.appendingPathComponent(id.uuidString, isDirectory: true) }
    func moduleFolder(_ group: UUID) -> URL {
        env.profilesRoot.appendingPathComponent("modules-\(group.uuidString)", isDirectory: true)
    }

    // MARK: - Switching

    /// Puts `outgoing`'s data aside and `incoming`'s in its place. Throws before moving anything
    /// when the Keychain can't be read.
    func switchProfile(from outgoing: AppProfile, to incoming: AppProfile) throws {
        try checkKeychainReadable(for: [outgoing.id, incoming.id])
        stash(outgoing)
        restore(incoming)
    }

    /// Puts the live data away under a profile.
    func stash(_ profile: AppProfile) {
        let folder = profileFolder(profile.id)
        let modules = moduleFolder(profile.moduleGroup)
        resetFolder(folder)
        resetFolder(modules)

        // Credentials
        for account in Self.keychainAccounts {
            let stashed = Self.stashedAccount(account, profile: profile.id)
            if let data = try? env.keychain.read(account) {
                env.keychain.write(data, account: stashed)
                env.keychain.delete(account)
            } else {
                env.keychain.delete(stashed)
            }
        }

        // Settings
        var domain = env.defaults.persistentDomain(forName: env.domainName) ?? [:]
        var own: [String: Any] = [:]
        var shared: [String: Any] = [:]
        for (key, value) in domain where !Self.isDeviceKey(key) {
            if Self.isModuleKey(key) { shared[key] = value } else { own[key] = value }
            domain.removeValue(forKey: key)
        }
        writePlist(own, to: folder.appendingPathComponent("defaults.plist"))
        writePlist(shared, to: modules.appendingPathComponent("defaults.plist"))
        env.defaults.setPersistentDomain(domain, forName: env.domainName)

        // Files
        let support = folder.appendingPathComponent("support", isDirectory: true)
        let caches = folder.appendingPathComponent("caches", isDirectory: true)
        try? fm.createDirectory(at: support, withIntermediateDirectories: true)
        try? fm.createDirectory(at: caches, withIntermediateDirectories: true)
        for name in (try? fm.contentsOfDirectory(atPath: env.support.path)) ?? [] where isProfileFile(name) {
            let destination = (Self.moduleFiles.contains(name) ? modules : support).appendingPathComponent(name)
            move(env.support.appendingPathComponent(name), to: destination)
        }
        for name in Self.profileCaches {
            move(env.caches.appendingPathComponent(name), to: caches.appendingPathComponent(name))
        }
    }

    /// Brings a profile's data back to where the app reads it. A profile never used comes up empty.
    func restore(_ profile: AppProfile) {
        let folder = profileFolder(profile.id)
        let modules = moduleFolder(profile.moduleGroup)

        for account in Self.keychainAccounts {
            let stashed = Self.stashedAccount(account, profile: profile.id)
            env.keychain.delete(account)
            if let data = try? env.keychain.read(stashed) {
                env.keychain.write(data, account: account)
                env.keychain.delete(stashed)
            }
        }

        var domain = env.defaults.persistentDomain(forName: env.domainName) ?? [:]
        for key in domain.keys where !Self.isDeviceKey(key) { domain.removeValue(forKey: key) }
        for source in [folder.appendingPathComponent("defaults.plist"), modules.appendingPathComponent("defaults.plist")] {
            for (key, value) in readPlist(source) where !Self.isDeviceKey(key) { domain[key] = value }
        }
        env.defaults.setPersistentDomain(domain, forName: env.domainName)

        // Whatever the last profile left behind goes, so nothing of theirs shows through.
        for name in (try? fm.contentsOfDirectory(atPath: env.support.path)) ?? [] where isProfileFile(name) {
            try? fm.removeItem(at: env.support.appendingPathComponent(name))
        }
        for name in Self.profileCaches { try? fm.removeItem(at: env.caches.appendingPathComponent(name)) }
        let support = folder.appendingPathComponent("support", isDirectory: true)
        for name in (try? fm.contentsOfDirectory(atPath: support.path)) ?? [] {
            move(support.appendingPathComponent(name), to: env.support.appendingPathComponent(name))
        }
        for name in Self.moduleFiles {
            move(modules.appendingPathComponent(name), to: env.support.appendingPathComponent(name))
        }
        let caches = folder.appendingPathComponent("caches", isDirectory: true)
        for name in Self.profileCaches {
            move(caches.appendingPathComponent(name), to: env.caches.appendingPathComponent(name))
        }
        resetFolder(folder)
        resetFolder(modules)
    }

    // MARK: - Modules for a new profile

    /// Starts `group` with a copy of the modules `source` uses. `sourceIsLive` when that's the
    /// active profile's, which are where the app reads them rather than in its group's folder.
    func copyModules(from source: AppProfile, sourceIsLive: Bool, into group: UUID) {
        let destination = moduleFolder(group)
        resetFolder(destination)
        if sourceIsLive {
            let domain = env.defaults.persistentDomain(forName: env.domainName) ?? [:]
            writePlist(domain.filter { !Self.isDeviceKey($0.key) && Self.isModuleKey($0.key) },
                       to: destination.appendingPathComponent("defaults.plist"))
            for name in Self.moduleFiles {
                try? fm.copyItem(at: env.support.appendingPathComponent(name), to: destination.appendingPathComponent(name))
            }
        } else {
            let from = moduleFolder(source.moduleGroup)
            for name in (try? fm.contentsOfDirectory(atPath: from.path)) ?? [] {
                try? fm.copyItem(at: from.appendingPathComponent(name), to: destination.appendingPathComponent(name))
            }
        }
    }

    // MARK: - Removing

    /// Deletes everything an inactive profile had. Its module group goes too when no profile
    /// left uses it.
    func remove(_ profile: AppProfile, groupStillUsed: Bool) {
        try? fm.removeItem(at: profileFolder(profile.id))
        if !groupStillUsed { try? fm.removeItem(at: moduleFolder(profile.moduleGroup)) }
        for account in Self.keychainAccounts {
            env.keychain.delete(Self.stashedAccount(account, profile: profile.id))
        }
    }

    // MARK: - Helpers

    static func stashedAccount(_ account: String, profile: UUID) -> String {
        "\(account)|profile:\(profile.uuidString)"
    }

    private func isProfileFile(_ name: String) -> Bool {
        !name.hasPrefix(".") && !name.hasPrefix("com.apple") && !Self.deviceFiles.contains(name)
    }

    /// Reads every credential either profile has, so a locked Keychain is found before anything
    /// moves, not halfway.
    private func checkKeychainReadable(for profiles: [UUID]) throws {
        for account in Self.keychainAccounts {
            _ = try env.keychain.read(account)
            for id in profiles { _ = try env.keychain.read(Self.stashedAccount(account, profile: id)) }
        }
    }

    private func resetFolder(_ url: URL) {
        try? fm.removeItem(at: url)
        try? fm.createDirectory(at: url, withIntermediateDirectories: true)
    }

    private func move(_ from: URL, to: URL) {
        guard fm.fileExists(atPath: from.path) else { return }
        try? fm.removeItem(at: to)
        try? fm.createDirectory(at: to.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? fm.moveItem(at: from, to: to)
    }

    private func writePlist(_ dictionary: [String: Any], to url: URL) {
        try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? PropertyListSerialization.data(fromPropertyList: dictionary, format: .binary, options: 0) {
            try? data.write(to: url, options: .atomic)
        }
    }

    private func readPlist(_ url: URL) -> [String: Any] {
        guard let data = try? Data(contentsOf: url),
              let object = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        else { return [:] }
        return object
    }
}

// MARK: - Keychain

protocol ProfileKeychain {
    /// The item's bytes, nil when there's none. Throws when the Keychain can't be read now.
    func read(_ account: String) throws -> Data?
    func write(_ data: Data, account: String)
    func delete(_ account: String)
}

/// Generic passwords, as the auth managers keep them.
struct SystemProfileKeychain: ProfileKeychain {
    func read(_ account: String) throws -> Data? {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrAccount: account,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess: return result as? Data
        case errSecItemNotFound: return nil
        default: throw ProfileSwap.SwapError.keychainLocked
        }
    }

    func write(_ data: Data, account: String) {
        delete(account)
        SecItemAdd([
            kSecClass: kSecClassGenericPassword,
            kSecAttrAccount: account,
            kSecValueData: data,
            kSecAttrAccessible: kSecAttrAccessibleWhenUnlocked
        ] as CFDictionary, nil)
    }

    func delete(_ account: String) {
        SecItemDelete([kSecClass: kSecClassGenericPassword, kSecAttrAccount: account] as CFDictionary)
    }
}
