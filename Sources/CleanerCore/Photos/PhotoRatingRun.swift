import Foundation

public protocol PhotoAnalyzing: Sendable {
    func aestheticsScore(_ photoID: String) async throws -> Double
}

public struct RatingTally: Equatable, Sendable {
    public var total = 0
    public var processed = 0
    public var stars = Dictionary(uniqueKeysWithValues: (1...5).map { ($0, 0) })
    public var written = 0
    public var overwritten = 0
    public var screenshots = 0
    public var failed = 0
    public var currentDate: Date?

    public init(total: Int = 0) {
        self.total = total
    }

    public var rated: Int { stars.values.reduce(0, +) }

    public var counts: [String: Int] {
        var counts = Dictionary(uniqueKeysWithValues: stars.map { ("stars\($0.key)", $0.value) })
        counts["photos"] = total
        counts["processed"] = processed
        counts["rated"] = written
        counts["overwritten"] = overwritten
        counts["screenshots"] = screenshots
        counts["failed"] = failed
        return counts
    }
}

public enum PhotoRatingError: Error, LocalizedError, Equatable {
    case analysisFailing(String)

    public var errorDescription: String? {
        switch self {
        case .analysisFailing(let message): "Every photo so far failed to analyze, so the run stopped: \(message)"
        }
    }
}

/// Scores photos as they stream in and writes their stars in small batches, so a cancelled run keeps what it finished.
public struct PhotoRatingRun: Sendable {
    public static let concurrentAnalyses = 4
    public static let writeBatch = 20
    public static let writeInterval: Duration = .seconds(5)
    static let abortAfterFailures = 8

    let library: any PhotoLibraryService
    let analyzer: any PhotoAnalyzing
    let scope: RatingScope
    let thresholds: [Double]

    public init(library: any PhotoLibraryService, analyzer: any PhotoAnalyzing, scope: RatingScope, thresholds: [Double]) {
        self.library = library
        self.analyzer = analyzer
        self.scope = scope
        self.thresholds = thresholds
    }

    public func run(context: JobContext, report: @escaping @Sendable (RatingTally) -> Void) async throws -> RatingTally {
        let photos = await library.photos(scope.query)
        var tally = RatingTally(total: photos.count)
        var pending: [String: Int] = [:]
        var lastWrite = ContinuousClock.now
        var lastError = ""
        report(tally)
        for start in stride(from: 0, to: photos.count, by: Self.concurrentAnalyses) {
            guard !Task.isCancelled else { break }
            let batch = Array(photos[start..<min(start + Self.concurrentAnalyses, photos.count)])
            let scores = await analyze(batch.filter { !$0.isScreenshot })
            guard !Task.isCancelled else { break }
            for photo in batch {
                if photo.isScreenshot {
                    tally.screenshots += 1
                } else {
                    switch scores[photo.id] {
                    case .success(let score): pending[photo.id] = StarRater.stars(for: score, thresholds: thresholds)
                    case .failure(let error):
                        tally.failed += 1
                        lastError = error.localizedDescription
                    case nil: break
                    }
                }
                tally.processed += 1
                if let date = photo.creationDate { tally.currentDate = date }
            }
            if tally.failed >= Self.abortAfterFailures, tally.rated + pending.count == 0 {
                throw PhotoRatingError.analysisFailing(lastError)
            }
            if pending.count >= Self.writeBatch || ContinuousClock.now - lastWrite >= Self.writeInterval {
                try await write(&pending, into: &tally)
                lastWrite = .now
            }
            context.progress(tally.processed, of: tally.total, item: tally.currentDate?.formatted(date: .abbreviated, time: .omitted))
            report(tally)
        }
        try await write(&pending, into: &tally)
        report(tally)
        return tally
    }

    private func write(_ pending: inout [String: Int], into tally: inout RatingTally) async throws {
        guard !pending.isEmpty else { return }
        let current = await library.ratings(of: Array(pending.keys))
        // A photo rated by hand during an unrated run is left alone.
        let targets = pending.filter { id, _ in current[id].map { scope.isReRate || $0 == 0 } ?? false }
        let writes = targets.filter { current[$0.key] != $0.value }
        if !writes.isEmpty { try await library.setRatings(writes) }
        for stars in targets.values { tally.stars[stars, default: 0] += 1 }
        tally.written += writes.count
        tally.overwritten += writes.keys.filter { current[$0] != 0 }.count
        pending = [:]
    }

    private func analyze(_ photos: [LibraryPhoto]) async -> [String: Result<Double, any Error>] {
        await withTaskGroup(of: (String, Result<Double, any Error>).self) { group in
            for photo in photos {
                group.addTask {
                    do { return (photo.id, .success(try await analyzer.aestheticsScore(photo.id))) } catch { return (photo.id, .failure(error)) }
                }
            }
            return await group.reduce(into: [:]) { $0[$1.0] = $1.1 }
        }
    }
}
