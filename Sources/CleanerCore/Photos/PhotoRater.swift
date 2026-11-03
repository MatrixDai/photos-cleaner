import Foundation

public struct PhotoRater: Sendable {
    public static let writeBatch = 200
    public static let lowQualityStars = 1...2

    let library: any PhotoLibraryService

    public init(library: any PhotoLibraryService) {
        self.library = library
    }

    public func rateAndMark(_ scan: PhotoScanResult, thresholds: [Double], lowQualityAlbum: String, duplicatedAlbum: String?,
                            context: JobContext) async throws -> JobSummary {
        let stars = Dictionary(uniqueKeysWithValues: scan.photos.map { ($0.id, StarRater.stars(for: $0.score, thresholds: thresholds)) })
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

        var counts = StarRater.counts(scan.photos.map(\.score), thresholds: thresholds).reduce(into: [String: Int]()) {
            $0["stars\($1.key)"] = $1.value
        }
        counts["rated"] = writes.count
        counts["overwritten"] = overwritten
        counts["addedLowQuality"] = add.count
        counts["removedLowQuality"] = remove.count
        return JobSummary(scope: scan.scope.label, counts: counts)
    }
}

public struct PhotoReverter: Sendable {
    let library: any PhotoLibraryService

    public init(library: any PhotoLibraryService) {
        self.library = library
    }

    public func members(of albums: [String]) async -> Set<String> {
        var members = Set<String>()
        for album in albums { members.formUnion(await library.albumMembers(id: album)) }
        return members
    }

    public func revert(albums: [String], context: JobContext) async throws -> JobSummary {
        let members = await members(of: albums).sorted()
        for start in stride(from: 0, to: members.count, by: PhotoRater.writeBatch) {
            try context.checkCancellation()
            let batch = members[start..<min(start + PhotoRater.writeBatch, members.count)]
            try await library.setRatings(Dictionary(uniqueKeysWithValues: batch.map { ($0, 0) }))
            context.progress(start + batch.count, of: members.count, item: "Clearing ratings")
        }
        for album in albums {
            let inAlbum = await library.albumMembers(id: album)
            if !inAlbum.isEmpty { try await library.removeAssets(inAlbum.sorted(), fromAlbum: album) }
        }
        return JobSummary(counts: ["cleared": members.count, "albums": albums.count])
    }
}
