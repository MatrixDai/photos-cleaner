import Foundation

public enum Sequences {
    public static func split<T>(_ items: [T], date: (T) -> Date, maxGap: TimeInterval) -> [[T]] {
        var result: [[T]] = []
        var current: [T] = []
        for item in items {
            if let last = current.last, date(item).timeIntervalSince(date(last)) > maxGap {
                result.append(current)
                current = []
            }
            current.append(item)
        }
        if !current.isEmpty { result.append(current) }
        return result
    }
}

public struct Histogram: Sendable {
    public let lower: Double
    public let width: Double
    public private(set) var counts: [Int]

    public init(lower: Double, upper: Double, bins: Int) {
        self.lower = lower
        width = (upper - lower) / Double(bins)
        counts = Array(repeating: 0, count: bins)
    }

    public func bin(for value: Double) -> Int {
        min(max(Int(((value - lower) / width).rounded(.down)), 0), counts.count - 1)
    }

    public mutating func add(_ value: Double) {
        counts[bin(for: value)] += 1
    }

    public func range(ofBin index: Int) -> ClosedRange<Double> {
        (lower + Double(index) * width)...(lower + Double(index + 1) * width)
    }
}

public func percentile(_ values: [Double], _ p: Double) -> Double? {
    guard !values.isEmpty else { return nil }
    let sorted = values.sorted()
    let index = Int((Double(sorted.count - 1) * p).rounded())
    return sorted[index]
}
