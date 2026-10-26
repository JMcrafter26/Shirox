import Combine
import Foundation
import SwiftUI

/// Mirror of MangaModuleResolver's preference, for the anime side: keep the active
/// module if it's an anime (non-manga) module, else fall back to the first anime
/// module, else nil.
enum AnimeModulePreference {
    static func pick(active: ModuleDefinition?, modules: [ModuleDefinition]) -> ModuleDefinition? {
        if let active, active.isManga == false { return active }
        return modules.first { $0.isManga == false }
    }
}

@MainActor
final class ModuleManager: ObservableObject {
    static let shared = ModuleManager()

    @Published var modules: [ModuleDefinition] = []
    @Published var activeModule: ModuleDefinition?
    @Published var moduleReadyId: String?
    @Published var isLoading = false
    @Published var errorMessage: String?
    /// The last check of each module, by id (see ``ModuleCheck``).
    @Published private(set) var checkResults: [String: ModuleCheckResult] = [:]
    /// Modules being checked now.
    @Published private(set) var checking: Set<String> = []
    /// The module the last successful add installed, for the add screen to check.
    private(set) var lastAddedModuleID: String?
    /// A repo link just added: the sheet listing its providers shows while this is set.
    @Published var pendingRepo: ExtensionRepo?
    private let checkResultsKey = "moduleCheckResults"

    /// Megabytes of scripts, kept out of UserDefaults (see `StoredFile`).
    private let storage = StoredFile(name: "modules.json", legacyKey: "savedModules")
    private let activeKey = "activeModuleId"

    private init() {
        loadFromStorage()
        if let data = UserDefaults.standard.data(forKey: checkResultsKey),
           let saved = try? JSONDecoder().decode([String: ModuleCheckResult].self, from: data) {
            checkResults = saved
        }
    }

    // MARK: - Check

    /// Runs `module` through a search, episodes and a stream, and keeps the result.
    @discardableResult
    func check(_ module: ModuleDefinition) async -> ModuleCheckResult {
        checking.insert(module.id)
        let result = await ModuleCheck.check(module)
        checking.remove(module.id)
        Logger.shared.log("[ModuleCheck] \(module.sourceName): \(result)", type: result.isFailure ? "Error" : "Info")
        checkResults[module.id] = result
        persistCheckResults()
        return result
    }

    /// Checks every module, a few at a time.
    func checkAll() async {
        let pending = modules
        await withTaskGroup(of: Void.self) { group in
            var started = 0
            for module in pending {
                if started >= 3 { await group.next() }
                group.addTask { await self.check(module) }
                started += 1
            }
        }
    }

    /// The modules whose last check failed.
    var brokenModules: [ModuleDefinition] {
        modules.filter { checkResults[$0.id]?.isFailure == true }
    }

    private func persistCheckResults() {
        let known = Set(modules.map(\.id))
        let kept = checkResults.filter { known.contains($0.key) }
        if let data = try? JSONEncoder().encode(kept) {
            UserDefaults.standard.set(data, forKey: checkResultsKey)
        }
    }

    // MARK: - Add Module

