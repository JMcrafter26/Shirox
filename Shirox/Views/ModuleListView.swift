import SwiftUI
import UniformTypeIdentifiers

struct ModuleListView: View {
    @EnvironmentObject private var moduleManager: ModuleManager
    @ObservedObject private var providerManager = ProviderManager.shared
    @ObservedObject private var discovery = DiscoverySource.shared
    @ObservedObject private var simklAuth = SimklAuthManager.shared
    @Environment(\.dismiss) private var dismiss
    /// In a sheet, a Done button closes it — a Mac's sheet can't be swiped away.
    var showsDone = false
    @State private var moduleURL = ""
    @State private var isRefreshing = false
    @State private var isAddingModule = false
    @State private var addModuleError: String?
    @State private var isAddingLocalModule = false
    @State private var isAddingJellyfinModule = false
    @FocusState private var isTextFieldFocused: Bool
    @State private var isCheckingAll = false
    /// Set after Check All finds broken modules, to offer removing them.
    @State private var offerRemovingBroken = false
    /// A module just added whose check failed, to keep or remove.
    @State private var failedNewModule: (module: ModuleDefinition, step: ModuleCheckStep, reason: String)?
    @State private var showModuleImport = false
    /// The module whose script is open in the editor.
    @State private var editingScriptOf: ModuleDefinition?

    private static var localFilesBlurb: String {
        #if os(macOS) || targetEnvironment(macCatalyst)
        String(localized: "modules.watch_video_files_from_your")
        #else
        String(localized: "modules.watch_videos_from_your_devices")
        #endif
    }

    private let localFilesModuleURL = "https://raw.githubusercontent.com/xibrox/local-files-module/refs/heads/main/local.json"
    private let jellyfinModuleURL = "https://raw.githubusercontent.com/xibrox/jellyfin-module/refs/heads/main/jellyfin.json"

