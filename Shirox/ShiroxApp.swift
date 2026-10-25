import Combine
import SwiftUI
#if os(iOS)
import UIKit
import AVFoundation
#if canImport(GoogleCast)
import GoogleCast
#endif

class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        configureAudioSession()
        configureURLSession()
        IDMappingService.shared.prefetchAllMappingsIfNeeded()
        #if os(iOS)
        configureGlobalBarAppearances()
        DownloadManager.shared.reconnectPendingTasks()
        #endif
        application.shortcutItems = QuickAction.registeredItems
        return true
    }

    func application(_ application: UIApplication,
                     configurationForConnecting connectingSceneSession: UISceneSession,
                     options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        if let shortcutItem = options.shortcutItem {
            let action = QuickAction(shortcutItem)
            MainActor.assumeIsolated {
                QuickActionManager.shared.pending = action
            }
        }
        let config = UISceneConfiguration(name: connectingSceneSession.configuration.name,
                                          sessionRole: connectingSceneSession.role)
        #if !targetEnvironment(macCatalyst)
        // A mirrored TV, where MPV's picture can go (see `ExternalDisplay`).
        if ExternalDisplay.isExternalDisplay(connectingSceneSession.role) {
            config.delegateClass = ExternalDisplaySceneDelegate.self
            return config
        }
        #endif
        config.delegateClass = SceneDelegate.self
        return config
    }

    func applicationWillTerminate(_ application: UIApplication) {
        #if !targetEnvironment(macCatalyst) || os(macOS) && canImport(GoogleCast)
        let bgTask = application.beginBackgroundTask { }
        Task { @MainActor in
            CastManager.shared.stopCasting()
            application.endBackgroundTask(bgTask)
        }
        // Small sleep to give the network request a chance to fire before the process is killed
        Thread.sleep(forTimeInterval: 0.5)
        #endif
    }

    func application(_ application: UIApplication, handleEventsForBackgroundURLSession identifier: String, completionHandler: @escaping () -> Void) {
        #if os(iOS)
        DownloadManager.shared.handleBackgroundEvents(identifier: identifier, completionHandler: completionHandler)
        #endif
    }

    func application(_ application: UIApplication, supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        #if targetEnvironment(macCatalyst) || os(macOS)
        return .all
        #elseif os(iOS)
        if UIDevice.current.userInterfaceIdiom == .pad {
            return .all
        }
        return PlayerPresenter.shared.orientationLock
        #else
        return .all
        #endif
    }

    private func configureAudioSession() {
        do {
            // Declare the category at launch (harmless — does NOT interrupt other
            // apps' audio). Activation is deferred to player open so system music
            // (Spotify/Apple Music) keeps playing while browsing the app.
            try AppAudioSession.configureForPlayback()
        } catch {
            Logger.shared.log("Failed to configure audio session: \(error)", type: "Error")
        }
    }

    func applicationDidEnterBackground(_ application: UIApplication) {
        // Background execution during a cast is held by BackgroundKeepAlive (the `audio`
        // exemption) and CastProxyServer's own assertion, both scoped to an actual session.
        //
        // What used to be here took an unconditional assertion on every backgrounding with
        // an EMPTY expiration handler and ended it 27s later on a timer. An assertion whose
        // handler doesn't end it is a watchdog termination if it ever expires first, and
        // taking one when nothing is casting just burns the app's budget.
    }

    private func configureURLSession() {
        let config = URLSessionConfiguration.default
        // Allow network transfers in background
        config.waitsForConnectivity = true
        config.shouldUseExtendedBackgroundIdleMode = true
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 3600
        // Create a default session with this config for general use
        _ = URLSession(configuration: config)
    }
}
#endif

@main
struct ShiroxApp: App {
#if os(iOS)
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
#endif
    @StateObject private var moduleManager = ModuleManager.shared
    @AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding = false
    #if targetEnvironment(macCatalyst) || os(macOS)
    // Read so View ▸ Home, Search… and their ⌘1, ⌘2… follow the tab order.
    @AppStorage(AppTab.orderKey) private var tabOrder = ""
    @AppStorage(AppTab.hiddenKey) private var hiddenTabs = ""
    #endif
    /// Shown on every cold start, not just the first — the system launch screen is blank, so
    /// without this the app opens on nothing and then snaps to content.
    @State private var showSplash = true
    @State private var showOnboarding = false
    @Environment(\.scenePhase) private var scenePhase

