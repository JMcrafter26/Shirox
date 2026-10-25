import SwiftUI
import UniformTypeIdentifiers

#if !os(tvOS)

/// A module made from files on the device: its script (.js), which it can't work without, and
/// everything a manifest holds, typed in or filled from the module's .json.
struct ModuleImportView: View {
    @EnvironmentObject private var moduleManager: ModuleManager
    @Environment(\.dismiss) private var dismiss

    // Script
    @State private var scriptName: String?
    @State private var script: String?
    // Manifest
    @State private var manifestName: String?
    @State private var scriptUrl: String?
    @State private var name = ""
    @State private var version = "1.0.0"
    @State private var authorName = ""
    @State private var authorIcon = ""
    @State private var iconURL = ""
    @State private var iconData: Data?
    @State private var kind = "anime"
    @State private var language = ""
    @State private var baseUrl = ""
    @State private var searchBaseUrl = ""
    @State private var streamType = ""
    @State private var quality = ""
    @State private var softsub = false
    @State private var asyncJS = true

    @State private var picking: Picking?
    @State private var problem: String?
    @State private var isAdding = false
    @State private var confirmDiscard = false

    private enum Picking: Identifiable {
        case script, manifest, icon
        var id: Self { self }
        var types: [UTType] {
            switch self {
            case .script: return [.javaScript, .plainText]
            case .manifest: return [.json]
            case .icon: return [.image]
            }
        }
    }

    private var canAdd: Bool {
        script != nil && !name.trimmingCharacters(in: .whitespaces).isEmpty && !isAdding
    }
    private var hasInput: Bool { script != nil || manifestName != nil || !name.isEmpty }

    /// "120 lines", for the script row.
    private static func lineCount(_ script: String) -> String {
        let lines = script.split(separator: "\n", omittingEmptySubsequences: false).count
        return String(localized: "modules.lines \(lines)")
    }

