import SwiftUI
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

/// The font families installed on this device, for subtitles.
enum SubtitleFonts {
    static let families: [String] = {
        #if canImport(UIKit)
        let names = UIFont.familyNames
        #else
        let names = NSFontManager.shared.availableFontFamilies
        #endif
        // Families whose names start with a dot are the system's private ones.
        return names.filter { !$0.hasPrefix(".") }.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }()
}

/// The Font row of the subtitle settings: the family in use, opening the list to pick from.
struct SubtitleFontRow: View {
    @ObservedObject var settings: SubtitleSettingsManager

    var body: some View {
        NavigationLink {
            SubtitleFontPicker(settings: settings)
        } label: {
            LabeledContent("settings.subtitle_font") {
                Text(settings.fontFamily.isEmpty ? String(localized: "settings.subtitle_font_system") : settings.fontFamily)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }
}

/// Every font family on the device, each drawn in itself, with the system font first.
struct SubtitleFontPicker: View {
    @ObservedObject var settings: SubtitleSettingsManager
    @State private var search = ""

    private var shown: [String] {
        let query = search.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return SubtitleFonts.families }
        return SubtitleFonts.families.filter { $0.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        List {
            if search.isEmpty {
                Section {
                    row(title: String(localized: "settings.subtitle_font_system"), family: "")
                }
            }
            Section {
                ForEach(shown, id: \.self) { family in
                    row(title: family, family: family)
                }
            } footer: {
                Text("settings.subtitle_font_note")
            }
        }
        .searchable(text: $search, prompt: String(localized: "settings.search_fonts"))
        .navigationTitle("settings.subtitle_font")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }

    private func row(title: String, family: String) -> some View {
        let isSelected = settings.fontFamily == family
        return Button {
            settings.fontFamily = family
        } label: {
            HStack {
                Text(title)
                    .font(family.isEmpty ? .body : .custom(family, size: 17, relativeTo: .body))
                    .foregroundStyle(.primary)
                Spacer()
                if isSelected {
                    Image(icon: "checkmark")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.tint)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
