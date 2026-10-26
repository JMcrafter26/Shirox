import ImageIO
import SwiftUI
import UniformTypeIdentifiers
#if canImport(PhotosUI)
import PhotosUI
#endif

#if !os(tvOS)

extension Color {
    /// `#RRGGBB`; grey when it isn't one.
    init(profileHex hex: String) {
        let (r, g, b) = ProfilePalette.rgb(hex) ?? (0.5, 0.5, 0.5)
        self.init(red: r, green: g, blue: b)
    }
}

// MARK: - Avatar

/// A profile's picture: the one chosen for it, else its account's (AniList, MyAnimeList, Simkl),
/// else its initial on its colour. Only one of them is ever drawn, so a picture still loading or
/// a button pressed never shows the initial through it.
struct ProfileAvatarView: View {
    let profile: AppProfile
    var size: CGFloat = 44
    /// Liquid Glass tinted with the profile's colour in place of the flat fill, for the
    /// Settings row. Falls back to the flat fill where there's no glass.
    var glass = false
    @ObservedObject private var manager = ProfileManager.shared

    private var color: Color { Color(profileHex: profile.colorHex) }

    var body: some View {
        if glass {
            picture
                .glassChrome(Circle(), enabled: true, tint: color, off: color)
        } else {
            picture
        }
    }

    private var picture: some View {
        ZStack {
            if !glass { Circle().fill(color) }
            if profile.hasPhoto, let image = ProfilePhotoCache.image(at: manager.photoURL(for: profile.id),
                                                                     version: manager.photoVersion) {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .scaledToFill()
            } else if let url = profile.accountAvatarURL {
                CachedAsyncImage(urlString: url).scaledToFill()
            } else {
                Text(profile.initial)
                    .font(.system(size: size * 0.42, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .accessibilityHidden(true)
    }
}

/// Chosen pictures, read from disk once per change.
@MainActor
enum ProfilePhotoCache {
    private static var images: [URL: (version: Int, image: CGImage)] = [:]

    static func image(at url: URL, version: Int) -> CGImage? {
        if let hit = images[url], hit.version == version { return hit.image }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        images[url] = (version, image)
        return image
    }
}

/// Shrinks a little while pressed, without the plain style's fading.
private struct PressScaleStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.94 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: configuration.isPressed)
    }
}

// MARK: - Host

/// The app's content, rebuilt on every profile switch, with the profile picker over it.
struct ProfileHost<Content: View>: View {
    @ObservedObject private var manager = ProfileManager.shared
    @ViewBuilder let content: () -> Content

    var body: some View {
        content()
            .id(manager.generation)
            .overlay {
                if manager.isPickerShown {
                    ProfilePickerView()
                        .transition(.opacity.combined(with: .scale(scale: 1.04)))
                }
            }
            .animation(.easeInOut(duration: 0.3), value: manager.isPickerShown)
    }
}

// MARK: - Picker

/// Who's watching: every profile on this device as a big picture, to switch to with a tap, or
/// to change in Manage Profiles.
struct ProfilePickerView: View {
    @ObservedObject private var manager = ProfileManager.shared
    @AppStorage(ProfileManager.askAtLaunchKey) private var askAtLaunch = true
    @AppStorage("playerLiquidGlass") private var liquidGlass = true
    @State private var managing = false
    @State private var editing: EditorTarget?
    @State private var scrollSize: CGSize = .zero
    /// The picker's colour, the device's (not a profile's): red unless changed.
    @AppStorage(ProfilePickerTheme.key) private var themeHex = ProfilePickerTheme.defaultHex

    private var avatarSize: CGFloat {
        #if os(macOS)
        120
        #else
        UIDevice.current.userInterfaceIdiom == .pad ? 150 : 118
        #endif
    }

    var body: some View {
        ZStack {
            background
            VStack(spacing: 0) {
                topBar
                if !centersContent { title }
                ScrollView {
                    VStack(spacing: 0) {
                        if centersContent { title }
                        centeredRows
                            .padding(.horizontal, 24)
                            .padding(.vertical, 40)
                            .frame(maxWidth: 720)
                    }
                    .frame(maxWidth: .infinity, minHeight: centersContent ? scrollSize.height : 0)
                }
                .background(GeometryReader { geo in
                    Color.clear.preference(key: PickerSizeKey.self, value: geo.size)
                })
                .onPreferenceChange(PickerSizeKey.self) { scrollSize = $0 }
                bottomBar
            }
            if let target = manager.switchingTo {
                switchingCover(target)
            }
        }
        .animation(.easeInOut(duration: 0.25), value: managing)
        .animation(.easeInOut(duration: 0.25), value: manager.switchingTo)
        .sheet(item: $editing) { target in
            NavigationStack {
                ProfileEditorView(target: target)
            }
            .interactiveDismissDisabled(true)
            #if os(macOS)
            .frame(minWidth: 460, minHeight: 600)
            #endif
        }
    }

