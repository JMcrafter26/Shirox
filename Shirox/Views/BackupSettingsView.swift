#if !os(tvOS)
import SwiftUI
import UniformTypeIdentifiers

/// Export and restore of a `.shiroxbackup` file.
///
/// tvOS has no document picker, so this whole screen is iOS/Catalyst only, matching the
/// existing gating on the Settings "Data" section.
struct BackupSettingsView: View {
    @State private var includeAccounts = false
    @State private var exportedURL: URL?
    @State private var exportError: String?

    @State private var showImporter = false
    @State private var pendingData: Data?
    @State private var pendingSummary: BackupSummary?
    @State private var importError: String?
    @State private var report: BackupImportReport?
    @State private var isRestoring = false

    /// The app declares `com.shirox.backup` in Info.plist; the fallbacks keep the picker
    /// usable if the declaration hasn't been registered yet (a fresh install from Xcode).
    private static var backupContentTypes: [UTType] {
        if let declared = UTType("com.shirox.backup") { return [declared, .json] }
        if let byExtension = UTType(filenameExtension: "shiroxbackup") { return [byExtension, .json] }
        return [.json]
    }

    var body: some View {
        SettingsList {
            exportSection
            importSection
            if let report { reportSection(report) }
        }
        .navigationTitle("settings.backup")
        // One importer only: two `.fileImporter` modifiers in a single view conflict —
        // see the note in SearchView.swift.
        .fileImporter(isPresented: $showImporter,
                      allowedContentTypes: Self.backupContentTypes) { result in
            handlePickedFile(result)
        }
        .confirmationDialog("settings.restore_this_backup",
                            isPresented: Binding(get: { pendingSummary != nil },
                                                 set: { if !$0 { clearPendingImport() } }),
                            titleVisibility: .visible) {
            Button("settings.replace_data_on_this_device", role: .destructive) { runRestore() }
            Button("common.cancel", role: .cancel) { clearPendingImport() }
        } message: {
            if let pendingSummary { Text(Self.confirmationMessage(pendingSummary)) }
        }
        .alert("settings.couldnt_read_backup",
               isPresented: Binding(get: { importError != nil },
                                    set: { if !$0 { importError = nil } })) {
            Button("common.ok") { importError = nil }
        } message: {
            Text(importError ?? "")
        }
        .alert("settings.couldnt_create_backup",
               isPresented: Binding(get: { exportError != nil },
                                    set: { if !$0 { exportError = nil } })) {
            Button("common.ok") { exportError = nil }
        } message: {
            Text(exportError ?? "")
        }
    }

    // MARK: - Export

    @ViewBuilder
    private var exportSection: some View {
        Section("settings.create_backup") {
            Toggle("settings.include_accounts", isOn: $includeAccounts)
                .switchTint()
            Text(includeAccounts
                 ? String(localized: "settings.this_backup_will_contain_live")
                 : String(localized: "settings.progress_library_settings_and_modules"))
                .font(.caption)
                .foregroundStyle(includeAccounts ? .orange : .secondary)

            #if os(macOS)
            // A Mac saves the file where it's told; the share menu there has no "Save".
            Button("settings.save_backup") { saveBackup() }
            #else
            Button("settings.create_backup") { createBackup() }
            #endif

            if let exportedURL {
                #if os(iOS)
                AnchoredShareButton(items: [exportedURL]) {
                    Label("settings.share \(exportedURL.lastPathComponent)", icon: "square.and.arrow.up")
                }
                #else
                if #available(macOS 13.0, *) {
                    ShareLink(item: exportedURL) {
                        Label("settings.share \(exportedURL.lastPathComponent)", icon: "square.and.arrow.up")
                    }
                }
                #endif
            }
        }
    }

    #if os(macOS)
    private func saveBackup() {
        createBackup()
        guard let exportedURL else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = exportedURL.lastPathComponent
        panel.allowedContentTypes = Self.backupContentTypes
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        do {
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.copyItem(at: exportedURL, to: destination)
            ToastManager.shared.show(message: String(localized: "settings.backup_saved"), type: .success)
        } catch {
            exportError = error.localizedDescription
        }
    }
    #endif

    private func createBackup() {
        do {
            exportedURL = try BackupManager.shared.exportFile(includeAccounts: includeAccounts)
        } catch {
            exportError = error.localizedDescription
        }
    }

    // MARK: - Import

    @ViewBuilder
    private var importSection: some View {
        Section("settings.restore") {
            Button("settings.restore_from_backup") { showImporter = true }
                .disabled(isRestoring)
            Text("settings.replaces_the_progress_library_settings")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func handlePickedFile(_ result: Result<URL, Error>) {
        switch result {
        case .failure(let error):
            importError = error.localizedDescription
        case .success(let url):
            // A picked file lives outside the sandbox until the scope is opened.
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            do {
                let data = try Data(contentsOf: url)
                let (_, summary) = try BackupManager.shared.summarize(data)
                pendingData = data
                pendingSummary = summary
            } catch {
                importError = error.localizedDescription
            }
        }
    }

    private func clearPendingImport() {
        pendingData = nil
        pendingSummary = nil
    }

    private static func confirmationMessage(_ summary: BackupSummary) -> String {
        var parts: [String] = []
        parts.append(summary.lines.isEmpty
                     ? String(localized: "settings.this_backup_records_no_data")
                     : summary.lines.joined(separator: " · "))
        parts.append(String(localized: "settings.made_with_shirox \(summary.createdAt.formatted(date: .abbreviated, time: .shortened)) \(summary.appVersion)"))
        parts.append(String(localized: "settings.this_replaces_the_data_on"))
        if summary.includesAccounts {
            parts.append(String(localized: "settings.it_also_signs_this_device"))
        }
        return parts.joined(separator: "\n\n")
    }

    private func runRestore() {
        guard let data = pendingData else { return }
        clearPendingImport()
        isRestoring = true
        Task {
            do {
                report = try await BackupManager.shared.importBackup(from: data)
            } catch {
                importError = error.localizedDescription
            }
            isRestoring = false
        }
    }

    // MARK: - Result

    @ViewBuilder
    private func reportSection(_ report: BackupImportReport) -> some View {
        Section("settings.last_restore") {
            if !report.applied.isEmpty {
                LabeledContent("settings.restored") {
                    Text(report.applied.map(Self.label).joined(separator: ", "))
                }
            }
            ForEach(report.warnings, id: \.detail) { note in
                Text(note.detail)
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            ForEach(report.skipped, id: \.detail) { note in
                Text("settings.skipped \(Self.label(note.section)) \(note.detail)")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
            if report.skipped.isEmpty && report.warnings.isEmpty {
                Text("settings.everything_in_the_backup_was")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private static func label(_ sectionID: String) -> String {
        switch sectionID {
        case BackupSectionID.progress: return String(localized: "common.progress")
        case BackupSectionID.localLibrary: return String(localized: "settings.local_library")
        case BackupSectionID.settings: return String(localized: "settings.settings")
        case BackupSectionID.modules: return String(localized: "common.modules")
        case BackupSectionID.accounts: return String(localized: "settings.accounts")
        case BackupSectionID.links: return String(localized: "settings.links")
        default: return sectionID
        }
    }
}
#endif
