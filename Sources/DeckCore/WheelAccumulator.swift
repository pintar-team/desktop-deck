import Foundation

/// Converts high-resolution trackpad motion to discrete RFB wheel detents.
public struct WheelAccumulator {
    private static let pointsPerDetent = 40.0
    private static let maximumDetents = 6
    private static let idleInterval = 0.25

    private var remainder = 0.0
    private var lastTimestamp: TimeInterval?

    public init() {}

    public mutating func reset() {
        remainder = 0
        lastTimestamp = nil
    }

    public mutating func steps(for delta: Double, precise: Bool, at timestamp: TimeInterval, begins: Bool = false) -> Int {
        guard delta.isFinite, timestamp.isFinite else { reset(); return 0 }
        let cap = Double(Self.maximumDetents)
        if !precise {
            reset()
            return Int(min(cap, max(-cap, delta.rounded())))
        }

        if begins || lastTimestamp.map({ timestamp < $0 || timestamp - $0 > Self.idleInterval }) == true {
            reset()
        }
        lastTimestamp = timestamp
        if (delta > 0 && remainder < 0) || (delta < 0 && remainder > 0) {
            remainder = 0
        }
        let distanceLimit = cap * Self.pointsPerDetent
        remainder += min(distanceLimit, max(-distanceLimit, delta))
        let detents = Int((remainder / Self.pointsPerDetent).rounded(.towardZero))
        remainder -= Double(detents) * Self.pointsPerDetent
        return detents
    }
}
