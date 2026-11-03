import Foundation
import Testing
@testable import CleanerCore

struct StarRaterTests {
    private let thresholds = [-0.3, 0.0, 0.3, 0.6]

    @Test(arguments: [
        (-1.0, 1), (-0.3001, 1), (-0.3, 2), (-0.0001, 2), (0.0, 3), (0.2999, 3), (0.3, 4), (0.5999, 4), (0.6, 5), (1.0, 5),
    ])
    func scoresExactlyOnAThresholdTakeTheHigherBand(_ score: Double, _ stars: Int) {
        #expect(StarRater.stars(for: score, thresholds: thresholds) == stars)
    }

    @Test func countsEveryBand() {
        let counts = StarRater.counts([-0.5, -0.1, 0.1, 0.2, 0.5, 0.9], thresholds: thresholds)
        #expect(counts == [1: 1, 2: 1, 3: 2, 4: 1, 5: 1])
    }
}

struct PhotoScopeTests {
    private let shanghai = TimeZone(identifier: "Asia/Shanghai")!
    private let utc = TimeZone(identifier: "UTC")!
    private let now = ISO8601DateFormatter().date(from: "2026-11-03T12:00:00Z")!

    private func range(_ from: String, _ to: String) -> PhotoScopeSetting {
        var setting = PhotoScopeSetting()
        setting.kind = .dateRange
        setting.from = from
        setting.to = to
        return setting
    }

    @Test func olderThanCountsBackFromNowAndResumesAfterThePoint() throws {
        var setting = PhotoScopeSetting()
        setting.olderThanDays = 90
        let resume = ISO8601DateFormatter().date(from: "2015-03-02T10:00:00Z")!
        let scope = try PhotoScope.resolve(setting, resumeAfter: resume, now: now)
        #expect(scope.query == PhotoQuery(lowerBound: resume, lowerInclusive: false,
                                          upperBound: now.addingTimeInterval(-90 * 86_400), unratedOnly: true))
        #expect(!scope.query.contains(resume))
        #expect(scope.query.contains(resume.addingTimeInterval(0.001)))
    }

    @Test func dateRangeRunsFromMidnightToMidnightInTheSystemTimeZone() throws {
        let scope = try PhotoScope.resolve(range("2026-10-01", "2026-10-31"), resumeAfter: nil, now: now, timeZone: shanghai)
        let start = ISO8601DateFormatter().date(from: "2026-09-30T16:00:00Z")!
        let end = ISO8601DateFormatter().date(from: "2026-10-31T16:00:00Z")!
        #expect(scope.query == PhotoQuery(lowerBound: start, lowerInclusive: true, upperBound: end, unratedOnly: false))
        #expect(scope.query.contains(start))
        #expect(scope.query.contains(end.addingTimeInterval(-1)))
        #expect(!scope.query.contains(end))
        #expect(!scope.query.contains(start.addingTimeInterval(-1)))
    }

    @Test func theSameRangeIsADifferentInstantInAnotherZone() throws {
        let local = try PhotoScope.resolve(range("2026-10-01", "2026-10-01"), resumeAfter: nil, now: now, timeZone: shanghai)
        let other = try PhotoScope.resolve(range("2026-10-01", "2026-10-01"), resumeAfter: nil, now: now, timeZone: utc)
        #expect(local.query.lowerBound != other.query.lowerBound)
        #expect(other.query.lowerBound == ISO8601DateFormatter().date(from: "2026-10-01T00:00:00Z"))
    }

    @Test func singleDayRangeIsAllowed() throws {
        _ = try PhotoScope.resolve(range("2026-10-01", "2026-10-01"), resumeAfter: nil, now: now)
    }

    @Test func endBeforeStartIsRejected() {
        #expect(throws: PhotoScopeError.endBeforeStart) {
            try PhotoScope.resolve(range("2026-10-31", "2026-10-01"), resumeAfter: nil, now: now)
        }
    }

    @Test func missingDatesAreRejected() {
        var setting = PhotoScopeSetting()
        setting.kind = .dateRange
        #expect(throws: PhotoScopeError.missingDates) { try PhotoScope.resolve(setting, resumeAfter: nil, now: now) }
    }
}

struct PhotoScannerTests {
    private let base = ISO8601DateFormatter().date(from: "2015-01-01T00:00:00Z")!
    private let now = ISO8601DateFormatter().date(from: "2026-11-03T12:00:00Z")!

