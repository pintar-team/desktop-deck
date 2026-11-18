import Foundation

public enum ActivitySource: Equatable {
    case desktop(Int)
    case terminal(UUID, Int)
}

public struct ActivityReading: Equatable {
    public let source: ActivitySource
    public let perSecond: Int
    public var segments: Int {
        let thresholds: [Int]
        switch source {
        case .desktop: thresholds = [1, 1024, 16 * 1024, 128 * 1024, 1024 * 1024]
        case .terminal: thresholds = [1, 3, 8, 20, 50]
        }
        return thresholds.prefix { perSecond >= $0 }.count
    }
}

public struct ActivitySampler {
    private var previous: (source: ActivitySource, total: UInt64, time: TimeInterval)?
    public init() {}
    public mutating func sample(source: ActivitySource?, total: UInt64?, at time: TimeInterval) -> ActivityReading? {
        guard let source, let total, time.isFinite else { previous = nil; return nil }
        defer { previous = (source, total, time) }
        guard let previous, previous.source == source, total >= previous.total else { return nil }
        let elapsed = time - previous.time
        guard elapsed > 0, elapsed <= 5 else { return nil }
        let delta = total - previous.total
        let rate = Double(delta) / elapsed
        return ActivityReading(source: source, perSecond: delta == 0 ? 0 : max(1, Int(exactly: rate.rounded()) ?? Int.max))
    }
}
