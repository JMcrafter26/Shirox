import SwiftUI
import AuthenticationServices
import Combine

// MARK: - Navigation Row Component

struct SettingsNavRow: View {
    let icon: String
    let title: String
    var subtitle: String? = nil

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                Image(systemName: icon)
                    .font(.system(size: 13, weight: .semibold))
                    // Adapts to the appearance: white vanished against light mode's pale glass.
                    .foregroundStyle(.primary)
            }
            .frame(width: 28, height: 28)
            .glassChrome(
                RoundedRectangle(cornerRadius: 7, style: .continuous),
                enabled: true,
                tint: nil,
                off: .ultraThinMaterial
            )
            .overlay(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.14), lineWidth: 0.5)
            )

            Text(title)
                .font(.body)

            Spacer()

            if let subtitle, !subtitle.isEmpty {
                Text(subtitle)
                    .font(.body)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - Root Settings View

#if !os(tvOS)
/// The window a sign-in sheet hangs from: the app's key window, or nil when there's none.
@MainActor
func keyPresentationAnchor() -> ASPresentationAnchor? {
    #if os(macOS)
    return NSApplication.shared.keyWindow ?? NSApplication.shared.mainWindow
    #else
    return UIApplication.shared.connectedScenes
        .compactMap { $0 as? UIWindowScene }
        .flatMap { $0.windows }
        .first { $0.isKeyWindow }
    #endif
}
#endif

/// A settings page's sections: grouped on a Mac, as System Settings is, where a List draws one
/// flat full-width column; a List everywhere else.
struct SettingsList<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        #if os(macOS)
        Form { content }
            .formStyle(.grouped)
        #else
        List { content }
        #endif
    }
}

#if !os(tvOS)
/// The active profile, at the top of Settings.
private struct ProfileSettingsRow: View {
    @ObservedObject private var profiles = ProfileManager.shared

    var body: some View {
        HStack(spacing: 14) {
            if let active = profiles.active {
                ProfileAvatarView(profile: active, size: 52, glass: true)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(profiles.active?.name ?? "Profile")
                    .font(.headline.weight(.semibold))
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .contentShape(Rectangle())
        .padding(.vertical, 4)
    }

    /// "Add a Profile" only while the one profile is still as Shirox made it: named
    /// "Profile 1", with no picture of its own.
    private var subtitle: String {
        if profiles.profiles.count > 1 { return "Switch or Manage Profiles" }
        guard let only = profiles.active else { return "Add a Profile" }
        return only.name == "Profile 1" && !only.hasPhoto ? "Add a Profile" : "Manage Profiles"
    }
}
#endif

struct SettingsView: View {
    @ObservedObject private var aniListAuth = AniListAuthManager.shared
    @ObservedObject private var malAuth = MALAuthManager.shared
    @ObservedObject private var simklAuth = SimklAuthManager.shared
    @ObservedObject private var providerManager = ProviderManager.shared
    @EnvironmentObject private var moduleManager: ModuleManager
    @AppStorage("preferredQuality") private var preferredQuality: String = "auto"
    #if !os(tvOS)
    @State private var totalUsage = 0
    #endif

    /// The services signed in, short, for the Providers row.
    private var providersSubtitle: String {
        let services = [
            aniListAuth.isLoggedIn ? "AniList" : nil,
            malAuth.isLoggedIn ? "MAL" : nil,
            simklAuth.isLoggedIn ? "Simkl" : nil,
        ].compactMap { $0 }
        return services.isEmpty ? "Sign In" : services.joined(separator: ", ")
    }

    private var modulesSubtitle: String? {
        moduleManager.activeModule?.sourceName ?? providerManager.primary?.providerType.displayName
    }

    private var playerSubtitle: String {
        switch preferredQuality {
        case "auto": return "Auto"
        case "highest": return "Highest"
        case "lowest": return "Lowest"
        default: return "\(preferredQuality)p"
        }
    }

    var body: some View {
        NavigationStack {
            Group {
                #if os(macOS)
                // Grouped, as the Mac's own settings are; a List there draws one long flat column.
                Form { sections }
                    .formStyle(.grouped)
                #else
                List { sections }
                #endif
            }
            .softScrollEdges()
            .navigationTitle("Settings")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.large)
            .onAppear {
                PlayerPresenter.shared.resetToAppOrientation()
                Task {
                    totalUsage = await CacheManager.shared.totalDiskUsage
                }
            }
            #elseif os(macOS)
            .onAppear {
                Task { totalUsage = await CacheManager.shared.totalDiskUsage }
            }
            #endif
        }
    }

    @ViewBuilder
    private var sections: some View {
            Section {
                #if !os(tvOS)
                Button {
                    ProfileManager.shared.isPickerShown = true
                } label: {
                    ProfileSettingsRow()
                }
                .buttonStyle(.plain)
                #endif
            }

            Section {
                NavigationLink {
                    AccountsSettingsView()
                } label: {
                    SettingsNavRow(
                        icon: "person.2",
                        title: "Providers",
                        subtitle: providersSubtitle
                    )
                }

                NavigationLink {
                    PlayerSettingsView()
                } label: {
                    SettingsNavRow(
                        icon: "play.tv",
                        title: "Player",
                        subtitle: playerSubtitle
                    )
                }

                NavigationLink {
                    SubtitleSettingsPage()
                } label: {
                    SettingsNavRow(
                        icon: "captions.bubble",
                        title: "Subtitles"
                    )
                }

                #if !os(tvOS)
                NavigationLink {
                    ReaderSettingsView()
                } label: {
                    SettingsNavRow(
                        icon: "book",
                        title: "Reader"
                    )
                }
                #endif

                NavigationLink {
                    ModulesSettingsView()
                } label: {
                    SettingsNavRow(
                        icon: "puzzlepiece.extension",
                        title: "Modules",
                        subtitle: modulesSubtitle
                    )
                }
            }

            Section {
                NavigationLink {
                    LibrarySettingsView()
                } label: {
                    SettingsNavRow(
                        icon: "books.vertical",
                        title: "Library",
                        subtitle: "Lists & Matching"
                    )
                }

                NavigationLink {
                    DownloadsSettingsView()
                } label: {
                    SettingsNavRow(
                        icon: "arrow.down.circle",
                        title: "Downloads"
                    )
                }

                #if !os(tvOS)
                NavigationLink {
                    StorageSettingsView()
                } label: {
                    SettingsNavRow(
                        icon: "internaldrive",
                        title: "Storage & Cache",
                        subtitle: totalUsage > 0 ? Self.formattedBytes(totalUsage) : nil
                    )
                }
                #endif
            }

            Section {
                #if !os(tvOS)
                NavigationLink {
                    BackupSettingsView()
                } label: {
                    SettingsNavRow(
                        icon: "arrow.up.arrow.down.circle",
                        title: "Backup & Restore"
                    )
                }
                #endif

                NavigationLink {
                    SettingsViewLogger()
                } label: {
                    SettingsNavRow(
                        icon: "terminal",
                        title: "App Logs"
                    )
                }

                // Expert settings for blocked regions, deliberately last.
                NavigationLink { AdvancedNetworkSettingsView() } label: { SettingsNavRow(icon: "network", title: "Advanced Network") }
            }

            Section {
                ForEach([LegalPage.imprint, .privacy, .contributors, .licenses], id: \.title) { page in
                    NavigationLink {
                        LegalWebView(page: page)
                    } label: {
                        SettingsNavRow(icon: page.icon, title: page.title)
                    }
                }

                // TMDB's terms ask for its logo and this notice in an About or Credits section.
                VStack(alignment: .leading, spacing: 8) {
                    Image("TMDBLogo")
                        .resizable()
                        .scaledToFit()
                        .frame(height: 12)
                        .accessibilityLabel("TMDB")
                    Text("This application uses TMDB and the TMDB APIs but is not endorsed, certified, or otherwise approved by TMDB.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
            }

            Section {
                SettingsNavRow(icon: Platform.icon, title: "Platform", subtitle: Platform.summary)
                SettingsNavRow(icon: "info.circle", title: "Version", subtitle: Self.appVersion)
            }
    }

    private static var appVersion: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
        let build   = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "—"
        return "\(version) (\(build))"
    }

    static func formattedBytes(_ bytes: Int) -> String {
        guard bytes > 0 else { return "0 KB" }
        if bytes >= 1_000_000 {
            return String(format: "%.1f MB", Double(bytes) / 1_000_000)
        } else {
            return String(format: "%.0f KB", Double(bytes) / 1_000)
        }
    }
}

// MARK: - Platform

/// The device and system Shirox runs on, for the Platform row: "iPhone 14 Pro · iOS 27.0".
private enum Platform {
    static var summary: String { "\(deviceName) · \(systemName)" }

    static var icon: String {
        #if os(macOS)
        return "desktopcomputer"
        #elseif os(tvOS)
        return "appletv"
        #else
        if runsOnMac { return "desktopcomputer" }
        return UIDevice.current.userInterfaceIdiom == .pad ? "ipad" : "iphone"
        #endif
    }

    #if !os(macOS)
    /// Catalyst, or the iPad app on Apple silicon.
    private static var runsOnMac: Bool {
        ProcessInfo.processInfo.isMacCatalystApp || ProcessInfo.processInfo.isiOSAppOnMac
    }
    #endif

    private static var systemName: String {
        #if os(macOS)
        let onMac = true
        #else
        let onMac = runsOnMac
        #endif
        if onMac {
            let v = ProcessInfo.processInfo.operatingSystemVersion
            return "macOS \(v.majorVersion).\(v.minorVersion)"
        }
        #if os(macOS)
        return ""
        #else
        return "\(UIDevice.current.systemName) \(UIDevice.current.systemVersion)"
        #endif
    }

    /// The marketing name where it's known, else the model identifier ("iPad15,3"). The system
    /// only hands out the identifier, and since iOS 16 the device name is just "iPhone".
    private static var deviceName: String {
        let id = modelIdentifier
        if let name = marketingNames[id] { return name }
        #if os(macOS)
        return id.isEmpty ? "Mac" : id
        #else
        if runsOnMac { return id.isEmpty ? "Mac" : id }
        return id.isEmpty ? UIDevice.current.model : id
        #endif
    }

    private static var modelIdentifier: String {
        #if targetEnvironment(simulator)
        return ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] ?? ""
        #else
        #if os(macOS)
        return sysctlString("hw.model")
        #else
        if runsOnMac { return sysctlString("hw.model") }
        var info = utsname()
        uname(&info)
        return withUnsafeBytes(of: &info.machine) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
        #endif
        #endif
    }

    private static func sysctlString(_ name: String) -> String {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return "" }
        var bytes = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &bytes, &size, nil, 0) == 0 else { return "" }
        return String(cString: bytes)
    }

    /// iPhones Shirox runs on (iOS 15 and later). iPads, Macs and Apple TVs show their identifier.
    private static let marketingNames: [String: String] = [
        "iPhone8,1": "iPhone 6s", "iPhone8,2": "iPhone 6s Plus", "iPhone8,4": "iPhone SE",
        "iPhone9,1": "iPhone 7", "iPhone9,3": "iPhone 7", "iPhone9,2": "iPhone 7 Plus", "iPhone9,4": "iPhone 7 Plus",
        "iPhone10,1": "iPhone 8", "iPhone10,4": "iPhone 8", "iPhone10,2": "iPhone 8 Plus", "iPhone10,5": "iPhone 8 Plus",
        "iPhone10,3": "iPhone X", "iPhone10,6": "iPhone X",
        "iPhone11,2": "iPhone XS", "iPhone11,4": "iPhone XS Max", "iPhone11,6": "iPhone XS Max", "iPhone11,8": "iPhone XR",
        "iPhone12,1": "iPhone 11", "iPhone12,3": "iPhone 11 Pro", "iPhone12,5": "iPhone 11 Pro Max",
        "iPhone12,8": "iPhone SE (2nd generation)",
        "iPhone13,1": "iPhone 12 mini", "iPhone13,2": "iPhone 12", "iPhone13,3": "iPhone 12 Pro", "iPhone13,4": "iPhone 12 Pro Max",
        "iPhone14,4": "iPhone 13 mini", "iPhone14,5": "iPhone 13", "iPhone14,2": "iPhone 13 Pro", "iPhone14,3": "iPhone 13 Pro Max",
        "iPhone14,6": "iPhone SE (3rd generation)",
        "iPhone14,7": "iPhone 14", "iPhone14,8": "iPhone 14 Plus", "iPhone15,2": "iPhone 14 Pro", "iPhone15,3": "iPhone 14 Pro Max",
        "iPhone15,4": "iPhone 15", "iPhone15,5": "iPhone 15 Plus", "iPhone16,1": "iPhone 15 Pro", "iPhone16,2": "iPhone 15 Pro Max",
        "iPhone17,3": "iPhone 16", "iPhone17,4": "iPhone 16 Plus", "iPhone17,1": "iPhone 16 Pro", "iPhone17,2": "iPhone 16 Pro Max",
        "iPhone17,5": "iPhone 16e",
        "iPhone18,3": "iPhone 17", "iPhone18,4": "iPhone Air", "iPhone18,1": "iPhone 17 Pro", "iPhone18,2": "iPhone 17 Pro Max",
        "iPhone19,4": "iPhone Duo",
    ]
}

