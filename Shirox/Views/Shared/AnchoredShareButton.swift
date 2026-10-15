import SwiftUI

#if os(iOS)
import UIKit

/// A button that opens the share sheet from itself.
///
/// SwiftUI's `ShareLink` in a list row on an iPad (iPadOS 26, with the floating tab bar) put its
/// popover at the top of the screen, cut down to the file's name: the apps to send it to were out
/// of sight and out of reach. Presented here, the popover points at the row that was tapped.
struct AnchoredShareButton<Label: View>: View {
    let items: [Any]
    @ViewBuilder let label: () -> Label
    @State private var anchor = ShareAnchor()

    var body: some View {
        Button { anchor.present(items) } label: { label() }
            .background(ShareAnchorView(anchor: anchor).allowsHitTesting(false))
    }
}

/// The view the popover points at, and the presenting.
@MainActor
final class ShareAnchor {
    weak var view: UIView?

    func present(_ items: [Any]) {
        guard let view, let root = view.window?.rootViewController else { return }
        var top = root
        while let presented = top.presentedViewController, !presented.isBeingDismissed { top = presented }
        let sheet = UIActivityViewController(activityItems: items, applicationActivities: nil)
        if let popover = sheet.popoverPresentationController {
            popover.sourceView = view
            popover.sourceRect = view.bounds
            popover.permittedArrowDirections = [.up, .down]
        }
        top.present(sheet, animated: true)
    }
}

private struct ShareAnchorView: UIViewRepresentable {
    let anchor: ShareAnchor

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.isUserInteractionEnabled = false
        anchor.view = view
        return view
    }

    func updateUIView(_ view: UIView, context: Context) {
        anchor.view = view
    }
}
#endif
