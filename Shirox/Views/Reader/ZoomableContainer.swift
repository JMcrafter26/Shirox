#if os(iOS)
import SwiftUI
import UIKit

// MARK: - Quick taps

/// Tells a single tap from a double tap sooner than UIKit does. A single tap made to wait for
/// a double-tap recognizer to fail sits for about a third of a second, which in the reader and
/// the player read as lag on every tap. This waits `window` for a second tap instead: one
/// within it, near the first, is a double tap and the single never fires; otherwise the single
/// fires once the window is out.
final class QuickTaps {
    /// Short enough to feel immediate, long enough for a quick double tap.
    static let window: TimeInterval = 0.2
    /// How far apart two taps can land and still make a double tap, in points.
    private static let reach: CGFloat = 70

    var onSingle: (CGPoint) -> Void = { _ in }
    var onDouble: (CGPoint) -> Void = { _ in }
    private var pending: (point: CGPoint, work: DispatchWorkItem)?

    func tap(at point: CGPoint) {
        if let pending {
            pending.work.cancel()
            self.pending = nil
            if hypot(pending.point.x - point.x, pending.point.y - point.y) <= Self.reach {
                onDouble(point)
                return
            }
            // Far from the first: two separate taps, and the first is due now.
            onSingle(pending.point)
        }
        let work = DispatchWorkItem { [weak self] in
            self?.pending = nil
            self?.onSingle(point)
        }
        pending = (point, work)
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.window, execute: work)
    }

    /// Drops a single tap still waiting, as when the view goes away.
    func cancel() {
        pending?.work.cancel()
        pending = nil
    }
}

// MARK: - Zoomable page

/// UIScrollView-backed pinch-zoom container for one paged-mode page.
/// Double-tap toggles 1× ↔ 2.5×; pinch zooms 1–3×. Owns the single tap too, told from the
/// double by ``QuickTaps``, surfacing it via onSingleTap so the reader can toggle its chrome,
/// or turn the page from a side. At 1×, horizontal swipes pass through to the surrounding
/// TabView for page turns.
struct ZoomableContainer<Content: View>: UIViewRepresentable {
    let content: Content
    /// Where across the page the tap landed, 0 at the left edge to 1 at the right.
    let onSingleTap: (CGFloat) -> Void
    /// Fires with the live zoom scale whenever it changes. The poster viewer uses
    /// this to suspend its drag-to-dismiss while zoomed in, so the two pans don't
    /// fight. Defaults to a no-op, leaving the reader's behaviour unchanged.
    let onZoomChange: (CGFloat) -> Void

    init(onSingleTap: @escaping () -> Void,
         onZoomChange: @escaping (CGFloat) -> Void = { _ in },
         @ViewBuilder content: () -> Content) {
        self.init(onSingleTapAt: { _ in onSingleTap() }, onZoomChange: onZoomChange, content: content)
    }

    init(onSingleTapAt: @escaping (CGFloat) -> Void,
         onZoomChange: @escaping (CGFloat) -> Void = { _ in },
         @ViewBuilder content: () -> Content) {
        self.onSingleTap = onSingleTapAt
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
        context.coordinator.scroll = scroll

        let tap = UITapGestureRecognizer(target: context.coordinator,
                                         action: #selector(Coordinator.handleTap(_:)))
        scroll.addGestureRecognizer(tap)

        return scroll
    }

    func updateUIView(_ uiView: UIScrollView, context: Context) {
        context.coordinator.onSingleTap = onSingleTap
        context.coordinator.onZoomChange = onZoomChange
        context.coordinator.host?.rootView = content
    }

    static func dismantleUIView(_ uiView: UIScrollView, coordinator: Coordinator) {
        coordinator.taps.cancel()
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(onSingleTap: onSingleTap, onZoomChange: onZoomChange)
    }

    final class Coordinator: NSObject, UIScrollViewDelegate {
        var host: UIHostingController<Content>?
        weak var scroll: UIScrollView?
        var onSingleTap: (CGFloat) -> Void
        var onZoomChange: (CGFloat) -> Void
        /// Points in the scroll view's frame, so a side is a side at any zoom.
        let taps = QuickTaps()

        init(onSingleTap: @escaping (CGFloat) -> Void, onZoomChange: @escaping (CGFloat) -> Void) {
            self.onSingleTap = onSingleTap
            self.onZoomChange = onZoomChange
            super.init()
            taps.onSingle = { [weak self] point in
                guard let self, let scroll = self.scroll, scroll.bounds.width > 0 else { return }
                self.onSingleTap(min(max(point.x / scroll.bounds.width, 0), 1))
            }
            taps.onDouble = { [weak self] point in self?.toggleZoom(at: point) }
        }

        func viewForZooming(in scrollView: UIScrollView) -> UIView? { host?.view }

        func scrollViewDidZoom(_ scrollView: UIScrollView) {
            onZoomChange(scrollView.zoomScale)
        }

        @objc func handleTap(_ gesture: UITapGestureRecognizer) {
            guard let scroll = gesture.view as? UIScrollView else { return }
            let point = gesture.location(in: scroll)
            taps.tap(at: CGPoint(x: point.x - scroll.contentOffset.x, y: point.y - scroll.contentOffset.y))
        }

        /// `point` is in the scroll view's frame.
        private func toggleZoom(at point: CGPoint) {
            guard let scroll, let content = host?.view else { return }
            if scroll.zoomScale > 1 {
                scroll.setZoomScale(1, animated: true)
            } else {
                let inContent = content.convert(
                    CGPoint(x: point.x + scroll.contentOffset.x, y: point.y + scroll.contentOffset.y), from: scroll)
                let size = CGSize(width: scroll.bounds.width / 2.5,
                                  height: scroll.bounds.height / 2.5)
                let rect = CGRect(x: inContent.x - size.width / 2,
                                  y: inContent.y - size.height / 2,
                                  width: size.width, height: size.height)
                scroll.zoom(to: rect, animated: true)
            }
        }
    }
}
#endif
