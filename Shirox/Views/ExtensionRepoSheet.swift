import SwiftUI

/// A Nuvio, Vega or SkyStream repo's providers, to install one by one or all at once. Adult ones
/// were dropped when the repo was read, so they never show here.
struct ExtensionRepoSheet: View {
    let repo: ExtensionRepo
    @EnvironmentObject private var moduleManager: ModuleManager
    @Environment(\.dismiss) private var dismiss
    @State private var installing: Set<String> = []
    @State private var failures: [String: String] = [:]

    private func isInstalled(_ entry: ExtensionRepoEntry) -> Bool {
        moduleManager.modules.contains { $0.ext?.key == entry.key && $0.ext?.repoUrl == repo.url.absoluteString }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    if repo.entries.isEmpty {
                        Text("This repo has no providers Shirox can add.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(repo.entries) { entry in
                        row(entry)
                    }
                } header: {
                    Text("\(repo.kind.badge) · \(repo.entries.count) providers")
                } footer: {
                    Text("Adult providers and torrent links are never offered.")
                }
            }
            .navigationTitle(repo.name)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Install All") {
                        Task { await install(repo.entries.filter { !isInstalled($0) }) }
                    }
                    .disabled(repo.entries.allSatisfy(isInstalled) || !installing.isEmpty)
                }
            }
        }
    }

    private func row(_ entry: ExtensionRepoEntry) -> some View {
        HStack(spacing: 12) {
            AsyncImage(url: entry.iconUrl.flatMap(URL.init(string:))) { image in
                image.resizable().scaledToFit()
            } placeholder: {
                Image(systemName: "puzzlepiece.extension").foregroundStyle(.secondary)
            }
            .frame(width: 32, height: 32)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.name)
                Text([entry.language?.uppercased(), "v\(entry.version)"].compactMap { $0 }.joined(separator: " · "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let failure = failures[entry.key] {
                    Text(failure)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
            Spacer()
            if installing.contains(entry.key) {
                ProgressView()
            } else if isInstalled(entry) {
                Image(systemName: "checkmark")
                    .foregroundStyle(.secondary)
            } else {
                Button("Install") {
                    Task { await install([entry]) }
                }
            }
        }
    }

    private func install(_ entries: [ExtensionRepoEntry]) async {
        installing.formUnion(entries.map(\.key))
        let result = await moduleManager.install(entries: entries, from: repo)
        failures.merge(result) { $1 }
        for key in entries.map(\.key) where result[key] == nil { failures[key] = nil }
        installing.subtract(entries.map(\.key))
    }
}
