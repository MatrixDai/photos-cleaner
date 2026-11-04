import Foundation

public protocol PhotoAnalyzing: Sendable {
    func analyze(_ photoID: String, featurePrint: Bool) async throws -> PhotoAnalysis
}

public protocol SimilarityPrint: Sendable {
    func distance(to other: any SimilarityPrint) -> Double?
}

public struct PhotoAnalysis: Sendable {
    public var score: Double
    public var print: (any SimilarityPrint)?

    public init(score: Double, print: (any SimilarityPrint)? = nil) {
        self.score = score
        self.print = print
    }
}

public struct RatingTally: Equatable, Sendable {
    public var total = 0
    public var processed = 0
    public var stars = Dictionary(uniqueKeysWithValues: (1...5).map { ($0, 0) })
    public var written = 0
    public var overwritten = 0
    public var screenshots = 0
    public var failed = 0
    public var groups = 0
    public var grouped = 0
    public var addedToAlbum = 0
    public var removedFromAlbum = 0
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
        counts["groups"] = groups
        counts["grouped"] = grouped
        counts["addedDuplicated"] = addedToAlbum
        counts["removedDuplicated"] = removedFromAlbum
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
/// Batches end only between shot sequences, so a sequence's stars and album changes are never split across runs.
public struct PhotoRatingRun: Sendable {
    public static let concurrentAnalyses = 4
    public static let writeBatch = 20
    public static let writeInterval: Duration = .seconds(5)
    static let abortAfterFailures = 8

    let library: any PhotoLibraryService
    let analyzer: any PhotoAnalyzing
    let scope: RatingScope
    let thresholds: [Double]
    let duplicatesAlbum: String?

    public init(library: any PhotoLibraryService, analyzer: any PhotoAnalyzing, scope: RatingScope, thresholds: [Double],
                duplicatesAlbum: String? = nil) {
        self.library = library
        self.analyzer = analyzer
        self.scope = scope
        self.thresholds = thresholds
        self.duplicatesAlbum = duplicatesAlbum
    }

    private struct Pending {
        var stars: [String: Int] = [:]
        var groups: [[String]] = []
        var ungrouped: [String] = []
    }

    private enum Outcome: Sendable {
        case analyzed(PhotoAnalysis)
        case failed(String)
    }

    public func run(context: JobContext, report: @escaping @Sendable (RatingTally) -> Void) async throws -> RatingTally {
        let photos = await library.photos(scope.query)
        var tally = RatingTally(total: photos.count)
        tally.screenshots = photos.filter(\.isScreenshot).count
        tally.processed = tally.screenshots
        let sequences = SimilarShots.sequences(photos.filter { !$0.isScreenshot }, date: \.creationDate)
        var pending = Pending()
        var lastWrite = ContinuousClock.now
        var lastError = ""
        var next = 0
        report(tally)
        while next < sequences.count, !Task.isCancelled {
            var chunk: [[LibraryPhoto]] = []
            while next < sequences.count, chunk.joined().count < Self.concurrentAnalyses {
                chunk.append(sequences[next])
                next += 1
            }
            let printing = duplicatesAlbum == nil ? [] : Set(chunk.filter { $0.count >= 2 }.joined().map(\.id))
            let outcomes = await analyze(Array(chunk.joined()), printing: printing)
            guard !Task.isCancelled else { break }
            for sequence in chunk {
                var printed: [(id: String, date: Date, print: any SimilarityPrint)] = []
                var analyzed: [String] = []
                for photo in sequence {
                    switch outcomes[photo.id] {
                    case .analyzed(let analysis):
                        pending.stars[photo.id] = StarRater.stars(for: analysis.score, thresholds: thresholds)
                        analyzed.append(photo.id)
                        if let print = analysis.print, let date = photo.creationDate { printed.append((photo.id, date, print)) }
                    case .failed(let message):
                        tally.failed += 1
                        lastError = message
                    case nil: break
                    }
                    tally.processed += 1
                    if let date = photo.creationDate { tally.currentDate = date }
                }
                guard duplicatesAlbum != nil else { continue }
                let groups = SimilarShots.groups(dates: printed.map(\.date)) { printed[$0].print.distance(to: printed[$1].print) }
                    .map { $0.map { printed[$0].id } }
                pending.groups += groups
                if scope.isReRate {
                    let grouped = Set(groups.joined())
                    pending.ungrouped += analyzed.filter { !grouped.contains($0) }
                }
            }
            if tally.failed >= Self.abortAfterFailures, tally.rated + pending.stars.count == 0 {
                throw PhotoRatingError.analysisFailing(lastError)
            }
            if pending.stars.count >= Self.writeBatch || ContinuousClock.now - lastWrite >= Self.writeInterval {
                try await write(&pending, into: &tally)
                lastWrite = .now
            }
            context.progress(tally.processed, of: tally.total, item: tally.currentDate?.formatted(date: .abbreviated, time: .omitted))
            report(tally)
        }
        try await write(&pending, into: &tally)
        if let duplicatesAlbum { tally.removedFromAlbum += try await removeLonelyMembers(of: duplicatesAlbum) }
        report(tally)
        return tally
    }