// MARK: - Accounts & Tracking Settings

struct AccountsSettingsView: View {
    @ObservedObject private var aniListAuth = AniListAuthManager.shared
    @ObservedObject private var malAuth = MALAuthManager.shared
    @ObservedObject private var simklAuth = SimklAuthManager.shared
    @StateObject private var librarySync = LibrarySyncService.shared
    @State private var pendingSyncRun: SyncRun?
    @State private var previewRun: SyncRun?
    @State private var overwritePlan: LibraryOverwritePlan?

    @AppStorage("aniListTrackingEnabled") private var aniListTrackingEnabled = true
    @AppStorage("malTrackingEnabled") private var malTrackingEnabled = true
    @AppStorage("skipReWatchTracking") private var skipReWatchTracking = true
    @AppStorage("simklTrackingEnabled") private var simklTrackingEnabled = true
    @AppStorage(SyncTargets.key) private var syncTargetsRaw = ""
    @AppStorage("rateOnFinish") private var rateOnFinish = true
    @AppStorage(ProviderMenuStyle.key) private var providerMenuStyle = ProviderMenuStyle.iconAndName

    #if !os(tvOS)
    /// The window Simkl's sign-in sheet is anchored to.
    static func presentationAnchor() -> ASPresentationAnchor {
        #if os(macOS)
        return NSApplication.shared.keyWindow ?? ASPresentationAnchor()
        #else
        let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene
        return scene?.keyWindow ?? ASPresentationAnchor()
        #endif
    }
    #endif

    /// The sync sections are generated from whoever is signed in. Defined once on
    /// `LibrarySyncService` so reads and the UI can never disagree about who that is.
    private var signedInSides: [LibrarySide] { librarySync.signedInSides }

