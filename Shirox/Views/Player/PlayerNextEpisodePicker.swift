import SwiftUI

struct PlayerNextEpisodePicker: View {
    let streams: [StreamResult]
    var title = String(localized: "player.choose_quality")
    let onSelect: (StreamResult) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List(streams) { stream in
                Button {
                    onSelect(stream)
                    dismiss()
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(stream.title)
                            .foregroundStyle(.primary)
                        if let details = stream.details {
                            Text(details)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .softScrollEdges()
            .navigationTitle(title)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("common.cancel") { dismiss() }
                }
            }
        }
    }
}