    /// iPad and Mac put the title and tiles in the middle of the screen; iPhone keeps them up top.
    private var centersContent: Bool {
        #if os(macOS)
        true
        #else
        UIDevice.current.userInterfaceIdiom != .phone
        #endif
    }

    private var title: some View {
        Text(managing ? String(localized: "profile.manage_profiles") : String(localized: "profile.whos_going_on_an_adventure"))
            .font(.system(size: 30, weight: .semibold, design: .rounded))
            .foregroundStyle(.white)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 24)
    }

    private var background: some View {
        ProfilePickerTheme.gradient(themeHex).ignoresSafeArea()
    }

    private enum Item: Identifiable {
        case profile(AppProfile)
        case add
        var id: String {
            if case .profile(let profile) = self { return profile.id.uuidString }
            return "add"
        }
    }

    /// Rows of tiles, each centred, so a lone Add Profile sits in the middle of its row.
    private var centeredRows: some View {
        let items = manager.profiles.map(Item.profile) + [.add]
        let spacing: CGFloat = 24
        let tileWidth = avatarSize + 24
        let available = min(max(scrollSize.width - 48, tileWidth), 720 - 48)
        let perRow = max(1, Int((available + spacing) / (tileWidth + spacing)))
        let rows = stride(from: 0, to: items.count, by: perRow).map { Array(items[$0..<min($0 + perRow, items.count)]) }
        return VStack(spacing: 30) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                HStack(alignment: .top, spacing: spacing) {
                    ForEach(row) { item in
                        Group {
                            switch item {
                            case .profile(let profile): tile(profile)
                            case .add: addTile
                            }
                        }
                        .frame(width: tileWidth)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity)
    }

    private var topBar: some View {
        HStack {
            Spacer()
            Button {
                if managing { managing = false } else { manager.isPickerShown = false }
            } label: {
                IconView("xmark")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 40, height: 40)
                    .mediaGlassChrome(Circle(), enabled: liquidGlass, off: Color.white.opacity(0.15))
            }
            .buttonStyle(PressScaleStyle())
            .accessibilityLabel(managing ? String(localized: "common.done") : String(localized: "profile.close"))
            .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, 20)
        .padding(.top, 12)
        .padding(.bottom, 8)
    }