    init() {
        // Before anything reads the stored data: a profile switch swaps it now.
        ProfileManager.applyPendingSwitch()
        // Before the first request, and after the switch: the setting is the profile's.
        SecureDNS.applyAtLaunch()
        NetworkProxy.applyAtLaunch()
        KingfisherImageCache.configure()
        URLCache.shared = URLCache(
            memoryCapacity: 20 * 1024 * 1024,
            diskCapacity: 150 * 1024 * 1024,
            diskPath: nil
        )
        #if !os(tvOS) && !targetEnvironment(macCatalyst) || os(macOS)
            _ = CastManager.shared
        #endif
        ProviderManager.shared.setup(providers: [AniListProvider.shared, MALProvider.shared])
        // Creates the first profile on an install that has none, and keeps its account picture.
        _ = ProfileManager.shared
        // Anyone who already has the app set up has effectively finished onboarding; don't
        // interrupt an existing install to tell it how to do what it is already doing.
        if !UserDefaults.standard.bool(forKey: "hasCompletedOnboarding"),
           !ModuleManager.shared.modules.isEmpty {
            UserDefaults.standard.set(true, forKey: "hasCompletedOnboarding")
        }
        // Before any view reads `syncTargets`: seeds it from `dualSync` on the first launch after upgrade.
        SyncTargets.migrateIfNeeded()
        PendingWriteQueue.shared.register(sink: LibraryWriteSink())
        LocalLibraryManager.shared.syncFromContinueWatching()
        // Adult modules installed before Shirox refused them go, once their sites can be checked.
        HostBlocklist.shared.loadIfNeeded {
            Task { @MainActor in ModuleManager.shared.removeAdultModules() }
        }
        #if os(iOS)
        configureGlobalBarAppearances()
        #endif
        #if os(macOS)
        // What iOS's app delegate does at launch: pick up downloads left mid-way.
        DownloadManager.shared.reconnectPendingTasks()
        _ = MangaDownloadManager.shared
        #endif
    }

