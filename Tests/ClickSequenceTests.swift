import XCTest
import CoreGraphics

@testable import MouseToucherLib

class ClickSequenceTests: XCTestCase {
    let p = CGPoint(x: 100, y: 100)

    func testCountsUpWithinIntervalAndDistance() {
        var s = ClickSequence(interval: 0.5)
        XCTAssertEqual(s.register(at: p, time: 1.0), 1)
        XCTAssertEqual(s.register(at: p, time: 1.3), 2)
        XCTAssertEqual(s.register(at: CGPoint(x: 103, y: 101), time: 1.6), 3)
    }

    func testRestartsAfterIntervalOrDistance() {
        var s = ClickSequence(interval: 0.5)
        _ = s.register(at: p, time: 1.0)
        XCTAssertEqual(s.register(at: p, time: 1.6), 1)
        XCTAssertEqual(s.register(at: CGPoint(x: 120, y: 100), time: 1.7), 1)
    }

    func testPriorCountArmsHoldOnlyAfterRecentTap() {
        var s = ClickSequence(interval: 0.5)
        XCTAssertEqual(s.priorCount(at: p, time: 1.0), 0)
        _ = s.register(at: p, time: 1.0)
        XCTAssertEqual(s.priorCount(at: p, time: 1.2), 1)
        XCTAssertEqual(s.priorCount(at: p, time: 2.0), 0)
        s.reset()
        XCTAssertEqual(s.priorCount(at: p, time: 1.2), 0)
    }
}
