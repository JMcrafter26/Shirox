import XCTest
@testable import Shirox

final class HostRequestGateTests: XCTestCase {
    typealias Limit = HostRequestGate.AdaptiveLimit

    func testStartsWiderThanTheOldFixedTwo() {
        XCTAssertGreaterThan(Limit().limit, 2)
    }

    func testThrottlingHalvesDownToOne() {
        var limit = Limit()
        limit.throttled()
        XCTAssertEqual(limit.limit, Limit.start / 2)
        for _ in 0..<10 { limit.throttled() }
        XCTAssertEqual(limit.limit, 1)
    }

    func testARunOfSuccessesRaisesItUpToTheCeiling() {
        var limit = Limit()
        limit.throttled()
        let low = limit.limit
        for _ in 0..<(low * Limit.successesPerRaise) { limit.succeeded() }
        XCTAssertEqual(limit.limit, low + 1)
        for _ in 0..<10_000 { limit.succeeded() }
        XCTAssertEqual(limit.limit, Limit.ceiling)
    }

    /// AnimePahe's CDN: a 429 whenever more than 3 are out. The limit ends at or under 3 and
    /// doesn't climb far past it again.
    func testSettlesUnderAHostThatAllowsThree() {
        var limit = Limit()
        for _ in 0..<2_000 {
            if limit.limit > 3 { limit.throttled() } else { limit.succeeded() }
        }
        XCTAssertLessThanOrEqual(limit.limit, 4)
        XCTAssertGreaterThanOrEqual(limit.limit, 2)
    }

    func testNeverMoreInFlightThanTheLimit() async {
        let gate = HostRequestGate()
        let host = "cdn.example"
        let counter = Counter()
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<40 {
                group.addTask {
                    await gate.acquire(host)
                    await counter.enter()
                    try? await Task.sleep(nanoseconds: 2_000_000)
                    await counter.leave()
                    await gate.release(host)
                }
            }
        }
        let peak = await counter.peak
        XCTAssertEqual(peak, Limit.start)
        let done = await counter.total
        XCTAssertEqual(done, 40)
    }

    private actor Counter {
        var current = 0, peak = 0, total = 0
        func enter() { current += 1; total += 1; peak = max(peak, current) }
        func leave() { current -= 1 }
    }
}
