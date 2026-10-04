import Foundation
#if os(macOS)
import AppKit
#endif

/// Manages mouse cursor hiding and showing on macOS and iOS apps running on Mac ("Designed for iPad").
enum MouseCursorManager {
    private static var isHidden = false

    private static let nsCursorClass: AnyObject? = {
        #if os(macOS)
        return nil
        #else
        if let cls = NSClassFromString("NSCursor") {
            return cls as AnyObject
        }
        if let handle = dlopen("/System/Library/Frameworks/AppKit.framework/AppKit", RTLD_LAZY) {
            return NSClassFromString("NSCursor") as AnyObject
        }
        return nil
        #endif
    }()

    /// Indicates whether cursor hide/unhide is supported on the current platform/mode.
    /// Returns true on macOS and on Mac running an iOS app in Designed for iPad mode.
    static var isSupported: Bool {
        #if os(macOS)
        return true
        #else
        return ProcessInfo.processInfo.isiOSAppOnMac
        #endif
    }

    /// Hides the mouse cursor if supported and not already hidden.
    static func hide() {
        guard isSupported, !isHidden else { return }
        #if os(macOS)
        NSCursor.hide()
        isHidden = true
        #else
        if let nsCursor = nsCursorClass {
            nsCursor.perform(Selector(("hide")))
            isHidden = true
        }
        #endif
    }

    /// Unhides the mouse cursor if supported and currently hidden.
    static func unhide() {
        guard isHidden else { return }
        #if os(macOS)
        NSCursor.unhide()
        isHidden = false
        #else
        if let nsCursor = nsCursorClass {
            nsCursor.perform(Selector(("unhide")))
            isHidden = false
        }
        #endif
    }
}
