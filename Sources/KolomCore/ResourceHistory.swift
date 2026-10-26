import Foundation

/// Missing samples remain gaps; a PID restart must not become a CPU spike.
public struct ResourceHistory {
    public private(set) var samples: [Double?] = []
    public let capacity: Int
    public init(capacity: Int = 60) { self.capacity = max(2, capacity) }
    public mutating func append(_ value: Double?) {
        samples.append(value.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil })
        if samples.count > capacity { samples.removeFirst(samples.count - capacity) }
    }
}
public func processCPUShare(
    previous: UInt64?, current: UInt64, elapsed: Double, cores: Int, nanosecondsPerTick: Double = 1
) -> Double? {
    guard let previous, current >= previous, elapsed.isFinite, elapsed > 0, cores > 0, nanosecondsPerTick.isFinite,
        nanosecondsPerTick > 0
    else { return nil }
    return min(1, Double(current - previous) * nanosecondsPerTick / (elapsed * 1_000_000_000 * Double(cores)))
}