    var body: some Scene {
        WindowGroup {
            ProfileHost { RootTabView() }
                .environmentObject(moduleManager)
                .appAppearance()
                #if os(macOS)
                // The player and the manga reader cover the window, as on iOS.
                .macWindowCover()
                // A video opened from outside goes to the window that's already up; SwiftUI
                // otherwise opens a new one for every file.
                .handlesExternalEvents(preferring: ["*"], allowing: ["*"])
                #endif
                // First run: the app ships with no sources, so every tab is empty until one is
                // connected. Onboarding says so and wires up the two things that fix it.
                //
                // Driven by plain state rather than a binding computed from the stored flag.
                // SwiftUI calls a presentation binding's setter with `false` whenever the cover
                // isn't showing, and a setter that wrote "finished" on that marked onboarding
                // complete before it had ever been seen.
                .fullScreenCoverCompat(isPresented: $showOnboarding) {
                    OnboardingView()
                        .environmentObject(moduleManager)
                }
                .overlay {
                    if showSplash { SplashView(isPresented: $showSplash) }
                }
                .onChangeOf(showSplash) { stillShowing in
                    // Decide once, after the splash hands over: presenting a cover underneath
                    // it would just be revealed by the fade instead of arriving on its own.
                    guard !stillShowing else { return }
                    showOnboarding = !hasCompletedOnboarding
                    if hasCompletedOnboarding { ProfileManager.shared.presentAtLaunchIfNeeded() }
                }
                .onChange(of: scenePhase) { phase in
                    switch phase {
                    case .active:
                        Task { await PendingWriteQueue.shared.flush() }
                        // Picks up changes made on Simkl elsewhere, but only after the app has
                        // been away a while — activity checks are charged to the user's own
                        // request budget. Nothing polls; this is activation-driven only.
                        Task { await SimklLibraryService.shared.refreshOnActivation() }
                    case .background, .inactive:
                        SimklLibraryService.shared.noteEnteredBackground()
                    @unknown default:
                        break
                    }
                }
        }
        #if os(macOS)
        .defaultSize(width: 1320, height: 860)
        #endif
        #if targetEnvironment(macCatalyst) || os(macOS)
        .commands {
            CommandGroup(replacing: .appSettings) {
                Button("app.settings") {
                    NotificationCenter.default.post(name: .openSettingsTab, object: nil)
                }
                .keyboardShortcut(",", modifiers: .command)
            }
            // View ▸ Home, Search, Library…, each with ⌘ and its place in the sidebar.
            CommandGroup(before: .sidebar) {
                ForEach(SidebarTab.available.filter { $0 != .settings }, id: \.self) { tab in
                    Button(tab.label) {
                        NotificationCenter.default.post(name: .selectSidebarTab, object: tab)
                    }
                    .keyboardShortcut(tab.shortcut ?? " ", modifiers: .command)
                }
                Divider()
                // A Mac has no pull to refresh.
                Button("app.reload") {
                    NotificationCenter.default.post(name: .reloadPage, object: nil)
                }
                .keyboardShortcut("r", modifiers: .command)
                Divider()
            }
            #if os(macOS)
            CommandGroup(after: .newItem) {
                Button("app.open_video") { MacOpenVideo.choose() }
                    .keyboardShortcut("o", modifiers: .command)
            }
            // The player window's actions, where a Mac looks for them. Its keys (space, the
            // arrows, F, S, P, M) work as well while it's in front.
            CommandMenu("app.playback") {
                Button("app.play_pause") { MacPlayerCommand.send(.playPause) }
                    .keyboardShortcut(.space, modifiers: [.option])
                Button("app.skip_back") { MacPlayerCommand.send(.skipBack) }
                    .keyboardShortcut(.leftArrow, modifiers: [.option])
                Button("app.skip_forward") { MacPlayerCommand.send(.skipForward) }
                    .keyboardShortcut(.rightArrow, modifiers: [.option])
                Divider()
                Button("app.picture_in_picture") { MacPlayerWindowManager.shared.togglePictureInPicture() }
                    .keyboardShortcut("p", modifiers: [.command, .option])
                Button("app.mute_unmute") { MacPlayerCommand.send(.toggleMute) }
                    .keyboardShortcut("m", modifiers: [.command, .option])
                Button("app.save_frame") { MacPlayerCommand.send(.saveFrame) }
                    .keyboardShortcut("s", modifiers: [.command, .option])
            }
            #endif
            CommandGroup(after: .textEditing) {
                Button("common.find") {
                    NotificationCenter.default.post(name: .selectSidebarTab, object: SidebarTab.search)
                }
                .keyboardShortcut("f", modifiers: .command)
            }
        }
        #endif
    }
}

#if targetEnvironment(macCatalyst) || os(macOS)
enum SidebarTab: Int, CaseIterable, Hashable {
    case home, search, library, downloads, settings

    /// What the sidebar lists: the tabs left showing, in the order set in Settings › General.
    static var available: [SidebarTab] { AppTab.visible.map(SidebarTab.init) }

    init(_ tab: AppTab) {
        switch tab {
        case .home:      self = .home
        case .library:   self = .library
        case .downloads: self = .downloads
        case .settings:  self = .settings
        case .search:    self = .search
        }
    }

    var label: String {
        switch self {
        case .home:      return String(localized: "settings.home")
        case .library:   return String(localized: "common.library")
        case .downloads: return String(localized: "common.downloads")
        case .settings:  return String(localized: "settings.settings")
        case .search:    return String(localized: "common.search")
        }
    }

    var icon: String {
        switch self {
        case .home:      return "house"
        case .library:   return "books.vertical"
        case .downloads: return "arrow.down.circle"
        case .settings:  return "gearshape"
        case .search:    return "magnifyingglass"
        }
    }

    /// ⌘1, ⌘2… in the order the sidebar lists them.
    var shortcut: KeyEquivalent? {
        guard let index = Self.available.firstIndex(of: self), index < 9 else { return nil }
        return KeyEquivalent(Character(String(index + 1)))
    }
}

