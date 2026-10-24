import SwiftUI

// MARK: - General Settings

struct GeneralSettingsView: View {
    @AppStorage(AppColorScheme.key) private var colorScheme = AppColorScheme.system.rawValue
    @AppStorage(AppTint.key) private var tint = AppTint.monochrome.rawValue
    @AppStorage(AppTab.launchKey) private var launchTab = LaunchTab.home.rawValue
    @AppStorage(AppTab.orderKey) private var tabOrder = ""
    @AppStorage(AppTab.hiddenKey) private var hiddenTabs = ""
    @AppStorage(AppTab.hideLabelsKey) private var hideTabLabels = false
    @AppStorage(AppTab.minimizeKey) private var minimizeTabBar = false
    @AppStorage(PullToRefreshStyle.key) private var refreshStyle = PullToRefreshStyle.defaultStyle
    @AppStorage(CardTitleSetting.hiddenKey) private var hideCardTitles = false
    @AppStorage(DetailLayoutSetting.cinematicKey) private var cinematicDetailLayout = true
    @AppStorage(DetailLayoutSetting.cinematicHomeKey) private var cinematicHomeLayout = true
    @AppStorage(ProviderMenuStyle.key) private var providerMenuStyle = ProviderMenuStyle.iconAndName
    #if os(iOS) && !targetEnvironment(macCatalyst)
    @State private var appIcon = UIApplication.shared.alternateIconName
    @State private var appIconError: String?
    #endif

    /// Where the tab bar settings apply: the iPhone and iPad tab bar. A Mac lists its sections
    /// in a sidebar or the toolbar.
    private static var hasTabBar: Bool {
        #if os(iOS) && !targetEnvironment(macCatalyst)
        return true
        #else
        return false
        #endif
    }

