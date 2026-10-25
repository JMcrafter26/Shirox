import Combine
import SwiftUI

/// Shared rename/delete coordination for on-device collections. Drives the rename
/// text-field alert and the (non-empty-only) delete confirmation, so the Manage
/// Collections screen and the library entry edit sheet behave identically.
@MainActor
final class CollectionEditor: ObservableObject {
    @Published var renaming: LocalCollection?
    @Published var deleting: LocalCollection?
    @Published var draftName: String = ""

    private let library = LocalLibraryManager.shared

    /// Seeds the draft with the current name and presents the rename alert.
    func beginRename(_ collection: LocalCollection) {
        draftName = collection.name
        renaming = collection
    }

    /// Deletes an empty collection immediately; routes a non-empty one to confirmation.
    func requestDelete(_ collection: LocalCollection) {
        if collection.mediaUniqueIds.isEmpty {
            library.deleteCollection(id: collection.id)
        } else {
            deleting = collection
        }
    }

    /// Commits the in-flight rename (the manager no-ops on empty/whitespace or a collision).
    func commitRename() {
        guard let collection = renaming else { return }
        library.renameCollection(id: collection.id, to: draftName)
    }

    /// Commits the confirmed deletion of a non-empty collection.
    func commitDelete() {
        guard let collection = deleting else { return }
        library.deleteCollection(id: collection.id)
    }
}

extension View {
    /// Attaches the shared collection rename + delete alerts, driven by `editor`.
    func collectionEditorAlerts(_ editor: CollectionEditor) -> some View {
        modifier(CollectionEditorAlerts(editor: editor))
    }
}

private struct CollectionEditorAlerts: ViewModifier {
    @ObservedObject var editor: CollectionEditor

    func body(content: Content) -> some View {
        content
            .alert("library.rename_collection", isPresented: Binding(
                get: { editor.renaming != nil },
                set: { if !$0 { editor.renaming = nil } }
            ), presenting: editor.renaming) { _ in
                TextField("common.name", text: $editor.draftName)
                Button("common.save") { editor.commitRename() }
                Button("common.cancel", role: .cancel) {}
            } message: { _ in
                Text("library.choose_a_new_name_for")
            }
            .alert("library.delete_collection", isPresented: Binding(
                get: { editor.deleting != nil },
                set: { if !$0 { editor.deleting = nil } }
            ), presenting: editor.deleting) { _ in
                Button("common.delete", role: .destructive) { editor.commitDelete() }
                Button("common.cancel", role: .cancel) {}
            } message: { collection in
                let n = collection.mediaUniqueIds.count
                Text("library.this_wont_remove_the_titles \(n)")
            }
    }
}

/// Lists every on-device collection with rename (tap / context menu) and delete
/// (swipe / context menu). On-device only — collections don't exist for AniList/MAL.
struct ManageCollectionsView: View {
    @ObservedObject private var library = LocalLibraryManager.shared
    @StateObject private var editor = CollectionEditor()
    @State private var showNewCollection = false
    @State private var newCollectionName = ""
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if library.collections.isEmpty {
                    ContentUnavailableView(
                        "library.no_collections",
                        systemImage: "folder",
                        description: Text("library.tap_to_create_a_collection")
                    )
                } else {
                    List {
                        ForEach(library.collections) { collection in
                            row(for: collection)
                        }
                    }
                    .softScrollEdges()
                }
            }
            .navigationTitle("library.collections")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("common.done") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        newCollectionName = ""
                        showNewCollection = true
                    } label: {
                        Label("library.new_collection", icon: "plus")
                    }
                }
            }
            .collectionEditorAlerts(editor)
            .alert("library.new_collection", isPresented: $showNewCollection) {
                TextField("common.name", text: $newCollectionName)
                Button("library.create") {
                    let trimmed = newCollectionName.trimmingCharacters(in: .whitespacesAndNewlines)
                    newCollectionName = ""
                    guard !trimmed.isEmpty else { return }
                    library.createCollection(name: trimmed)
                }
                Button("common.cancel", role: .cancel) { newCollectionName = "" }
            } message: {
                Text("library.name_your_new_collection")
            }
        }
    }

    @ViewBuilder
    private func row(for collection: LocalCollection) -> some View {
        let count = collection.mediaUniqueIds.count
        Button {
            editor.beginRename(collection)
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(collection.name).foregroundStyle(.primary)
                Text("common.titles \(count)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        #if !os(tvOS)
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button(role: .destructive) {
                editor.requestDelete(collection)
            } label: {
                Label("common.delete", icon: "trash")
            }
            .tint(.red)
        }
        .swipeActions(edge: .leading) {
            Button {
                editor.beginRename(collection)
            } label: {
                Label("library.rename", icon: "pencil")
            }
            .tint(.blue)
        }
        #endif
        .contextMenu {
            Button {
                editor.beginRename(collection)
            } label: {
                Label("library.rename", icon: "pencil")
            }
            Button(role: .destructive) {
                editor.requestDelete(collection)
            } label: {
                Label("common.delete", icon: "trash")
            }
        }
    }
}