/// The app's sections, as a Mac sidebar lists them: the system's own selection and highlight.
private struct MacSidebarView: View {
    @Binding var selection: SidebarTab
    // Read so the sidebar follows the order and hiding set in Settings › General.
    @AppStorage(AppTab.orderKey) private var tabOrder = ""
    @AppStorage(AppTab.hiddenKey) private var hiddenTabs = ""

    var body: some View {
        List(selection: Binding<SidebarTab?>(get: { selection }, set: { if let tab = $0 { selection = tab } })) {
            Section {
                ForEach(SidebarTab.available.filter { $0 != .settings }, id: \.self) { tab in
                    Label(tab.label, systemImage: tab.icon).tag(tab)
                }
            }
            Section {
                Label(SidebarTab.settings.label, systemImage: SidebarTab.settings.icon).tag(SidebarTab.settings)
            }
        }
        .listStyle(.sidebar)
        #if targetEnvironment(macCatalyst)
        // The app's tint is the label colour, so Catalyst drew the selected row white on white.
        .tint(Color(uiColor: .systemGray))
        #endif
        .navigationSplitViewColumnWidthIfAvailable(min: 180, ideal: 210, max: 280)
    }
}

extension Notification.Name {
    /// A sidebar section picked from the menu bar; `object` is its `SidebarTab`.
    static let selectSidebarTab = Notification.Name("SelectSidebarTab")
    /// View ▸ Reload (⌘R): the page on screen loads again.
    static let reloadPage = Notification.Name("ReloadPage")
}
#endif

#if os(macOS)
import UniformTypeIdentifiers

/// File ▸ Open Video…: a video on disk, played where it is. iOS copies a picked file into the
/// app's storage because the picker's access to it is fleeting; an unsandboxed Mac app can read
/// it in place, and a copy of a film would double the space it takes.
@MainActor
enum MacOpenVideo {
    static func choose() {
        let panel = NSOpenPanel()
        panel.title = String(localized: "common.open_video")
        panel.prompt = String(localized: "shared.play")
        panel.allowedContentTypes = [.movie, .video, .mpeg4Movie, .quickTimeMovie]
            + ["mkv", "webm", "avi", "flv", "ts"].compactMap { UTType(filenameExtension: $0) }
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        play(url)
    }

    static func isVideo(_ url: URL) -> Bool {
        guard let type = UTType(filenameExtension: url.pathExtension) else { return false }
        return type.conforms(to: .movie) || type.conforms(to: .video)
            || ["mkv", "webm", "avi", "flv", "ts"].contains(url.pathExtension.lowercased())
    }

    static func play(_ url: URL) {
        LocalPlaybackCoordinator.shared.launch(videoURL: url, subtitle: nil, resumeFrom: nil)
    }
}
#endif

// MARK: - Root Tab View

private struct RootTabView: View {
    @EnvironmentObject private var moduleManager: ModuleManager
    @ObservedObject private var cfManager = CloudflareBypassManager.shared
    #if !os(tvOS)
    @ObservedObject private var playerPresenter = PlayerPresenter.shared
    #endif
    #if os(iOS)
    @ObservedObject private var quickActions = QuickActionManager.shared
    #endif
    @State private var selectedTab = LaunchTab.initialTab.rawValue
    @AppStorage(AppTab.orderKey) private var tabOrder = ""
    @AppStorage(AppTab.hiddenKey) private var hiddenTabs = ""
    @AppStorage(AppTab.hideLabelsKey) private var hidesTabLabels = false
    @AppStorage(AppTab.minimizeKey) private var minimizesTabBar = false
    #if os(iOS)
    /// Where the menu raised by holding the tab bar opens from, while it's up (iPhone).
    @State private var tabBarMenuSource: CGRect?
    @State private var hidesTabBar = false
    @State private var showsModuleList = false
    #endif
    #if targetEnvironment(macCatalyst) || os(macOS)
    @State private var sidebarTab = SidebarTab(LaunchTab.initialTab)
    #endif
    #if os(macOS)
    /// Bumped when the tab already showing is clicked again, which rebuilds it at its first page,
    /// as iOS's tab bar pops to the root.
    @State private var tabResets: [SidebarTab: Int] = [:]

