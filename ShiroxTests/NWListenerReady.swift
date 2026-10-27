import Foundation
import Network

extension NWListener {
    /// Starts listening on `queue` and returns once the port is open, so a test can read `port`.
    /// The state handler runs on that queue and can see `.ready` more than once, so a flag behind
    /// a lock lets only the first one resume.
    func startWhenReady(queue: DispatchQueue) async {
        let once = OnceFlag()
        await withCheckedContinuation { (ready: CheckedContinuation<Void, Never>) in
            stateUpdateHandler = { state in
                guard case .ready = state, once.claim() else { return }
                ready.resume()
            }
            start(queue: queue)
        }
    }
}

/// True from `claim()` the first time only, from whichever thread gets there first.
private final class OnceFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var claimed = false

    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !claimed else { return false }
        claimed = true
        return true
    }
}