    private func write(_ pending: inout Pending, into tally: inout RatingTally) async throws {
        if !pending.stars.isEmpty {
            let current = await library.ratings(of: Array(pending.stars.keys))
            // A photo rated by hand during an unrated run is left alone.
            let targets = pending.stars.filter { id, _ in current[id].map { scope.isReRate || $0 == 0 } ?? false }
            let writes = targets.filter { current[$0.key] != $0.value }
            if !writes.isEmpty { try await library.setRatings(writes) }
            for stars in targets.values { tally.stars[stars, default: 0] += 1 }
            tally.written += writes.count
            tally.overwritten += writes.keys.filter { current[$0] != 0 }.count
        }
        if let duplicatesAlbum, !pending.groups.isEmpty || !pending.ungrouped.isEmpty {
            let members = await library.albumMembers(id: duplicatesAlbum)
            let grouped = Set(pending.groups.joined())
            let additions = grouped.subtracting(members).sorted()
            let removals = members.intersection(pending.ungrouped).sorted()
            if !additions.isEmpty { try await library.addAssets(additions, toAlbum: duplicatesAlbum) }
            if !removals.isEmpty { try await library.removeAssets(removals, fromAlbum: duplicatesAlbum) }
            tally.groups += pending.groups.count
            tally.grouped += grouped.count
            tally.addedToAlbum += additions.count
            tally.removedFromAlbum += removals.count
        }
        pending = Pending()
    }

    /// A member left with no other member within the window, e.g. after the user deleted the rest of its group, leaves the album.
    private func removeLonelyMembers(of album: String) async throws -> Int {
        let members = await library.albumMembers(id: album)
        guard !members.isEmpty else { return 0 }
        let dated = await library.creationDates(of: Array(members)).sorted { $0.value < $1.value }
        let lonely = dated.indices.filter { index in
            let before = index > 0 ? dated[index].value.timeIntervalSince(dated[index - 1].value) : .infinity
            let after = index + 1 < dated.count ? dated[index + 1].value.timeIntervalSince(dated[index].value) : .infinity
            return min(before, after) > SimilarShots.window
        }.map { dated[$0].key }
        if !lonely.isEmpty { try await library.removeAssets(lonely, fromAlbum: album) }
        return lonely.count
    }

    private func analyze(_ photos: [LibraryPhoto], printing: Set<String>) async -> [String: Outcome] {
        await withTaskGroup(of: (String, Outcome).self) { group in
            var queue = photos.makeIterator()
            func enqueue() {
                guard !Task.isCancelled, let photo = queue.next() else { return }
                group.addTask { (photo.id, await analyze(photo, featurePrint: printing.contains(photo.id))) }
            }
            for _ in 0..<Self.concurrentAnalyses { enqueue() }
            var results: [String: Outcome] = [:]
            while let (id, outcome) = await group.next() {
                results[id] = outcome
                enqueue()
            }
            return results
        }
    }

    // A do/catch that returns from inside a task-group child closure aborts optimized builds (Swift 6.4), so it lives here.
    private func analyze(_ photo: LibraryPhoto, featurePrint: Bool) async -> Outcome {
        do {
            return .analyzed(try await analyzer.analyze(photo.id, featurePrint: featurePrint))
        } catch {
            return .failed(error.localizedDescription)
        }
    }
}
