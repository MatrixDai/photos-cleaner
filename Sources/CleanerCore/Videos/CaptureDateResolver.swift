import AVFoundation
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

public enum CaptureDateSource: String, Codable, Sendable {
    case quicktime, avasset, photos
}

public struct CaptureDate: Equatable, Sendable {
    public let day: String
    public let source: CaptureDateSource
}

public struct VideoMetadataDates: Equatable, Sendable {
    public var quickTime: String?
    public var assetCreationString: String?
    public var assetCreationDate: Date?

    public init(quickTime: String? = nil, assetCreationString: String? = nil, assetCreationDate: Date? = nil) {
        self.quickTime = quickTime
        self.assetCreationString = assetCreationString
        self.assetCreationDate = assetCreationDate
    }
}

public enum CaptureDateResolver {
    public static func resolve(_ metadata: VideoMetadataDates, photosDate: Date?, timeZone: TimeZone = .current) -> CaptureDate {
        if let day = metadata.quickTime.flatMap(QuickTimeDate.init)?.day { return CaptureDate(day: day, source: .quicktime) }
        if let day = metadata.assetCreationString.flatMap(QuickTimeDate.init)?.day { return CaptureDate(day: day, source: .avasset) }
        if let date = metadata.assetCreationDate { return CaptureDate(day: day(of: date, in: timeZone), source: .avasset) }
        return CaptureDate(day: photosDate.map { day(of: $0, in: timeZone) } ?? "0000-00-00", source: .photos)
    }

    public static func read(_ file: URL) async -> VideoMetadataDates {
        let asset = AVURLAsset(url: file)
        var dates = VideoMetadataDates()
        if let metadata = try? await asset.load(.metadata),
           let item = AVMetadataItem.metadataItems(from: metadata, filteredByIdentifier: .quickTimeMetadataCreationDate).first {
            dates.quickTime = try? await item.load(.stringValue)
        }
        if let creation = try? await asset.load(.creationDate) {
            dates.assetCreationString = try? await creation.load(.stringValue)
            dates.assetCreationDate = try? await creation.load(.dateValue)
        }
        return dates
    }

    static func day(of date: Date, in timeZone: TimeZone) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year!, parts.month!, parts.day!)
    }
}