    private var macTabSelection: Binding<SidebarTab> {
        Binding(get: { sidebarTab }, set: { tab in
            if tab == sidebarTab { tabResets[tab, default: 0] += 1 } else { sidebarTab = tab }
        })
    }

    /// The toolbar's tabs, in the order and with the ones hidden in Settings › General.
    private var macTabs: [SidebarTab] {
        AppTab.visible(order: tabOrder, hidden: hiddenTabs).map(SidebarTab.init)
    }

    @ViewBuilder
    private func macPage(_ tab: SidebarTab) -> some View {
        switch tab {
        case .home:      HomeView()
        case .library:   LibraryView()
        case .downloads: DownloadsView()
        case .settings:  SettingsView()
        case .search:    SearchView()
        }
    }
    #endif

    /// The tabs the bar shows, in the user's order.
    private var visibleTabs: [AppTab] {
        AppTab.visible(order: tabOrder, hidden: hiddenTabs)
    }

    #if os(iOS)
    private func routePendingQuickAction() {
        guard let action = quickActions.pending else { return }
        let tab: AppTab
        switch action {
        case .library:   tab = .library
        case .downloads: tab = .downloads
        case .search:    tab = .search
        }
        // A hidden tab isn't there to go to.
        if visibleTabs.contains(tab) { selectedTab = tab.rawValue }
        quickActions.pending = nil
    }
    #endif

    #if !targetEnvironment(macCatalyst) && !os(macOS)
    @ViewBuilder
    private func page(_ tab: AppTab) -> some View {
        switch tab {
        case .home:      HomeView()
        case .library:   LibraryView()
        #if os(iOS)
        case .downloads: DownloadsView()
        #else
        case .downloads: EmptyView()
        #endif
        case .settings:  SettingsView()
        case .search:    SearchView()
        }
    }

    /// Icon only when labels are hidden; VoiceOver still reads the name.
    @ViewBuilder
    private func tabLabel(_ tab: AppTab) -> some View {
        if hidesTabLabels {
            Image(systemName: tab.icon).accessibilityLabel(tab.title)
        } else {
            Label(tab.title, systemImage: tab.icon)
        }
    }
    #endif

    #if os(iOS) && !targetEnvironment(macCatalyst)
    private func openFromTabBarMenu(_ destination: TabBarMenuDestination) {
        switch destination {
        case .tab(let tab):        selectedTab = tab
        case .calendar:
            selectedTab = 0
            TabRequests.shared.showsCalendar = true
        case .module(let module):  moduleManager.selectModule(module)
        case .manageModules:       showsModuleList = true
        }
    }
    #endif