    var body: some View {
        List {
                addModuleSection

                if !isLocalModuleInstalled {
                    Section {
                        localFilesPromoCard
                    }
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
                #if !os(tvOS)
                .listRowSeparator(.hidden)
                #endif
                }

                if !isJellyfinModuleInstalled {
                    Section {
                        jellyfinPromoCard
                    }
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
                #if !os(tvOS)
                .listRowSeparator(.hidden)
                #endif
                }

                if let error = addModuleError {
                    Section {
                        errorBanner(error)
                    }
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
                #if !os(tvOS)
                .listRowSeparator(.hidden)
                #endif
                }

                // A failed add copies its message into `addModuleError` too — shown once, above.
                if let error = moduleManager.errorMessage, error != addModuleError {
                    Section {
                        errorBanner(error)
                    }
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
                #if !os(tvOS)
                .listRowSeparator(.hidden)
                #endif
                }

                Section {
                    ForEach(ProviderType.userProviders, id: \.self) { type in
                        builtInProviderRow(type)
                            .listRowInsets(EdgeInsets())
                            .listRowBackground(Color.clear)
                    }
                    // Home and Search from Simkl — offered while signed in, as its search needs the account.
                    if simklAuth.isLoggedIn {
                        builtInProviderRow(.simkl)
                            .listRowInsets(EdgeInsets())
                            .listRowBackground(Color.clear)
                    }

                    if moduleManager.modules.isEmpty {
                        emptyModulesView
                            .listRowInsets(EdgeInsets())
                            .listRowBackground(Color.clear)
                    } else {
                        ForEach(moduleManager.modules) { module in
                            moduleRow(module)
                                .listRowInsets(EdgeInsets())
                                .listRowBackground(Color.clear)
                                .contextMenu {
                                    seanimeDubAction(module)
                                    shareModuleActions(module)
                                    #if !os(tvOS)
                                    Button {
                                        editingScriptOf = module
                                    } label: {
                                        Label("modules.edit_script", icon: "chevron.left.forwardslash.chevron.right")
                                    }
                                    if #available(iOS 16.0, macOS 13.0, *), let files = ModuleShareFiles.urls(for: module) {
                                        ShareLink(items: files) {
                                            Label("modules.share_as_files", icon: "doc.on.doc")
                                        }
                                    }
                                    #endif
                                    Button {
                                        Task { await moduleManager.check(module) }
                                    } label: {
                                        Label("modules.check_again", icon: "checkmark.shield")
                                    }
                                    .disabled(moduleManager.checking.contains(module.id))
                                    Button(role: .destructive) {
                                        removeModule(module)
                                    } label: {
                                        Label("common.remove", icon: "trash")
                                    }
                                }
                        }
                        .onMove(perform: moduleManager.moveModules)
                    }
                } header: {
                    Text("modules.sources")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .textCase(.uppercase)
                }
            }
            .softScrollEdges()
            #if os(iOS)
            .listStyle(.insetGrouped)
            #elseif !os(tvOS)
            .listStyle(.inset)
            #endif
            .hideScrollContentBackground()
            #if os(iOS)
            .scrollDismissesKeyboardImmediately()
            #endif
            #if os(iOS)
            .background(Color(.systemBackground))
            #elseif os(tvOS)
            // TODO: add back background color
            #else
            .background(Color(NSColor.windowBackgroundColor))
            #endif
            .navigationTitle("common.modules")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .automatic) {
                    Button {
                        Task {
                            isRefreshing = true
                            await moduleManager.checkForUpdates()
                            isRefreshing = false
                        }
                    } label: {
                        if isRefreshing {
                            ProgressView().scaleEffect(0.8)
                        } else {
                            IconView("arrow.clockwise")
                                .font(.system(size: 14, weight: .medium))
                        }
                    }
                    .disabled(moduleManager.modules.isEmpty || isRefreshing)
                }
                ToolbarItem(placement: .automatic) {
                    // Runs every module through a search, episodes and a stream.
                    Button {
                        Task {
                            isCheckingAll = true
                            await moduleManager.checkAll()
                            isCheckingAll = false
                            offerRemovingBroken = !moduleManager.brokenModules.isEmpty
                        }
                    } label: {
                        if isCheckingAll {
                            ProgressView().scaleEffect(0.8)
                        } else {
                            IconView("checkmark.shield")
                                .font(.system(size: 14, weight: .medium))
                        }
                    }
                    .accessibilityLabel("modules.check_all_modules")
                    .disabled(moduleManager.modules.isEmpty || isCheckingAll)
                }
                #if os(iOS)
                ToolbarItem(placement: .automatic) {
                    EditButton()
                }
                #endif
            }
            .modifier(DoneItem(isShown: showsDone) { dismiss() })
            .confirmationDialog(
                brokenTitle,
                isPresented: $offerRemovingBroken,
                titleVisibility: .visible
            ) {
                Button(moduleManager.brokenModules.count == 1 ? String(localized: "modules.remove_it") : String(localized: "modules.remove_them"), role: .destructive) {
                    moduleManager.brokenModules.forEach(removeModule)
                }
                Button("modules.keep", role: .cancel) {}
            } message: {
                Text(moduleManager.brokenModules.map(\.sourceName).joined(separator: ", "))
            }
            .alert(
                String(localized: "modules.this_module_may_not_work"),
                isPresented: Binding(get: { failedNewModule != nil }, set: { if !$0 { failedNewModule = nil } }),
                presenting: failedNewModule
            ) { failed in
                Button("common.remove", role: .destructive) { removeModule(failed.module) }
                Button("modules.keep", role: .cancel) {}
            } message: { failed in
                Text("modules.was_added_but_a_test \(failed.module.sourceName) \(failed.step.label.lowercased()) \(failed.reason)")
            }
        .onChangeOf(moduleURL) { _ in
            addModuleError = nil
            moduleManager.errorMessage = nil
        }
        #if !os(tvOS)
        .sheet(isPresented: $showModuleImport, onDismiss: checkNewModule) {
            NavigationStack {
                ModuleImportView()
            }
            .environmentObject(moduleManager)
            #if os(macOS)
            .frame(minWidth: 520, minHeight: 640)
            #endif
        }
        .sheet(item: Binding(get: { editingScriptOf.map(EditingScript.init) },
                             set: { editingScriptOf = $0?.module })) { editing in
            NavigationStack {
                ModuleScriptEditorView(moduleID: editing.module.id)
            }
            .environmentObject(moduleManager)
            #if os(macOS)
            .frame(minWidth: 640, minHeight: 520)
            #endif
        }
        #endif
        .sheet(item: $moduleManager.pendingRepo) { repo in
            ExtensionRepoSheet(repo: repo)
                .environmentObject(moduleManager)
                #if os(macOS)
                .frame(minWidth: 520, minHeight: 560)
                #endif
        }
    }

    private struct EditingScript: Identifiable {
        let module: ModuleDefinition
        var id: String { module.id }
    }

    private var brokenTitle: String {
        let count = moduleManager.brokenModules.count
        return count == 1 ? "1 module didn't work" : "\(count) modules didn't work"
    }

    /// The module's last check, under its name.
    @ViewBuilder
    private func checkStatus(_ module: ModuleDefinition) -> some View {
        if moduleManager.checking.contains(module.id) {
            HStack(spacing: 4) {
                ProgressView().controlSize(.mini)
                Text("modules.checking")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        } else {
            switch moduleManager.checkResults[module.id] {
            case .passed:
                Label("modules.works", icon: "checkmark.seal.fill")
                    .font(.caption)
                    .foregroundStyle(.green)
            case .failed(let step, let reason):
                Label("modules.failed \(step.label) \(reason)", icon: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .lineLimit(2)
            case .needsVerification:
                Label("modules.asks_for_a_cloudflare_check", icon: "shield.lefthalf.filled")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            case .skipped, .none:
                EmptyView()
            }
        }
    }

    // MARK: - Add Module
    /// A link to paste, or a module's files.
    private var addModuleSection: some View {
        Section {
            HStack(spacing: 10) {
                IconView("link")
                    .foregroundStyle(.secondary)
                    .frame(width: 22)
                TextField("modules.module_json_url", text: $moduleURL)
                    .textContentType(.URL)
                    .autocorrectionDisabled()
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    .keyboardType(.URL)
                    .submitLabel(.go)
                    #endif
                    .focused($isTextFieldFocused)
                    .disabled(isAddingModule)
                    .onSubmit { addModule() }
                if isAddingModule {
                    ProgressView()
                } else if !moduleURL.isEmpty {
                    Button("modules.add", action: addModule)
                        .font(.body.weight(.semibold))
                        .buttonStyle(.borderless)
                } else {
                    Button {
                        if let text = Clipboard.string?.trimmingCharacters(in: .whitespacesAndNewlines) { moduleURL = text }
                    } label: {
                        IconView("doc.on.clipboard")
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("modules.paste_link")
                }
            }
            #if !os(tvOS)
            Button {
                showModuleImport = true
            } label: {
                Label {
                    Text("modules.import_from_files").foregroundStyle(Color.primary)
                } icon: {
                    IconView("doc.badge.plus").foregroundStyle(.secondary)
                }
            }
            #endif
        } header: {
            Text("modules.add_module")
        } footer: {
            Text("modules.paste_a_modules_json_link")
        }
    }

    // MARK: - Local Files Promo
    private var isLocalModuleInstalled: Bool {
        moduleManager.modules.contains { $0.isLocalPlayback }
    }

    private var localFilesPromoCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                IconView("folder.badge.plus")
                    .font(.title2)
                    .foregroundStyle(Color.primary)
                    .frame(width: 44, height: 44)
                    .background(Color.primary.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))

                VStack(alignment: .leading, spacing: 3) {
                    Text("modules.play_local_files")
                        .font(.headline)
                    Text(Self.localFilesBlurb)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            HStack(spacing: 8) {
                Text(localFilesModuleURL)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 8)
                Button {
                    copyLocalFilesURL()
                } label: {
                    IconView("doc.on.doc")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }

            Button {
                addLocalFilesModule()
            } label: {
                HStack {
                    Spacer()
                    if isAddingLocalModule {
                        ProgressView().scaleEffect(0.8)
                    } else {
                        Label("modules.add_module", icon: "plus.circle.fill")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Color.primary)
                    }
                    Spacer()
                }
                .padding(.vertical, 10)
                .background(Color.primary.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
            }
            .buttonStyle(.plain)
            .disabled(isAddingLocalModule)
        }
        .padding(16)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    // MARK: - Jellyfin Promo
    private var isJellyfinModuleInstalled: Bool {
        moduleManager.modules.contains { $0.isJellyfin }
    }

    private var jellyfinPromoCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                IconView("server.rack")
                    .font(.title2)
                    .foregroundStyle(Color.primary)
                    .frame(width: 44, height: 44)
                    .background(Color.primary.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))

                VStack(alignment: .leading, spacing: 3) {
                    Text("modules.connect_jellyfin")
                        .font(.headline)
                    Text("modules.stream_your_own_jellyfin_server")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            HStack(spacing: 8) {
                Text(jellyfinModuleURL)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 8)
                Button {
                    copyJellyfinURL()
                } label: {
                    IconView("doc.on.doc")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }

            Button {
                addJellyfinModule()
            } label: {
                HStack {
                    Spacer()
                    if isAddingJellyfinModule {
                        ProgressView().scaleEffect(0.8)
                    } else {
                        Label("modules.add_module", icon: "plus.circle.fill")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Color.primary)
                    }
                    Spacer()
                }
                .padding(.vertical, 10)
                .background(Color.primary.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
            }
            .buttonStyle(.plain)
            .disabled(isAddingJellyfinModule)
        }
        .padding(16)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    // MARK: - Error Banner
    private func errorBanner(_ error: String) -> some View {
        HStack(spacing: 8) {
            IconView("xmark.circle.fill")
                .foregroundStyle(Color.red)   // Error remains red for clarity
            Text(error)
                .font(.subheadline)
                .foregroundStyle(Color.red)
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        #if os(iOS)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
        #elseif os(tvOS)
        // TODO: add back background color
        #else
        .background(Color(.controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
        #endif
        .padding(.horizontal, 16)
        .padding(.vertical, 4)
    }

    // MARK: - Built-in Provider Row
    private func builtInProviderRow(_ type: ProviderType) -> some View {
        // Simkl is the Home and Search source beside the AniList/MAL chain, not a link in it.
        let isChosen = type == .simkl
            ? discovery.usesSimkl
            : !discovery.usesSimkl && providerManager.orderedProviders.first?.providerType == type
        let isSelected = moduleManager.activeModule == nil
        let isDown = isChosen && type != .simkl && providerManager.fallbackActive

        return Button {
            if moduleManager.activeModule != nil {
                moduleManager.deselectModule()
            }
            if type == .simkl {
                discovery.chooseSimkl()
            } else {
                discovery.chooseProvider(type)
            }
            #if os(iOS)
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            #endif
        } label: {
            HStack(spacing: 14) {
                AsyncImage(url: URL(string: type.iconURL)) { phase in
                    switch phase {
                    case .success(let image):
                        image.resizable().scaledToFit()
                    case .failure, .empty:
                        IconView("list.bullet")
                            .font(.title2)
                            .foregroundStyle(Color.primary)
                    @unknown default:
                        IconView("list.bullet")
                            .font(.title2)
                            .foregroundStyle(Color.primary)
                    }
                }
                .frame(width: 44, height: 44)
                // Simkl's icon is a dark tile with a see-through "S": on white, as elsewhere.
                .background(type == .simkl ? Color.white : Color.clear)
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .background(Color.primary.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))

                VStack(alignment: .leading, spacing: 2) {
                    Text(type.displayName).font(.headline)
                    HStack(spacing: 6) {
                        Text(type == .simkl ? String(localized: "modules.built_in_anime_shows_and") : String(localized: "modules.built_in_anime_metadata"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        if isDown {
                            Text("modules.unavailable")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.red)
                                .padding(.horizontal, 6).padding(.vertical, 2)
                                .background(.red.opacity(0.12), in: Capsule())
                        }
                    }
                }
                Spacer()
                if isSelected && isChosen && !isDown {
                    IconView("checkmark.circle.fill")
                        .foregroundStyle(Color.primary)
                        .font(.title3)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .background(
                (isSelected && isChosen) ? Color.primary.opacity(0.08) : Color.black.opacity(0.001),
                in: RoundedRectangle(cornerRadius: 12)
            )
            .opacity(isDown ? 0.45 : 1.0)
        }
        .buttonStyle(.plain)
        .contentShape(Rectangle())
        .animation(.easeOut(duration: 0.2), value: isSelected)
        .animation(.easeOut(duration: 0.2), value: providerManager.fallbackActive)
    }

    // MARK: - Module Row
    private func moduleRow(_ module: ModuleDefinition) -> some View {
        let isActive = moduleManager.activeModule?.id == module.id
        return Button {
            if !isActive {
                moduleManager.selectModule(module)
                #if os(iOS)
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                #endif
            }
        } label: {
            HStack(spacing: 14) {
                Group {
                    CachedAsyncImage(urlString: module.iconUrl ?? "", base64String: module.iconData)
                        .frame(width: 44, height: 44)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                        .background(Color.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(module.sourceName).font(.headline)
                    HStack(spacing: 6) {
                        Text("v\(module.version)").font(.caption).foregroundStyle(.secondary)
                        if let author = module.author, !author.name.isEmpty {
                            Text("·").font(.caption).foregroundStyle(.secondary)
                            Text(author.name).font(.caption).foregroundStyle(.secondary)
                        }
                        if module.isFromFile || module.isScriptEdited {
                            Text(module.isFromFile ? String(localized: "modules.file") : String(localized: "modules.edited"))
                                .font(.caption2.weight(.semibold))
                                .padding(.horizontal, 5).padding(.vertical, 1)
                                .background(Color.secondary.opacity(0.15), in: Capsule())
                        }
                        if let badge = module.seanime != nil ? "Seanime" : module.ext?.kind.badge {
                            Text(badge)
                                .font(.caption2.weight(.semibold))
                                .padding(.horizontal, 5).padding(.vertical, 1)
                                .background(Color.secondary.opacity(0.15), in: Capsule())
                        }
                    }
                    checkStatus(module)
                }
                Spacer()
                if isActive {
                    IconView("checkmark.circle.fill")
                        .foregroundStyle(Color.primary)
                        .font(.title3)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .background(isActive ? Color.primary.opacity(0.08) : Color.black.opacity(0.001), in: RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .contentShape(Rectangle())
        .animation(.easeOut(duration: 0.2), value: isActive)
    }

    // MARK: - Empty State
    private var emptyModulesView: some View {
        VStack(spacing: 12) {
            IconView("puzzlepiece.extension")
                .font(.system(size: 32))
                .foregroundStyle(.tertiary)
            Text("modules.no_modules_installed")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Text("modules.paste_a_module_json_url")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
        .padding(.horizontal, 16)
        .background(Color.clear)
    }

    // MARK: - Actions

    /// A Seanime streaming provider that dubs: Sub or Dub for its searches. Reloads it when active.
    @ViewBuilder
    private func seanimeDubAction(_ module: ModuleDefinition) -> some View {
        if let info = module.seanime, info.kind == .anime, info.supportsDub {
            let dub = SeanimeProviderSettings.dub(for: module.id)
            Button {
                SeanimeProviderSettings.setDub(!dub, for: module.id)
                if moduleManager.activeModule?.id == module.id { moduleManager.selectModule(module) }
            } label: {
                if dub { Label("modules.dub", icon: "checkmark") } else { Text("modules.dub") }
            }
        }
    }

    /// Copy / share actions for an installed module, so a source can be passed to someone else
    /// without them hunting down the original link.
    ///
    /// Shares `jsonUrl` — the manifest URL `ModuleManager.addModule(from:)` records at install
    /// time, and the one the recipient can paste straight back into "Add from URL". `scriptUrl`
    /// is the raw JS and is not installable, so it is deliberately not offered.
    @ViewBuilder
    private func shareModuleActions(_ module: ModuleDefinition) -> some View {
        #if os(tvOS)
        EmptyView()
        #else
        if let link = module.jsonUrl, !link.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            Button {
                Clipboard.copy(link)
                #if os(iOS)
                ToastManager.shared.show(message: String(localized: "modules.module_link_copied"), type: .info)
                #endif
            } label: {
                Label("modules.copy_link", icon: "link")
            }
            if #available(iOS 16.0, macOS 13.0, *), let url = URL(string: link) {
                ShareLink(item: url) {
                    Label("modules.share_module", icon: "square.and.arrow.up")
                }
            }
        }
        #endif
    }

    private func addModule() {
        let trimmedURL = moduleURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedURL.isEmpty, let url = URL(string: trimmedURL) else {
            addModuleError = String(localized: "modules.invalid_url")
            #if os(iOS)
            UINotificationFeedbackGenerator().notificationOccurred(.error)
            #endif
            return
        }

        withAnimation {
            addModuleError = nil
            isAddingModule = true
        }

        Task {
            await moduleManager.addModule(from: url)

            await MainActor.run {
                withAnimation {
                    isAddingModule = false
                    if moduleManager.errorMessage == nil {
                        moduleURL = ""
                        isTextFieldFocused = false
                        #if os(iOS)
                        UINotificationFeedbackGenerator().notificationOccurred(.success)
                        #endif
                        checkNewModule()
                    } else {
                        addModuleError = moduleManager.errorMessage
                        #if os(iOS)
                        UINotificationFeedbackGenerator().notificationOccurred(.error)
                        #endif
                    }
                }
            }
        }
    }

    /// Tests a module just added, and warns when it doesn't get as far as a stream.
    private func checkNewModule() {
        guard let id = moduleManager.lastAddedModuleID,
              let module = moduleManager.modules.first(where: { $0.id == id }) else { return }
        Task {
            if case .failed(let step, let reason) = await moduleManager.check(module),
               moduleManager.modules.contains(where: { $0.id == id }) {
                failedNewModule = (module, step, reason)
            }
        }
    }

    private func copyLocalFilesURL() {
        #if os(iOS)
        UIPasteboard.general.string = localFilesModuleURL
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        #elseif os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(localFilesModuleURL, forType: .string)
        #endif
    }

    private func addLocalFilesModule() {
        guard let url = URL(string: localFilesModuleURL) else {
            addModuleError = String(localized: "modules.invalid_url")
            return
        }
        withAnimation {
            addModuleError = nil
            moduleManager.errorMessage = nil
            isAddingLocalModule = true
        }
        Task {
            await moduleManager.addModule(from: url)

            await MainActor.run {
                withAnimation {
                    isAddingLocalModule = false
                    if moduleManager.errorMessage == nil {
                        #if os(iOS)
                        UINotificationFeedbackGenerator().notificationOccurred(.success)
                        #endif
                    } else {
                        addModuleError = moduleManager.errorMessage
                        #if os(iOS)
                        UINotificationFeedbackGenerator().notificationOccurred(.error)
                        #endif
                    }
                }
            }
        }
    }

    private func copyJellyfinURL() {
        #if os(iOS)
        UIPasteboard.general.string = jellyfinModuleURL
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        #elseif os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(jellyfinModuleURL, forType: .string)
        #endif
    }

    private func addJellyfinModule() {
        guard let url = URL(string: jellyfinModuleURL) else {
            addModuleError = String(localized: "modules.invalid_url")
            return
        }
        withAnimation {
            addModuleError = nil
            moduleManager.errorMessage = nil
            isAddingJellyfinModule = true
        }
        Task {
            await moduleManager.addModule(from: url)

            await MainActor.run {
                withAnimation {
                    isAddingJellyfinModule = false
                    if moduleManager.errorMessage == nil {
                        #if os(iOS)
                        UINotificationFeedbackGenerator().notificationOccurred(.success)
                        #endif
                    } else {
                        addModuleError = moduleManager.errorMessage
                        #if os(iOS)
                        UINotificationFeedbackGenerator().notificationOccurred(.error)
                        #endif
                    }
                }
            }
        }
    }

    private func removeModule(_ module: ModuleDefinition) {
        moduleManager.removeModule(module)
        #if os(iOS)
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        #endif
    }
}

/// The Done button of a sheet, left out rather than left empty elsewhere: from iOS 26 an
/// empty item still draws its glass.
private struct DoneItem: ViewModifier {
    let isShown: Bool
    let done: () -> Void

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(iOS 16, *) {
            content.toolbar {
                if isShown {
                    ToolbarItem(placement: .confirmationAction) { Button("common.done", action: done) }
                }
            }
        } else {
            // A bare `if` in a toolbar builder needs iOS 16; before it, the condition lives
            // inside the item.
            content.toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    if isShown { Button("common.done", action: done) }
                }
            }
        }
    }
}

#if !os(tvOS)
/// A module's .json and .js, written once per version of it, for Share as Files.
@MainActor
enum ModuleShareFiles {
    private static var made: [String: [URL]] = [:]

    static func urls(for module: ModuleDefinition) -> [URL]? {
        let key = "\(module.id)|\(module.version)|\(module.scriptContent?.hashValue ?? 0)"
        if let urls = made[key], urls.allSatisfy({ FileManager.default.fileExists(atPath: $0.path) }) { return urls }
        guard module.scriptContent != nil, let urls = try? ModuleFileImport.exportFiles(for: module) else { return nil }
        made[key] = urls
        return urls
    }
}
#endif
