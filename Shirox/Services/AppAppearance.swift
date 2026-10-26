import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

// MARK: - Tint

/// The app's colour: what `.tint` and `Color.accentColor` resolve to. Monochrome is Shirox's own
/// black-and-white look; the others are system colours, which shift for light and dark mode.
enum AppTint: String, CaseIterable, Identifiable {
    case monochrome, blue, purple, pink, orange, green, brown

    static let key = "appTint"

    var id: String { rawValue }

    /// Nil for monochrome: tints stay `.primary`, and accents keep the asset catalogue's colour.
    var color: Color? {
        switch self {
        case .monochrome: return nil
        case .blue:       return .blue
        case .purple:     return .purple
        case .pink:       return .pink
        case .orange:     return .orange
        case .green:      return .green
        case .brown:      return .brown
        }
    }

    var title: String {
        switch self {
        case .monochrome: return String(localized: "settings.monochrome")
        case .blue:       return String(localized: "settings.blue")
        case .purple:     return String(localized: "settings.purple")
        case .pink:       return String(localized: "settings.pink")
        case .orange:     return String(localized: "settings.orange")
        case .green:      return String(localized: "settings.green")
        case .brown:      return String(localized: "settings.brown")
        }
    }

    static var current: AppTint {
        AppTint(rawValue: UserDefaults.standard.string(forKey: key) ?? "") ?? .monochrome
    }
}

/// `.tint(.primary)` until a colour is picked. A modifier rather than a value so every place
/// using it redraws the moment the setting changes.
private struct AppTintModifier: ViewModifier {
    @AppStorage(AppTint.key) private var raw = AppTint.monochrome.rawValue

    func body(content: Content) -> some View {
        content.tint(AppTint(rawValue: raw)?.color ?? .primary)
    }
}

/// Switches: grey until a colour is picked, then that colour.
private struct SwitchTintModifier: ViewModifier {
    @AppStorage(AppTint.key) private var raw = AppTint.monochrome.rawValue

    func body(content: Content) -> some View {
        content.tint(AppTint(rawValue: raw)?.color ?? .secondary)
    }
}

extension View {
    func appTint() -> some View { modifier(AppTintModifier()) }
    func switchTint() -> some View { modifier(SwitchTintModifier()) }

    /// The window's root: tint, accent colour and the light/dark override.
    func appAppearance() -> some View { modifier(AppAppearanceModifier()) }
}

// MARK: - Color Scheme

/// Light or dark regardless of the system, or following it.
enum AppColorScheme: String, CaseIterable, Identifiable {
    case system, light, dark

    static let key = "appColorScheme"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: return String(localized: "settings.system")
        case .light:  return String(localized: "settings.light")
        case .dark:   return String(localized: "settings.dark")
        }
    }

    static var current: AppColorScheme {
        AppColorScheme(rawValue: UserDefaults.standard.string(forKey: key) ?? "") ?? .system
    }

    /// Set on the windows rather than with `preferredColorScheme`, which on iOS doesn't let go
    /// once set back to nil, and doesn't reach windows of Shirox's own (Cloudflare, the refresh
    /// drop) or a Mac's other windows.
    @MainActor
    static func apply() {
        #if os(macOS)
        switch current {
        case .system: NSApp.appearance = nil
        case .light:  NSApp.appearance = NSAppearance(named: .aqua)
        case .dark:   NSApp.appearance = NSAppearance(named: .darkAqua)
        }
        #else
        WindowWatcher.start()
        for window in UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene }).flatMap(\.windows) {
            window.overrideUserInterfaceStyle = current.interfaceStyle
        }
        #endif
    }

    #if !os(macOS)
    var interfaceStyle: UIUserInterfaceStyle {
        switch self {
        case .system: return .unspecified
        case .light:  return .light
        case .dark:   return .dark
        }
    }

    /// Windows that come up later — the player's, Cloudflare's — get the override too. Left
    /// alone while following the system: the refresh drop's window copies its host's style.
    @MainActor
    private enum WindowWatcher {
        static var started = false

        static func start() {
            guard !started else { return }
            started = true
            NotificationCenter.default.addObserver(forName: UIWindow.didBecomeVisibleNotification,
                                                   object: nil, queue: .main) { note in
                guard let window = note.object as? UIWindow else { return }
                MainActor.assumeIsolated {
                    let style = AppColorScheme.current.interfaceStyle
                    if style != .unspecified { window.overrideUserInterfaceStyle = style }
                }
            }
        }
    }
    #endif
}

