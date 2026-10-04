import Foundation
#if os(macOS)
import AppKit
#endif

/// Hides the pointer over a playing video on a Mac: the Mac Catalyst app, and the iPhone app
/// running on an Apple silicon Mac ("Designed for iPad", as TestFlight installs it there).
enum MouseCursorManager {
    private static var isHidden = false

    private static let nsCursorClass: AnyObject? = {
        #if os(macOS)
        return nil
        #else
        if let cls = NSClassFromString("NSCursor") {
            return cls as AnyObject
        }
        // The iPhone app on a Mac may not have AppKit loaded yet.
        guard dlopen("/System/Library/Frameworks/AppKit.framework/AppKit", RTLD_LAZY) != nil else { return nil }
        return NSClassFromString("NSCursor") as AnyObject?
        #endif
    }()

    /// True on a Mac: macOS, Mac Catalyst, and the iPhone app on an Apple silicon Mac
    /// (`isMacCatalystApp` is true for both of the latter).
    static var isSupported: Bool {
        #if os(macOS)
        return true
        #else
        return ProcessInfo.processInfo.isMacCatalystApp
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
