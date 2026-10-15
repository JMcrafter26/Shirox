import Foundation

/// How many requests a download may have out at once to one host, found as it goes.
///
/// It used to be two for every host, because AnimePahe's segment CDN answers a burst of four
/// with 429s. Most hosts take far more, so two left downloads several times slower than they
/// had to be. Now each host starts at `start`; a 429 or 503 halves its limit, and a run of
/// successes raises it by one again, up to `ceiling`. A host that throttles settles just under
/// what it allows; the rest run wide open. What's learned lasts until the app quits, and every
/// download to the same host shares it.
actor HostRequestGate {
    static let shared = HostRequestGate()

    /// One host's limit, on its own so it can be tested.
    struct AdaptiveLimit: Equatable {
        static let start = 6
        static let ceiling = 10
        /// Successes in a row, per request allowed, before one more is allowed.
        static let successesPerRaise = 4

        private(set) var limit = start
        private var successes = 0

        mutating func succeeded() {
            successes += 1
            guard limit < Self.ceiling, successes >= limit * Self.successesPerRaise else { return }
            limit += 1
            successes = 0
        }

        mutating func throttled() {
            limit = max(1, limit / 2)
            successes = 0
        }
    }

    private struct Lane {
        var limit = AdaptiveLimit()
        var inFlight = 0
        var waiters: [CheckedContinuation<Void, Never>] = []
    }

    private var lanes: [String: Lane] = [:]

    /// Waits for room under the host's limit. Pair every call with `release`.
    func acquire(_ host: String) async {
        var lane = lanes[host, default: Lane()]
        if lane.inFlight < lane.limit.limit {
            lane.inFlight += 1
            lanes[host] = lane
            return
        }
        await withCheckedContinuation { continuation in
            lanes[host, default: Lane()].waiters.append(continuation)
        }
        // `release` counted this request in before resuming it.
    }

    func release(_ host: String) {
        guard var lane = lanes[host] else { return }
        lane.inFlight = max(0, lane.inFlight - 1)
        // Hands freed room straight to waiters, as many as the limit now allows.
        while lane.inFlight < lane.limit.limit, !lane.waiters.isEmpty {
            lane.inFlight += 1
            lane.waiters.removeFirst().resume()
        }
        lanes[host] = lane
    }

    func succeeded(_ host: String) {
        lanes[host, default: Lane()].limit.succeeded()
    }

    func throttled(_ host: String) {
        lanes[host, default: Lane()].limit.throttled()
        Logger.shared.log("[HLS] \(host) is throttling; now \(lanes[host]?.limit.limit ?? 1) at a time", type: "Download")
    }

    func limit(for host: String) -> Int { lanes[host]?.limit.limit ?? AdaptiveLimit.start }
}
