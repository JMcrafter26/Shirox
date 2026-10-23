#if os(iOS)
import SwiftUI
import UIKit

/// UIScrollView-backed pinch-zoom container for one paged-mode page.
/// Double-tap toggles 1× ↔ 2.5×; pinch zooms 1–3×. Owns the single-tap
/// recognizer too (it must wait for the double-tap to fail), surfacing it via
/// onSingleTap so the reader can toggle its chrome, or turn the page from a side. At 1×, horizontal swipes
/// pass through to the surrounding TabView for page turns.
struct ZoomableContainer<Content: View>: UIViewRepresentable {
    let content: Content
    /// Where across the page the tap landed, 0 at the left edge to 1 at the right.
    let onSingleTap: (CGFloat) -> Void
    /// Fires with the live zoom scale whenever it changes. The poster viewer uses
    /// this to suspend its drag-to-dismiss while zoomed in, so the two pans don't
    /// fight. Defaults to a no-op, leaving the reader's behaviour unchanged.
    let onZoomChange: (CGFloat) -> Void
    /// Whether a single tap at that point across the page fires as the finger lifts instead of
    /// waiting out a double tap; the reader's side zones do. A double tap there doesn't zoom.
    let tapActsAtOnce: (CGFloat) -> Bool

    init(onSingleTap: @escaping () -> Void,
         onZoomChange: @escaping (CGFloat) -> Void = { _ in },
         @ViewBuilder content: () -> Content) {
        self.init(onSingleTapAt: { _ in onSingleTap() }, onZoomChange: onZoomChange, content: content)
    }

    init(onSingleTapAt: @escaping (CGFloat) -> Void,
         onZoomChange: @escaping (CGFloat) -> Void = { _ in },
         tapActsAtOnce: @escaping (CGFloat) -> Bool = { _ in false },
         @ViewBuilder content: () -> Content) {
        self.onSingleTap = onSingleTapAt
        self.tapActsAtOnce = tapActsAtOnce
        self.onZoomChange = onZoomChange
        self.content = content()
    }

    func makeUIView(context: Context) -> UIScrollView {
        let scroll = UIScrollView()
        scroll.minimumZoomScale = 1
        scroll.maximumZoomScale = 3
        scroll.showsVerticalScrollIndicator = false
        scroll.showsHorizontalScrollIndicator = false
        scroll.bouncesZoom = true
        scroll.backgroundColor = .clear
        scroll.delegate = context.coordinator

        let host = UIHostingController(rootView: content)
        host.view.translatesAutoresizingMaskIntoConstraints = false
        host.view.backgroundColor = .clear
        scroll.addSubview(host.view)
        NSLayoutConstraint.activate([
            host.view.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor),
            host.view.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor),
            host.view.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor),
            host.view.widthAnchor.constraint(equalTo: scroll.frameLayoutGuide.widthAnchor),
            host.view.heightAnchor.constraint(equalTo: scroll.frameLayoutGuide.heightAnchor),
        ])
        context.coordinator.host = host

        let doubleTap = UITapGestureRecognizer(target: context.coordinator,
                                               action: #selector(Coordinator.handleDoubleTap(_:)))
        doubleTap.numberOfTapsRequired = 2
        scroll.addGestureRecognizer(doubleTap)

        let singleTap = UITapGestureRecognizer(target: context.coordinator,
                                               action: #selector(Coordinator.handleSingleTap(_:)))
        singleTap.numberOfTapsRequired = 1
        singleTap.require(toFail: doubleTap)
        scroll.addGestureRecognizer(singleTap)

        let immediateTap = UITapGestureRecognizer(target: context.coordinator,
                                                  action: #selector(Coordinator.handleSingleTap(_:)))
        scroll.addGestureRecognizer(immediateTap)
        for recognizer in [doubleTap, singleTap, immediateTap] { recognizer.delegate = context.coordinator }
        context.coordinator.immediateTap = immediateTap

        return scroll
    }

    func updateUIView(_ uiView: UIScrollView, context: Context) {
        context.coordinator.onSingleTap = onSingleTap
        context.coordinator.onZoomChange = onZoomChange
        context.coordinator.tapActsAtOnce = tapActsAtOnce
        context.coordinator.host?.rootView = content
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(onSingleTap: onSingleTap, onZoomChange: onZoomChange)
    }

    final class Coordinator: NSObject, UIScrollViewDelegate, UIGestureRecognizerDelegate {
        var host: UIHostingController<Content>?
        weak var immediateTap: UIGestureRecognizer?
        var tapActsAtOnce: (CGFloat) -> Bool = { _ in false }
        var onSingleTap: (CGFloat) -> Void
        var onZoomChange: (CGFloat) -> Void

        init(onSingleTap: @escaping (CGFloat) -> Void, onZoomChange: @escaping (CGFloat) -> Void) {
            self.onSingleTap = onSingleTap
            self.onZoomChange = onZoomChange
        }

        func viewForZooming(in scrollView: UIScrollView) -> UIView? { host?.view }

        func scrollViewDidZoom(_ scrollView: UIScrollView) {
            onZoomChange(scrollView.zoomScale)
        }

        @objc func handleSingleTap(_ gesture: UITapGestureRecognizer) {
            guard let scroll = gesture.view as? UIScrollView else { return }
            onSingleTap(Self.fraction(gesture.location(in: scroll).x, in: scroll))
        }

        /// Against the screen, not the zoomed content: a side is a side at any zoom.
        private static func fraction(_ x: CGFloat, in scroll: UIScrollView) -> CGFloat {
            guard scroll.bounds.width > 0 else { return 0.5 }
            return min(max((x - scroll.contentOffset.x) / scroll.bounds.width, 0), 1)
        }

        /// The immediate tap takes touches where taps act at once; the double tap and the
        /// waiting single tap take the rest.
        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
            guard let scroll = gestureRecognizer.view as? UIScrollView else { return true }
            let atOnce = tapActsAtOnce(Self.fraction(touch.location(in: scroll).x, in: scroll))
            return gestureRecognizer === immediateTap ? atOnce : !atOnce
        }

        @objc func handleDoubleTap(_ gesture: UITapGestureRecognizer) {
            guard let scroll = gesture.view as? UIScrollView else { return }
            if scroll.zoomScale > 1 {
                scroll.setZoomScale(1, animated: true)
            } else {
                let point = gesture.location(in: host?.view)
                let size = CGSize(width: scroll.bounds.width / 2.5,
                                  height: scroll.bounds.height / 2.5)
                let rect = CGRect(x: point.x - size.width / 2,
                                  y: point.y - size.height / 2,
                                  width: size.width, height: size.height)
                scroll.zoom(to: rect, animated: true)
            }
        }
    }
}
#endif
