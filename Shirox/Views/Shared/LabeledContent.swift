import SwiftUI

// iOS 15 backport — shadows SwiftUI.LabeledContent (iOS 16+)
struct LabeledContent<Content: View>: View {
    private let title: Text
    private let content: Content

    /// A key from the string catalog.
    init(_ titleKey: LocalizedStringKey, @ViewBuilder content: () -> Content) {
        self.title = Text(titleKey)
        self.content = content()
    }

    /// Text that's already localized, or a name, shown as it is.
    @_disfavoredOverload
    init<S: StringProtocol>(_ title: S, @ViewBuilder content: () -> Content) {
        self.title = Text(title)
        self.content = content()
    }

    var body: some View {
        HStack {
            title
            Spacer()
            content
        }
    }
}