    var body: some View {
        Group {
            if #available(iOS 18, macOS 15, *) {
                #if targetEnvironment(macCatalyst)
                NavigationSplitView {
                    MacSidebarView(selection: $sidebarTab)
                } detail: {
                    switch sidebarTab {
                    case .home:      HomeView()
                    case .library:   LibraryView()
                    case .downloads: DownloadsView()
                    case .settings:  SettingsView()
                    case .search:    SearchView()
                    }
                }
                #elseif os(macOS)
                // Tabs in the window's toolbar, as iOS has them in its tab bar, rather than a
                // sidebar taking a column of the window for five rows.
                TabView(selection: macTabSelection) {
                    ForEach(macTabs, id: \.self) { tab in
                        Tab(tab.label, systemImage: tab.icon, value: tab) {
                            macPage(tab).id(tabResets[tab, default: 0])
                        }
                    }
                }
                .tabViewStyle(.tabBarOnly)
                #else
                TabView(selection: $selectedTab) {
                    ForEach(visibleTabs) { tab in
                        if tab == .search {
                            Tab(value: tab.rawValue, role: .search) {
                                page(tab)
                            } label: {
                                tabLabel(tab)
                            }
                        } else {
                            Tab(value: tab.rawValue) {
                                page(tab)
                            } label: {
                                tabLabel(tab)
                            }
                        }
                    }
                }
                .tabViewStyle(.sidebarAdaptable)
                .tabBarMinimizes(minimizesTabBar)
                .searchTabOpensWithoutKeyboard(selectedTab: selectedTab)
                .toolbarBackgroundHidden()
                .appTint()
                #endif
            } else {
                #if targetEnvironment(macCatalyst) || os(macOS)
                TabView(selection: $selectedTab) {
                    HomeView()
                        .tabItem { Label("settings.home", systemImage: "house.fill") }
                        .tag(0)
                    LibraryView()
                        .tabItem { Label("common.library", systemImage: "books.vertical.fill") }
                        .tag(1)
                    #if os(iOS)
                    DownloadsView()
                        .tabItem { Label("common.downloads", systemImage: "arrow.down.circle.fill") }
                        .tag(2)
                    #endif
                    SettingsView()
                        .tabItem { Label("settings.settings", systemImage: "gearshape.fill") }
                        .tag(3)
                    SearchView()
                        .tabItem { Label("common.search", systemImage: "magnifyingglass") }
                        .tag(4)
                }
                .appTint()
                #else
                TabView(selection: $selectedTab) {
                    ForEach(visibleTabs) { tab in
                        page(tab)
                            .tabItem { tabLabel(tab) }
                            .tag(tab.rawValue)
                    }
                }
                .appTint()
                #endif
            }
        }
        .onOpenURL { url in
            #if os(macOS)
            // A video opened with Shirox from Finder, or dropped on its Dock icon.
            if url.isFileURL {
                MacOpenVideo.play(url)
                return
            }
            #endif
            guard url.scheme == "shirox" else { return }
            AniListAuthManager.shared.handleCallback(url: url)
        }
        .task {
            await moduleManager.restoreActiveModule()
            await moduleManager.checkForUpdates()
            await AniListAuthManager.shared.fetchViewer()
            await ContinueWatchingManager.shared.syncWithAniList()
            await ContinueWatchingManager.shared.syncWithMAL()
        }
        #if os(macOS)
        // A video file dragged into the window plays.
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first(where: \.isFileURL), MacOpenVideo.isVideo(url) else { return false }
            MacOpenVideo.play(url)
            return true
        }
        #endif
        #if targetEnvironment(macCatalyst) || os(macOS)
        .onReceive(NotificationCenter.default.publisher(for: .selectSidebarTab)) { note in
            if let tab = note.object as? SidebarTab { sidebarTab = tab }
        }
        #endif
        // The tab showing was just hidden: on to the first one left.
        .onChangeOf(visibleTabs.map(\.rawValue)) { visible in
            #if targetEnvironment(macCatalyst) || os(macOS)
            let tabs = visibleTabs.map(SidebarTab.init)
            if !tabs.contains(sidebarTab), let first = tabs.first { sidebarTab = first }
            #else
            if !visible.contains(selectedTab), let first = visible.first { selectedTab = first }
            #endif
        }
        .onReceive(NotificationCenter.default.publisher(for: .openSettingsTab)) { _ in
            #if targetEnvironment(macCatalyst) || os(macOS)
            sidebarTab = .settings
            #else
            selectedTab = 3
            #endif
        }
        #if os(iOS) && !targetEnvironment(macCatalyst)
        .background {
            // The bar sits at the top on iPad, where a menu rising from the bottom makes no sense.
            if UIDevice.current.userInterfaceIdiom == .phone {
                TabBarHoldProbe(hidesBar: hidesTabBar) { tabBarMenuSource = $0 }
            }
        }
        .overlay {
            if let source = tabBarMenuSource {
                TabBarMenu(source: source, selectedTab: selectedTab, tabs: visibleTabs, onPick: openFromTabBarMenu,
                           onHidesBar: { hidesTabBar = $0 }) {
                    tabBarMenuSource = nil
                }
            }
        }
        .adaptiveSheet(isPresented: $showsModuleList) {
            NavigationStack {
                ModuleListView()
            }
            .environmentObject(moduleManager)
            .appTint()
        }
        #endif
        #if os(iOS)
        .onAppear { routePendingQuickAction() }
        .onChange(of: quickActions.pending) { _ in routePendingQuickAction() }
        #endif
        #if !os(tvOS)
        .sheet(isPresented: Binding(
            get: { playerPresenter.pendingRatingContext != nil },
            set: { if !$0 { playerPresenter.pendingRatingContext = nil } }
        )) {
            if let ctx = playerPresenter.pendingRatingContext {
                RatingPromptView(
                    title: ctx.mediaTitle,
                    imageUrl: ctx.imageUrl,
                    scoreFormat: AniListAuthManager.shared.scoreFormat,
                    onSave: { score in
                        PlayerPresenter.shared.submitRating(score, for: ctx)
                        playerPresenter.pendingRatingContext = nil
                    },
                    onSkip: {
                        playerPresenter.pendingRatingContext = nil
                    }
                )
                .adaptivePresentationDetents([.medium, .large])
            }
        }
        .sheet(item: $playerPresenter.pendingSimklRating) { request in
            RatingPromptView(
                title: request.title,
                imageUrl: request.posterURL ?? "",
                scoreFormat: .point10,
                heading: request.ref.kind == .movie ? String(localized: "app.rate_movie") : String(localized: "app.rate_show"),
                onSave: { score in
                    Task { await SimklPlayTracker.rate(request, score: score) }
                    playerPresenter.pendingSimklRating = nil
                },
                onSkip: {
                    playerPresenter.pendingSimklRating = nil
                }
            )
            .adaptivePresentationDetents([.medium, .large])
        }

        .overlay(alignment: .bottom) {
            ToastView()
                .allowsHitTesting(false)
        }

        .onChange(of: cfManager.activeBypassWebView != nil) { presented in
            if presented {
                CloudflareBypassWindowController.shared.show()
            } else {
                CloudflareBypassWindowController.shared.hide()
            }
        }
        #endif
        #if targetEnvironment(macCatalyst)
        .onAppear {
            guard let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene else { return }
            scene.sizeRestrictions?.minimumSize = CGSize(width: 1024, height: 700)
        }
        #endif
    }
}