    private func at(_ minutes: Double) -> Date { base.addingTimeInterval(minutes * 60) }

    private func olderThan(after: Date? = nil) -> ResolvedPhotoScope {
        .olderThan(days: 90, before: now.addingTimeInterval(-90 * 86_400), after: after)
    }

    private func scan(_ library: FakeLibrary, _ analyzer: FakeAnalyzer, limit: Int, scope: ResolvedPhotoScope? = nil) async throws -> PhotoScanResult {
        try await PhotoScanner(library: library, analyzer: analyzer, limit: limit)
            .scan(scope ?? olderThan(), context: JobContext(emit: { _ in }))
    }

    @Test func screenshotsAndNonCameraPhotosAreSkippedAndNotCounted() async throws {
        let library = FakeLibrary(), analyzer = FakeAnalyzer()
        library.addPhoto("shot", created: at(0), screenshot: true)
        library.addPhoto("saved", created: at(10))
        analyzer.notCamera("saved")
        for index in 1...3 {
            library.addPhoto("p\(index)", created: at(Double(20 * index)))
            analyzer.camera("p\(index)", score: 0.1)
        }
        let result = try await scan(library, analyzer, limit: 2)
        #expect(result.photos.map(\.id) == ["p1", "p2"])
        #expect(result.screenshots == 1 && result.nonCamera == 1)
        #expect(!analyzer.tagCalls.contains("shot"))
        #expect(!analyzer.scoreCalls.contains("saved"))
        #expect(result.resumeAfter == at(40))
        #expect(!result.reachedEnd)
    }

    @Test func theLimitIsExtendedToTheEndOfTheShotSequence() async throws {
        let library = FakeLibrary(), analyzer = FakeAnalyzer()
        let seconds: [Double] = [0, 10, 20, 35, 200]
        for (index, offset) in seconds.enumerated() {
            library.addPhoto("p\(index)", created: base.addingTimeInterval(offset))
            analyzer.camera("p\(index)", score: 0)
        }
        let result = try await scan(library, analyzer, limit: 2)
        #expect(result.photos.map(\.id) == ["p0", "p1", "p2", "p3"])
        #expect(result.resumeAfter == base.addingTimeInterval(35))
    }

    @Test func nextScanContinuesAfterTheResumePoint() async throws {
        let library = FakeLibrary(), analyzer = FakeAnalyzer()
        for index in 1...5 {
            library.addPhoto("p\(index)", created: at(Double(10 * index)))
            analyzer.camera("p\(index)", score: 0)
        }
        analyzer.notCamera("p2")
        let first = try await scan(library, analyzer, limit: 2)
        #expect(first.photos.map(\.id) == ["p1", "p3"])
        let calls = analyzer.tagCalls.count
        let second = try await scan(library, analyzer, limit: 2, scope: olderThan(after: first.resumeAfter))
        #expect(second.photos.map(\.id) == ["p4", "p5"])
        #expect(!analyzer.tagCalls.dropFirst(calls).contains("p2"))
        #expect(second.reachedEnd)
    }

    @Test func olderThanNeverIncludesRatedPhotos() async throws {
        let library = FakeLibrary(), analyzer = FakeAnalyzer()
        library.addPhoto("rated", created: at(0), rating: 4)
        library.addPhoto("unrated", created: at(10))
        analyzer.camera("unrated", score: 0)
        let result = try await scan(library, analyzer, limit: 10)
        #expect(result.photos.map(\.id) == ["unrated"])
        #expect(!analyzer.tagCalls.contains("rated"))
    }

    @Test func dateRangeIncludesRatedPhotosAndRefusesOverTheLimitBeforeScoring() async throws {
        let library = FakeLibrary(), analyzer = FakeAnalyzer()
        let start = ISO8601DateFormatter().date(from: "2026-10-01T00:00:00Z")!
        for index in 0..<4 {
            library.addPhoto("p\(index)", created: start.addingTimeInterval(Double(index) * 3600), rating: index == 0 ? 5 : 0)
            analyzer.camera("p\(index)", score: 0.4)
        }
        library.addPhoto("outside", created: start.addingTimeInterval(-1))
        let scope = ResolvedPhotoScope.dateRange(from: "2026-10-01", to: "2026-10-01", start: start, end: start.addingTimeInterval(86_400))

        let refused = try await scan(library, analyzer, limit: 3, scope: scope)
        #expect(refused.refusal != nil && refused.cameraInRange == 4 && refused.photos.isEmpty)
        #expect(analyzer.scoreCalls.isEmpty)

        let accepted = try await scan(library, analyzer, limit: 4, scope: scope)
        #expect(accepted.photos.map(\.id) == ["p0", "p1", "p2", "p3"])
        #expect(accepted.alreadyRated == 1)
        #expect(!analyzer.tagCalls.contains("outside"))
    }

