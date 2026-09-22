import Foundation
import CoreGraphics

/// Handles tap detection logic - separated for testability
class TapDetector {
    let tapTimeThreshold: TimeInterval
    let tapMovementThreshold: CGFloat

    private var touchStartTime: Date?
    private var touchStartLocation: CGPoint?

    init(tapTimeThreshold: TimeInterval = 0.3, tapMovementThreshold: CGFloat = 5.0) {
        self.tapTimeThreshold = tapTimeThreshold
        self.tapMovementThreshold = tapMovementThreshold
    }

    /// Records the start of a touch
    func touchBegan(at location: CGPoint) {
        touchStartTime = Date()
        touchStartLocation = location
    }

    /// Records movement during touch
    /// Returns true if movement exceeds threshold (not a tap)
    func touchMoved(to location: CGPoint) -> Bool {
        guard let startLocation = touchStartLocation else { return false }
        let distance = hypot(location.x - startLocation.x, location.y - startLocation.y)

        if distance > tapMovementThreshold {
            reset()
            return true
        }
        return false
    }

    /// Checks if touch ending qualifies as a tap
    /// Returns the tap location if it's a valid tap, nil otherwise
    func touchEnded(at location: CGPoint) -> CGPoint? {
        defer { reset() }

        guard let startTime = touchStartTime,
              let startLocation = touchStartLocation else {
            return nil
        }

        let duration = Date().timeIntervalSince(startTime)
        let distance = hypot(location.x - startLocation.x, location.y - startLocation.y)

        if duration < tapTimeThreshold && distance < tapMovementThreshold {
            return location
        }

        return nil
    }

    /// Resets tap detection state
    func reset() {
        touchStartTime = nil
        touchStartLocation = nil
    }

    /// Returns true if a touch is currently being tracked
    var isTracking: Bool {
        return touchStartTime != nil
    }
}

/// Tracks consecutive taps so synthesized clicks carry a real click count
/// (2 = double-click / select word, 3 = triple-click / select line or paragraph).
struct ClickSequence {
    var interval: TimeInterval
    var maxDistance: CGFloat

    private(set) var count = 0
    private var lastTime: TimeInterval = 0
    private var lastLocation = CGPoint.zero

    init(interval: TimeInterval, maxDistance: CGFloat = 5.0) {
        self.interval = interval
        self.maxDistance = maxDistance
    }

    /// Clicks so far in the sequence if an event at `location`/`time` continues it, else 0.
    func priorCount(at location: CGPoint, time: TimeInterval) -> Int {
        guard count > 0,
              time >= lastTime,
              time - lastTime <= interval,
              hypot(location.x - lastLocation.x, location.y - lastLocation.y) <= maxDistance
        else { return 0 }
        return count
    }

    /// Registers a click and returns its click count (1, 2, 3, ...).
    mutating func register(at location: CGPoint, time: TimeInterval) -> Int {
        count = priorCount(at: location, time: time) + 1
        lastTime = time
        lastLocation = location
        return count
    }

    mutating func reset() {
        count = 0
    }
}
