import SwiftUI
import ImageIO
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
/// else its initial on its colour.
struct ProfileAvatarView: View {
    let profile: AppProfile
    var size: CGFloat = 44
    @ObservedObject private var manager = ProfileManager.shared

    var body: some View {
        ZStack {
            Circle().fill(Color(profileHex: profile.colorHex))
            Text(profile.initial)
                .font(.system(size: size * 0.42, weight: .semibold, design: .rounded))
                .foregroundStyle(.white)
            if profile.hasPhoto, let image = ProfilePhotoCache.image(at: manager.photoURL(for: profile.id),
                                                                     version: manager.photoVersion) {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .scaledToFill()
            } else if let url = profile.accountAvatarURL {
                CachedAsyncImage(urlString: url)
                    .aspectRatio(contentMode: .fill)
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .overlay(Circle().strokeBorder(Color.primary.opacity(0.1), lineWidth: 0.5))
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

// MARK: - Profiles

/// Every profile on this device: switch to one, add one, or change one.
struct ProfilesView: View {
    @ObservedObject private var manager = ProfileManager.shared
    @State private var editing: EditorTarget?
    @State private var switchTarget: AppProfile?

    private let columns = [GridItem(.adaptive(minimum: 104, maximum: 140), spacing: 20)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                LazyVGrid(columns: columns, spacing: 24) {
                    ForEach(manager.profiles) { profile in
                        profileTile(profile)
                    }
                    addTile
                }
                .padding(.top, 8)

                Text(Self.footnote)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .padding(20)
        }
        .navigationTitle("Profiles")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .sheet(item: $editing) { target in
            NavigationStack {
                ProfileEditorView(target: target)
            }
            #if os(macOS)
            .frame(minWidth: 460, minHeight: 560)
            #endif
        }
        .confirmationDialog(switchTitle, isPresented: Binding(
            get: { switchTarget != nil }, set: { if !$0 { switchTarget = nil } }
        ), titleVisibility: .visible, presenting: switchTarget) { profile in
            Button("Switch to \(profile.name)") { manager.switchTo(profile.id) }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text(Self.switchMessage)
        }
    }

    private var switchTitle: String {
        switchTarget.map { "Switch to \($0.name)?" } ?? ""
    }

    private static var switchMessage: String {
        #if os(macOS)
        "Shirox restarts with this profile's library, progress, accounts and settings."
        #else
        "Shirox closes to load this profile's library, progress, accounts and settings. Open it again to continue."
        #endif
    }

    private static let footnote = "Each profile has its own library, watch progress, settings and sign-ins, and works without an account. Downloads are shared by every profile on this device."

    private func profileTile(_ profile: AppProfile) -> some View {
        let isActive = profile.id == manager.active?.id
        return Button {
            if !isActive { switchTarget = profile }
        } label: {
            VStack(spacing: 8) {
                ProfileAvatarView(profile: profile, size: 84)
                    .overlay(
                        Circle().strokeBorder(Color.accentColor, lineWidth: isActive ? 3 : 0)
                            .padding(-5)
                    )
                Text(profile.name)
                    .font(.subheadline.weight(isActive ? .semibold : .regular))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text(isActive ? "Current" : sharingNote(profile) ?? " ")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button { editing = .edit(profile.id) } label: { Label("Edit", systemImage: "pencil") }
            if !isActive {
                Button { switchTarget = profile } label: { Label("Switch to \(profile.name)", systemImage: "arrow.left.arrow.right") }
            }
        }
        .overlay(alignment: .topTrailing) {
            Button { editing = .edit(profile.id) } label: {
                Image(systemName: "pencil.circle.fill")
                    .font(.title3)
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.white, Color.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Edit \(profile.name)")
            .offset(x: -6, y: -2)
        }
    }

    private func sharingNote(_ profile: AppProfile) -> String? {
        let sharers = manager.moduleSharers(of: profile)
        guard !sharers.isEmpty else { return nil }
        return "Modules shared"
    }

    private var addTile: some View {
        Button { editing = .create } label: {
            VStack(spacing: 8) {
                ZStack {
                    Circle().strokeBorder(Color.secondary.opacity(0.5), style: StrokeStyle(lineWidth: 2, dash: [6, 5]))
                    Image(systemName: "plus").font(.title.weight(.medium)).foregroundStyle(.secondary)
                }
                .frame(width: 84, height: 84)
                Text("Add Profile").font(.subheadline).foregroundStyle(.primary)
                Text(" ").font(.caption2)
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
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
/// modules come from.
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
        if editing == nil { profile.accountAvatarURL = nil }
        return profile
    }

    var body: some View {
        Form {
            Section {
                VStack(spacing: 14) {
                    avatarPreview
                    photoButtons
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .listRowBackground(Color.clear)
            }

            Section("Name") {
                TextField("Name", text: $name)
                    #if os(iOS)
                    .textInputAutocapitalization(.words)
                    #endif
            }

            Section {
                colorSwatches
            } header: {
                Text("Colour")
            } footer: {
                Text("Shown when the profile has no picture of its own or from its account.")
            }

            if editing == nil, manager.profiles.count > 0 {
                modulesSection
            } else if let editing, !manager.moduleSharers(of: editing).isEmpty {
                Section("Modules") {
                    Text("Shares modules with \(manager.moduleSharers(of: editing).map(\.name).joined(separator: ", ")).")
                        .foregroundStyle(.secondary)
                }
            }

            if let editing, !isActive {
                Section {
                    Button("Delete Profile", role: .destructive) { confirmDelete = true }
                } footer: {
                    Text("Deletes \(editing.name)'s library, progress, settings and sign-ins on this device. Accounts themselves aren't touched.")
                }
            }
        }
        #if os(macOS)
        .formStyle(.grouped)
        #endif
        .navigationTitle(editing == nil ? "New Profile" : "Edit Profile")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button(editing == nil ? "Add" : "Save", action: save)
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
        .confirmationDialog("Delete \(editing?.name ?? "")?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete Profile", role: .destructive) {
                if let id = editing?.id { manager.delete(id) }
                dismiss()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Its library, progress, settings and sign-ins on this device are deleted. This can't be undone.")
        }
    }

    // MARK: Parts

    @ViewBuilder
    private var avatarPreview: some View {
        if let photo, let image = Self.cgImage(photo) {
            Image(decorative: image, scale: 1)
                .resizable()
                .scaledToFill()
                .frame(width: 96, height: 96)
                .clipShape(Circle())
        } else {
            ProfileAvatarView(profile: preview, size: 96)
        }
    }

    @ViewBuilder
    private var photoButtons: some View {
        HStack(spacing: 12) {
            #if canImport(PhotosUI)
            if #available(iOS 16.0, macOS 13.0, *) {
                PhotoPickerButton { usePhoto($0) }
            }
            #endif
            Button { showFileImporter = true } label: {
                Label("Choose File", systemImage: "folder")
            }
            .buttonStyle(.bordered)
            if photo != nil || (preview.hasPhoto && !photoRemoved) {
                Button(role: .destructive) {
                    photo = nil
                    photoRemoved = true
                } label: {
                    Label("Remove", systemImage: "trash")
                }
                .buttonStyle(.bordered)
            }
        }
        .font(.subheadline)
        Text(pictureNote)
            .font(.caption)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
    }

    private var pictureNote: String {
        "Without a picture, the profile uses its AniList picture, then MyAnimeList's, then Simkl's, or else its initial."
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
                                Image(systemName: "person.fill").font(.caption2).foregroundStyle(.white.opacity(0.8))
                            }
                        }
                }
                .buttonStyle(.plain)
                .accessibilityLabel(takenBy.map { "Colour used by \($0.name)" } ?? "Colour")
            }
        }
        .padding(.vertical, 6)
    }

    private var modulesSection: some View {
        Section {
            Picker("Modules", selection: $moduleChoice) {
                Text("Its Own").tag(ModuleChoiceTag.own)
                Text("Copy").tag(ModuleChoiceTag.copy)
                Text("Share").tag(ModuleChoiceTag.share)
            }
            .pickerStyle(.segmented)
            if moduleChoice != .own {
                Picker(moduleChoice == .share ? "Share with" : "Copy from", selection: $moduleSource) {
                    ForEach(manager.profiles) { profile in
                        Text(profile.name).tag(Optional(profile.id))
                    }
                }
            }
        } header: {
            Text("Modules")
        } footer: {
            Text(modulesFootnote)
        }
    }

    private var modulesFootnote: String {
        let other = manager.profiles.first { $0.id == moduleSource }?.name ?? "the other profile"
        switch moduleChoice {
        case .own: return "Starts with no modules; add its own from Settings › Modules."
        case .copy: return "Starts with \(other)'s modules. After that each profile's are its own."
        case .share: return "Uses the same modules as \(other): adding, removing or editing one changes both."
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
            name = ""
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

#if canImport(PhotosUI)
/// The Photos library's picker, handing back the chosen image's data.
@available(iOS 16.0, macOS 13.0, *)
private struct PhotoPickerButton: View {
    let onPick: (Data) -> Void
    @State private var item: PhotosPickerItem?

    var body: some View {
        PhotosPicker(selection: $item, matching: .images) {
            Label("Choose Photo", systemImage: "photo")
        }
        .buttonStyle(.bordered)
        .onChange(of: item) { newItem in
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

#endif
