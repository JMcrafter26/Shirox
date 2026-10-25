import Combine

#if !os(tvOS)
import SwiftUI

struct DownloadStreamPickerView: View {
    let streams: [StreamResult]
    let onSelect: (StreamResult) -> Void
    @Environment(\.dismiss) var dismiss

    var body: some View {
        NavigationStack {
            List {
                ForEach(streams) { stream in
                    DownloadStreamRow(stream: stream) {
                        onSelect(stream)
                        dismiss()
                    }
                }
            }
            .softScrollEdges()
            #if os(iOS)
            .listStyle(.insetGrouped)
            #else
            .listStyle(.inset)
            #endif
            .navigationTitle("downloads.select_stream_quality")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("common.cancel") { dismiss() }
                }
            }
            .appTint()
        }
        #if os(iOS)
        .adaptivePresentationDetents([.medium, .large])

        #else

        .macSheetFrame()

        #endif
    }
}

// MARK: - Stream Row

private struct DownloadStreamRow: View {
    let stream: StreamResult
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 12) {
                IconView("play.circle.fill")
                    .font(.system(size: 32))
                    .foregroundStyle(.primary)

                StreamRowText(stream: stream)
                Spacer()
            }
            .contentShape(Rectangle())
            .padding(.vertical, 6)
        }
        .buttonStyle(.plain)
    }
}
#endif
