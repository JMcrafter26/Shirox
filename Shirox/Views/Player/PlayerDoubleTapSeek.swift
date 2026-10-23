import SwiftUI

struct PlayerDoubleTapSeek: View {
    var onSingleTap: () -> Void
    var onSeekBackward: () -> Void
    var onSeekForward: () -> Void
    var onHover: (() -> Void)? = nil
    let seekAmount: Double
    /// Screen lock is on. Double-tap seeking used to ignore it entirely, so a locked player
    /// still jumped when a pocket or a passing hand caught the screen twice — the one thing
    /// locking is for. The single tap stays live: it's what reveals the unlock button.
    var isLocked: Bool = false

    @State private var showLeftFeedback = false
    @State private var showRightFeedback = false
    @State private var leftTask: Task<Void, Never>?
    @State private var rightTask: Task<Void, Never>?

    var body: some View {
        ZStack {
            #if os(iOS)
            // Full-screen UIKit gesture view. Using a single UIView that covers both halves
            // ensures event.allTouches includes fingers from either side of the screen,
            // allowing SingleTouchTapGR to correctly fail on any multi-finger touch.
            FullScreenSeekView(
                onSingleTap: onSingleTap,
                onSeekLeft:  { guard !isLocked else { return }; showFeedback(left: true);  onSeekBackward() },
                onSeekRight: { guard !isLocked else { return }; showFeedback(left: false); onSeekForward()  },
                onHover: onHover
            )
            #else
            HStack(spacing: 0) {
                macHalfView(isLeft: true).frame(maxWidth: .infinity, maxHeight: .infinity)
                macHalfView(isLeft: false).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            #endif

            // Visual feedback (hit-testing disabled — purely decorative)
            HStack(spacing: 0) {
                feedbackCircle(isLeft: true).frame(maxWidth: .infinity, maxHeight: .infinity)
                feedbackCircle(isLeft: false).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .allowsHitTesting(false)
        }
    }

    @ViewBuilder
    private func feedbackCircle(isLeft: Bool) -> some View {
        let showing = isLeft ? showLeftFeedback : showRightFeedback
        ZStack {
            if showing {
                VStack(spacing: 6) {
                    Image(systemName: isLeft ? "chevron.left.2" : "chevron.right.2")
                        .font(.system(size: 26, weight: .bold))
                    Text(isLeft ? "-\(Int(seekAmount))s" : "+\(Int(seekAmount))s")
                        .font(.subheadline.weight(.semibold))
                }
                .foregroundStyle(.white)
                .frame(width: 110, height: 110)
                .background(Color.black.opacity(0.45), in: Circle())
                .transition(.opacity.combined(with: .scale(scale: 0.8)))
            }
        }
    }

    #if !os(iOS)
    @State private var didDoubleTap = false

    @ViewBuilder
    private func macHalfView(isLeft: Bool) -> some View {
        Color.clear
            .contentShape(Rectangle())
            .gesture(
                SimultaneousGesture(
                    TapGesture(count: 2).onEnded {
                        didDoubleTap = true
                        guard !isLocked else { return }
                        if isLeft { onSeekBackward(); showFeedback(left: true) }
                        else      { onSeekForward();  showFeedback(left: false) }
                        Task {
                            try? await Task.sleep(nanoseconds: 350_000_000)
                            didDoubleTap = false
                        }
                    },
                    TapGesture(count: 1).onEnded {
                        guard !didDoubleTap else { return }
                        onSingleTap()
                    }
                )
            )
    }
    #endif

    private func showFeedback(left: Bool) {
        if left {
            leftTask?.cancel()
            withAnimation(.easeOut(duration: 0.15)) { showLeftFeedback = true }
            leftTask = Task {
                try? await Task.sleep(nanoseconds: 600_000_000)
                guard !Task.isCancelled else { return }
                withAnimation(.easeOut(duration: 0.25)) { showLeftFeedback = false }
            }
        } else {
            rightTask?.cancel()
            withAnimation(.easeOut(duration: 0.15)) { showRightFeedback = true }
            rightTask = Task {
                try? await Task.sleep(nanoseconds: 600_000_000)
                guard !Task.isCancelled else { return }
                withAnimation(.easeOut(duration: 0.25)) { showRightFeedback = false }
            }
        }
    }
}

// MARK: - iOS: full-screen UIKit seek view

#if os(iOS)
private struct FullScreenSeekView: UIViewRepresentable {
    var onSingleTap: () -> Void
    var onSeekLeft: () -> Void
    var onSeekRight: () -> Void
    var onHover: (() -> Void)? = nil

    func makeCoordinator() -> Coordinator {
        Coordinator(onSingleTap: onSingleTap, onSeekLeft: onSeekLeft, onSeekRight: onSeekRight, onHover: onHover)
    }

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.backgroundColor = .clear

        // One tap recognizer; QuickTaps tells a double tap (seek) from a single (the controls)
        // within a fifth of a second. A single tap made to wait for a double-tap recognizer to
        // fail sat for about a third, and showing the controls felt slow. A double tap never
        // shows or hides them.
        let tap = SingleTouchTapGR(
            target: context.coordinator,
            action: #selector(Coordinator.handleTap(_:))
        )

        // On iOS 16 SwiftUI's own recognizers on the hosting view (the centre play button,
        // the controls) won these touches outright, so a tap on the video never showed the
        // controls; only the middle, a SwiftUI button, did anything. Recognising alongside
        // them lets the video tap through, as it already does on later versions.
        tap.delegate = context.coordinator

        let hoverGR = UIHoverGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handleHover(_:))
        )
        hoverGR.cancelsTouchesInView = false