    var body: some View {
        Form {
            Section {
                fileRow(title: String(localized: "modules.script"), systemImage: "curlybraces", file: scriptName,
                        detail: script.map { Self.lineCount($0) },
                        action: String(localized: "modules.choose_js_file")) { picking = .script }
                NavigationLink {
                    ScriptDraftView(script: Binding(
                        get: { script ?? "" },
                        set: { newValue in
                            script = newValue.isEmpty ? nil : newValue
                            scriptName = newValue.isEmpty ? nil : String(localized: "modules.written_in_the_editor")
                            if !newValue.isEmpty { asyncJS = newValue.contains("async ") }
                        }))
                } label: {
                    Label {
                        Text(scriptName == String(localized: "modules.written_in_the_editor") ? String(localized: "modules.edit_in_editor") : String(localized: "modules.write_or_paste_in_editor"))
                            .foregroundStyle(Color.primary)
                    } icon: {
                        Image(systemName: "square.and.pencil").foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text("modules.script")
            } footer: {
                Text("modules.required_the_modules_javascript_from")
            }

            Section {
                fileRow(title: String(localized: "modules.manifest"), systemImage: "doc.text", file: manifestName, detail: nil,
                        action: String(localized: "modules.fill_from_json_file")) { picking = .manifest }
            } header: {
                Text("modules.manifest")
            } footer: {
                Text("modules.optional_a_modules_json_fills")
            }

            Section {
                HStack(spacing: 14) {
                    iconPreview
                    VStack(alignment: .leading, spacing: 4) {
                        TextField("modules.name_required", text: $name)
                            .font(.headline)
                        TextField("modules.version", text: $version)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
                Menu {
                    Button { picking = .icon } label: { Label("modules.choose_picture", systemImage: "photo") }
                    if iconData != nil || !iconURL.isEmpty {
                        Button(role: .destructive) { iconData = nil; iconURL = "" } label: { Label("modules.remove_icon", systemImage: "trash") }
                    }
                } label: {
                    Label(iconData == nil && iconURL.isEmpty ? String(localized: "modules.add_icon") : String(localized: "modules.change_icon"), systemImage: "photo.badge.plus")
                }
                urlField(String(localized: "modules.icon_url"), text: $iconURL)
            } header: {
                Text("modules.module")
            }

            Section("modules.author") {
                TextField("common.name", text: $authorName)
                urlField(String(localized: "modules.picture_url"), text: $authorIcon)
            }

            Section("modules.source") {
                Picker("settings.type", selection: $kind) {
                    Text("common.anime").tag("anime")
                    Text("common.manga").tag("manga")
                }
                TextField("modules.language_e_g_english", text: $language)
                urlField(String(localized: "modules.website"), text: $baseUrl)
                urlField(String(localized: "modules.search_url"), text: $searchBaseUrl)
            }

            Section("modules.streams") {
                TextField("modules.stream_type_e_g_hls", text: $streamType)
                TextField("modules.quality_e_g_1080p", text: $quality)
                Toggle("modules.soft_subtitles", isOn: $softsub)
                    .switchTint()
                Toggle("modules.async_script", isOn: $asyncJS)
                    .switchTint()
            }
        }
        #if os(macOS)
        .formStyle(.grouped)
        #endif
        .navigationTitle("modules.import_module")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .interactiveDismissDisabled(hasInput)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("common.cancel") { if hasInput { confirmDiscard = true } else { dismiss() } }
            }
            ToolbarItem(placement: .confirmationAction) {
                if isAdding { ProgressView() } else { Button("modules.add", action: add).disabled(!canAdd) }
            }
        }
        .fileImporter(isPresented: Binding(get: { picking != nil }, set: { if !$0 { picking = nil } }),
                      allowedContentTypes: picking?.types ?? [.data]) { result in
            let kind = picking
            picking = nil
            switch result {
            case .success(let url): read(url, as: kind)
            case .failure(let error): problem = error.localizedDescription
            }
        }
        .confirmationDialog("modules.discard_this_module", isPresented: $confirmDiscard, titleVisibility: .visible) {
            Button("modules.discard", role: .destructive) { dismiss() }
            Button("modules.keep_editing", role: .cancel) {}
        }
        .alert("modules.couldnt_do_that", isPresented: Binding(get: { problem != nil }, set: { if !$0 { problem = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(problem ?? "")
        }
    }

    // MARK: Parts

    private func fileRow(title: String, systemImage: String, file: String?, detail: String?,
                         action: String, pick: @escaping () -> Void) -> some View {
        Button(action: pick) {
            HStack(spacing: 12) {
                Image(systemName: file == nil ? systemImage : "checkmark.circle.fill")
                    .font(.title3)
                    .foregroundStyle(file == nil ? Color.secondary : Color.green)
                    .frame(width: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text(file ?? action)
                        .foregroundStyle(Color.primary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if let detail { Text(detail).font(.caption).foregroundStyle(.secondary) }
                }
                Spacer()
                if file != nil {
                    Text("modules.replace").font(.subheadline).foregroundStyle(Color.accentColor)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var iconPreview: some View {
        Group {
            if let iconData {
                CachedAsyncImage(urlString: "", base64String: iconData.base64EncodedString())
            } else if !iconURL.isEmpty {
                CachedAsyncImage(urlString: iconURL)
            } else {
                Image(systemName: "puzzlepiece.extension.fill")
                    .font(.title2)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: 56, height: 56)
        .background(Color.secondary.opacity(0.12))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private func urlField(_ title: String, text: Binding<String>) -> some View {
        TextField(title, text: text)
            .autocorrectionDisabled()
            #if os(iOS)
            .textInputAutocapitalization(.never)
            .keyboardType(.URL)
            #endif
    }

    // MARK: Reading files

    private func read(_ url: URL, as kind: Picking?) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url) else {
            problem = "\(url.lastPathComponent) couldn't be read."
            return
        }
        switch kind {
        case .script:
            guard let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else {
                problem = "\(url.lastPathComponent) isn't a text file."
                return
            }
            script = text
            scriptName = url.lastPathComponent
            if name.isEmpty { name = (url.lastPathComponent as NSString).deletingPathExtension }
            if ModuleFileImport.looksLikeManga(text) { self.kind = "manga" }
            asyncJS = text.contains("async ")
        case .manifest:
            do {
                fill(from: try JSONDecoder().decode(ModuleDefinition.self, from: data))
                manifestName = url.lastPathComponent
            } catch {
                problem = ModuleFileImport.Failure.notAModule(url.lastPathComponent, ModuleFileImport.reason(error))
                    .localizedDescription
            }
        case .icon:
            guard let jpeg = ProfileManager.normalizedPhoto(data, maxSide: 256) else {
                problem = "\(url.lastPathComponent) isn't a picture."
                return
            }
            iconData = jpeg
        case nil:
            break
        }
    }

    private func fill(from module: ModuleDefinition) {
        name = module.sourceName
        version = module.version
        authorName = module.author?.name ?? ""
        authorIcon = module.author?.icon ?? ""
        iconURL = module.iconUrl ?? ""
        if let data = module.iconData.flatMap({ Data(base64Encoded: $0) }) { iconData = data }
        kind = module.isManga ? "manga" : "anime"
        language = module.language ?? ""
        baseUrl = module.baseUrl ?? ""
        searchBaseUrl = module.searchBaseUrl ?? ""
        streamType = module.streamType ?? ""
        quality = module.quality ?? ""
        softsub = module.softsub ?? false
        asyncJS = module.asyncJS ?? asyncJS
        // Keeps the manifest's script address, the module's identity: importing a fixed copy of
        // an installed module replaces it rather than adding a second.
        scriptUrl = module.scriptUrl.hasPrefix("http") ? module.scriptUrl : nil
    }

    // MARK: Adding

    private func add() {
        guard let script else { return }
        func text(_ value: String) -> String? {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        var object: [String: Any] = [
            "sourceName": name.trimmingCharacters(in: .whitespacesAndNewlines),
            "version": text(version) ?? "1.0.0",
            "type": kind,
            "scriptUrl": scriptUrl ?? ModuleFileImport.fileScriptURL(named: scriptName ?? "module.js"),
            "asyncJS": asyncJS,
            "softsub": softsub,
        ]
        if let author = text(authorName) {
            var entry: [String: Any] = ["name": author]
            if let icon = text(authorIcon) { entry["icon"] = icon }
            object["author"] = entry
        }
        for (key, value) in [("iconUrl", iconURL), ("language", language), ("baseUrl", baseUrl),
                             ("searchBaseUrl", searchBaseUrl), ("streamType", streamType), ("quality", quality)] {
            if let value = text(value) { object[key] = value }
        }
        do {
            var module = try JSONDecoder().decode(ModuleDefinition.self, from: JSONSerialization.data(withJSONObject: object))
            module.scriptContent = script
            module.iconData = iconData?.base64EncodedString()
            module.fromFile = true
            isAdding = true
            Task {
                await moduleManager.addModule(module)
                isAdding = false
                if let error = moduleManager.errorMessage {
                    problem = error
                    moduleManager.errorMessage = nil
                } else {
                    dismiss()
                }
            }
        } catch {
            problem = error.localizedDescription
        }
    }
}


/// The import form's script, typed or pasted.
private struct ScriptDraftView: View {
    @Binding var script: String
    @State private var text = ""
    @State private var loaded = false
    @State private var confirmPaste = false
    @State private var syntaxError: String?
    @State private var check: Task<Void, Never>?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            CodeTextEditor(text: $text)
            if let syntaxError {
                Label(syntaxError, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(.regularMaterial)
            }
        }
        .navigationTitle("modules.script")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            ToolbarItem(placement: .automatic) {
                Button {
                    if text.isEmpty { paste() } else { confirmPaste = true }
                } label: {
                    Label("modules.paste", systemImage: "doc.on.clipboard")
                }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("common.done") {
                    script = text
                    dismiss()
                }
            }
        }
        .onAppear {
            guard !loaded else { return }
            loaded = true
            text = script
        }
        .onChangeOf(text) { newValue in
            // Checked once typing pauses, not on every key of a long script.
            check?.cancel()
            check = Task {
                try? await Task.sleep(nanoseconds: 600_000_000)
                guard !Task.isCancelled else { return }
                syntaxError = newValue.isEmpty ? nil : ModuleFileImport.syntaxError(in: newValue)
            }
        }
        .confirmationDialog("modules.replace_the_whole_script", isPresented: $confirmPaste, titleVisibility: .visible) {
            Button("modules.delete_all_and_paste", role: .destructive, action: paste)
            Button("common.cancel", role: .cancel) {}
        } message: {
            Text("modules.everything_in_the_editor_is")
        }
    }

    private func paste() {
        if let pasted = Clipboard.string, !pasted.isEmpty { text = pasted }
    }
}

#endif