    var body: some View {
        SettingsList {
            ProvidersSettingsSection()

            // Simkl is a write-side tracker, not a browsing source, so it isn't in the provider list,
            // but sits right under it: below the tracking toggles, it was off the first screen.
            Section {
                HStack(spacing: 12) {
                    CachedAsyncImage(urlString: ProviderType.simkl.iconURL)
                        .frame(width: 28, height: 28)
                        // A dark tile with a see-through "S" — invisible on a dark background
                        // without something light behind it.
                        .background(Color.white)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(simklAuth.username ?? "Simkl")
                            .font(.headline)
                        Text(simklAuth.isLoggedIn
                             ? (simklAuth.needsReauthorization ? "Sign in again to allow syncing" : "Signed in")
                             : "Not signed in")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    #if !os(tvOS)
                    Button(simklAuth.isLoggedIn ? "Sign Out" : "Sign In") {
                        if simklAuth.isLoggedIn {
                            simklAuth.logout()
                        } else {
                            simklAuth.login(presentationAnchor: Self.presentationAnchor())
                        }
                    }
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(simklAuth.isLoggedIn ? Color.red : Color.accentColor)
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background((simklAuth.isLoggedIn ? Color.red : Color.accentColor)
                        .opacity(0.1), in: Capsule())
                    .buttonStyle(.plain)
                    #endif
                }
                if simklAuth.isLoggedIn {
                    SimklBudgetRow()
                }
            } footer: {
                Text("Tracks your anime, shows and movies on Simkl alongside AniList and MyAnimeList. Simkl has no manga.")
            }

            Section {
                Picker("Home Provider Menu", selection: $providerMenuStyle) {
                    ForEach(ProviderMenuStyle.allCases, id: \.self) { style in
                        Text(style.title).tag(style)
                    }
                }
            } footer: {
                Text("The menu at the top of Home that picks where Home and Search come from. Hidden, they keep the last choice.")
            }

            if aniListAuth.isLoggedIn || malAuth.isLoggedIn || simklAuth.isLoggedIn {
                Section("Tracking") {
                    if aniListAuth.isLoggedIn {
                        Toggle("Track on AniList", isOn: $aniListTrackingEnabled)
                            .tint(.secondary)
                    }
                    if malAuth.isLoggedIn {
                        Toggle("Track on MyAnimeList", isOn: $malTrackingEnabled)
                            .tint(.secondary)
                    }
                    if simklAuth.isLoggedIn {
                        Toggle("Track on Simkl", isOn: $simklTrackingEnabled)
                            .tint(.secondary)
                    }
                    Toggle("Never reduce progress", isOn: $skipReWatchTracking)
                        .tint(.secondary)
                    Toggle("Prompt to rate after finishing", isOn: $rateOnFinish)
                        .tint(.secondary)
                    Text("Automatically update your watch progress as you watch.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if signedInSides.count >= 2 {
                Section {
                    ForEach(signedInSides, id: \.self) { side in
                        Toggle(side.name, isOn: mirrorBinding(for: side))
                            .tint(.secondary)
                    }
                } header: {
                    Text("Mirror Edits")
                } footer: {
                    Text("An edit you make to a title — its status, progress, score, or removing it — is also written to every other service switched on here. Services left off change only through the sync runs below.")
                }
            }

            if signedInSides.count >= 2 {
                Section("Sync Library") {
                    ForEach(SyncRun.runs(in: .sync, among: signedInSides)) { run in
                        syncRow(run)
                    }
                    Text("Brings your two accounts into line — a one-time backfill for everything you tracked before signing in here. Syncing both ways reconciles them in a single pass; the one-way copies only ever write to the destination. Either way progress is only ever moved forward, so anything further along is left as it is.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("Overwrite Library") {
                    ForEach(SyncRun.runs(in: .overwrite, among: signedInSides)) { run in
                        syncRow(run)
                    }
                    Text("Use when one account is simply the one you want to keep. Overwrites the other with it — progress, status, score and rewatch count — even where that means going backwards. Titles only the overwritten account has are left in place. This can't be undone.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("Mirror Library") {
                    ForEach(SyncRun.runs(in: .mirror, among: signedInSides)) { run in
                        syncRow(run)
                    }
                    Text("Everything Overwrite does, and the overwritten account also loses any entry the other doesn't have, ending up an exact copy. Entries whose match can't be confirmed are kept rather than deleted. This can't be undone.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .softScrollEdges()
        .navigationTitle("Providers")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .alert(
            pendingSyncRun?.title ?? "Sync Library",
            isPresented: Binding(
                get: { pendingSyncRun != nil },
                set: { if !$0 { pendingSyncRun = nil } }
            ),
            presenting: pendingSyncRun
        ) { run in
            Button(run.confirmButtonTitle, role: run.isDestructive ? .destructive : nil) {
                pendingSyncRun = nil
                Task { await librarySync.sync(run) }
            }
            Button("Cancel", role: .cancel) { pendingSyncRun = nil }
        } message: { run in
            Text(run.confirmationMessage)
        }
        .sheet(isPresented: Binding(
            get: { overwritePlan != nil && previewRun != nil },
            set: { if !$0 { overwritePlan = nil; previewRun = nil } }
        )) {
            if let plan = overwritePlan, let run = previewRun {
                OverwritePreviewSheet(run: run, plan: plan) {
                    overwritePlan = nil
                    previewRun = nil
                    Task { await librarySync.apply(plan, for: run) }
                } onCancel: {
                    overwritePlan = nil
                    previewRun = nil
                }
                .macSheetFrame()
            }
        }
    }

    private func mirrorBinding(for side: LibrarySide) -> Binding<Bool> {
        Binding(
            get: { SyncTargets.decode(syncTargetsRaw).contains(side) },
            set: { isOn in
                var sides = SyncTargets.decode(syncTargetsRaw)
                if isOn { sides.insert(side) } else { sides.remove(side) }
                SyncTargets.save(sides)
            })
    }

    /// One row in the Sync / Overwrite / Mirror sections. Safe runs get a confirmation dialog;
    /// destructive ones get a full preview of what they would change.
    @ViewBuilder
    private func syncRow(_ run: SyncRun) -> some View {
        Button {
            if run.isDestructive {
                // Destructive runs are never launched straight from a tap — they go through a
                // preview of exactly what they would change.
                previewRun = run
                Task { overwritePlan = await librarySync.preview(run) }
            } else {
                pendingSyncRun = run
            }
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(run.title)
                        .foregroundStyle(run.isDestructive ? Color.red : Color.accentColor)
                    Text(run.subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if librarySync.isRunning {
                    Text(librarySync.statusText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .disabled(librarySync.isRunning)
    }
}

// MARK: - Player Settings

struct PlayerSettingsView: View {
    fileprivate static var isMac: Bool {
        #if os(macOS)
        true
        #else
        false
        #endif
    }

    @AppStorage("forceLandscape") private var forceLandscape = false
    @AppStorage("autoRotateForcedLandscape") private var autoRotateForcedLandscape = false
    @AppStorage("playerLiquidGlass") private var playerLiquidGlass = true
    @AppStorage("playerEngine") private var playerEngine = PlaybackEngineKind.native.rawValue
    @AppStorage("preferredQuality") private var preferredQuality: String = "auto"
    @AppStorage("speedBoostTolerance") private var speedBoostTolerance: Int = 10
    @AppStorage("playerHoldAction") private var playerHoldAction = "speed"
    @AppStorage("playerSkipShort") private var skipShort: Int = 10
    @AppStorage("playerSkipLong") private var skipLong: Int = 85
    @AppStorage("autoNextEpisode") private var autoNextEpisode = true
    @AppStorage("pauseWhenInactive") private var pauseWhenInactive = true
    @AppStorage("playerAmbientMode") private var ambientMode = false
    @AppStorage("playerSpatialAudio") private var spatialAudio = false
    @AppStorage("playerPlayInBackground") private var playInBackground = false
    @AppStorage("autoSkipSegments") private var autoSkipSegments = true
    @AppStorage("watchedPercentage") private var watchedPercentage = 90.0

    private let shortOptions = [5, 10, 15, 30]
    private let longOptions  = [30, 60, 85, 90, 120, 150, 180]

    var body: some View {
        SettingsList {
            Section("Display & Style") {
                // A phone's: a Mac's player is a window.
                #if !os(macOS)
                Toggle("Force Landscape Mode", isOn: $forceLandscape)
                    .tint(.secondary)
                    #if os(iOS)
                    .onChangeOf(forceLandscape) {
                        PlayerPresenter.shared.resetToAppOrientation(shouldRotate: true)
                    }
                    #endif
                #endif

                if forceLandscape, !Self.isMac {
                    Toggle("Auto-Rotate in Landscape", isOn: $autoRotateForcedLandscape)
                        .tint(.secondary)
                    Text("Turns the player to the other landscape side even with Rotation Lock on in Control Center.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if #available(iOS 26.0, macOS 26.0, *) {
                    Toggle("Liquid Glass Controls", isOn: $playerLiquidGlass)
                        .tint(.secondary)
                    Text("Frosted glass buttons in the video player. Turn off for solid controls.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                #if os(iOS)
                if !Self.isMac {
                    Toggle("Play in Background", isOn: $playInBackground)
                        .tint(.secondary)
                    Text("Keeps a video playing when you leave the app. Off, it pauses, unless it's in Picture in Picture, on AirPlay or cast to a TV.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Toggle("Spatial Audio", isOn: $spatialAudio)
                        .tint(.secondary)
                        .onChangeOf(spatialAudio) { _ in AppAudioSession.applySpatialAudioSetting() }
                    Text("Lets iOS play videos in Spatial Audio, with its movie sound processing, on AirPods and other headphones. Turn off for plain stereo, or if headphones play quieter here than in other apps. Takes effect from the next video.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Toggle("Ambient Mode", isOn: $ambientMode)
                    .tint(.secondary)
                Text("Fills the bars around the video with a soft glow of its colours. Native engine only.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                #endif

                #if !os(tvOS)
                Picker("Player Engine", selection: $playerEngine) {
                    Text("Native").tag(PlaybackEngineKind.native.rawValue)
                    Text("MPV").tag(PlaybackEngineKind.mpv.rawValue)
                }
                Text("MPV plays more formats, like MKV, and more subtitle styles. AirPlay moves playback to Native, or sends only the sound when Native can't play it. Native switches to MPV by itself when it can't play something.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                #endif
            }

            Section(Self.isMac ? "Playback Quality" : "Playback Quality & Gestures") {
                Picker("Preferred Quality", selection: $preferredQuality) {
                    Text("Auto").tag("auto")
                    Text("Highest").tag("highest")
                    Text("1080p").tag("1080")
                    Text("720p").tag("720")
                    Text("480p").tag("480")
                    Text("Lowest").tag("lowest")
                }
                Text("Which rendition to start on when a stream offers several. Auto lets the player adapt to your connection; a fixed choice falls back to the closest available.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                // Holding a finger on the video; there's no such gesture with a pointer.
                #if !os(macOS)
                Picker("Hold Action", selection: $playerHoldAction) {
                    Text("2× Speed").tag("speed")
                    Text("Save Frame to Photos").tag("saveFrame")
                }

                Picker("Hold Tolerance", selection: $speedBoostTolerance) {
                    Text("Strict").tag(10)
                    Text("Relaxed").tag(30)
                    Text("Very Relaxed").tag(60)
                }
                Text("How far your finger may drift before a hold is recognized. Raise it if the hold action keeps cancelling.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                #endif

                #if os(iOS)
                Toggle("Pause for Control Center", isOn: $pauseWhenInactive)
                    .tint(.secondary)
                Text("Pauses while Control Center or Notification Center is open and picks up again when you close it. Leaving the app or locking the phone still plays in the background.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                #endif
            }

            Section("Skipping") {
                Picker("Skip Duration", selection: $skipShort) {
                    ForEach(shortOptions, id: \.self) { s in
                        Text("\(s)s").tag(s)
                    }
                }
                Picker("Long Skip Duration", selection: $skipLong) {
                    ForEach(longOptions, id: \.self) { s in
                        Text("\(s)s").tag(s)
                    }
                }
                Toggle("Auto-Skip Segments", isOn: $autoSkipSegments)
                    .tint(.secondary)
                Text("Automatically skip intros, recaps, credits, and previews")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Episodes & Progress") {
                Toggle("Auto Next Episode", isOn: $autoNextEpisode)
                    .tint(.secondary)

                Toggle("Reverse Episode List by Default", isOn: EpisodeSortManager.shared.$defaultReverseSort)
                    .tint(.secondary)

                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("Episode Progress Threshold")
                        Spacer()
                        Text("\(Int(watchedPercentage))%")
                            .font(.headline)
                            .monospacedDigit()
                    }
                    #if !os(tvOS)
                    Slider(value: $watchedPercentage, in: 50...100, step: 1)
                    #endif
                }
            }
        }
        .softScrollEdges()
        .navigationTitle("Player")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            PlayerPresenter.shared.resetToAppOrientation()
        }
        #endif
    }
}

// MARK: - Subtitle Settings

/// How subtitles look and sit in every video: the same settings the player's subtitle sheet
/// changes, set here ahead of time. A track's own pick stays in the player.
struct SubtitleSettingsPage: View {
    @ObservedObject private var settings = SubtitleSettingsManager.shared

    var body: some View {
        SettingsList {
            Section("Preview") {
                preview
                    .listRowInsets(EdgeInsets())
            }

            Section {
                Toggle("Show Subtitles", isOn: $settings.enabled)
                    .tint(.secondary)
            } footer: {
                Text("Turns subtitles on or off in every video. The player's subtitles button changes it too.")
            }

            Section {
                #if !os(tvOS)
                ColorPicker("Text Color", selection: $settings.foregroundColor, supportsOpacity: false)
                #endif
                Picker("Size", selection: sizeSelection) {
                    ForEach(PlayerSubtitleMenu.sizes, id: \.points) { size in
                        Text(size.name).tag(size.points)
                    }
                    if !PlayerSubtitleMenu.sizes.contains(where: { $0.points == settings.fontSize }) {
                        Text("\(Int(settings.fontSize.rounded())) pt").tag(settings.fontSize)
                    }
                }
                #if !os(tvOS)
                sliderRow("Font Size", value: $settings.fontSize, in: 12...40, step: 1,
                          text: "\(Int(settings.fontSize))")
                sliderRow("Shadow", value: $settings.shadowRadius, in: 0...8, step: 0.5,
                          text: String(format: "%.1f", settings.shadowRadius))
                #endif
            } header: {
                Text("Appearance")
            } footer: {
                #if !os(tvOS)
                Text("Shadow is a soft dark glow around the text, for bright scenes.")
                #endif
            }

            Section("Background") {
                Toggle("Show Background", isOn: $settings.backgroundEnabled)
                    .tint(.secondary)
                #if !os(tvOS)
                if settings.backgroundEnabled {
                    ColorPicker("Color", selection: $settings.backgroundColor, supportsOpacity: false)
                    sliderRow("Opacity", value: $settings.backgroundOpacity, in: 0.1...1, step: 0.05,
                              text: "\(Int((settings.backgroundOpacity * 100).rounded()))%")
                    sliderRow("Rounding", value: $settings.backgroundCornerRadius, in: 0...20, step: 1,
                              text: "\(Int(settings.backgroundCornerRadius))pt")
                }
                #endif
            }

            #if !os(tvOS)
            Section {
                sliderRow("Bottom Padding", value: $settings.bottomPadding, in: 20...200, step: 5,
                          text: "\(Int(settings.bottomPadding))pt")
            } header: {
                Text("Position")
            }

            Section {
                HStack {
                    Text("Delay")
                    Spacer()
                    Text(PlayerSubtitleMenu.delayLabel(settings.delaySeconds))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                Button("Reset Delay") { settings.delaySeconds = 0 }
                    .disabled(settings.delaySeconds == 0)
            } header: {
                Text("Sync")
            } footer: {
                Text("Set while watching, from the subtitles button. It carries over to the next video until you reset it.")
            }
            #endif

            Section {
                Button("Restore Defaults", role: .destructive) { settings.restoreDefaults() }
            } footer: {
                Text("Styled (.ass) subtitles keep their own fonts and colours; size and delay still apply.")
            }
        }
        .softScrollEdges()
        .navigationTitle("Subtitles")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }

    /// The size presets the player's menu offers, or the slider's own value.
    private var sizeSelection: Binding<Double> {
        Binding(get: { settings.fontSize }, set: { settings.fontSize = $0 })
    }

    /// A line of subtitle over a frame, drawn as the player draws it. The frame is bright, the
    /// case the outline and shadow are there for. Nothing over it while subtitles are off.
    private var preview: some View {
        ZStack(alignment: .bottom) {
            Image("SubtitlePreview")
                .resizable()
                .scaledToFill()
                .frame(height: 170)
                .frame(maxWidth: .infinity)
                .clipped()
            if settings.enabled {
                subtitleLine
            }
        }
        .frame(height: 170)
        .frame(maxWidth: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .accessibilityHidden(true)
    }

    private var subtitleLine: some View {
        Text("Did he give you any clues,\nany coordinates, anything?")
            .font(.system(size: min(settings.fontSize, 32)))
            .foregroundStyle(settings.foregroundColor)
            .shadow(color: .black, radius: 0, x: -1, y: 0)
            .shadow(color: .black, radius: 0, x: 1, y: 0)
            .shadow(color: .black, radius: 0, x: 0, y: -1)
            .shadow(color: .black, radius: 0, x: 0, y: 1)
            .shadow(color: .black.opacity(0.8), radius: settings.shadowRadius)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 12)
            .padding(.vertical, settings.backgroundEnabled ? 6 : 0)
            .background(settings.backgroundEnabled
                        ? RoundedRectangle(cornerRadius: settings.backgroundCornerRadius).fill(settings.backgroundFill)
                        : nil)
            .padding(.bottom, 18)
    }

    #if !os(tvOS)
    private func sliderRow(_ title: String, value: Binding<Double>, in range: ClosedRange<Double>,
                           step: Double, text: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                Spacer()
                Text(text)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            Slider(value: value, in: range, step: step)
        }
    }
    #endif
}

// MARK: - Reader Settings

#if !os(tvOS)
struct ReaderSettingsView: View {
    @AppStorage("readerLiquidGlass") private var readerLiquidGlass = true
    @AppStorage("readerPageCurl") private var readerPageCurl = true
    @AppStorage("readerPortraitOnly") private var readerPortraitOnly = false
    @AppStorage(ReaderTapZone.enabledKey) private var tapZones = true
    @AppStorage(ReaderTapZone.reversedKey) private var tapZonesReversed = false

    var body: some View {
        SettingsList {
            Section {
                Toggle("Tap Sides to Scroll or Turn", isOn: $tapZones)
                    .tint(.secondary)
            } header: {
                Text("Tap Zones")
            } footer: {
                Text(tapZones
                     ? "\(Self.tapVerb) the right side to scroll down or turn to the next page, the left to go back; right to left reading swaps them. The middle shows and hides the controls."
                     : "A \(Self.tapVerb.lowercased()) anywhere on a page shows and hides the controls.")
            }
            Section {
                Toggle("Reverse Direction", isOn: $tapZonesReversed)
                    .tint(.secondary)
            } header: {
                Text("Vertical Scroll")
            } footer: {
                Text("Runs the page slider and the chapter buttons from right to left, and swaps the \(Self.tapVerb.lowercased()) sides with them.")
            }
            // A Mac's reader turns pages with a slide; there's no curl to turn off.
            #if os(iOS)
            Section {
                Toggle("Page Curl", isOn: $readerPageCurl)
                    .tint(.secondary)
            } header: {
                Text("Turning Pages")
            } footer: {
                Text("Turn pages with a curl, like a book, in the paged reading modes. Turn off to slide them instead.")
            }
            // An iPad turns everywhere, so this only means something on iPhone.
            if UIDevice.current.userInterfaceIdiom == .phone {
                Section {
                    Toggle("Portrait Only", isOn: $readerPortraitOnly)
                        .tint(.secondary)
                } header: {
                    Text("Orientation")
                } footer: {
                    Text("Keep the reader upright. Turn off to read sideways when you turn your phone.")
                }
            }
            #endif
            if #available(iOS 26.0, macOS 26.0, *) {
                Section {
                    Toggle("Liquid Glass Controls", isOn: $readerLiquidGlass)
                        .tint(.secondary)
                } header: {
                    Text("Style")
                } footer: {
                    Text("Frosted glass buttons in the manga reader. Turn off for solid controls.")
                }
            } else {
                Section {
                    Text("Liquid Glass reader controls need \(Self.systemName) 26.")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .softScrollEdges()
        .navigationTitle("Reader")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }

    private static var tapVerb: String {
        #if os(macOS)
        "Click"
        #else
        "Tap"
        #endif
    }

    private static var systemName: String {
        #if os(macOS)
        "macOS"
        #else
        "iOS"
        #endif
    }
}
#endif

// MARK: - Modules Settings

struct ModulesSettingsView: View {
    @AppStorage("useDefaultExtension") private var useDefaultExtension = false
    @AppStorage("autoPickLastSearchResult") private var autoPickLastSearchResult = false
    @AppStorage("autoPickLastStream") private var autoPickLastStream = false
    @EnvironmentObject private var moduleManager: ModuleManager
    @ObservedObject private var providerManager = ProviderManager.shared

    var body: some View {
        SettingsList {
            Section {
                NavigationLink {
                    ModuleListView()
                } label: {
                    HStack(spacing: 12) {
                        Group {
                            if let active = moduleManager.activeModule {
                                CachedAsyncImage(urlString: active.iconUrl ?? "", base64String: active.iconData)
                            } else {
                                AsyncImage(url: URL(string: providerManager.primary?.providerType.iconURL ?? "")) { phase in
                                    if case .success(let image) = phase {
                                        image.resizable().aspectRatio(contentMode: .fit)
                                    } else {
                                        Image(systemName: "list.bullet")
                                            .font(.title)
                                            .foregroundStyle(Color.red)
                                    }
                                }
                            }
                        }
                        .frame(width: 44, height: 44)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                        .background(Color.red.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))

                        VStack(alignment: .leading, spacing: 3) {
                            Text(moduleManager.activeModule?.sourceName ?? providerManager.primary?.providerType.displayName ?? "AniList")
                                .font(.headline)
                            Text("Manage Installed Modules")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 2)
                }
            }

            Section {
                Toggle("Use Default Extension", isOn: $useDefaultExtension)
                    .tint(.secondary)
                    .disabled(moduleManager.activeModule == nil)
                Toggle("Auto-pick Last Search Result", isOn: $autoPickLastSearchResult)
                    .tint(.secondary)
                Toggle("Auto-pick Last Stream", isOn: $autoPickLastStream)
                    .tint(.secondary)
            } header: {
                Text("Automation")
            } footer: {
                Text("Auto-pick choices reuse your previous source and stream selections when opening an episode or chapter.")
            }
        }
        .softScrollEdges()
        .navigationTitle("Modules")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }
}

// MARK: - Library Settings

struct LibrarySettingsView: View {
    @AppStorage("titleLanguagePriority") private var titlePriority = "english,romaji,native"
    @AppStorage("localAutoTrackEnabled") private var localAutoTrackEnabled = true
    @AppStorage("localScoreFormat") private var localScoreFormatRaw: String = ScoreFormat.point10Decimal.rawValue
    @AppStorage(GooeyRefreshGeometry.settingKey) private var gooeyRefresh = true
    @AppStorage(NewEpisodeTracker.badgesKey) private var newEpisodeBadges = true
    @AppStorage(CardTitleSetting.hiddenKey) private var hideCardTitles = false
    @AppStorage(DetailLayoutSetting.cinematicKey) private var cinematicDetailLayout = true
    @AppStorage(DetailLayoutSetting.cinematicHomeKey) private var cinematicHomeLayout = true
    @State private var showClearLocalLibrary = false

    private var orderedLanguages: [String] {
        titlePriority.components(separatedBy: ",").filter { !$0.isEmpty }
    }

    var body: some View {
        SettingsList {
            Section {
                NavigationLink {
                    LibraryListOrderView()
                } label: {
                    Label("List Order & Custom Lists", systemImage: "list.bullet.indent")
                }
            }

            Section {
                Toggle("New Episode Badges", isOn: $newEpisodeBadges)
                    .tint(.secondary)
                Text("Marks shows you're watching that have aired episodes you haven't seen, with a dot for ones that came out since you last opened the show. Sort by New Episodes First from the Library's sort menu.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Toggle("Hide Titles on Cards", isOn: $hideCardTitles)
                    .tint(.secondary)
                Text("Posters from TVDB carry the show's name, so the title over them says it twice. Hold a card for its full title.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Text("Cards")
            }

            if DetailLayoutSetting.isOffered {
                Section {
                    Toggle("Cinematic Home", isOn: $cinematicHomeLayout)
                        .tint(.secondary)
                    Toggle("Cinematic Detail Pages", isOn: $cinematicDetailLayout)
                        .tint(.secondary)
                } header: {
                    Text("Layout")
                } footer: {
                    Text("The featured show's artwork fills the window, with the rows scrolling up over it. Turn off for Home's banner with the rows under it, and for a show's poster with its episode list.")
                }
            }

            #if os(iOS)
            Section {
                Toggle("Gooey Pull to Refresh", isOn: $gooeyRefresh)
                    .tint(.secondary)
            } footer: {
                Text("Pulling to refresh stretches a drop out of the Dynamic Island that holds the spinner. Turn off for a frosted circle instead, as sheets always use.")
            }
            #endif

            Section("Matching") {
                ForEach(orderedLanguages, id: \.self) { lang in
                    HStack {
                        Image(systemName: "line.3.horizontal")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                        Text(lang.capitalized)
                    }
                }
                .onMove { from, to in
                    var langs = orderedLanguages
                    langs.move(fromOffsets: from, toOffset: to)
                    titlePriority = langs.joined(separator: ",")
                }
                Text("Drag to reorder title priority for display and matching.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            #if os(iOS)
            .environment(\.editMode, .constant(.active))
            #endif

            Section {
                Toggle("Auto-track what you watch", isOn: $localAutoTrackEnabled)
                    .tint(.secondary)
                Picker("Score Format", selection: $localScoreFormatRaw) {
                    Text("100 Point").tag(ScoreFormat.point100.rawValue)
                    Text("10 Point (Decimal)").tag(ScoreFormat.point10Decimal.rawValue)
                    Text("10 Point").tag(ScoreFormat.point10.rawValue)
                    Text("5 Star").tag(ScoreFormat.point5.rawValue)
                    Text("3 Point").tag(ScoreFormat.point3.rawValue)
                }
                Button(role: .destructive) {
                    showClearLocalLibrary = true
                } label: {
                    Label("Clear Local Library", systemImage: "trash")
                }
            } header: {
                Text("Local Library")
            } footer: {
                Text("Your on-device library works without signing in. Auto-track keeps its Watching list in sync with what you watch.")
            }
            .alert("Clear Local Library", isPresented: $showClearLocalLibrary) {
                Button("Clear", role: .destructive) { LocalLibraryManager.shared.clearAll() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This permanently removes all on-device entries and collections. AniList/MyAnimeList lists are not affected.")
            }
        }
        .softScrollEdges()
        .navigationTitle("Library")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }
}

// MARK: - Library List Order View

struct LibraryListOrderView: View {
    @AppStorage("libraryStatusOrder") private var statusOrderRaw: String = MediaListStatus.allCases.map(\.rawValue).joined(separator: ",")

    private var statuses: [MediaListStatus] {
        let saved = statusOrderRaw.components(separatedBy: ",").compactMap(MediaListStatus.init(rawValue:))
        let missing = MediaListStatus.allCases.filter { !saved.contains($0) }
        return saved + missing
    }

    private var customListNames: [String] {
        UserDefaults.standard.stringArray(forKey: "libraryCustomListNames") ?? []
    }

    var body: some View {
        List {
            Section {
                ForEach(statuses) { status in
                    Label(status.displayName, systemImage: icon(for: status))
                }
                .onMove { from, to in
                    var list = statuses
                    list.move(fromOffsets: from, toOffset: to)
                    statusOrderRaw = list.map(\.rawValue).joined(separator: ",")
                }
            } header: {
                Text("Drag to reorder status tabs")
            }

            if !customListNames.isEmpty {
                Section {
                    ForEach(customListNames, id: \.self) { name in
                        Label(name, systemImage: "list.star")
                    }
                } header: {
                    Text("Custom Lists")
                } footer: {
                    Text("Custom lists are managed on AniList.")
                }
            }
        }
        .softScrollEdges()
        .navigationTitle("List Order")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        .environment(\.editMode, .constant(.active))
        #endif
    }

    private func icon(for status: MediaListStatus) -> String {
        switch status {
        case .current:   return "play.circle"
        case .planning:  return "bookmark"
        case .completed: return "checkmark.circle"
        case .dropped:   return "xmark.circle"
        case .paused:    return "pause.circle"
        case .repeating: return "arrow.counterclockwise.circle"
        }
    }
}

// MARK: - Downloads Settings

struct DownloadsSettingsView: View {
    @AppStorage("maxConcurrentDownloads") private var maxConcurrentDownloads: Int = 3
    @AppStorage("backgroundDownloadsEnabled") private var backgroundDownloadsEnabled = true
    @AppStorage("autoResumeDownloads") private var autoResumeDownloads = false
    @AppStorage("autoDeleteWatched") private var autoDeleteWatched = false
    @AppStorage("downloadQuality") private var downloadQuality = "highest"
    #if !os(tvOS)
    @State private var downloadsSize = 0
    @State private var showDeleteDownloadsConfirmation = false
    #endif

    var body: some View {
        SettingsList {
            Section("Downloads") {
                Picker("Download Quality", selection: $downloadQuality) {
                    Text("Best").tag("highest")
                    Text("1080p").tag("1080")
                    Text("720p").tag("720")
                    Text("480p").tag("480")
                    Text("Smallest").tag("lowest")
                }
                Picker("Concurrent Downloads", selection: $maxConcurrentDownloads) {
                    ForEach(1...5, id: \.self) { count in
                        Text("\(count)").tag(count)
                    }
                }
                // A Mac app keeps running in the background; only iOS has to ask to.
                #if os(iOS)
                Toggle("Background Downloads", isOn: $backgroundDownloadsEnabled)
                    .tint(.secondary)
                #endif
                Toggle("Auto-Resume Interrupted", isOn: $autoResumeDownloads)
                    .tint(.secondary)
                Toggle("Delete After Watching", isOn: $autoDeleteWatched)
                    .tint(.secondary)
                Text("Download Quality picks the rendition for streams that offer several, falling back to the closest below. A downloaded episode keeps the one it was saved in. Delete After Watching removes a downloaded episode once you finish it and close the player. Retry downloads that were interrupted or failed when the app next opens — off by default so reopening the app never starts a large transfer on cellular without you asking.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            #if !os(tvOS)
            Section {
                Button(role: .destructive) {
                    showDeleteDownloadsConfirmation = true
                } label: {
                    LabeledContent("Delete All Downloads") {
                        Text(SettingsView.formattedBytes(downloadsSize))
                            .foregroundStyle(.secondary)
                    }
                }
                .foregroundStyle(.red)
                .disabled(downloadsSize == 0)
            } footer: {
                Text("Removes every downloaded episode and chapter. Kept out of cache resets — these are files you saved for offline use, not a cache the app can rebuild.")
            }
            #endif
        }
        .softScrollEdges()
        .navigationTitle("Downloads")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        #if !os(tvOS)
        .alert("Delete All Downloads?", isPresented: $showDeleteDownloadsConfirmation) {
            Button("Delete", role: .destructive) {
                DownloadManager.shared.removeAll(DownloadManager.shared.items)
                MangaDownloadManager.shared.removeAll(MangaDownloadManager.shared.items)
                downloadsSize = DownloadManager.shared.bytesOnDisk + MangaDownloadManager.shared.bytesOnDisk
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Every downloaded episode and chapter will be removed from this device. You can download them again later.")
        }
        .onAppear {
            downloadsSize = DownloadManager.shared.bytesOnDisk + MangaDownloadManager.shared.bytesOnDisk
        }
        #endif
    }
}

// MARK: - Storage & Cache Settings

#if !os(tvOS)
struct StorageSettingsView: View {
    @AppStorage(DataSaver.key) private var dataSaverEnabled = false
    @State private var imageCacheSize = 0
    @State private var websiteDataSize = 0
    @State private var tempFilesSize = 0
    @State private var continueWatchingSize = 0
    @State private var networkCacheSize = 0
    @State private var dataCacheSize = 0
    @State private var searchAliasSize = 0
    @State private var idMappingSize = 0
    @State private var episodeSortSize = 0
    @State private var totalUsage = 0
    @State private var isClearing = false
    @State private var showResetCWConfirmation = false
    @State private var downloadsSize = 0
    @State private var showDeleteDownloadsConfirmation = false

    var body: some View {
        SettingsList {
            Section("Data") {
                Toggle("Data Saver", isOn: $dataSaverEnabled)
                    .tint(.secondary)
                Text("Loads smaller artwork and skips the large banner images on Home. Posters look softer; everything still works, and downloads and playback are unaffected.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Storage & Cache") {
                Button(role: .destructive) {
                    guard !isClearing else { return }
                    isClearing = true
                    Task {
                        await CacheManager.shared.clearEverything()
                        isClearing = false
                        updateCacheSizes()
                    }
                } label: {
                    LabeledContent("Clear Everything") {
                        if isClearing {
                            ProgressView().scaleEffect(0.7)
                        } else {
                            Text(SettingsView.formattedBytes(totalUsage))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .foregroundStyle(.red)
                .disabled(isClearing)

                DisclosureGroup("Individual Resets") {
                    Button {
                        Task {
                            await CacheManager.shared.clearImageCache()
                            updateCacheSizes()
                        }
                    } label: {
                        LabeledContent("Reset Image Cache") {
                            Text(SettingsView.formattedBytes(imageCacheSize))
                                .foregroundStyle(.secondary)
                        }
                    }
                    .foregroundStyle(.primary)

                    Button {
                        guard !isClearing else { return }
                        isClearing = true
                        Task {
                            await CacheManager.shared.clearWebsiteData()
                            totalUsage -= websiteDataSize
                            websiteDataSize = 0
                            isClearing = false
                        }
                    } label: {
                        LabeledContent("Reset Website Data") {
                            Text(SettingsView.formattedBytes(websiteDataSize))
                                .foregroundStyle(.secondary)
                        }
                    }
                    .foregroundStyle(.primary)

                    Button {
                        CacheManager.shared.clearNetworkCache()
                        updateCacheSizes()
                    } label: {
                        LabeledContent("Reset Network Cache") {
                            Text(SettingsView.formattedBytes(networkCacheSize))
                                .foregroundStyle(.secondary)
                        }
                    }
                    .foregroundStyle(.primary)

                    Button {
                        CacheManager.shared.clearDataCaches()
                        updateCacheSizes()
                    } label: {
                        LabeledContent("Reset Home & Simkl Cache") {
                            Text(SettingsView.formattedBytes(dataCacheSize))
                                .foregroundStyle(.secondary)
                        }
                    }
                    .foregroundStyle(.primary)

                    Button {
                        CacheManager.shared.clearTempFiles()
                        updateCacheSizes()
                    } label: {
                        LabeledContent("Clear Temporary Files") {
                            Text(SettingsView.formattedBytes(tempFilesSize))
                                .foregroundStyle(.secondary)
                        }
                    }
                    .foregroundStyle(.primary)

                    Button {
                        CacheManager.shared.clearSearchAliases()
                        updateCacheSizes()
                    } label: {
                        LabeledContent("Reset Search Aliases") {
                            Text(SettingsView.formattedBytes(searchAliasSize))
                                .foregroundStyle(.secondary)
                        }
                    }
                    .foregroundStyle(.primary)

                    Button {
                        CacheManager.shared.clearIDMappingCache()
                        updateCacheSizes()
                    } label: {
                        LabeledContent("Reset ID Mapping Cache") {
                            Text(SettingsView.formattedBytes(idMappingSize))
                                .foregroundStyle(.secondary)
                        }
                    }
                    .foregroundStyle(.primary)

                    Button {
                        CacheManager.shared.clearEpisodeSortPreferences()
                        updateCacheSizes()
                    } label: {
                        LabeledContent("Reset Episode Sort Preferences") {
                            Text(SettingsView.formattedBytes(episodeSortSize))
                                .foregroundStyle(.secondary)
                        }
                    }
                    .foregroundStyle(.primary)

                    Button {
                        showResetCWConfirmation = true
                    } label: {
                        LabeledContent("Reset Watch Progress") {
                            Text(SettingsView.formattedBytes(continueWatchingSize))
                                .foregroundStyle(.secondary)
                        }
                    }
                    .foregroundStyle(.red)
                }
                .font(.subheadline)
                .disabled(isClearing)

                Text("Clear Everything removes caches the app can rebuild. It keeps your watch progress, which has its own reset. Website Data includes cookies and local storage from module scrapers. Search Aliases store remembered search results and stream picks per module. The Network Cache holds saved answers from sites and services.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Button(role: .destructive) {
                    showDeleteDownloadsConfirmation = true
                } label: {
                    LabeledContent("Delete All Downloads") {
                        Text(SettingsView.formattedBytes(downloadsSize))
                            .foregroundStyle(.secondary)
                    }
                }
                .foregroundStyle(.red)
                .disabled(downloadsSize == 0)
                NavigationLink("Download Settings") { DownloadsSettingsView() }
            } header: {
                Text("Downloads")
            } footer: {
                Text("Downloaded episodes and chapters aren't a cache, so Clear Everything leaves them alone. Delete single episodes from the Downloads tab, or turn on Delete After Watching in Download Settings.")
            }
        }
        .alert("Delete All Downloads?", isPresented: $showDeleteDownloadsConfirmation) {
            Button("Delete", role: .destructive) {
                DownloadManager.shared.removeAll(DownloadManager.shared.items)
                MangaDownloadManager.shared.removeAll(MangaDownloadManager.shared.items)
                downloadsSize = DownloadManager.shared.bytesOnDisk + MangaDownloadManager.shared.bytesOnDisk
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Every downloaded episode and chapter will be removed from this device. You can download them again later.")
        }
        .softScrollEdges()
        .navigationTitle("Storage & Cache")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .alert("Reset Watch Progress?", isPresented: $showResetCWConfirmation) {
            Button("Reset", role: .destructive) {
                CacheManager.shared.clearContinueWatching()
                updateCacheSizes()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            // It takes the watched marks too: the old wording promised only the Home cards, and a
            // separate Watch History reset, of data nothing writes any more, promised the marks.
            Text("Clears Continue Watching and every Watched mark in episode lists on this device. AniList, MyAnimeList and Simkl aren't changed.")
        }
        .onAppear {
            updateCacheSizes()
        }
    }

    private func updateCacheSizes() {
        downloadsSize = DownloadManager.shared.bytesOnDisk + MangaDownloadManager.shared.bytesOnDisk
        websiteDataSize = CacheManager.shared.websiteDataSize
        tempFilesSize = CacheManager.shared.tempFilesSize
        continueWatchingSize = CacheManager.shared.continueWatchingSize
        networkCacheSize = CacheManager.shared.networkCacheSize
        dataCacheSize = CacheManager.shared.dataCacheSize
        searchAliasSize = CacheManager.shared.searchAliasSize
        idMappingSize = CacheManager.shared.idMappingSize
        episodeSortSize = CacheManager.shared.episodeSortSize
        Task {
            imageCacheSize = await CacheManager.shared.imageCacheSize
            totalUsage = await CacheManager.shared.totalDiskUsage
        }
    }
}
#endif

// MARK: - App directories

/// Where the app keeps the files it writes itself: logs, download manifests, downloads.
enum AppDirectories {
    /// The app's own Documents on iOS, which the Files app can browse. On the Mac, an
    /// unsandboxed app's Documents is the user's `~/Documents`, which macOS guards: writing
    /// logs and manifests there asked for permission to the Documents folder, and asked again
    /// on every launch of a build signed without a stable identity. Application Support needs
    /// no permission.
    static let documents: URL = {
        #if os(macOS) || targetEnvironment(macCatalyst)
        let fm = FileManager.default
        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Shirox", isDirectory: true)
        try? fm.createDirectory(at: base, withIntermediateDirectories: true)
        moveOutOfDocumentsOnce(to: base)
        return base
        #else
        return FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        #endif
    }()

    /// Where the app keeps its own files: modules, caches, the local library. The system's
    /// Application Support on iOS, which is the app's alone. An unsandboxed Mac app shares
    /// `~/Library/Application Support` with every other app, so there it's a Shirox folder.
    static let applicationSupport: URL = {
        let fm = FileManager.default
        let root = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        #if os(macOS) || targetEnvironment(macCatalyst)
        let base = root.appendingPathComponent("Shirox", isDirectory: true)
        try? fm.createDirectory(at: base, withIntermediateDirectories: true)
        moveOutOfSharedSupportOnce(from: root, to: base)
        return base
        #else
        try? fm.createDirectory(at: root, withIntermediateDirectories: true)
        return root
        #endif
    }()

    #if os(macOS) || targetEnvironment(macCatalyst)
    /// Files earlier Mac builds left loose in `~/Library/Application Support`.
    private static let looseSupportFiles = [
        "modules.json", "id-mappings.json", "id-media-mappings.json", "id-tvdb-groups.json",
        "local_library.json", "pending-writes.json", "library-cache.json", "profile-cache.json",
        "home-cache.json", "simkl-write-queue.json", "LocalImports",
    ]

    /// Moves them into the Shirox folder, once. `modules.json` is a common name, so it goes only
    /// when it holds Shirox modules.
    private static func moveOutOfSharedSupportOnce(from root: URL, to base: URL) {
        let key = "movedFilesIntoSupportFolder"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        UserDefaults.standard.set(true, forKey: key)
        let fm = FileManager.default
        for name in looseSupportFiles {
            let from = root.appendingPathComponent(name)
            let to = base.appendingPathComponent(name)
            guard fm.fileExists(atPath: from.path), !fm.fileExists(atPath: to.path) else { continue }
            if name == "modules.json" {
                guard let data = try? Data(contentsOf: from),
                      String(decoding: data.prefix(4096), as: UTF8.self).contains("scriptContent") else { continue }
            }
            try? fm.moveItem(at: from, to: to)
        }
    }

    /// Brings downloads and their manifests over from `~/Documents`, where earlier Mac builds
    /// kept them. Once only, whatever happens: if macOS is told not to allow it, the app
    /// doesn't keep asking.
    private static func moveOutOfDocumentsOnce(to base: URL) {
        let key = "movedFilesOutOfDocuments"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        UserDefaults.standard.set(true, forKey: key)
        moveDownloads(from: FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0], to: base)
    }
    #endif

    /// Moves Shirox's downloads and their manifests from `old` to `base`. A folder goes only with
    /// its manifest beside it: `~/Documents/Downloads` is a common name, and one with no Shirox
    /// manifest next to it is the user's own, which an earlier build moved out of sight.
    static func moveDownloads(from old: URL, to base: URL) {
        let fm = FileManager.default
        for (folder, manifest) in [("Downloads", "downloads_manifest.json"),
                                   ("MangaDownloads", "manga_downloads_manifest.json")] {
            guard fm.fileExists(atPath: old.appendingPathComponent(manifest).path) else { continue }
            for name in [manifest, folder] {
                let from = old.appendingPathComponent(name)
                let to = base.appendingPathComponent(name)
                guard fm.fileExists(atPath: from.path), !fm.fileExists(atPath: to.path) else { continue }
                try? fm.moveItem(at: from, to: to)
            }
        }
    }
}

// MARK: - Logger Views & Utilities

private func logTypeColor(_ type: String) -> Color {
    switch type {
    case "Error":       return .red
    case "Debug":       return .blue
    case "Stream":      return .green
    case "Download":    return .orange
    case "HTMLStrings": return .purple
    default:            return .secondary
    }
}

private func logTypeIcon(_ type: String) -> String {
    switch type {
    case "Error":       return "exclamationmark.triangle.fill"
    case "Debug":       return "ladybug.fill"
    case "Stream":      return "play.circle.fill"
    case "Download":    return "arrow.down.circle.fill"
    case "HTMLStrings": return "text.alignleft"
    default:            return "gear"
    }
}

struct LogEntryRow: View {
    let entry: Logger.LogEntry

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: logTypeIcon(entry.type))
                    .font(.caption)
                    .foregroundStyle(logTypeColor(entry.type))
                Text(entry.type.uppercased())
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(logTypeColor(entry.type))
                Spacer()
                Text(Self.timeFormatter.string(from: entry.timestamp))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .monospacedDigit()
            }
            Text(entry.message)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.primary)
                #if !os(tvOS)
                .textSelection(.enabled)
                #endif
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(logTypeColor(entry.type).opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(logTypeColor(entry.type).opacity(0.18), lineWidth: 1)
        )
    }
}

struct SettingsViewLogger: View {
    @State private var entries: [Logger.LogEntry] = []
    @State private var isLoading: Bool = true
    @State private var searchText: String = ""
    @StateObject private var filterViewModel = LogFilterViewModel.shared

    private var filteredEntries: [Logger.LogEntry] {
        let base = searchText.isEmpty ? entries : entries.filter {
            $0.message.localizedCaseInsensitiveContains(searchText) || $0.type.localizedCaseInsensitiveContains(searchText)
        }
        return base.reversed()
    }

    var body: some View {
        Group {
            if isLoading {
                ProgressView("Loading logs…")
            } else if filteredEntries.isEmpty {
                ContentUnavailableView(
                    entries.isEmpty ? "No Logs" : "No Results",
                    systemImage: entries.isEmpty ? "doc.text" : "magnifyingglass",
                    description: Text(entries.isEmpty ? "Nothing has been logged yet." : "No logs match your search.")
                )
            } else {
                ScrollView {
                    LazyVStack(spacing: 6) {
                        ForEach(filteredEntries) { entry in
                            LogEntryRow(entry: entry)
                        }
                    }
                    .padding()
                }
                .softScrollEdges()
            }
        }
        .searchable(text: $searchText, prompt: "Search logs")
        .navigationTitle("Logs")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .onAppear { loadEntries() }
        .toolbar {
            ToolbarItemGroup(placement: .automatic) {
                Menu {
                    Button {
                        let text = entries.map { "[\($0.type)] \($0.message)" }.joined(separator: "\n")
                        #if os(iOS)
                        UIPasteboard.general.string = text
                        #elseif os(macOS)
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(text, forType: .string)
                        #endif
                    } label: {
                        Label("Copy to Clipboard", systemImage: "doc.on.doc")
                    }
                    Button(role: .destructive) {
                        Task {
                            await Logger.shared.clearLogsAsync()
                            await MainActor.run { entries = [] }
                        }
                    } label: {
                        Label("Clear Logs", systemImage: "trash")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }

                NavigationLink(destination: SettingsViewLoggerFilter(viewModel: filterViewModel)) {
                    Image(systemName: "slider.horizontal.3")
                }
            }
        }
    }

    private func loadEntries() {
        Task {
            let loaded = await Logger.shared.getLogEntriesAsync()
            await MainActor.run {
                self.entries = loaded
                self.isLoading = false
            }
        }
    }
}

struct SettingsViewLoggerFilter: View {
    @ObservedObject var viewModel = LogFilterViewModel.shared

    var body: some View {
        SettingsList {
            Section(header: Text("Log Types"), footer: Text("Choose which log categories to record. Debug and HTMLStrings can be very verbose.")) {
                ForEach($viewModel.filters) { $filter in
                    Toggle(isOn: $filter.isEnabled) {
                        Label {
                            Text(filter.type)
                        } icon: {
                            Image(systemName: logTypeIcon(filter.type))
                                .foregroundStyle(logTypeColor(filter.type))
                        }
                    }
                    .tint(logTypeColor(filter.type))
                }
            }
        }
        .softScrollEdges()
        .navigationTitle("Log Filters")
    }
}

struct LogFilter: Identifiable, Hashable {
    let id = UUID()
    let type: String
    var isEnabled: Bool
    let description: String
}

class LogFilterViewModel: ObservableObject {
    nonisolated(unsafe) static let shared = LogFilterViewModel()
    
    @Published var filters: [LogFilter] = [] {
        didSet {
            saveFiltersToUserDefaults()
        }
    }
    
    private let userDefaultsKey = "LogFilterStates"
    private let hardcodedFilters: [(type: String, description: String, defaultState: Bool)] = [
        ("General", "General events and activities.", true),
        ("Stream", "Streaming and video playback.", true),
        ("Error", "Errors and critical issues.", true),
        ("Debug", "Debugging and troubleshooting.", false),
        ("Network", "Network requests and responses.", false),
        ("Download", "HLS video downloading.", true),
        ("HTMLStrings", "Raw HTML response strings.", false)
    ]
    
    private init() {
        loadFilters()
    }
    
    func loadFilters() {
        if let savedStates = UserDefaults.standard.dictionary(forKey: userDefaultsKey) as? [String: Bool] {
            filters = hardcodedFilters.map {
                LogFilter(
                    type: $0.type,
                    isEnabled: savedStates[$0.type] ?? $0.defaultState,
                    description: $0.description
                )
            }
        } else {
            filters = hardcodedFilters.map {
                LogFilter(type: $0.type, isEnabled: $0.defaultState, description: $0.description)
            }
        }
    }
    
    func toggleFilter(for type: String) {
        if let index = filters.firstIndex(where: { $0.type == type }) {
            filters[index].isEnabled.toggle()
        }
    }
    
    func isFilterEnabled(for type: String) -> Bool {
        return filters.first(where: { $0.type == type })?.isEnabled ?? true
    }
    
    private func saveFiltersToUserDefaults() {
        let states = filters.reduce(into: [String: Bool]()) { result, filter in
            result[filter.type] = filter.isEnabled
        }
        UserDefaults.standard.set(states, forKey: userDefaultsKey)
    }
}

class Logger: @unchecked Sendable {
    static let shared = Logger()

    struct LogEntry: Identifiable {
        let id = UUID()
        let message: String
        let type: String
        let timestamp: Date
    }
    
    private let queue = DispatchQueue(label: "com.shirox.logger", attributes: .concurrent)
    private var logs: [LogEntry] = []
    private let logFileURL: URL
    private let logFilterViewModel = LogFilterViewModel.shared

    private let maxFileSize = 1024 * 512
    private let maxLogEntries = 1000 
    
    private init() {
        logFileURL = AppDirectories.documents.appendingPathComponent("logs.txt")
    }
    
    /// Query/fragment keys whose values must never reach the log file.
    private static let sensitiveURLKeys: Set<String> = [
        "access_token", "refresh_token", "id_token", "token", "api_key", "apikey",
        "code", "client_secret", "password", "x-emby-token"
    ]

    /// Marker substituted for redacted values. Deliberately free of characters that URL
    /// serialization would percent-encode, so the marker stays readable in the log.
    static let redactionMarker = "REDACTED"

    /// URL rendered safe for the log file: sensitive query values and any fragment are replaced
    /// with `redactionMarker`. These logs are written to logs.txt and exported from Settings → App Logs,
    /// which is what users paste into bug reports — so a stream URL carrying a Jellyfin `api_key`,
    /// or an OAuth callback carrying `#access_token=…`, must not be written verbatim.
    static func redact(_ url: URL) -> String {
        guard var comps = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return "\(url.scheme ?? "?")://\(url.host ?? "?")/\(redactionMarker)"
        }
        if let items = comps.queryItems {
            comps.queryItems = items.map { item in
                sensitiveURLKeys.contains(item.name.lowercased())
                    ? URLQueryItem(name: item.name, value: redactionMarker)
                    : item
            }
        }
        if comps.fragment != nil { comps.fragment = redactionMarker }
        return comps.string ?? "\(url.scheme ?? "?")://\(url.host ?? "?")\(url.path)"
    }

    func log(_ message: String, type: String = "General") {
        guard logFilterViewModel.isFilterEnabled(for: type) else { return }
        
        let entry = LogEntry(message: message, type: type, timestamp: Date())
        
        queue.async(flags: .barrier) {
            self.logs.append(entry)
            
            if self.logs.count > self.maxLogEntries {
                self.logs.removeFirst(self.logs.count - self.maxLogEntries)
            }
            
            self.saveLogToFile(entry)
            self.debugLog(entry)
        }
    }
    
    func getLogs() -> String {
        var result = ""
        queue.sync {
            let dateFormatter = DateFormatter()
            dateFormatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
            result = logs.map { "[\(dateFormatter.string(from: $0.timestamp))] [\($0.type.uppercased())]\n\($0.message)" }
            .joined(separator: "\n\n" + String(repeating: "─", count: 20) + "\n\n")
        }
        return result
    }
    
    func getLogsAsync() async -> String {
        return await withCheckedContinuation { continuation in
            queue.async {
                let dateFormatter = DateFormatter()
                dateFormatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
                let result = self.logs.map { "[\(dateFormatter.string(from: $0.timestamp))] [\($0.type.uppercased())]\n\($0.message)" }
                .joined(separator: "\n\n" + String(repeating: "─", count: 20) + "\n\n")
                continuation.resume(returning: result)
            }
        }
    }

    func getLogEntriesAsync() async -> [LogEntry] {
        return await withCheckedContinuation { continuation in
            queue.async {
                continuation.resume(returning: self.logs)
            }
        }
    }
    
    func clearLogs() {
        queue.async(flags: .barrier) {
            self.logs.removeAll()
            try? FileManager.default.removeItem(at: self.logFileURL)
        }
    }
    
    func clearLogsAsync() async {
        await withCheckedContinuation { continuation in
            queue.async(flags: .barrier) {
                self.logs.removeAll()
                try? FileManager.default.removeItem(at: self.logFileURL)
                continuation.resume()
            }
        }
    }
    
    private func saveLogToFile(_ log: LogEntry) {
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        
        let separator = String(repeating: "─", count: 20)
        let logString = "[\(dateFormatter.string(from: log.timestamp))] [\(log.type.uppercased())]\n\(log.message)\n\(separator)\n"
        
        guard let data = logString.data(using: .utf8) else {
            return
        }
        
        do {
            if FileManager.default.fileExists(atPath: logFileURL.path) {
                let attributes = try FileManager.default.attributesOfItem(atPath: logFileURL.path)
                let fileSize = attributes[.size] as? UInt64 ?? 0
                
                if fileSize + UInt64(data.count) > maxFileSize {
                    self.truncateLogFile()
                }
                
                if let handle = try? FileHandle(forWritingTo: logFileURL) {
                    handle.seekToEndOfFile()
                    handle.write(data)
                    handle.closeFile()
                }
            } else {
                try data.write(to: logFileURL)
            }
        } catch {
            try? data.write(to: logFileURL)
        }
    }
    
    private func truncateLogFile() {
        do {
            guard let content = try? String(contentsOf: logFileURL, encoding: .utf8),
                  !content.isEmpty else {
                return
            }
            
            let separator = String(repeating: "─", count: 20)
            let entries = content.components(separatedBy: "\n\(separator)\n")
            guard entries.count > 10 else { return }
            
            let keepCount = entries.count / 2
            let truncatedEntries = Array(entries.suffix(keepCount))
            let truncatedContent = truncatedEntries.joined(separator: "\n\(separator)\n")
            
            if let truncatedData = truncatedContent.data(using: .utf8) {
                try truncatedData.write(to: logFileURL)
            }
        } catch {
            try? FileManager.default.removeItem(at: logFileURL)
        }
    }
    
    private func debugLog(_ entry: LogEntry) {
#if DEBUG
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "dd-MM HH:mm:ss"
        let formattedMessage = "[\(dateFormatter.string(from: entry.timestamp))] [\(entry.type)] \(entry.message)"
        print(formattedMessage)
#endif
    }
}

// MARK: - Providers Settings Section

private struct ProvidersSettingsSection: View {
    @ObservedObject private var manager = ProviderManager.shared
    @ObservedObject private var malAuth = MALAuthManager.shared
    @ObservedObject private var aniListAuth = AniListAuthManager.shared
    #if os(iOS)
    @State private var presentationWindow: UIWindow?
    #endif

    var body: some View {
        Section {
            ForEach(manager.orderedProviders, id: \.providerType) { provider in
                HStack(spacing: 12) {
                    Image(systemName: "line.3.horizontal")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    CachedAsyncImage(urlString: provider.providerType.iconURL)
                        .frame(width: 28, height: 28)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(provider.providerType.displayName)
                            .font(.headline)
                        Text(providerStatus(provider))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    HStack(spacing: 8) {
                        if manager.orderedProviders.first?.providerType == provider.providerType {
                            Text("Primary")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(Color.accentColor)
                                .padding(.horizontal, 8).padding(.vertical, 3)
                                .background(.primary.opacity(0.1), in: Capsule())
                        } else if isSignedIn(provider.providerType) {
                            Button("Make Primary") {
                                manager.selectProvider(provider.providerType)
                            }
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Color.accentColor)
                            .padding(.horizontal, 8).padding(.vertical, 3)
                            .background(Color.accentColor.opacity(0.1), in: Capsule())
                            .buttonStyle(.plain)
                        }
                        #if !os(tvOS)
                        providerAuthButton(for: provider.providerType)
                        #endif
                    }
                }
            }
            .onMove { from, to in
                manager.moveProvider(from: from, to: to)
            }
        } header: {
            Text("Providers")
        } footer: {
            Text("Drag to reorder. The first provider is primary; the second is used as fallback.")
        }
        #if os(iOS)
        .environment(\.editMode, .constant(.active))
        .onAppear {
            presentationWindow = UIApplication.shared.connectedScenes
                .compactMap { $0 as? UIWindowScene }
                .flatMap { $0.windows }
                .first { $0.isKeyWindow }
        }
        #endif
    }

    #if !os(tvOS)
    @ViewBuilder
    private func providerAuthButton(for type: ProviderType) -> some View {
        let isLoggedIn = type == .anilist ? aniListAuth.isLoggedIn : malAuth.isLoggedIn
        Button(isLoggedIn ? "Sign Out" : "Sign In") {
            if isLoggedIn {
                if type == .anilist { aniListAuth.logout() } else { malAuth.logout() }
            } else {
                #if os(iOS)
                let anchor = presentationWindow
                #else
                let anchor = keyPresentationAnchor()
                #endif
                if let window = anchor {
                    if type == .anilist {
                        aniListAuth.login(presentationAnchor: window)
                    } else {
                        malAuth.login(presentationAnchor: window)
                    }
                }
            }
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(isLoggedIn ? .red : Color.accentColor)
        .padding(.horizontal, 8).padding(.vertical, 3)
        .background((isLoggedIn ? Color.red : Color.accentColor).opacity(0.1), in: Capsule())
        .buttonStyle(.plain)
    }
    #endif

    private func isSignedIn(_ type: ProviderType) -> Bool {
        switch type {
        case .anilist: return aniListAuth.isLoggedIn
        case .mal:     return malAuth.isLoggedIn
        case .simkl:   return SimklAuthManager.shared.isLoggedIn   // listed in its own section
        case .local:   return false   // not a sign-in-able provider
        }
    }

    private func providerStatus(_ provider: any MediaProvider) -> String {
        switch provider.providerType {
        case .anilist:
            guard aniListAuth.isLoggedIn else { return "Not signed in" }
            // A token AniList has started refusing still has `isLoggedIn` true — the token is
            // kept on purpose, since a revoked one and a failing auth backend are
            // indistinguishable from here. Saying "Signed in" while every sync fails is the
            // part that left people with no idea what to do about it.
            return aniListAuth.needsReauthentication ? "Sign in again" : "Signed in"
        case .mal: return malAuth.isLoggedIn ? "Signed in" : "Not signed in"
        case .simkl: return SimklAuthManager.shared.isLoggedIn ? "Signed in" : "Not signed in"
        case .local: return "Not signed in"
        }
    }
}


/// Shows exactly what an overwrite or mirror would do before it does any of it. These runs can't be
/// undone, so the deletions are listed by name rather than just counted — a number is easy to
/// wave through, a list of titles you recognise is not.
private struct OverwritePreviewSheet: View {
    let run: SyncRun
    let plan: LibraryOverwritePlan
    let onConfirm: () -> Void
    let onCancel: () -> Void

    private var additions: Int { plan.writes.filter(\.isNew).count }
    private var overwrites: Int { plan.writes.filter { !$0.isNew }.count }

    var body: some View {
        NavigationView {
            List {
                Section {
                    Text(run.title)
                        .font(.headline)
                    Text(run.subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("What this will do") {
                    if plan.isEmpty {
                        Text("Nothing — \(run.targetName) already matches.")
                            .foregroundStyle(.secondary)
                    }
                    if additions > 0 { row("Add to \(run.targetName)", additions) }
                    if overwrites > 0 { row("Overwrite on \(run.targetName)", overwrites) }
                    if !plan.deletions.isEmpty {
                        row("Delete from \(run.targetName)", plan.deletions.count, tint: .red)
                    }
                    if plan.unchanged > 0 { row("Leave unchanged", plan.unchanged, tint: .secondary) }
                }

                if !plan.deletions.isEmpty {
                    Section("Will be deleted") {
                        ForEach(plan.deletions, id: \.id) { deletion in
                            Text(deletion.title)
                                .font(.callout)
                        }
                    }
                }

                if plan.keptUnverified > 0 || !plan.unmatched.isEmpty {
                    Section("Left alone") {
                        if plan.keptUnverified > 0 {
                            Text("\(plan.keptUnverified) on \(run.targetName) couldn't be matched against \(run.sourceName), so they're kept rather than deleted.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        if !plan.unmatched.isEmpty {
                            Text("\(plan.unmatched.count) on \(run.sourceName) have no \(run.targetName) entry to write to.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                Section {
                    Button(run.confirmButtonTitle, role: .destructive, action: onConfirm)
                        .disabled(plan.isEmpty)
                } footer: {
                    Text("This can't be undone.")
                }
            }
            .navigationTitle(run.confirmationTitle)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: onCancel)
                }
            }
        }
    }

    private func row(_ label: String, _ count: Int, tint: Color = .primary) -> some View {
        HStack {
            Text(label)
            Spacer()
            Text("\(count)")
                .foregroundStyle(tint)
        }
    }
}