    @Test func aFewFailuresAreSkipped() async throws {
        let library = FakeLibrary(), analyzer = FakeAnalyzer()
        for index in 0..<10 {
            library.addPhoto("p\(index)", created: at(Double(index * 10)))
            analyzer.camera("p\(index)", score: 0)
        }
        analyzer.fail("p3")
        let result = try await scan(library, analyzer, limit: 100)
        #expect(result.failed == 1 && result.photos.count == 9)
        #expect(result.reachedEnd && result.resumeAfter == at(90))
    }

    @Test func failingOnEveryPhotoAbortsTheScan() async throws {
        let library = FakeLibrary(), analyzer = FakeAnalyzer()
        for index in 0..<20 {
            library.addPhoto("p\(index)", created: at(Double(index * 10)))
            analyzer.fail("p\(index)")
        }
        await #expect(throws: PhotoScanError.self) { _ = try await scan(library, analyzer, limit: 100) }
    }
}

struct PhotoRaterTests {
    private let base = ISO8601DateFormatter().date(from: "2015-01-01T00:00:00Z")!
    private let thresholds = [-0.3, 0.0, 0.3, 0.6]

    private func result(_ photos: [(String, Double, Int)], dateRange: Bool = false) -> PhotoScanResult {
        let scope: ResolvedPhotoScope = dateRange
            ? .dateRange(from: "2015-01-01", to: "2015-01-01", start: base, end: base.addingTimeInterval(86_400))
            : .olderThan(days: 90, before: .now, after: nil)
        var result = PhotoScanResult(scope: scope)
        result.photos = photos.map { AnalyzedPhoto(id: $0.0, date: base, score: $0.1, rating: $0.2) }
        return result
    }

    private func rate(_ library: FakeLibrary, _ scan: PhotoScanResult) async throws -> JobSummary {
        let stars = Dictionary(uniqueKeysWithValues: scan.photos.map { ($0.id, StarRater.stars(for: $0.score, thresholds: thresholds)) })
        return try await PhotoRater(library: library).rateAndMark(scan, stars: stars, context: JobContext(emit: { _ in }))
    }

    @Test func writesStarsAndTouchesNoAlbum() async throws {
        let library = FakeLibrary()
        for id in ["a", "b", "c"] { library.addPhoto(id, created: base) }
        let summary = try await rate(library, result([("a", -0.5, 0), ("b", -0.1, 0), ("c", 0.7, 0)]))
        #expect([library.rating("a"), library.rating("b"), library.rating("c")] == [1, 2, 5])
        #expect(summary.counts["rated"] == 3 && summary.counts["stars1"] == 1 && summary.counts["stars5"] == 1)
        #expect(library.addBatches.isEmpty)
    }

    @Test func olderThanNeverChangesARatingSetSinceTheScan() async throws {
        let library = FakeLibrary()
        library.addPhoto("a", created: base)
        library.setPhotoRating("a", 4)
        let summary = try await rate(library, result([("a", -0.9, 0)]))
        #expect(library.rating("a") == 4)
        #expect(summary.counts["rated"] == 0)
    }

    @Test func dateRangeOverwritesExistingStars() async throws {
        let library = FakeLibrary()
        library.addPhoto("a", created: base, rating: 1)
        library.addPhoto("b", created: base, rating: 5)
        library.addPhoto("same", created: base, rating: 4)
        let summary = try await rate(library, result([("a", 0.4, 1), ("b", -0.2, 5), ("same", 0.4, 4)], dateRange: true))
        #expect(library.rating("a") == 4 && library.rating("b") == 2 && library.rating("same") == 4)
        #expect(summary.counts["overwritten"] == 2 && summary.counts["rated"] == 2)
    }

    @Test func ratingsAreWrittenInBatchesOf200() async throws {
        let library = FakeLibrary()
        let photos = (0..<450).map { ("p\($0)", 0.4, 0) }
        for photo in photos { library.addPhoto(photo.0, created: base) }
        _ = try await rate(library, result(photos))
        #expect(library.ratingBatches.map(\.count) == [200, 200, 50])
    }
}

