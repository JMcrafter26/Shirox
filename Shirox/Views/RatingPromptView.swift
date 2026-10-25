import SwiftUI

struct RatingPromptView: View {
    let title: String
    let imageUrl: String
    let scoreFormat: ScoreFormat
    var heading = String(localized: "shared.rate_anime")
    let onSave: (Double) -> Void
    let onSkip: () -> Void

    @State private var score: Double = 0
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        sheetBody.macGroupedForms()
    }

    @ViewBuilder private var sheetBody: some View {
        NavigationStack {
            Form {
                Section {
                    HStack {
                        Spacer()
                        VStack(spacing: 8) {
                            CachedAsyncImage(urlString: imageUrl)
                                .frame(width: 80, height: 110)
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                            Text(title)
                                .font(.headline)
                                .multilineTextAlignment(.center)
                            Text("shared.how_would_you_rate_it")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                    .listRowBackground(Color.clear)
                }

                Section("library.score") {
                    ScoreInputView(score: $score, format: scoreFormat)
                }
            }
            .softScrollEdges()
            .navigationTitle(heading)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("shared.skip") {
                        onSkip()
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("common.save") {
                        onSave(score)
                        dismiss()
                    }
                    .disabled(score == 0)
                }
            }
        }
    }
}
