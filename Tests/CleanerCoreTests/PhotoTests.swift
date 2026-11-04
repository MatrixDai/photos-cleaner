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

struct RatingScopeTests {
    private let shanghai = TimeZone(identifier: "Asia/Shanghai")!
    private func date(_ text: String) -> Date { ISO8601DateFormatter().date(from: text)! }

    @Test func unratedHasNoDateBounds() {
        #expect(RatingScope.unrated.query == PhotoQuery(range: nil, unratedOnly: true))
        #expect(RatingScope.unrated.query.contains(nil))
    }

    @Test func reRateRunsFromMidnightToMidnightInTheTimeZone() throws {
        let scope = try RatingScope.reRate(from: date("2026-10-01T09:00:00+08:00"), to: date("2026-10-31T23:00:00+08:00"), timeZone: shanghai)
        let query = scope.query
        #expect(query.range == date("2026-09-30T16:00:00Z")..<date("2026-10-31T16:00:00Z"))
        #expect(!query.unratedOnly)
        #expect(query.contains(date("2026-10-01T00:00:00+08:00")))
        #expect(query.contains(date("2026-10-31T23:59:59+08:00")))
        #expect(!query.contains(date("2026-11-01T00:00:00+08:00")))
        #expect(!query.contains(nil))
    }

    @Test func singleDayAndReversedRange() throws {
        let day = date("2026-10-01T12:00:00+08:00")
        #expect(try RatingScope.reRate(from: day, to: day, timeZone: shanghai).query.range?.lowerBound == date("2026-09-30T16:00:00Z"))
        #expect(throws: RatingScopeError.endBeforeStart) {
            try RatingScope.reRate(from: day, to: day.addingTimeInterval(-86_400), timeZone: shanghai)
        }
    }
}

struct PhotoRatingRunTests {
    private let base = ISO8601DateFormatter().date(from: "2015-01-01T00:00:00Z")!
    private let thresholds = [-0.3, 0.0, 0.3, 0.6]

    private func at(_ hours: Double) -> Date { base.addingTimeInterval(hours * 3600) }

    private func run(_ library: FakeLibrary, _ analyzer: FakeAnalyzer, scope: RatingScope = .unrated) async throws -> RatingTally {
        try await PhotoRatingRun(library: library, analyzer: analyzer, scope: scope, thresholds: thresholds)
            .run(context: JobContext(emit: { _ in }), report: { _ in })
    }

    @Test func ratesUnratedPhotosNewestFirstAndSkipsScreenshots() async throws {
        let library = FakeLibrary(), analyzer = FakeAnalyzer()
        for index in 0..<8 {
            library.addPhoto("p\(index)", created: at(Double(index)))
            analyzer.score("p\(index)", index < 2 ? -0.8 : 0.4)
        }
        library.addPhoto("kept", created: at(10), rating: 3)
        library.addPhoto("shot", created: at(11), screenshot: true)
        let tally = try await run(library, analyzer)

        #expect(Set(analyzer.calls.prefix(4)) == ["p7", "p6", "p5", "p4"])
        #expect(!analyzer.calls.contains("shot") && !analyzer.calls.contains("kept"))
        #expect(library.rating("p0") == 1 && library.rating("p7") == 4 && library.rating("kept") == 3 && library.rating("shot") == 0)
        #expect(tally.stars == [1: 2, 2: 0, 3: 0, 4: 6, 5: 0])
        #expect(tally.total == 9 && tally.processed == 9 && tally.screenshots == 1 && tally.written == 8)
        #expect(tally.currentDate == at(0))
    }

    @Test func starsAreWrittenInBatchesOf20() async throws {
        let library = FakeLibrary(), analyzer = FakeAnalyzer()
        for index in 0..<45 { library.addPhoto("p\(index)", created: at(Double(index))) }
        _ = try await run(library, analyzer)
        #expect(library.ratingBatches.map(\.count) == [20, 20, 5])
    }

    @Test func aSecondRunFindsNothingLeft() async throws {
        let library = FakeLibrary(), analyzer = FakeAnalyzer()
        library.addPhoto("p", created: at(0))
        _ = try await run(library, analyzer)
        let second = try await run(library, analyzer)
        #expect(second.total == 0 && analyzer.calls == ["p"])
    }

    @Test func aPhotoRatedByHandDuringTheRunIsLeftAlone() async throws {
        let library = FakeLibrary(), analyzer = FakeAnalyzer()
        library.addPhoto("p", created: at(0))
        analyzer.score("p", -0.8)
        analyzer.onScore = { _ in library.setPhotoRating("p", 5) }
        let tally = try await run(library, analyzer)
        #expect(library.rating("p") == 5 && tally.written == 0 && tally.rated == 0)
    }