extension Notification.Name {
    static let openSettingsTab = Notification.Name("OpenSettingsTab")
}

extension View {
    /// The tab bar shrinks to its selected tab while a page scrolls down (iOS 26).
    @ViewBuilder
    func tabBarMinimizes(_ enabled: Bool) -> some View {
        #if os(iOS)
        if #available(iOS 26, *) {
            tabBarMinimizeBehavior(enabled ? .onScrollDown : .automatic)
        } else {
            self
        }
        #else
        self
        #endif
    }

    /// Search keeps its own circle in the tab bar and opens with its field at the bottom,
    /// but without raising the keyboard.
    ///
    /// Built with the iOS 27 SDK, a search tab gets its circle and the bottom field only when
    /// selecting it opens search straight away; otherwise it joins the other tabs and opens
    /// as a page with the field up top. Opening straight away also raises the keyboard, so
    /// the field gives it up as it takes it: search stays open, and a tap on the field
    /// brings the keyboard when it's wanted.
    @ViewBuilder
    func searchTabOpensWithoutKeyboard(selectedTab: Int) -> some View {
        #if os(iOS)
        if #available(iOS 26, *) {
            tabViewSearchActivation(.searchTabSelection)
                .onChangeOf(selectedTab) { tab in
                    if tab == 4 { SearchKeyboardHold.shared.holdNextKeyboard() }
                }
        } else {
            self
        }
        #else
        self
        #endif
    }
}

#if os(iOS)
/// Keeps the keyboard down when the search tab focuses its field by itself.
///
/// Giving up focus doesn't work: the tab takes it straight back, several times over, and the
/// two fighting made the field jump. The field keeps its focus instead, with no keyboard
/// behind it, until the user taps it.
@MainActor
final class SearchKeyboardHold: NSObject {
    static let shared = SearchKeyboardHold()
    /// Until when a search field starting to edit is the tab's doing, not the user's.
    private var holdUntil: Date?
    private weak var heldField: UISearchTextField?
    private var tap: UITapGestureRecognizer?

