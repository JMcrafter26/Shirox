import XCTest
import Combine
@testable import Shirox

/// Pages call `resetToAppOrientation()` from `onAppear`. The root tab view observes
/// `PlayerPresenter`, so a change notification from that call re-rendered the whole app as each
/// page appeared — and on iOS 27 that popped the page just pushed, leaving rows that "don't open".
@MainActor
final class OrientationLockTests: XCTestCase {
    func testResettingOrientationDoesNotNotifyObservers() {
        let presenter = PlayerPresenter.shared
        var notified = 0
        let token = presenter.objectWillChange.sink { _ in notified += 1 }
        presenter.resetToAppOrientation()
        presenter.updateOrientationLock(.allButUpsideDown)
        presenter.resetToAppOrientation()
        token.cancel()
        XCTAssertEqual(notified, 0)
    }
}
