import Foundation

public enum ResolvedPhotoScope: Equatable, Sendable {
    case olderThan(days: Int, before: Date, after: Date?)
    case dateRange(from: String, to: String, start: Date, end: Date)

    public var query: PhotoQuery {
        switch self {
        case .olderThan(_, let before, let after):
            PhotoQuery(lowerBound: after, lowerInclusive: false, upperBound: before, unratedOnly: true)
        case .dateRange(_, _, let start, let end):
            PhotoQuery(lowerBound: start, lowerInclusive: true, upperBound: end, unratedOnly: false)
        }
    }

    public var label: String {
        switch self {
        case .olderThan(let days, _, _): "olderThan \(days)"
        case .dateRange(let from, let to, _, _): "dateRange \(from)..\(to)"
        }
    }

    public var isDateRange: Bool {
        if case .dateRange = self { return true }
        return false
    }
}

public enum PhotoScopeError: Error, Equatable, LocalizedError {
    case missingDates
    case endBeforeStart

    public var errorDescription: String? {
        switch self {
        case .missingDates: "Pick a start and an end date."
        case .endBeforeStart: "The end date is before the start date."
        }
    }
}

public enum PhotoScope {
    public static func resolve(_ setting: PhotoScopeSetting, resumeAfter: Date?, now: Date,
                               timeZone: TimeZone = .current) throws(PhotoScopeError) -> ResolvedPhotoScope {
        switch setting.kind {
        case .olderThan:
            return .olderThan(days: setting.olderThanDays,
                              before: now.addingTimeInterval(-Double(setting.olderThanDays) * 86_400), after: resumeAfter)
        case .dateRange:
            guard let from = setting.from, let to = setting.to,
                  let start = startOfDay(from, timeZone), let lastDay = startOfDay(to, timeZone) else { throw .missingDates }
            guard lastDay >= start else { throw .endBeforeStart }
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = timeZone
            return .dateRange(from: from, to: to, start: start, end: calendar.date(byAdding: .day, value: 1, to: lastDay)!)
        }
    }

    static func startOfDay(_ day: String, _ timeZone: TimeZone) -> Date? {
        let parts = day.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
    }
}
