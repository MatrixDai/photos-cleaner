import Foundation

public struct PhotoRater: Sendable {
    public static let writeBatch = 200
    public static let lowQualityStars = 1...2

    let library: any PhotoLibraryService

    public init(library: any PhotoLibraryService) {
        self.library = library
    }

    /// `stars` holds the stars to write per photo: the threshold suggestion, or the user's adjustment.
    public func rateAndMark(_ scan: PhotoScanResult, stars: [String: Int], lowQualityAlbum: String, duplicatedAlbum: String?,
                            context: JobContext) async throws -> JobSummary {
        let current = await library.ratings(of: Array(stars.keys))
        var writes = stars.filter { id, value in current[id].map { $0 != value } ?? false }
        if !scan.scope.isDateRange {
            writes = writes.filter { current[$0.key] == 0 }
        }
        let overwritten = writes.keys.filter { (current[$0] ?? 0) != 0 }.count
        let ordered = writes.sorted { $0.key < $1.key }
        for start in stride(from: 0, to: ordered.count, by: Self.writeBatch) {
            try context.checkCancellation()
            try await library.setRatings(Dictionary(uniqueKeysWithValues: ordered[start..<min(start + Self.writeBatch, ordered.count)].map { ($0.key, $0.value) }))
            context.progress(min(start + Self.writeBatch, ordered.count), of: ordered.count, item: "Writing ratings")
        }

        var final = current.merging(writes) { _, written in written }
        var duplicated = Set<String>()
        if let duplicatedAlbum { duplicated = await library.albumMembers(id: duplicatedAlbum) }
        let lowQuality = await library.albumMembers(id: lowQualityAlbum)
        let outside = lowQuality.subtracting(final.keys)
        final.merge(await library.ratings(of: Array(outside))) { scanned, _ in scanned }

        let add = stars.keys.filter { id in
            Self.lowQualityStars.contains(final[id] ?? 0) && !duplicated.contains(id) && !lowQuality.contains(id)
        }
        let remove = lowQuality.filter { id in duplicated.contains(id) || (final[id] ?? 0) >= 3 }
        if !add.isEmpty { try await library.addAssets(add.sorted(), toAlbum: lowQualityAlbum) }
        if !remove.isEmpty { try await library.removeAssets(remove.sorted(), fromAlbum: lowQualityAlbum) }

        var counts = stars.values.reduce(into: [String: Int]()) { $0["stars\($1)", default: 0] += 1 }
        counts["rated"] = writes.count
        counts["overwritten"] = overwritten
        counts["addedLowQuality"] = add.count
        counts["removedLowQuality"] = remove.count
        return JobSummary(scope: scan.scope.label, counts: counts)
    }
}
