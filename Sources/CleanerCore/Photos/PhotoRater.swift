import Foundation

public struct PhotoRater: Sendable {
    public static let writeBatch = 200

    let library: any PhotoLibraryService

    public init(library: any PhotoLibraryService) {
        self.library = library
    }

    /// `stars` holds the stars to write per photo: the threshold suggestion, or the user's adjustment.
    public func rateAndMark(_ scan: PhotoScanResult, stars: [String: Int], context: JobContext) async throws -> JobSummary {
        let current = await library.ratings(of: Array(stars.keys))
        var writes = stars.filter { id, value in current[id].map { $0 != value } ?? false }
        if !scan.scope.isDateRange {
            writes = writes.filter { current[$0.key] == 0 }
        }
        let overwritten = writes.keys.filter { (current[$0] ?? 0) != 0 }.count
        let ordered = writes.sorted { $0.key < $1.key }
        for start in stride(from: 0, to: ordered.count, by: Self.writeBatch) {
            try context.checkCancellation()
            let batch = ordered[start..<min(start + Self.writeBatch, ordered.count)]
            try await library.setRatings(Dictionary(uniqueKeysWithValues: batch.map { ($0.key, $0.value) }))
            context.progress(start + batch.count, of: ordered.count, item: "Writing ratings")
        }
        var counts = stars.values.reduce(into: [String: Int]()) { $0["stars\($1)", default: 0] += 1 }
        counts["rated"] = writes.count
        counts["overwritten"] = overwritten
        return JobSummary(scope: scan.scope.label, counts: counts)
    }
}