@MainActor
struct PhotoModelTests {
    private func model(_ library: FakeLibrary, _ analyzer: FakeAnalyzer) async throws -> AppModel {
        let model = try AppModel(dataDirectory: temporaryDirectory(), library: library, keepAwake: FakeKeepAwake(),
                                 settingsDebounce: .milliseconds(1), analyzer: analyzer)
        await model.launch()
        model.settings.update { $0.photos.cameraPhotosPerRun = 100 }
        return model
    }

    @Test func rateAndMarkMovesTheResumePointAndStartOverResetsIt() async throws {
        let library = FakeLibrary(), analyzer = FakeAnalyzer()
        let old = Date.now.addingTimeInterval(-400 * 86_400)
        for index in 0..<3 {
            library.addPhoto("p\(index)", created: old.addingTimeInterval(Double(index) * 3600))
            analyzer.camera("p\(index)", score: index == 0 ? -0.8 : 0.5)
        }
        let model = try await model(library, analyzer)
        await model.photos.scan()
        #expect(model.photos.photosToRate.count == 3)
        await model.photos.rateAndMark()
        #expect(model.settings.settings.photos.resumeAfter == old.addingTimeInterval(2 * 3600))
        #expect(library.rating("p0") == 1 && library.rating("p1") == 4)

        await model.photos.scan()
        #expect(model.photos.photosToRate.isEmpty)
        #expect(model.photos.notice?.hasPrefix("No more unrated photos") == true)

        library.setPhotoRating("p1", 0)
        model.photos.startOver()
        #expect(model.settings.settings.photos.resumeAfter == nil)
        await model.photos.scan()
        #expect(model.photos.photosToRate.map(\.id) == ["p1"])
    }

    @Test func invalidRangeDisablesScan() async throws {
        let model = try await model(FakeLibrary(), FakeAnalyzer())
        model.settings.update {
            $0.photos.scope.kind = .dateRange
            $0.photos.scope.from = "2026-10-31"
            $0.photos.scope.to = "2026-10-01"
        }
        #expect(!model.photos.canScan)
        #expect(model.photos.scopeError == PhotoScopeError.endBeforeStart.localizedDescription)
    }

    @Test func dateRangeRunWithNewThresholdsUpdatesStarsAndKeepsTheResumePoint() async throws {
        let library = FakeLibrary(), analyzer = FakeAnalyzer()
        let day = ISO8601DateFormatter().date(from: "2025-06-10T08:00:00Z")!
        library.addPhoto("p", created: day, rating: 4)
        analyzer.camera("p", score: 0.4)
        let model = try await model(library, analyzer)
        let resume = Date(timeIntervalSince1970: 1_000_000)
        model.settings.update {
            $0.photos.resumeAfter = resume
            $0.photos.starThresholds = [0.5, 0.6, 0.7, 0.8]
            $0.photos.scope.kind = .dateRange
            $0.photos.scope.from = "2025-06-09"
            $0.photos.scope.to = "2025-06-11"
        }
        await model.photos.scan()
        #expect(model.photos.scan?.alreadyRated == 1)
        await model.photos.rateAndMark()
        #expect(library.rating("p") == 1)
        #expect(model.settings.settings.photos.resumeAfter == resume)
    }

    @Test func adjustedStarsAreWrittenAndCountedLive() async throws {
        let library = FakeLibrary(), analyzer = FakeAnalyzer()
        let old = Date.now.addingTimeInterval(-400 * 86_400)
        library.addPhoto("good", created: old)
        library.addPhoto("bad", created: old.addingTimeInterval(3600))
        analyzer.camera("good", score: 0.7)
        analyzer.camera("bad", score: -0.8)
        let model = try await model(library, analyzer)
        await model.photos.scan()
        let good = try #require(model.photos.photosToRate.first { $0.id == "good" })
        let bad = try #require(model.photos.photosToRate.first { $0.id == "bad" })
        #expect(model.photos.starCounts[5] == 1 && model.photos.starCounts[1] == 1)

        model.photos.setStars(2, for: good)
        model.photos.setStars(4, for: bad)
        #expect(model.photos.isAdjusted(good) && model.photos.adjustedCount == 2)
        #expect(model.photos.starCounts[5] == 0 && model.photos.starCounts[2] == 1 && model.photos.starCounts[4] == 1)

        model.photos.setStars(4, for: bad)
        model.photos.setStars(1, for: bad)
        #expect(!model.photos.isAdjusted(bad) && model.photos.adjustedCount == 1)
        model.photos.setStars(4, for: bad)

        await model.photos.rateAndMark()
        #expect(library.rating("good") == 2 && library.rating("bad") == 4)
        #expect(model.photos.adjustedCount == 0)
        #expect(await eventually { model.runs.first?.counts["adjusted"] == 2 })
    }

