import Foundation

public enum RatingScope: Equatable, Sendable {
    case unrated
    case reRate(start: Date, end: Date)

    public var query: PhotoQuery {
        switch self {
        case .unrated: PhotoQuery(range: nil, unratedOnly: true)
        case .reRate(let start, let end): PhotoQuery(range: start..<end, unratedOnly: false)
        }
    }

    public var isReRate: Bool { self != .unrated }

    public var label: String {
        switch self {
        case .unrated: "unrated"
        case .reRate(let start, let end):
            "reRate \(start.formatted(.iso8601))..<\(end.formatted(.iso8601))"
        }
    }

    public static func reRate(from first: Date, to last: Date, timeZone: TimeZone = .current) throws(RatingScopeError) -> RatingScope {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let start = calendar.startOfDay(for: first)
        let lastDay = calendar.startOfDay(for: last)
        guard lastDay >= start else { throw .endBeforeStart }
        return .reRate(start: start, end: calendar.date(byAdding: .day, value: 1, to: lastDay)!)
    }
}

public enum RatingScopeError: Error, Equatable, LocalizedError {
    case endBeforeStart

    public var errorDescription: String? {
        switch self {
        case .endBeforeStart: "The end date is before the start date."
        }
    }
}