private struct AppAppearanceModifier: ViewModifier {
    @AppStorage(AppTint.key) private var tintRaw = AppTint.monochrome.rawValue
    @AppStorage(AppColorScheme.key) private var schemeRaw = AppColorScheme.system.rawValue

    func body(content: Content) -> some View {
        let tint = AppTint(rawValue: tintRaw)?.color
        content
            .tint(tint ?? .primary)
            // `Color.accentColor` follows this; nil keeps the asset catalogue's.
            .accentColor(tint)
            .onAppear { AppColorScheme.apply() }
            .onChangeOf(schemeRaw) { AppColorScheme.apply() }
    }
}

// MARK: - App Icon

#if os(iOS) && !targetEnvironment(macCatalyst)
/// The home screen icon. The alternates are whatever the build lists under Alternate App Icon
/// Sets (`ASSETCATALOG_COMPILER_ALTERNATE_APPICON_NAMES`), read back from Info.plist, so adding
/// one to the project is all it takes to offer it here.
struct AppIconOption: Identifiable, Hashable {
    /// Nil for the primary icon.
    let name: String?

    var id: String { name ?? "default" }

    var title: String {
        switch name {
        case nil:         return String(localized: "settings.default")
        case "realistic": return String(localized: "settings.app_icon_realistic")
        case "pride":     return String(localized: "settings.app_icon_pride")
        case let name?:
            return name.replacingOccurrences(of: "-", with: " ").replacingOccurrences(of: "_", with: " ")
                .localizedCapitalized
        }
    }

    static var all: [AppIconOption] {
        let icons = Bundle.main.infoDictionary?["CFBundleIcons"] as? [String: Any]
        let alternates = (icons?["CFBundleAlternateIcons"] as? [String: Any])?.keys.sorted() ?? []
        return [AppIconOption(name: nil)] + alternates.map { AppIconOption(name: $0) }
    }
}
#endif

// MARK: - Language

/// The language Shirox shows itself in. The choice is the per-app `AppleLanguages` that iOS's
/// own Settings › Shirox › Language writes, so the two agree; it takes effect on the next launch.
enum AppLanguage {
    /// The languages the app has strings for, as their codes ("en", "de").
    static var available: [String] {
        Bundle.main.localizations.filter { $0 != "Base" }.sorted { name(for: $0) < name(for: $1) }
    }

    /// The language picked in Shirox, or nil when following the system.
    static var selected: String? {
        guard let id = Bundle.main.bundleIdentifier,
              let languages = UserDefaults.standard.persistentDomain(forName: id)?["AppleLanguages"] as? [String],
              let first = languages.first else { return nil }
        // "de-DE" from the system's page matches the app's "de".
        return available.first { first == $0 || first.hasPrefix($0 + "-") }
    }

    static func select(_ code: String?) {
        if let code {
            UserDefaults.standard.set([code], forKey: "AppleLanguages")
        } else {
            UserDefaults.standard.removeObject(forKey: "AppleLanguages")
        }
    }

    /// The language in its own words: "Deutsch".
    static func name(for code: String) -> String {
        Locale(identifier: code).localizedString(forIdentifier: code)?.localizedCapitalized ?? code
    }