    @Test func adjustmentsAreDroppedByANewScan() async throws {
        let library = FakeLibrary(), analyzer = FakeAnalyzer()
        library.addPhoto("p", created: Date.now.addingTimeInterval(-400 * 86_400))
        analyzer.camera("p", score: 0.7)
        let model = try await model(library, analyzer)
        await model.photos.scan()
        model.photos.setStars(1, for: try #require(model.photos.photosToRate.first))
        await model.photos.scan()
        #expect(model.photos.adjustedCount == 0)
    }

    @Test func autoRateRunsRoundsUntilNoUnratedPhotosAreLeft() async throws {
        let library = FakeLibrary(), analyzer = FakeAnalyzer()
        let old = Date.now.addingTimeInterval(-400 * 86_400)
        for index in 0..<25 {
            library.addPhoto("p\(index)", created: old.addingTimeInterval(Double(index) * 3600))
            analyzer.camera("p\(index)", score: index < 5 ? -0.8 : 0.5)
        }
        library.addPhoto("rated", created: old.addingTimeInterval(1800), rating: 3)
        analyzer.camera("rated", score: -0.8)
        let model = try await model(library, analyzer)
        model.settings.update { $0.photos.cameraPhotosPerRun = 10 }
        model.photos.autoRate = true
        await model.photos.scan()

        let tally = try #require(model.photos.autoTally)
        #expect(tally.rounds == 3 && tally.rated == 25)
        #expect(tally.starCounts == [1: 5, 2: 0, 3: 0, 4: 20, 5: 0])
        #expect(library.rating("p0") == 1 && library.rating("p24") == 4 && library.rating("rated") == 3)
        #expect(model.settings.settings.photos.resumeAfter == old.addingTimeInterval(24 * 3600))
        #expect(model.photos.scan == nil && !model.photos.isAutoRunning)
        #expect(model.photos.notice?.hasPrefix("Done: rated 25 photos in 3 rounds") == true)
        await model.refreshActivity()
        #expect(model.runs.count == 6)
    }

    @Test func autoRateStopsWhenAScanFails() async throws {
        let library = FakeLibrary(), analyzer = FakeAnalyzer()
        let old = Date.now.addingTimeInterval(-400 * 86_400)
        for index in 0..<10 {
            library.addPhoto("p\(index)", created: old.addingTimeInterval(Double(index) * 3600))
            analyzer.fail("p\(index)")
        }
        let model = try await model(library, analyzer)
        model.photos.autoRate = true
        await model.photos.scan()
        #expect(model.photos.autoTally?.rounds == 0)
        #expect(model.photos.notice?.contains("Stopped after 0 rounds") == true)
        #expect(model.settings.settings.photos.resumeAfter == nil)
    }

    @Test func autoRateIsIgnoredForADateRange() async throws {
        let library = FakeLibrary(), analyzer = FakeAnalyzer()
        library.addPhoto("p", created: ISO8601DateFormatter().date(from: "2025-06-10T08:00:00Z")!)
        analyzer.camera("p", score: 0.5)
        let model = try await model(library, analyzer)
        model.settings.update {
            $0.photos.scope.kind = .dateRange
            $0.photos.scope.from = "2025-06-09"
            $0.photos.scope.to = "2025-06-11"
        }
        model.photos.autoRate = true
        #expect(!model.photos.autoRateApplies)
        await model.photos.scan()
        #expect(model.photos.autoTally == nil && model.photos.photosToRate.map(\.id) == ["p"])
        #expect(library.rating("p") == 0)
    }

    @Test func togglingAutoRateClearsTheReviewTable() async throws {
        let library = FakeLibrary(), analyzer = FakeAnalyzer()
        library.addPhoto("p", created: Date.now.addingTimeInterval(-400 * 86_400))
        analyzer.camera("p", score: 0.5)
        let model = try await model(library, analyzer)
        await model.photos.scan()
        #expect(!model.photos.photosToRate.isEmpty)
        model.photos.autoRate = true
        #expect(model.photos.scan == nil)
    }
}