        view.addGestureRecognizer(tap)
        view.addGestureRecognizer(hoverGR)
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        context.coordinator.onSingleTap = onSingleTap
        context.coordinator.onSeekLeft  = onSeekLeft
        context.coordinator.onSeekRight = onSeekRight
        context.coordinator.onHover     = onHover
    }

    static func dismantleUIView(_ uiView: UIView, coordinator: Coordinator) {
        coordinator.taps.cancel()
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var onSingleTap: () -> Void
        var onSeekLeft: () -> Void
        var onSeekRight: () -> Void
        var onHover: (() -> Void)?
        let taps = QuickTaps()
        private weak var view: UIView?

        init(onSingleTap: @escaping () -> Void,
             onSeekLeft: @escaping () -> Void,
             onSeekRight: @escaping () -> Void,
             onHover: (() -> Void)?) {
            self.onSingleTap = onSingleTap
            self.onSeekLeft  = onSeekLeft
            self.onSeekRight = onSeekRight
            self.onHover     = onHover
            super.init()
            taps.onSingle = { [weak self] _ in self?.onSingleTap() }
            taps.onDouble = { [weak self] point in
                guard let self else { return }
                if point.x < (self.view?.bounds.width ?? 0) / 2 { self.onSeekLeft() } else { self.onSeekRight() }
            }
        }

        @objc func handleTap(_ gr: UITapGestureRecognizer) {
            view = gr.view
            taps.tap(at: gr.location(in: gr.view))
        }

        @objc func handleHover(_ gr: UIHoverGestureRecognizer) {
            if gr.state == .began || gr.state == .changed {
                onHover?()
            }
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }
    }
}

/// Tap recognizer that immediately fails when more than one simultaneous touch is detected.
/// Attaching this to a full-screen view makes two-finger gestures invisible to it,
/// regardless of which halves the fingers land on.
private final class SingleTouchTapGR: UITapGestureRecognizer {
    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        guard (event.allTouches?.count ?? 0) == 1 else {
            state = .failed
            return
        }
        super.touchesBegan(touches, with: event)
    }
}
#endif

struct PlayerDoubleTapSeek_Previews: PreviewProvider {
    static var previews: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            PlayerDoubleTapSeek(
                onSingleTap: { print("single tap") },
                onSeekBackward: { print("seek backward") },
                onSeekForward: { print("seek forward") },
                seekAmount: 10
            )
        }
    }
}
