import SwiftUI
#if os(macOS)
import AVKit
#endif

struct PlayerTopBar: View {
    let title: String
    var onDismiss: () -> Void
    @Binding var isLocked: Bool
    /// The player's own mute, apart from the device's volume.
    @Binding var isMuted: Bool
    var onPiP: (() -> Void)? = nil
    /// Opens or closes the Video Details panel; nil hides the button.
    var onInfo: (() -> Void)? = nil
    var isInfoShown = false
    var topPadding: CGFloat = 24
    var isLandscape: Bool = true
    var showDismiss: Bool = true
    #if os(macOS)
    /// The native engine's player, which AirPlay can take to another screen. Nil on mpv.
    var airPlayPlayer: AVPlayer? = nil
    /// Whether the window is the small floating one.
    var isPictureInPicture = false
    #endif
    @AppStorage("playerLiquidGlass") private var playerLiquidGlass = true
    /// The title is shown whole, over as many lines as it takes, after a tap on it.
    @State private var showsFullTitle = false
    @State private var collapseTitle: Task<Void, Never>?
    #if os(macOS)
    @ObservedObject private var cover = MacPlayerWindowManager.shared
    #endif

    /// A Mac's row is as tall as a window's title bar, level with the window's buttons in it.
    private static var compact: Bool {
        #if os(macOS)
        true
        #else
        false
        #endif
    }

    private var rowHeight: CGFloat { isPad ? 56 : Self.compact ? 32 : 44 }

    private var isPad: Bool {
        #if os(iOS)
        return UIDevice.current.userInterfaceIdiom == .pad
        #else
        return false
        #endif
    }

    var body: some View {
        // The title takes the room between the dismiss button and the right capsule and is
        // centred in it. Centred on the screen instead, it had to clear the wider side on both
        // sides, and the landscape capsule (info, Cast, AirPlay, PiP, mute, lock) left it little.
        HStack(alignment: .top, spacing: isPad ? 16 : 10) {
            // Dismiss button (left). On a Mac it follows the window's own buttons, which
            // close the window rather than the player covering it.
            #if os(macOS)
            HStack(spacing: 0) {
                // Room for the window's buttons, which the small Picture in Picture window hides.
                if !cover.isFullScreen && !isPictureInPicture {
                    Color.clear.frame(width: 70)
                }
                if showDismiss {
                    Button(action: onDismiss) {
                        Image(systemName: "xmark")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 26, height: 26)
                            .mediaGlassChrome(Circle(), enabled: playerLiquidGlass, off: Color.white.opacity(0.25))
                            .shadow(color: .black.opacity(0.3), radius: 6)
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .help("Close (Esc)")
                }
            }
            .frame(height: rowHeight)
            #else
            if showDismiss {
                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                        .font(.system(size: isPad ? 24 : 18, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: isPad ? 56 : 44, height: isPad ? 56 : 44)
                        .mediaGlassChrome(Circle(), enabled: playerLiquidGlass, off: Color.white.opacity(0.25))
                        .shadow(color: .black.opacity(0.3), radius: 6)
                }
                .buttonStyle(.plain)
            } else {
                Color.clear.frame(width: isPad ? 56 : 44, height: isPad ? 56 : 44)
            }
            #endif

            titleView

            // Right capsule group: AirPlay | PiP | Mute | Lock
            Group {
                if isLandscape {
                    HStack(spacing: isPad ? 14 : 8) { rightButtons }
                        .padding(.horizontal, isPad ? 12 : Self.compact ? 6 : 8)
                        .padding(.vertical, isPad ? 6 : Self.compact ? 3 : 4)
                } else {
                    VStack(spacing: isPad ? 14 : 8) { rightButtons }
                        .padding(.horizontal, isPad ? 6 : 4)
                        .padding(.vertical, isPad ? 12 : 8)
                }
            }
            .mediaGlassChrome(Capsule(), enabled: playerLiquidGlass, off: Color.white.opacity(0.2))
        }
        #if os(macOS)
        // Level with the window's buttons in a window, a little way down in full screen, and
        // clear of the small Picture in Picture window's edges, where they sat against the top.
        .padding(.horizontal, isPictureInPicture ? 10 : 20)
        .padding(.top, isPictureInPicture ? 10 : topPadding)
        #else
        .padding(.horizontal, isPad ? 30 : 20)
        .padding(.top, isPad ? topPadding + 10 : topPadding)
        #endif
        .padding(.bottom, 16)
        .onDisappear { collapseTitle?.cancel() }
    }

