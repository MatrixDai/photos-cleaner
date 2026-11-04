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

struct SimilarShotsTests {
    private let base = Date(timeIntervalSince1970: 1_500_000_000)

    private func groups(_ seconds: [Double], _ values: [Double?]) -> [[Int]] {
        SimilarShots.groups(dates: seconds.map { base.addingTimeInterval($0) }) { a, b in
            guard let x = values[a], let y = values[b] else { return nil }
            return abs(x - y)
        }
    }

    @Test func sequencesSplitWhereTheGapExceeds30Seconds() {
        let seconds: [Double?] = [100, 80, 51, 20, nil, -100, -110]
        let runs = SimilarShots.sequences(seconds) { $0.map { base.addingTimeInterval($0) } }
        #expect(runs.map { $0.map { $0 ?? 0 } } == [[100, 80, 51], [20], [0], [-100, -110]])
    }

    @Test func closeShotsWithin30SecondsAreGrouped() {
        #expect(groups([0, 10, 20], [0, 0.1, 0.25]) == [[0, 1, 2]])
    }

    @Test func similarPhotosMoreThan30SecondsApartAreNotCompared() {
        #expect(groups([0, 31], [0, 0]).isEmpty)
    }

    @Test func distancesAboveTheThresholdOrWithoutAPrintDoNotJoin() {
        #expect(groups([0, 5, 10], [0, 0.21, nil]).isEmpty)
    }

    @Test func chainGuardDropsMembersThatDriftFromTheMedoid() {
        let values = (0..<7).map { Double($0) * 0.15 }
        #expect(groups((0..<7).map { Double($0) }, values) == [[1, 2, 3, 4, 5]])
    }

    @Test func groupsAreCappedAt100Photos() {
        let found = groups((0..<150).map { Double($0) * 0.1 }, Array(repeating: 0, count: 150))
        #expect(found.map(\.count).sorted() == [50, 100])
    }
}

struct PhotoRatingRunTests {
    private let base = ISO8601DateFormatter().date(from: "2015-01-01T00:00:00Z")!
    private let thresholds = [-0.3, 0.0, 0.3, 0.6]

    private func at(_ hours: Double) -> Date { base.addingTimeInterval(hours * 3600) }

    private func run(_ library: FakeLibrary, _ analyzer: FakeAnalyzer, scope: RatingScope = .unrated,
                     album: String? = nil) async throws -> RatingTally {
        try await PhotoRatingRun(library: library, analyzer: analyzer, scope: scope, thresholds: thresholds, duplicatesAlbum: album)
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

struct DedupRunTests {
    private let base = ISO8601DateFormatter().date(from: "2015-01-01T00:00:00Z")!
    private let thresholds = [-0.3, 0.0, 0.3, 0.6]

    private func at(_ seconds: Double) -> Date { base.addingTimeInterval(seconds) }

    private func run(_ library: FakeLibrary, _ analyzer: FakeAnalyzer, scope: RatingScope = .unrated,
                     album: String?) async throws -> RatingTally {
        try await PhotoRatingRun(library: library, analyzer: analyzer, scope: scope, thresholds: thresholds, duplicatesAlbum: album)
            .run(context: JobContext(emit: { _ in }), report: { _ in })
    }

    private func burst(_ library: FakeLibrary, _ analyzer: FakeAnalyzer) {
        library.addPhoto("a", created: at(0))
        library.addPhoto("b", created: at(5))
        library.addPhoto("c", created: at(10))
        library.addPhoto("alone", created: at(500))
        analyzer.print("a", 0)
        analyzer.print("b", 0.1)
        analyzer.print("c", 5)
        for id in ["a", "b", "c", "alone"] { analyzer.score(id, -0.8) }
    }

    @Test func similarShotsGoToTheAlbumAndAreRatedLikeAnyPhoto() async throws {
        let library = FakeLibrary(), analyzer = FakeAnalyzer()
        let album = library.addAlbum("photo-duplicated")
        burst(library, analyzer)
        let tally = try await run(library, analyzer, album: album)
        #expect(library.albums[album]?.members == ["a", "b"])
        #expect(Set(analyzer.printed) == ["a", "b", "c"])
        #expect(tally.groups == 1 && tally.grouped == 2 && tally.addedToAlbum == 2)
        #expect(["a", "b", "c", "alone"].allSatisfy { library.rating($0) == 1 })
    }

    @Test func dedupOffComputesNoPrintsAndLeavesTheAlbumAlone() async throws {
        let library = FakeLibrary(), analyzer = FakeAnalyzer()
        let album = library.addAlbum("photo-duplicated", members: ["old1"])
        burst(library, analyzer)
        let tally = try await run(library, analyzer, album: nil)
        #expect(analyzer.printed.isEmpty && tally.groups == 0)
        #expect(library.albums[album]?.members == ["old1"])
    }

    @Test func aSequenceIsNeverSplitAcrossWrites() async throws {
        let library = FakeLibrary(), analyzer = FakeAnalyzer()
        let album = library.addAlbum("photo-duplicated")
        for index in 0..<30 { library.addPhoto("s\(index)", created: at(10_000 + Double(index))) }
        for index in 0..<5 { library.addPhoto("single\(index)", created: at(Double(index) * 1000)) }
        _ = try await run(library, analyzer, album: album)
        #expect(library.ratingBatches.map(\.count) == [30, 5])
    }

    @Test func reRateRemovesPhotosInTheRangeThatNoLongerGroup() async throws {
        let library = FakeLibrary(), analyzer = FakeAnalyzer()
        library.addPhoto("x", created: at(3600), rating: 2)
        library.addPhoto("y", created: at(-86_400), rating: 2)
        library.addPhoto("z", created: at(-86_390), rating: 2)
        let album = library.addAlbum("photo-duplicated", members: ["x", "y", "z"])
        let scope = try RatingScope.reRate(from: base, to: base, timeZone: TimeZone(identifier: "UTC")!)
        let tally = try await run(library, analyzer, scope: scope, album: album)
        #expect(library.albums[album]?.members == ["y", "z"])
        #expect(tally.removedFromAlbum == 1)
    }

    @Test func membersLeftAloneLeaveTheAlbum() async throws {
        let library = FakeLibrary(), analyzer = FakeAnalyzer()
        library.addPhoto("p", created: at(0), rating: 1)
        library.addPhoto("q", created: at(10), rating: 1)
        library.addPhoto("r", created: at(500), rating: 1)
        let album = library.addAlbum("photo-duplicated", members: ["p", "q", "r"])
        let tally = try await run(library, analyzer, album: album)
        #expect(tally.total == 0 && tally.removedFromAlbum == 1)
        #expect(library.albums[album]?.members == ["p", "q"])
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

    @Test func dedupNeedsTheAlbum() async throws {
        let model = try await model(FakeLibrary(), FakeAnalyzer())
        #expect(model.photos.dedup && model.photos.canRun)
        model.settings.update { $0.photos.albums.duplicated.id = nil }
        #expect(!model.photos.canRun && model.photos.scopeError?.contains("isn't set up") == true)
        model.photos.dedup = false
        #expect(model.photos.canRun)
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
