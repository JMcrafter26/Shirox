#if os(iOS)
import SwiftUI
import UIKit

// MARK: - Quick taps

/// Tells a single tap from a double tap sooner than UIKit does. A single tap made to wait for
/// a double-tap recognizer to fail sits for about a third of a second, which in the reader and
/// the player read as lag on every tap. This waits `window` for a second finger to land
/// instead: one within it, near the first, makes a double tap once it lifts, and the single
/// never fires; otherwise the single fires once the window is out.
///
/// The window runs to the second tap's touch-down, not its lift. Counting to the lift took the
/// second press out of an already short window, and ordinary double taps came out as two
/// singles.
final class QuickTaps {
    /// Short enough to feel immediate, long enough for a quick double tap.
    static let window: TimeInterval = 0.1
    /// How long a second press may last before it stops counting as a tap.
    private static let pressLimit: TimeInterval = 0.4
    /// How far apart two taps can land and still make a double tap, in points.
    private static let reach: CGFloat = 70

    var onSingle: (CGPoint) -> Void = { _ in }
    var onDouble: (CGPoint) -> Void = { _ in }
    /// A first tap, waiting for the window to run out or a second finger to land.
    private var pending: (point: CGPoint, work: DispatchWorkItem)?
    /// A second finger is down near the first tap; its lift makes the double.
    private var secondDown: (point: CGPoint, work: DispatchWorkItem)?

    /// A finger landing, from ``QuickTapRecognizer``.
    func touchDown(at point: CGPoint) {
        guard let pending, secondDown == nil,
              hypot(pending.point.x - point.x, pending.point.y - point.y) <= Self.reach else { return }
        pending.work.cancel()
        self.pending = nil
        // Held, or dragged into a scroll, it isn't a tap; the first one is a single after all.
        let first = pending.point
        let work = DispatchWorkItem { [weak self] in
            self?.secondDown = nil
            self?.onSingle(first)
        }
        secondDown = (first, work)
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.pressLimit, execute: work)
    }

    /// A finger lifting from a tap.
    func tap(at point: CGPoint) {
        if let secondDown {
            secondDown.work.cancel()
            self.secondDown = nil
            onDouble(point)
            return
        }
        if let pending {
            // Far from the first: two separate taps, and the first is due now.
            pending.work.cancel()
            self.pending = nil
            onSingle(pending.point)
        }
        let work = DispatchWorkItem { [weak self] in
            self?.pending = nil
            self?.onSingle(point)
        }
        pending = (point, work)
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.window, execute: work)
    }

    /// Drops a tap still waiting, as when the view goes away.
    func cancel() {
        pending?.work.cancel()
        pending = nil
        secondDown?.work.cancel()
        secondDown = nil
    }
}

/// A single-tap recognizer that also reports each finger as it lands, for ``QuickTaps``.
class QuickTapRecognizer: UITapGestureRecognizer {
    var onTouchDown: ((UITouch) -> Void)?

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesBegan(touches, with: event)
        if state != .failed, let touch = touches.first { onTouchDown?(touch) }
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

        let tap = QuickTapRecognizer(target: context.coordinator,
                                     action: #selector(Coordinator.handleTap(_:)))
        tap.onTouchDown = { [weak coordinator = context.coordinator, weak scroll] touch in
            guard let coordinator, let scroll else { return }
            coordinator.taps.touchDown(at: Coordinator.framePoint(touch.location(in: scroll), in: scroll))
        }
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
            taps.tap(at: Self.framePoint(gesture.location(in: scroll), in: scroll))
        }

        /// A point in the scroll view's content, moved into its frame.
        static func framePoint(_ point: CGPoint, in scroll: UIScrollView) -> CGPoint {
            CGPoint(x: point.x - scroll.contentOffset.x, y: point.y - scroll.contentOffset.y)
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