    private var bottomBar: some View {
        VStack(spacing: 14) {
            if managing {
                HStack(spacing: 12) {
                    ForEach(ProfilePickerTheme.colors, id: \.self) { hex in
                        Button { themeHex = hex } label: {
                            Circle()
                                .fill(Color(profileHex: hex))
                                .frame(width: 26, height: 26)
                                .overlay(Circle().strokeBorder(.white, lineWidth: themeHex == hex ? 2.5 : 0).padding(-4))
                        }
                        .buttonStyle(PressScaleStyle())
                        .accessibilityLabel("profile.background_colour")
                    }
                }
                .padding(.bottom, 4)
                Toggle("profile.ask_at_launch", isOn: $askAtLaunch)
                    .tint(.white.opacity(0.6))
                    .foregroundStyle(.white)
                    .font(.subheadline)
                    .frame(maxWidth: 280)
            }
            Button {
                managing.toggle()
            } label: {
                Text(LocalizedStringKey(managing ? "common.done" : "profile.manage_profiles"))
                    .font(.system(size: 16, weight: .bold))
                    .tracking(0.8)
                    .textCase(.uppercase)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 22)
                    .padding(.vertical, 12)
                    .contentShape(Rectangle())
            }
            .buttonStyle(PressScaleStyle())
        }
        .padding(.bottom, 24)
    }

    private func tile(_ profile: AppProfile) -> some View {
        let isActive = profile.id == manager.active?.id
        return Button {
            if managing {
                editing = .edit(profile.id)
            } else if isActive {
                manager.isPickerShown = false
            } else {
                Task { await manager.switchTo(profile.id) }
            }
        } label: {
            VStack(spacing: 12) {
                ProfileAvatarView(profile: profile, size: avatarSize)
                    .overlay(Circle().strokeBorder(.white, lineWidth: isActive && !managing ? 3 : 0).padding(-6))
                    .overlay {
                        if managing {
                            ZStack {
                                Circle().fill(.black.opacity(0.35))
                                IconView("pencil")
                                    .font(.system(size: 24, weight: .semibold))
                                    .foregroundStyle(.white)
                                    .frame(width: 58, height: 58)
                                    .mediaGlassChrome(Circle(), enabled: liquidGlass, off: Color.white.opacity(0.2))
                            }
                            .transition(.opacity)
                        }
                    }
                Text(profile.name)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(PressScaleStyle())
        .accessibilityLabel(managing ? String(localized: "common.edit_name \(profile.name)") : isActive ? "\(profile.name), current" : String(localized: "profile.switch_to \(profile.name)"))
    }

    private var addTile: some View {
        Button { editing = .create } label: {
            VStack(spacing: 12) {
                ZStack {
                    Circle().fill(Color.black.opacity(0.35))
                    Circle().strokeBorder(.white, lineWidth: 2)
                    IconView("plus")
                        .font(.system(size: avatarSize * 0.3, weight: .light))
                        .foregroundStyle(.white)
                }
                .frame(width: avatarSize, height: avatarSize)
                Text("profile.add_profile")
                    .font(.system(size: 17, weight: .regular))
                    .foregroundStyle(.white)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(PressScaleStyle())
    }

    private func switchingCover(_ profile: AppProfile) -> some View {
        ZStack {
            background
            VStack(spacing: 20) {
                ProfileAvatarView(profile: profile, size: avatarSize)
                ProgressView().tint(.white)
                Text("profile.switching_to \(profile.name)")
                    .font(.headline)
                    .foregroundStyle(.white.opacity(0.85))
            }
        }
        .transition(.opacity)
    }
}

private struct PickerSizeKey: PreferenceKey {
    static var defaultValue: CGSize = .zero
    // Views that don't measure report zero too; taking the last value let one of them wipe
    // the width out, and an iPhone laid its profiles out one to a row.
    static func reduce(value: inout CGSize, nextValue: () -> CGSize) {
        let next = nextValue()
        value = CGSize(width: max(value.width, next.width), height: max(value.height, next.height))
    }
}

/// The profile picker's background: a dark gradient into the chosen colour.
enum ProfilePickerTheme {
    static let key = "profilesPickerColor"
    static let defaultHex = "#E5484D"
    static let colors = ["#E5484D", "#F76B15", "#C9A227", "#46A758", "#12A594", "#3E63DD", "#6E56CF", "#D6409F", "#8D6E63"]

    static func gradient(_ hex: String) -> LinearGradient {
        let (r, g, b) = ProfilePalette.rgb(hex) ?? (0.9, 0.28, 0.3)
        func shade(_ f: Double) -> Color { Color(red: r * f, green: g * f, blue: b * f) }
        return LinearGradient(colors: [Color(red: 0.03, green: 0.02, blue: 0.02), shade(0.22), shade(0.45)],
                              startPoint: .top, endPoint: .bottom)
    }
}

enum EditorTarget: Identifiable, Hashable {
    case create
    case edit(UUID)
    var id: String {
        switch self {
        case .create: return "create"
        case .edit(let id): return id.uuidString
        }
    }
}

// MARK: - Editor

/// Making a profile, or changing one: its name, picture and colour, and for a new one, where its
/// modules come from. Closes only through Cancel or Save.
struct ProfileEditorView: View {
    let target: EditorTarget
    @ObservedObject private var manager = ProfileManager.shared
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var colorHex = ""
    @State private var photo: Data?
    @State private var photoRemoved = false
    @State private var moduleChoice = ModuleChoiceTag.own
    @State private var moduleSource: UUID?
    @State private var showFileImporter = false
    @State private var showPhotoPicker = false
    @State private var confirmDelete = false
    @State private var loaded = false

    enum ModuleChoiceTag: Hashable { case own, copy, share }

    private var editing: AppProfile? {
        if case .edit(let id) = target { return manager.profiles.first { $0.id == id } }
        return nil
    }
    private var isActive: Bool { editing?.id == manager.active?.id }

    /// What the avatar shows while editing.
    private var preview: AppProfile {
        var profile = editing ?? AppProfile(id: UUID(), name: name, colorHex: colorHex, moduleGroup: UUID())
        profile.name = name.isEmpty ? (editing?.name ?? "?") : name
        profile.colorHex = colorHex
        if photoRemoved { profile.hasPhoto = false }
        return profile
    }

    private var hasPicture: Bool { photo != nil || (preview.hasPhoto && !photoRemoved) }

    var body: some View {
        Form {
            Section {
                VStack(spacing: 12) {
                    avatarPreview
                    pictureMenu
                    Text("profile.without_a_picture_the_profile")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .listRowBackground(Color.clear)
            }

            Section("common.name") {
                TextField("common.name", text: $name)
                    #if os(iOS)
                    .textInputAutocapitalization(.words)
                    #endif
            }

            Section {
                colorSwatches
            } header: {
                Text("profile.colour")
            } footer: {
                Text("profile.shown_when_the_profile_has")
            }

            if editing == nil {
                modulesSection
            } else if let editing, !manager.moduleSharers(of: editing).isEmpty {
                Section("common.modules") {
                    Text("profile.shares_modules_with \(manager.moduleSharers(of: editing).map(\.name).formatted(.list(type: .and)))")
                        .foregroundStyle(.secondary)
                }
            }

            // Any but the last: the one in use is switched away from first.
            if let editing, manager.profiles.count > 1 {
                Section {
                    Button("profile.delete_profile", role: .destructive) { confirmDelete = true }
                } footer: {
                    Text(deleteFooter(editing))
                }
            }
        }
        #if os(macOS)
        .formStyle(.grouped)
        #endif
        .navigationTitle(editing == nil ? String(localized: "profile.new_profile") : String(localized: "profile.edit_profile"))
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .interactiveDismissDisabled(true)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("common.cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button(editing == nil ? String(localized: "modules.add") : String(localized: "common.save"), action: save)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .onAppear(perform: load)
        .fileImporter(isPresented: $showFileImporter, allowedContentTypes: [.image]) { result in
            guard case .success(let url) = result else { return }
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            if let data = try? Data(contentsOf: url) { usePhoto(data) }
        }
        .modifier(PhotoPickerModifier(isPresented: $showPhotoPicker) { usePhoto($0) })
        .confirmationDialog(String(localized: "common.delete_name_confirm \(editing?.name ?? String())"), isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("profile.delete_profile", role: .destructive) {
                if let id = editing?.id { Task { await manager.deleteSwitchingAway(id) } }
                dismiss()
            }
            Button("common.cancel", role: .cancel) {}
        } message: {
            Text("profile.its_library_progress_settings_and")
        }
    }

    private func deleteFooter(_ profile: AppProfile) -> String {
        let deletes = String(localized: "profile.deletes_s_library_progress_settings \(profile.name)")
        guard isActive, let next = manager.profiles.first(where: { $0.id != profile.id }) else { return deletes }
        return deletes + " You're using it now, so Shirox switches to \(next.name) first."
    }

    // MARK: Parts

    @ViewBuilder
    private var avatarPreview: some View {
        if let photo, let image = Self.cgImage(photo) {
            Image(decorative: image, scale: 1)
                .resizable()
                .scaledToFill()
                .frame(width: 104, height: 104)
                .clipShape(Circle())
        } else {
            ProfileAvatarView(profile: preview, size: 104)
        }
    }

    /// One button under the picture, whatever there is to do with it, so the row never changes
    /// shape when a picture is chosen.
    private var pictureMenu: some View {
        Menu {
            if PhotoPickerModifier.isAvailable {
                Button { showPhotoPicker = true } label: { Label("profile.choose_photo", icon: "photo.on.rectangle") }
            }
            Button { showFileImporter = true } label: { Label("profile.choose_file", icon: "folder") }
            if hasPicture {
                Divider()
                Button(role: .destructive) {
                    photo = nil
                    photoRemoved = true
                } label: { Label("profile.remove_picture", icon: "trash") }
            }
        } label: {
            Text(hasPicture ? String(localized: "profile.change_picture") : String(localized: "profile.add_picture"))
                .font(.subheadline.weight(.semibold))
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    private var colorSwatches: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 34), spacing: 12)], spacing: 12) {
            ForEach(ProfilePalette.colors, id: \.self) { hex in
                let takenBy = manager.profiles.first { $0.colorHex == hex && $0.id != editing?.id }
                Button { colorHex = hex } label: {
                    Circle()
                        .fill(Color(profileHex: hex))
                        .frame(width: 34, height: 34)
                        .overlay(Circle().strokeBorder(Color.primary, lineWidth: colorHex == hex ? 3 : 0).padding(-4))
                        .overlay {
                            if takenBy != nil {
                                IconView("person.fill").font(.caption2).foregroundStyle(.white.opacity(0.8))
                            }
                        }
                }
                .buttonStyle(.plain)
                .accessibilityLabel(takenBy.map { String(localized: "profile.colour_used_by \($0.name)") } ?? String(localized: "profile.colour"))
            }
        }
        .padding(.vertical, 6)
    }

    private var modulesSection: some View {
        Section {
            Picker("common.modules", selection: $moduleChoice) {
                Text("profile.its_own").tag(ModuleChoiceTag.own)
                Text("shared.copy").tag(ModuleChoiceTag.copy)
                Text("profile.share").tag(ModuleChoiceTag.share)
            }
            .pickerStyle(.segmented)
            if moduleChoice != .own {
                Picker(moduleChoice == .share ? String(localized: "profile.share_with") : String(localized: "profile.copy_from"), selection: $moduleSource) {
                    ForEach(manager.profiles) { profile in
                        Text(profile.name).tag(Optional(profile.id))
                    }
                }
            }
        } header: {
            Text("common.modules")
        } footer: {
            Text(modulesFootnote)
        }
    }

    private var modulesFootnote: String {
        let other = manager.profiles.first { $0.id == moduleSource }?.name ?? "the other profile"
        switch moduleChoice {
        case .own: return String(localized: "profile.starts_with_no_modules_add")
        case .copy: return String(localized: "profile.starts_with_s_modules_after \(other)")
        case .share: return String(localized: "profile.uses_the_same_modules_as \(other)")
        }
    }

    // MARK: Actions

    private func load() {
        guard !loaded else { return }
        loaded = true
        if let editing {
            name = editing.name
            colorHex = editing.colorHex
        } else {
            colorHex = ProfilePalette.pick(avoiding: manager.profiles.map(\.colorHex))
            moduleSource = manager.active?.id
        }
    }

    private func usePhoto(_ data: Data) {
        guard let normalized = ProfileManager.normalizedPhoto(data) else { return }
        photo = normalized
        photoRemoved = false
    }

    private func save() {
        if let editing {
            manager.rename(editing.id, to: name)
            manager.setColor(editing.id, hex: colorHex)
            if let photo {
                manager.setPhoto(photo, for: editing.id)
            } else if photoRemoved {
                manager.setPhoto(nil, for: editing.id)
            }
        } else {
            let source = moduleSource ?? manager.active?.id
            let choice: ProfileManager.ModuleChoice
            switch (moduleChoice, source) {
            case (.copy, let id?): choice = .copy(from: id)
            case (.share, let id?): choice = .share(with: id)
            default: choice = .own
            }
            manager.create(name: name, photo: photo, colorHex: colorHex, modules: choice)
        }
        dismiss()
    }

    private static func cgImage(_ data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }
}

/// The Photos library's picker where the system has one (iOS 16, macOS 13), handing back the
/// chosen image's data.
private struct PhotoPickerModifier: ViewModifier {
    @Binding var isPresented: Bool
    let onPick: (Data) -> Void

    static var isAvailable: Bool {
        #if canImport(PhotosUI)
        if #available(iOS 16.0, macOS 13.0, *) { return true }
        #endif
        return false
    }

    func body(content: Content) -> some View {
        #if canImport(PhotosUI)
        if #available(iOS 16.0, macOS 13.0, *) {
            content.modifier(Picker16(isPresented: $isPresented, onPick: onPick))
        } else {
            content
        }
        #else
        content
        #endif
    }

    #if canImport(PhotosUI)
    @available(iOS 16.0, macOS 13.0, *)
    private struct Picker16: ViewModifier {
        @Binding var isPresented: Bool
        let onPick: (Data) -> Void
        @State private var item: PhotosPickerItem?

        func body(content: Content) -> some View {
            content
                .photosPicker(isPresented: $isPresented, selection: $item, matching: .images)
                .onChangeOf(item) { newItem in
                    guard let newItem else { return }
                    Task {
                        if let data = try? await newItem.loadTransferable(type: Data.self) {
                            await MainActor.run { onPick(data) }
                        }
                        item = nil
                    }
                }
        }
    }
    #endif
}

#endif

#if os(tvOS)
/// The Apple TV has no profile screens: its content as it is.
struct ProfileHost<Content: View>: View {
    @ViewBuilder let content: () -> Content
    var body: some View { content() }
}
#endif