    func addModule(from jsonURL: URL) async {
        isLoading = true
        errorMessage = nil
        lastAddedModuleID = nil
        do {
            let jsonURL = ExtensionRepoLoader.normalized(jsonURL)
            let (data, response) = try await URLSession.shared.data(from: jsonURL)
            var module: ModuleDefinition
            if let link = try await extensionLink(data, url: jsonURL) {
                switch link {
                case .repo(let repo):
                    if ExtensionRepoLoader.isSingleFile(repo), repo.entries.isEmpty { throw ModuleLinkError.adult }
                    // One provider's own link (a backup restoring it), or a single .sky: install that one.
                    guard let key = ExtensionRepoLoader.entryKey(in: jsonURL)
                            ?? (ExtensionRepoLoader.isSingleFile(repo) ? repo.entries.first?.key : nil) else {
                        // A repo: the sheet listing its providers installs them.
                        pendingRepo = repo
                        isLoading = false
                        return
                    }
                    guard let entry = repo.entries.first(where: { $0.key == key }) else { throw ModuleLinkError.notAModule }
                    module = try await ExtensionInstaller.module(entry: entry, repo: repo) { try await ExtensionInstaller.download($0) }
                    await cacheIcon(for: &module)
                case .stremio(let manifest):
                    module = try ExtensionInstaller.module(stremio: manifest)
                    await cacheIcon(for: &module)
                }
            } else if let seanime = SeanimeManifest.detect(data) {
                // A Seanime provider's manifest: its script is fetched, converted and checked here.
                module = try await SeanimeInstaller.module(from: seanime, manifestURL: jsonURL)
                await cacheIcon(for: &module)
            } else {
                do {
                    module = try JSONDecoder().decode(ModuleDefinition.self, from: data)
                } catch {
                    // A Vega or Mana repo given by its folder or web page rather than its index.
                    for index in ExtensionRepoLoader.indexCandidates(for: jsonURL) {
                        if let (indexData, _) = try? await URLSession.shared.data(from: index),
                           case .repo(let repo)? = try? await extensionLink(indexData, url: index) {
                            pendingRepo = repo
                            isLoading = false
                            return
                        }
                    }
                    // Not a module: say what the link is instead.
                    throw ModuleLinkError.diagnose(data, response: response, url: jsonURL)
                }
                module.jsonUrl = jsonURL.absoluteString
                // Cache script and icon
                await cacheAssets(for: &module)
            }

            if isAdult(module) { throw ModuleLinkError.adult }

            // Avoid duplicates
            if modules.contains(where: { $0.id == module.id }) {
                modules.removeAll { $0.id == module.id }
            }
            modules.append(module)
            saveToStorage()
            lastAddedModuleID = module.id
            // A new version is checked afresh.
            checkResults.removeValue(forKey: module.id)

            // Auto-select if it's the first module
            if activeModule == nil {
                selectModule(module)
            }
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }

    /// Installs a module put together on the device (`ModuleImportView`).
    func addModule(_ module: ModuleDefinition) async {
        errorMessage = nil
        lastAddedModuleID = nil
        var module = module
        if module.iconData == nil { await cacheIcon(for: &module) }
        guard !isAdult(module) else {
            errorMessage = ModuleLinkError.adult.localizedDescription
            return
        }
        install(module)
    }

    /// Puts a module in the list, in place of one with the same id.
    private func install(_ module: ModuleDefinition) {
        if let i = modules.firstIndex(where: { $0.id == module.id }) {
            let wasActive = activeModule?.id == module.id
            modules[i] = module
            if wasActive { selectModule(module) }
        } else {
            modules.append(module)
        }
        saveToStorage()
        lastAddedModuleID = module.id
        checkResults.removeValue(forKey: module.id)
        persistCheckResults()
        if activeModule == nil { selectModule(module) }
    }

    /// Puts back a module a backup carried whole: one from files, or one with an edited script.
    func restoreWhole(_ module: ModuleDefinition) {
        guard !isAdult(module) else { return }
        install(module)
    }

    // MARK: - Script Editing

    /// Saves a module's script as edited in the app, and reloads it if it's the one in use.
    func saveScript(_ script: String, for moduleID: String) {
        guard let i = modules.firstIndex(where: { $0.id == moduleID }) else { return }
        modules[i].scriptContent = script
        // A module from files has no original to go back to; its script is simply its own.
        if !modules[i].isFromFile { modules[i].scriptEdited = true }
        saveToStorage()
        checkResults.removeValue(forKey: moduleID)
        persistCheckResults()
        if activeModule?.id == moduleID { selectModule(modules[i]) }
    }

    /// Downloads an edited module's script again and drops the edits. False when it couldn't.
    func revertScript(for moduleID: String) async -> Bool {
        guard let original = modules.first(where: { $0.id == moduleID }) else { return false }
        var module = original
        if original.ext != nil {
            // An extension's script is assembled at install (wrapped, unzipped); fetch it the same way.
            guard var fresh = try? await ExtensionInstaller.reinstall(original, fetch: { try await ExtensionInstaller.download($0) }),
                  !isAdult(fresh) else { return false }
            fresh.iconData = original.iconData
            module = fresh
        } else {
            module.scriptContent = nil
            await cacheScript(for: &module)
        }
        guard module.scriptContent != nil,
              let i = modules.firstIndex(where: { $0.id == moduleID }) else { return false }
        module.scriptEdited = nil
        modules[i] = module
        saveToStorage()
        checkResults.removeValue(forKey: moduleID)
        persistCheckResults()
        if activeModule?.id == moduleID { selectModule(module) }
        return true
    }

    /// Adult modules installed before Shirox refused them. Run once the host list has loaded,
    /// so the sites they reach are checked too.
    func removeAdultModules() {
        for module in modules where isAdult(module) {
            Logger.shared.log("[ModuleManager] Removed adult module \(module.sourceName)", type: "Info")
            removeModule(module)
        }
    }

    private func extensionLink(_ data: Data, url: URL) async throws -> ExtensionLink? {
        try await ExtensionRepoLoader.detect(data, url: url) { try await ExtensionInstaller.download($0) }
    }

    /// Installs providers chosen from a repo sheet. Returns why each one that failed did, by key.
    func install(entries: [ExtensionRepoEntry], from repo: ExtensionRepo) async -> [String: String] {
        var failures: [String: String] = [:]
        for entry in entries {
            do {
                var module = try await ExtensionInstaller.module(entry: entry, repo: repo) { try await ExtensionInstaller.download($0) }
                await cacheIcon(for: &module)
                guard !isAdult(module) else { throw ExtensionInstallError.adult }
                install(module)
            } catch {
                failures[entry.key] = error.localizedDescription
            }
        }
        return failures
    }

    /// The current version of an installed extension, from what its link holds now.
    private func updatedExtension(_ module: ModuleDefinition, ext: ExtensionInfo, link: ExtensionLink) async -> ModuleDefinition? {
        var fresh: ModuleDefinition
        switch link {
        case .stremio(let manifest):
            guard let m = try? ExtensionInstaller.module(stremio: manifest) else { return nil }
            fresh = m
        case .repo(let repo):
            guard let entry = repo.entries.first(where: { $0.key == ext.key }),
                  let m = try? await ExtensionInstaller.module(entry: entry, repo: repo, fetch: { try await ExtensionInstaller.download($0) })
            else { return nil }
            fresh = m
        }
        await cacheIcon(for: &fresh)
        return fresh
    }

    private func isAdult(_ module: ModuleDefinition) -> Bool {
        AdultModuleCheck.isAdult(module) { HostBlocklist.shared.isBlocked(host: $0) }
    }

    // MARK: - Remove Module

    func removeModule(_ module: ModuleDefinition) {
        modules.removeAll { $0.id == module.id }
        checkResults.removeValue(forKey: module.id)
        persistCheckResults()
        if activeModule?.id == module.id {
            activeModule = nil
        }
        saveToStorage()
    }

    // MARK: - Select Module

    func selectModule(_ module: ModuleDefinition) {
        activeModule = module
        UserDefaults.standard.set(module.id, forKey: activeKey)
        
        Task {
            do {
                try await JSEngine.shared.loadModule(module)
                moduleReadyId = module.id
            } catch {
                Logger.shared.log("[ModuleManager] Failed to load JS for module \(module.sourceName): \(error.localizedDescription)", type: "Error")
            }
        }
    }

    /// Like selectModule, but suspends until the module's JS is loaded.
    /// Returns false when the script failed to load. Used by flows that must
    /// call into the module immediately after switching (Continue Reading).
    func selectAndAwaitReady(_ module: ModuleDefinition) async -> Bool {
        activeModule = module
        UserDefaults.standard.set(module.id, forKey: activeKey)
        do {
            try await JSEngine.shared.loadModule(module)
            moduleReadyId = module.id
            return true
        } catch {
            Logger.shared.log("[ModuleManager] Failed to load JS for module \(module.sourceName): \(error.localizedDescription)", type: "Error")
            return false
        }
    }

    // MARK: - Reorder Modules

    func moveModules(from source: IndexSet, to destination: Int) {
        modules.move(fromOffsets: source, toOffset: destination)
        saveToStorage()
    }

    func deselectModule() {
        activeModule = nil
        UserDefaults.standard.removeObject(forKey: activeKey)
    }

    // MARK: - Restore Active Module on Launch

    func restoreActiveModule() async {
        guard let savedId = UserDefaults.standard.string(forKey: activeKey),
              let module = modules.first(where: { $0.id == savedId }) else { return }
        selectModule(module)
    }

    // MARK: - Backup Restore

    /// Replaces the installed module list from a backup by re-fetching each manifest.
    /// Returns the `jsonUrl`s that could not be installed, so the import can report them.
    ///
    /// Re-fetching rather than restoring stored definitions keeps the backup file small:
    /// a `ModuleDefinition` carries the module's whole script in `scriptContent` and its
    /// icon as base64 in `iconData`.
    func restoreModules(jsonUrls: [String], activeId: String?) async -> [String] {
        modules = []
        activeModule = nil
        saveToStorage()

        var failed: [String] = []
        for urlString in jsonUrls {
            guard let url = URL(string: urlString) else {
                failed.append(urlString)
                continue
            }
            let before = modules.count
            await addModule(from: url)
            if modules.count == before { failed.append(urlString) }
        }

        if let activeId, let module = modules.first(where: { $0.id == activeId }) {
            selectModule(module)
        }
        return failed
    }

    // MARK: - Auto-Update

    func checkForUpdates() async {
        var didUpdate = false
        // A snapshot: `modules` can change while each fetch is awaited (a module removed, adult
        // ones purged), so positions are looked up again by id before writing back.
        for module in modules {
            // Edits made in the app aren't replaced; reverting them brings updates back.
            guard !module.isScriptEdited,
                  let jsonUrlStr = module.jsonUrl,
                  let jsonURL = URL(string: jsonUrlStr),
                  let (data, _) = try? await URLSession.shared.data(from: jsonURL) else { continue }
            var fresh: ModuleDefinition
            if let ext = module.ext {
                guard let link = try? await extensionLink(data, url: jsonURL) else { continue }
                switch ExtensionUpdate.decide(module, link: link) {
                case .keep: continue
                case .remove:
                    Logger.shared.log("[ModuleManager] Removed \(module.sourceName): its source now marks it adult", type: "Info")
                    removeModule(module)
                    continue
                case .update:
                    guard let updated = await updatedExtension(module, ext: ext, link: link) else { continue }
                    fresh = updated
                }
            } else if let seanime = SeanimeManifest.detect(data) {
                guard seanime.version != module.version,
                      let installed = try? await SeanimeInstaller.module(from: seanime, manifestURL: jsonURL) else { continue }
                fresh = installed
                await cacheIcon(for: &fresh)
            } else {
                guard let decoded = try? JSONDecoder().decode(ModuleDefinition.self, from: data),
                      decoded.version != module.version else { continue }
                fresh = decoded
                fresh.jsonUrl = jsonUrlStr
                // Cache fresh assets
                await cacheAssets(for: &fresh)
            }
            // An update that turns a module adult isn't taken; an extension that has turned adult goes.
            if isAdult(fresh) {
                if module.ext != nil { removeModule(module) }
                continue
            }
            guard let i = modules.firstIndex(where: { $0.id == module.id }) else { continue }

            let wasActive = activeModule?.id == modules[i].id
            modules[i] = fresh
            if wasActive { selectModule(fresh) }
            didUpdate = true
        }
        if didUpdate { saveToStorage() }
    }

    // MARK: - Asset Caching

    private func cacheAssets(for module: inout ModuleDefinition) async {
        await cacheScript(for: &module)
        await cacheIcon(for: &module)
    }

    private func cacheScript(for module: inout ModuleDefinition) async {
        if let scriptURL = URL(string: module.scriptUrl),
           let (data, _) = try? await URLSession.shared.data(from: scriptURL),
           let script = String(data: data, encoding: .utf8) {
            module.scriptContent = script
        }
    }

    private func cacheIcon(for module: inout ModuleDefinition) async {
        if let iconUrlStr = module.iconUrl,
           let iconURL = URL(string: iconUrlStr),
           let (data, _) = try? await URLSession.shared.data(from: iconURL) {
            module.iconData = data.base64EncodedString()
        }
    }

    // MARK: - Persistence

    private func saveToStorage() {
        if let data = try? JSONEncoder().encode(modules) {
            storage.save(data)
        }
    }

    /// After a profile switch: what the new profile saved, and nothing of the last one's.
    func reloadForProfileSwitch() {
        modules = []
        activeModule = nil
        moduleReadyId = nil
        errorMessage = nil
        checkResults = [:]
        loadFromStorage()
        if let data = UserDefaults.standard.data(forKey: checkResultsKey),
           let saved = try? JSONDecoder().decode([String: ModuleCheckResult].self, from: data) {
            checkResults = saved
        }
        Task { await restoreActiveModule() }
    }

    private func loadFromStorage() {
        guard let data = storage.load(),
              let saved = try? JSONDecoder().decode([ModuleDefinition].self, from: data) else { return }
        modules = saved
    }
}