    var body: some View {
        SettingsList {
            Section {
                Picker("Appearance", selection: $colorScheme) {
                    ForEach(AppColorScheme.allCases) { scheme in
                        Text(scheme.title).tag(scheme.rawValue)
                    }
                }
                .pickerStyle(.menu)

                #if os(iOS) && !targetEnvironment(macCatalyst)
                Picker("App Icon", selection: appIconSelection) {
                    ForEach(AppIconOption.all) { option in
                        Text(option.title).tag(option.name)
                    }
                }
                .pickerStyle(.menu)
                .retinted(tint)
                #endif

                TintColorRow(tint: $tint)
                note("Buttons, switches and highlights. Monochrome keeps Shirox black and white; the colors adjust themselves to light and dark mode.")
            } header: {
                Text("Appearance")
            }

            Section {
                #if os(iOS) && !targetEnvironment(macCatalyst)
                NavigationLink {
                    TabBarCustomizationView()
                } label: {
                    LabeledContent("Customize Bottom Tabs") {
                        Text(tabsSubtitle)
                            .foregroundStyle(.secondary)
                    }
                }
                #endif

                Picker("Open On", selection: $launchTab) {
                    ForEach(LaunchTab.available) { tab in
                        Text(tab.title).tag(tab.rawValue)
                    }
                }
                .pickerStyle(.menu)
                .retinted(tint)

                #if os(iOS) && !targetEnvironment(macCatalyst)
                Toggle("Hide Tab Labels", isOn: $hideTabLabels)
                    .switchTint()

                if #available(iOS 26, *) {
                    Toggle("Minimize on Scroll", isOn: $minimizeTabBar)
                        .switchTint()
                }
                #endif
            } header: {
                Text(Self.hasTabBar ? "Tab Bar" : "Tabs")
            }

            if DetailLayoutSetting.isOffered {
                Section {
                    Toggle("Cinematic Home", isOn: $cinematicHomeLayout)
                        .switchTint()
                    Toggle("Cinematic Detail Pages", isOn: $cinematicDetailLayout)
                        .switchTint()
                } header: {
                    Text("Layout")
                }
            }

            Section {
                Toggle("Hide Titles on Cards", isOn: $hideCardTitles)
                    .switchTint()
                note("Posters from TVDB carry the show's name, so the title over them says it twice. Hold a card for its full title.")
                Picker("Home & Search Buttons", selection: $providerMenuStyle) {
                    ForEach(ProviderMenuStyle.allCases, id: \.self) { style in
                        Text(style.title).tag(style)
                    }
                }
                .pickerStyle(.menu)
                .retinted(tint)
                note("The buttons at the top of Home and Search: Home's picks the provider, Search's the module. Hidden, both keep the last choice; modules are also in Settings › Modules.")
            } header: {
                Text("Cards & Buttons")
            }

            #if os(iOS)
            Section {
                Picker("Pull to Refresh", selection: $refreshStyle) {
                    ForEach(PullToRefreshStyle.allCases) { style in
                        Text(style.title).tag(style)
                    }
                }
                .pickerStyle(.menu)
                .retinted(tint)
            } header: {
                Text("Refreshing")
            } footer: {
                Text(refreshNote)
            }
            #endif

            Section {
                NavigationLink {
                    LanguageSettingsView()
                } label: {
                    LabeledContent("Change Language") {
                        Text(AppLanguage.name(for: AppLanguage.current))
                            .foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text("Language")
            } footer: {
                Text("The language Shirox shows itself in, or the one your device uses.")
            }
        }
        .softScrollEdges()
        .navigationTitle("General")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        #if os(iOS) && !targetEnvironment(macCatalyst)
        .alert("Couldn't Change Icon",
               isPresented: Binding(get: { appIconError != nil }, set: { if !$0 { appIconError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(appIconError ?? "")
        }
        #endif
    }

    /// The explanation under a row, as the other settings pages have them.
    private func note(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
    }

    private var refreshNote: String {
        switch refreshStyle {
        case .gooey: return "Pulling stretches a drop out of the Dynamic Island that holds the spinner."
        case .glass: return "A frosted circle holds the spinner, as sheets always have."
        case .none:  return "Pulling down still refreshes, with nothing on screen: a tap when you've pulled far enough, another when it's done."
        }
    }

    private var tabsSubtitle: String {
        let all = AppTab.available.count
        let shown = AppTab.visible(order: tabOrder, hidden: hiddenTabs).count
        return shown == all ? "All" : "\(shown) of \(all)"
    }

    #if os(iOS) && !targetEnvironment(macCatalyst)
    /// Picking an icon asks iOS to switch to it; the picker only moves once it has.
    private var appIconSelection: Binding<String?> {
        Binding(get: { appIcon }, set: { name in
            guard name != appIcon else { return }
            guard UIApplication.shared.supportsAlternateIcons else {
                appIconError = "This device doesn't support changing the app icon."
                return
            }
            UIApplication.shared.setAlternateIconName(name) { error in
                DispatchQueue.main.async {
                    if let error {
                        appIconError = error.localizedDescription
                    } else {
                        appIcon = name
                    }
                }
            }
        })
    }
    #endif
}

private extension View {
    /// A list row's menu picker draws its value in the tint, but kept the old colour after the
    /// accent colour changed until the page was opened again. A new identity per colour redraws it.
    func retinted(_ tint: String) -> some View {
        id(tint)
    }
}

// MARK: - Tint Color

/// The colours as swatches in one row, spread across it, the current one ringed. Not in a
/// horizontal scroller: a scroll view inside a list row didn't redraw, so the ring stayed put.
private struct TintColorRow: View {
    @Binding var tint: String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            LabeledContent("Accent Color") {
                Text(AppTint(rawValue: tint)?.title ?? AppTint.monochrome.title)
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 0) {
                ForEach(AppTint.allCases) { option in
                    swatch(option, isSelected: option.rawValue == tint)
                        .frame(maxWidth: .infinity)
                }
            }
        }
        .padding(.vertical, 4)
    }

    private func swatch(_ option: AppTint, isSelected: Bool) -> some View {
        Button {
            withAnimation(.easeOut(duration: 0.15)) { tint = option.rawValue }
        } label: {
            ZStack {
                if let color = option.color {
                    Circle().fill(color)
                } else {
                    // Half black, half white.
                    Circle().fill(Color.black)
                    Circle().fill(Color.white)
                        .mask(Rectangle().offset(x: 15))
                    Circle().strokeBorder(Color.primary.opacity(0.25), lineWidth: 0.5)
                }
            }
            .frame(width: 30, height: 30)
            .padding(3)
            .overlay {
                Circle()
                    .strokeBorder(Color.primary, lineWidth: 2)
                    .opacity(isSelected ? 1 : 0)
            }
            .contentShape(Circle())
        }
        .buttonStyle(.borderless)
        .accessibilityLabel(option.title)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

#if os(iOS) && !targetEnvironment(macCatalyst)
// MARK: - Tab Bar Customization

/// The tabs in the bar's order: drag to move, the eye to hide or show.
struct TabBarCustomizationView: View {
    @AppStorage(AppTab.orderKey) private var orderRaw = ""
    @AppStorage(AppTab.hiddenKey) private var hiddenRaw = ""
    @AppStorage(AppTab.hideLabelsKey) private var hideLabels = false

    private var tabs: [AppTab] { AppTab.ordered(orderRaw) }
    private var hidden: Set<AppTab> { AppTab.hidden(hiddenRaw) }

    var body: some View {
        List {
            Section {
                ForEach(tabs) { tab in
                    row(tab)
                }
                .onMove { from, to in
                    var list = tabs
                    list.move(fromOffsets: from, toOffset: to)
                    orderRaw = AppTab.encode(list)
                }
            } footer: {
                Text(footer)
            }

            Section {
                Button("Reset to Default") {
                    orderRaw = ""
                    hiddenRaw = ""
                }
                .disabled(orderRaw.isEmpty && hiddenRaw.isEmpty)
            }
        }
        .softScrollEdges()
        .navigationTitle("Customize Tabs")
        .navigationBarTitleDisplayMode(.inline)
        .environment(\.editMode, .constant(.active))
    }

    private var footer: String {
        var text = "Drag to reorder. Settings always stays, so hidden tabs can come back."
        if #available(iOS 26, *) {
            text += " Search keeps its own button at the end of the bar."
        }
        return text
    }

    private func row(_ tab: AppTab) -> some View {
        let isHidden = hidden.contains(tab)
        return HStack(spacing: 14) {
            Image(systemName: tab.icon)
                .font(.system(size: 17))
                .frame(width: 28)
            Text(tab.title)
            Spacer()
            if tab.canHide {
                Button {
                    toggle(tab)
                } label: {
                    Image(systemName: isHidden ? "eye.slash" : "eye")
                        .font(.body)
                        .foregroundStyle(isHidden ? AnyShapeStyle(.secondary) : AnyShapeStyle(.tint))
                        .frame(width: 32, height: 32)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .accessibilityLabel(isHidden ? "Show \(tab.title)" : "Hide \(tab.title)")
            } else {
                Image(systemName: "lock.fill")
                    .font(.footnote)
                    .foregroundStyle(.tertiary)
                    .frame(width: 32, height: 32)
            }
        }
        .opacity(isHidden ? 0.45 : 1)
    }

    private func toggle(_ tab: AppTab) {
        var set = hidden
        if set.contains(tab) {
            set.remove(tab)
        } else {
            set.insert(tab)
        }
        hiddenRaw = AppTab.encode(AppTab.available.filter(set.contains))
    }
}
#endif

// MARK: - Language

/// Every language Shirox has strings for, as a list rather than a menu: there'll be more.
struct LanguageSettingsView: View {
    @State private var selected = AppLanguage.selected
    /// What was showing when the page opened, to tell whether a restart is needed.
    private let running = AppLanguage.current

    var body: some View {
        SettingsList {
            Section {
                row(code: nil, title: "System Default",
                    subtitle: AppLanguage.localizedName(for: Locale.preferredLanguages.first ?? "en"))
            }

            Section {
                ForEach(AppLanguage.available, id: \.self) { code in
                    row(code: code, title: AppLanguage.name(for: code),
                        subtitle: AppLanguage.localizedName(for: code))
                }
            } footer: {
                if let footer { Text(footer) }
            }

            #if !os(tvOS)
            if let requestURL = Self.requestURL {
                Section {
                    Link(destination: requestURL) {
                        HStack {
                            Text("Request a Language")
                            Spacer()
                            Image(systemName: "arrow.up.right")
                                .font(.footnote.weight(.semibold))
                                .foregroundStyle(.secondary)
                        }
                    }
                    Text("Missing yours? Open an issue on GitHub; translations are welcome too.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            #endif
        }
        .softScrollEdges()
        .navigationTitle("Language")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }

    /// Only once a pick needs a restart to show.
    private var footer: String? {
        let target = selected ?? Bundle.preferredLocalizations(from: AppLanguage.available).first ?? running
        return target == running
            ? nil
            : "Shirox switches language the next time it opens. Close it from the app switcher to switch now."
    }

    /// A new issue on the app's repository, titled for a language request.
    private static var requestURL: URL? {
        guard let repo = Bundle.main.object(forInfoDictionaryKey: "GithubRepo") as? String,
              !repo.isEmpty else { return nil }
        return URL(string: "https://github.com/\(repo)/issues/new?title=Language%20request%3A%20")
    }

    private func row(code: String?, title: String, subtitle: String?) -> some View {
        let isSelected = selected == code
        return Button {
            selected = code
            AppLanguage.select(code)
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .foregroundStyle(.primary)
                    if let subtitle, subtitle != title {
                        Text(subtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.tint)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