    private override init() {
        super.init()
        NotificationCenter.default.addObserver(forName: UITextField.textDidBeginEditingNotification,
                                               object: nil, queue: .main) { note in
            guard let field = note.object as? UISearchTextField else { return }
            MainActor.assumeIsolated { SearchKeyboardHold.shared.fieldBeganEditing(field) }
        }
        NotificationCenter.default.addObserver(forName: UITextField.textDidEndEditingNotification,
                                               object: nil, queue: .main) { note in
            guard let field = note.object as? UISearchTextField else { return }
            MainActor.assumeIsolated {
                if field === SearchKeyboardHold.shared.heldField { SearchKeyboardHold.shared.release() }
            }
        }
    }

    func holdNextKeyboard() {
        holdUntil = Date().addingTimeInterval(1.5)
    }

    private func fieldBeganEditing(_ field: UISearchTextField) {
        guard let until = holdUntil, Date() < until, field !== heldField else { return }
        holdUntil = nil
        release()
        heldField = field
        // An empty input view: focused, but nothing comes up.
        field.inputView = UIView(frame: .zero)
        field.reloadInputViews()
        let tap = UITapGestureRecognizer(target: self, action: #selector(fieldTapped))
        tap.cancelsTouchesInView = false
        field.addGestureRecognizer(tap)
        self.tap = tap
    }

    /// The user wants to type: the keyboard comes back.
    @objc private func fieldTapped() {
        release()
    }

    private func release() {
        guard let field = heldField else { return }
        if let tap { field.removeGestureRecognizer(tap) }
        tap = nil
        heldField = nil
        field.inputView = nil
        field.reloadInputViews()
    }
}
#endif

/// Things a tab's page is asked to do from outside it — the tab bar, or the menu held up
/// from it — picked up once the page is showing.
@MainActor
final class TabRequests: ObservableObject {
    static let shared = TabRequests()
    /// Home pushes the Upcoming calendar.
    @Published var showsCalendar = false
}

#if os(iOS)
/// See-through bars on iOS 26, where Liquid Glass and the scroll edge effect stand in for the
/// background they give up. Before 26 nothing does: the tab bar's items sat straight on the
/// posters scrolling under them, and lists ran under their titles with no blur.
///
/// So before 26 the tab bar keeps the system blur all the time. SwiftUI's tab content often
/// isn't the scroll view UIKit watches, and a bar left to switch at the scroll edge stays clear.
/// Navigation bars stay clear at the top and blur once content scrolls under them. Screens
/// built to sit under a clear bar (Home's hero, the detail banners) still opt out with
/// `toolbarBackgroundHidden`. That needs iOS 16, so iOS 15 keeps the clear navigation bar
/// those screens expect.
func configureGlobalBarAppearances() {
    let clearNav = UINavigationBarAppearance()
    clearNav.configureWithTransparentBackground()
    clearNav.shadowColor = .clear
    clearNav.shadowImage = UIImage()

    let clearTab = UITabBarAppearance()
    clearTab.configureWithTransparentBackground()
    clearTab.shadowColor = .clear
    clearTab.shadowImage = UIImage()

    if #available(iOS 26, *) {
        UINavigationBar.appearance().standardAppearance = clearNav
        UINavigationBar.appearance().scrollEdgeAppearance = clearNav
        UINavigationBar.appearance().compactAppearance = clearNav
        UITabBar.appearance().standardAppearance = clearTab
        UITabBar.appearance().scrollEdgeAppearance = clearTab
        return
    }

    let blurredTab = UITabBarAppearance()
    blurredTab.configureWithDefaultBackground()
    UITabBar.appearance().standardAppearance = blurredTab
    UITabBar.appearance().scrollEdgeAppearance = blurredTab

    if #available(iOS 16, *) {
        let blurredNav = UINavigationBarAppearance()
        blurredNav.configureWithDefaultBackground()
        UINavigationBar.appearance().standardAppearance = blurredNav
        UINavigationBar.appearance().compactAppearance = blurredNav
        UINavigationBar.appearance().scrollEdgeAppearance = clearNav
        UINavigationBar.appearance().compactScrollEdgeAppearance = clearNav
    } else {
        UINavigationBar.appearance().standardAppearance = clearNav
        UINavigationBar.appearance().scrollEdgeAppearance = clearNav
        UINavigationBar.appearance().compactAppearance = clearNav
    }
}
#endif