    @Test func reRateOverwritesOnlyInsideTheRange() async throws {
        let library = FakeLibrary(), analyzer = FakeAnalyzer()
        library.addPhoto("before", created: at(-30), rating: 5)
        library.addPhoto("inside", created: at(1), rating: 5)
        library.addPhoto("same", created: at(2), rating: 4)
        library.addPhoto("new", created: at(3))
        for id in ["before", "inside", "same", "new"] { analyzer.score(id, 0.4) }
        let scope = try RatingScope.reRate(from: base, to: base, timeZone: TimeZone(identifier: "UTC")!)
        let tally = try await run(library, analyzer, scope: scope)
        #expect(library.rating("before") == 5 && library.rating("inside") == 4 && library.rating("new") == 4)
        #expect(tally.rated == 3 && tally.written == 2 && tally.overwritten == 1)
    }

    @Test func failuresStayUnratedAndAreRetriedNextRun() async throws {
        let library = FakeLibrary(), analyzer = FakeAnalyzer()
        for index in 0..<5 { library.addPhoto("p\(index)", created: at(Double(index))) }
        analyzer.fail("p2")
        let first = try await run(library, analyzer)
        #expect(first.failed == 1 && first.rated == 4 && library.rating("p2") == 0)

        analyzer.heal("p2")
        let second = try await run(library, analyzer)
        #expect(second.total == 1 && library.rating("p2") == 3)
    }

    @Test func failingOnEveryPhotoAbortsTheRun() async throws {
        let library = FakeLibrary(), analyzer = FakeAnalyzer()
        for index in 0..<20 {
            library.addPhoto("p\(index)", created: at(Double(index)))
            analyzer.fail("p\(index)")
        }
        await #expect(throws: PhotoRatingError.self) { try await run(library, analyzer) }
        #expect(analyzer.calls.count == PhotoRatingRun.abortAfterFailures)
    }

    @Test func cancellingKeepsTheStarsAlreadyScored() async throws {
        let library = FakeLibrary(), analyzer = FakeAnalyzer()
        for index in 0..<40 { library.addPhoto("p\(index)", created: at(Double(index))) }
        let task = LockedValue<Task<RatingTally, any Error>?>(nil)
        analyzer.onScore = { id in if id == "p27" { task.get()?.cancel() } }
        let started = Task { try await run(library, analyzer) }
        task.set(started)
        let tally = try await started.value
        #expect(tally.rated == 12 && tally.written == 12)
        #expect(library.rating("p39") == 3 && library.rating("p28") == 3 && library.rating("p27") == 0)
    }
}

@MainActor
struct PhotoModelTests {
    private func model(_ library: FakeLibrary, _ analyzer: FakeAnalyzer) async throws -> AppModel {
        let model = try AppModel(dataDirectory: temporaryDirectory(), library: library, keepAwake: FakeKeepAwake(),
                                 settingsDebounce: .milliseconds(1), analyzer: analyzer)
        await model.launch()
        return model
    }

    @Test func runShowsTheTallyAndLogsTheRun() async throws {
        let library = FakeLibrary(), analyzer = FakeAnalyzer()
        library.addPhoto("good", created: .now.addingTimeInterval(-3600))
        library.addPhoto("bad", created: .now.addingTimeInterval(-7200))
        analyzer.score("good", 0.7)
        analyzer.score("bad", -0.8)
        let model = try await model(library, analyzer)
        await model.photos.run()

        #expect(model.photos.tally?.stars[5] == 1 && model.photos.tally?.stars[1] == 1)
        #expect(model.photos.notice?.hasPrefix("Rated 2 photos") == true)
        await model.refreshActivity()
        #expect(model.runs.first?.counts["rated"] == 2 && model.runs.first?.counts["stars5"] == 1)

        await model.photos.run()
        #expect(model.photos.notice == "Every photo already has stars.")
    }

    @Test func thresholdsFromSettingsAreUsed() async throws {
        let library = FakeLibrary(), analyzer = FakeAnalyzer()
        library.addPhoto("p", created: .now)
        analyzer.score("p", 0.4)
        let model = try await model(library, analyzer)
        model.settings.update { $0.photos.starThresholds = [0.5, 0.6, 0.7, 0.8] }
        await model.photos.run()
        #expect(library.rating("p") == 1)
    }

    @Test func reRateDefaultsToTheLastMonthAndRejectsAReversedRange() async throws {
        let model = try await model(FakeLibrary(), FakeAnalyzer())
        let days = Calendar.current.dateComponents([.day], from: model.photos.reRateFrom, to: model.photos.reRateTo).day ?? 0
        #expect((28...31).contains(days))
        model.photos.reRate = true
        #expect(model.photos.canRun)
        model.photos.reRateFrom = model.photos.reRateTo.addingTimeInterval(86_400)
        #expect(!model.photos.canRun)
        #expect(model.photos.scopeError == RatingScopeError.endBeforeStart.localizedDescription)
        model.photos.reRate = false
        #expect(model.photos.canRun)
    }
}
