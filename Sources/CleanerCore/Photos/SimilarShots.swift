import Foundation

public enum SimilarShots {
    public static let window: TimeInterval = 30
    /// Calibrated in Phase 0 for feature-print revision 2 on 512 px images; distances from other revisions or sizes aren't comparable.
    public static let threshold = 0.20
    public static let chainGuard = threshold * 1.5
    public static let groupCap = 100

    /// An item without a date is a run of its own.
    public static func sequences<T>(_ items: [T], date: (T) -> Date?) -> [[T]] {
        var runs: [[T]] = []
        var previous: Date?
        for item in items {
            let current = date(item)
            if let current, let previous, abs(current.timeIntervalSince(previous)) <= window, !runs.isEmpty {
                runs[runs.count - 1].append(item)
            } else {
                runs.append([item])
            }
            previous = current
        }
        return runs
    }

    /// Groups of indices into `dates`; `distance` is nil when either photo has no feature print.
    public static func groups(dates: [Date], distance: (Int, Int) -> Double?) -> [[Int]] {
        cluster(Array(dates.indices), dates: dates, distance: distance)
    }

    private static func cluster(_ members: [Int], dates: [Date], distance: (Int, Int) -> Double?) -> [[Int]] {
        let order = members.sorted { dates[$0] < dates[$1] }
        var parent = Dictionary(uniqueKeysWithValues: order.map { ($0, $0) })
        var size = Dictionary(uniqueKeysWithValues: order.map { ($0, 1) })
        func root(_ index: Int) -> Int {
            var index = index
            while parent[index]! != index { index = parent[index]! }
            return index
        }
        for (position, photo) in order.enumerated() {
            for earlier in order[..<position].reversed() {
                guard dates[photo].timeIntervalSince(dates[earlier]) <= window else { break }
                guard let gap = distance(photo, earlier), gap <= threshold else { continue }
                let (a, b) = (root(photo), root(earlier))
                guard a != b, size[a]! + size[b]! <= groupCap else { continue }
                parent[b] = a
                size[a]! += size[b]!
            }
        }
        let components = Dictionary(grouping: order, by: root).values.filter { $0.count >= 2 }
        return components.flatMap { guarded($0, dates: dates, distance: distance) }
            .sorted { dates[$0[0]] < dates[$1[0]] }
    }

    /// Drops members too far from the group's medoid, so a chain of small steps can't join two different shots.
    private static func guarded(_ group: [Int], dates: [Date], distance: (Int, Int) -> Double?) -> [[Int]] {
        func gap(_ a: Int, _ b: Int) -> Double { a == b ? 0 : distance(a, b) ?? .infinity }
        let medoid = group.min { a, b in
            group.reduce(0) { $0 + gap(a, $1) } < group.reduce(0) { $0 + gap(b, $1) }
        }!
        let kept = group.filter { gap($0, medoid) <= chainGuard }
        let dropped = group.filter { gap($0, medoid) > chainGuard }
        return (kept.count >= 2 ? [kept.sorted { dates[$0] < dates[$1] }] : [])
            + (dropped.count >= 2 ? cluster(dropped, dates: dates, distance: distance) : [])
    }
}