    /// One line, cut short with an ellipsis; a tap shows the whole name for a few seconds.
    private var titleView: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.2)) { showsFullTitle.toggle() }
            collapseTitle?.cancel()
            guard showsFullTitle else { return }
            collapseTitle = Task {
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                guard !Task.isCancelled else { return }
                withAnimation(.easeInOut(duration: 0.2)) { showsFullTitle = false }
            }
        } label: {
            Text(title)
                .font(isPad ? .title3.weight(.semibold) : .subheadline.weight(.semibold))
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)
                .lineLimit(showsFullTitle ? nil : 1)
                .truncationMode(.tail)
                .fixedSize(horizontal: false, vertical: showsFullTitle)
                .shadow(color: .black.opacity(0.5), radius: 4)
                .frame(maxWidth: .infinity, minHeight: rowHeight)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityHint(showsFullTitle ? "" : "Shows the whole title")
    }

    @ViewBuilder
    private var rightButtons: some View {
        let iconSize: CGFloat = isPad ? 20 : Self.compact ? 13 : 15
        let frameSize: CGFloat = isPad ? 44 : Self.compact ? 26 : 32

        if let onInfo {
            Button(action: onInfo) {
                Image(systemName: isInfoShown ? "info.circle.fill" : "info.circle")
                    .font(.system(size: iconSize, weight: .medium))
                    .foregroundStyle(.white)
                    .frame(width: frameSize, height: frameSize)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Video Details")
            #if os(macOS)
            .help("Video Details (I)")
            #endif
        }
        #if os(iOS)
        #if !targetEnvironment(macCatalyst)
        CastButton()
            .frame(width: frameSize, height: frameSize)
        #endif
        AirPlayButton()
            .frame(width: frameSize, height: frameSize)
        if onPiP != nil {
            Button { onPiP?() } label: {
                Image(systemName: "pip.enter")
                    .font(.system(size: iconSize, weight: .medium))
                    .foregroundStyle(.white)
                    .frame(width: frameSize, height: frameSize)
            }
            .buttonStyle(.plain)
        }
        #endif
        #if os(macOS)
        if let airPlayPlayer {
            MacAirPlayButton(player: airPlayPlayer)
                .frame(width: frameSize, height: frameSize)
                .help("AirPlay")
        }
        Button { onPiP?() } label: {
            Image(systemName: isPictureInPicture ? "pip.exit" : "pip.enter")
                .font(.system(size: iconSize, weight: .medium))
                .foregroundStyle(.white)
                .frame(width: frameSize, height: frameSize)
        }
        .buttonStyle(.plain)
        .help(isPictureInPicture ? "Back to the full window (P)" : "Picture in Picture (P)")
        muteButton(iconSize: iconSize, frameSize: frameSize)
            .help(isMuted ? "Unmute (M)" : "Mute (M)")
        #else
        muteButton(iconSize: iconSize, frameSize: frameSize)
        Button {
            withAnimation(.easeInOut(duration: 0.2)) { isLocked.toggle() }
        } label: {
            Image(systemName: isLocked ? "lock.fill" : "lock.open.fill")
                .font(.system(size: iconSize, weight: .medium))
                .foregroundStyle(.white)
                .frame(width: frameSize, height: frameSize)
        }
        .buttonStyle(.plain)
        #endif
    }

    private func muteButton(iconSize: CGFloat, frameSize: CGFloat) -> some View {
        Button {
            withAnimation(.easeInOut(duration: 0.2)) { isMuted.toggle() }
        } label: {
            Image(systemName: isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                .font(.system(size: iconSize, weight: .medium))
                .foregroundStyle(.white)
                .frame(width: frameSize, height: frameSize)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isMuted ? "Unmute" : "Mute")
    }
}

#if os(macOS)
/// The system's AirPlay menu, sending the native engine's player to the chosen screen.
private struct MacAirPlayButton: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> AVRoutePickerView {
        let view = AVRoutePickerView()
        view.isRoutePickerButtonBordered = false
        view.setRoutePickerButtonColor(.white, for: .normal)
        view.player = player
        return view
    }

    func updateNSView(_ view: AVRoutePickerView, context: Context) {
        view.player = player
    }
}
#endif

extension PlayerTopBar {
    /// The Mac's own top-bar buttons: AirPlay for the native engine's player, and Picture in
    /// Picture. Nothing elsewhere.
    #if os(macOS)
    func macPlayerControls(airPlay: AVPlayer?, isPictureInPicture: Bool) -> PlayerTopBar {
        var bar = self
        bar.airPlayPlayer = airPlay
        bar.isPictureInPicture = isPictureInPicture
        return bar
    }
    #else
    func macPlayerControls(airPlay: Never?, isPictureInPicture: Bool) -> PlayerTopBar { self }
    #endif
}