    /// The language in the one Shirox is showing: "German".
    static func localizedName(for code: String) -> String? {
        Locale.current.localizedString(forIdentifier: code)?.localizedCapitalized
    }

    /// The language strings are coming from right now.
    static var current: String {
        Bundle.main.preferredLocalizations.first ?? "en"
    }
}

// MARK: - Tabs

/// The tabs of the tab bar, and of a Mac's toolbar or sidebar. Raw values are the `TabView` selection
/// values, which quick actions and the tab bar menu use too.
enum AppTab: Int, CaseIterable, Identifiable {
    case home = 0, library = 1, downloads = 2, settings = 3, search = 4

    static let orderKey = "tabOrder"
    static let hiddenKey = "hiddenTabs"
    static let launchKey = "launchTab"
    static let hideLabelsKey = "tabBarHidesLabels"
    static let minimizeKey = "tabBarMinimizes"

    var id: Int { rawValue }

    var title: String {
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
        case .home:      return "house.fill"
        case .library:   return "books.vertical.fill"
        case .downloads: return "arrow.down.circle.fill"
        case .settings:  return "gearshape.fill"
        case .search:    return "magnifyingglass"
        }
    }

    /// Settings can't go: it's where a hidden tab is brought back.
    var canHide: Bool { self != .settings }

    /// The tabs this platform has, in their default order. Apple TV has no downloads; a Mac
    /// lists search second and settings last.
    static var available: [AppTab] {
        #if os(tvOS)
        return [.home, .library, .settings, .search]
        #elseif os(macOS) || targetEnvironment(macCatalyst)
        return [.home, .search, .library, .downloads, .settings]
        #else
        return [.home, .library, .downloads, .settings, .search]
        #endif
    }

    /// Every tab in the user's order, hidden ones included.
    static func ordered(_ raw: String) -> [AppTab] {
        let saved = raw.split(separator: ",").compactMap { Int($0).flatMap(AppTab.init(rawValue:)) }
            .filter(available.contains)
        var seen = Set<AppTab>()
        let unique = saved.filter { seen.insert($0).inserted }
        return unique + available.filter { !unique.contains($0) }
    }

    static func hidden(_ raw: String) -> Set<AppTab> {
        Set(raw.split(separator: ",").compactMap { Int($0).flatMap(AppTab.init(rawValue:)) }.filter(\.canHide))
    }

    static func encode(_ tabs: some Sequence<AppTab>) -> String {
        tabs.map { String($0.rawValue) }.joined(separator: ",")
    }

    /// The tabs the bar shows, in order.
    static func visible(order: String, hidden: String) -> [AppTab] {
        let hiddenTabs = Self.hidden(hidden)
        return ordered(order).filter { !hiddenTabs.contains($0) }
    }

    static var visible: [AppTab] {
        let defaults = UserDefaults.standard
        return visible(order: defaults.string(forKey: orderKey) ?? "",
                       hidden: defaults.string(forKey: hiddenKey) ?? "")
    }
}

/// The tab Shirox opens on. Stored by name so the Mac's sidebar and the tab bar share it.
enum LaunchTab: String, CaseIterable, Identifiable {
    case home, library, downloads, search

    var id: String { rawValue }

    var title: String { appTab.title }

    var appTab: AppTab {
        switch self {
        case .home:      return .home
        case .library:   return .library
        case .downloads: return .downloads
        case .search:    return .search
        }
    }

    static var available: [LaunchTab] {
        allCases.filter { AppTab.available.contains($0.appTab) }
    }

    static var current: LaunchTab {
        LaunchTab(rawValue: UserDefaults.standard.string(forKey: AppTab.launchKey) ?? "") ?? .home
    }

    /// The tab bar's first tab: the chosen one, or the first left showing if it's hidden.
    static var initialTab: AppTab {
        let visible = AppTab.visible
        return visible.contains(current.appTab) ? current.appTab : (visible.first ?? .settings)
    }
}
