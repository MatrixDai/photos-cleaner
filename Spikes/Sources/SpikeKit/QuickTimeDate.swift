import Foundation

public struct QuickTimeDate: Equatable, Sendable {
    public let day: String
    public let utcOffsetSeconds: Int?

    /// The date part is already the recording's local day; converting to the system time zone would shift it.
    public init?(_ raw: String) {
        let pattern = #"^(\d{4}-\d{2}-\d{2})T\d{2}:\d{2}:\d{2}(?:\.\d+)?(Z|[+-]\d{2}:?\d{2})?$"#
        let text = raw.trimmingCharacters(in: .whitespaces)
        guard let match = text.wholeMatch(of: try! Regex(pattern)) else { return nil }
        day = String(match.output[1].substring!)
        guard let zone = match.output[2].substring else {
            utcOffsetSeconds = nil
            return
        }
        if zone == "Z" {
            utcOffsetSeconds = 0
            return
        }
        let digits = zone.dropFirst().filter(\.isNumber)
        let hours = Int(digits.prefix(2))!
        let minutes = Int(digits.suffix(2))!
        utcOffsetSeconds = (zone.first == "-" ? -1 : 1) * (hours * 3600 + minutes * 60)
    }
}
