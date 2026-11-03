import Foundation
import Testing
@testable import CleanerCore

struct AlbumServiceTests {
    @Test func keepsAnAlbumFoundByID() async throws {
        let library = FakeLibrary()
        let id = library.addAlbum("video-to-delete")
        library.rename(id, to: "renamed in Photos")
        let resolved = try await AlbumService(library: library).resolve(AlbumRef(name: "video-to-delete", id: id))
        #expect(resolved.id == id)
        #expect(library.createdNames.isEmpty)
    }

    @Test func staleIDFallsBackToName() async throws {
        let library = FakeLibrary()
        let id = library.addAlbum("photo-duplicated")
        let resolved = try await AlbumService(library: library).resolve(AlbumRef(name: "photo-duplicated", id: "gone/L0/040"))
        #expect(resolved.id == id)
        #expect(library.createdNames.isEmpty)
    }

    @Test func missingAlbumIsCreated() async throws {
        let library = FakeLibrary()
        let resolved = try await AlbumService(library: library).resolve(AlbumRef(name: "photo-low-quality"))
        #expect(library.createdNames == ["photo-low-quality"])
        #expect(resolved.id.flatMap { library.albums[$0]?.title } == "photo-low-quality")
    }
}

struct JobRunnerTests {
    private func runner(_ keepAwake: FakeKeepAwake = FakeKeepAwake()) throws -> (JobRunner, RunLog) {
        let dir = temporaryDirectory()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let log = RunLog(fileURL: dir.appending(path: "runs.jsonl"))
        return (JobRunner(runLog: log, keepAwake: keepAwake), log)
    }

    private func collect(_ stream: AsyncStream<JobEvent>) async -> [JobEvent] {
        var events: [JobEvent] = []
        for await event in stream { events.append(event) }
        return events
    }

    @Test func secondJobIsRejectedWhileOneRuns() async throws {
        let (runner, _) = try runner()
        let gate = AsyncStream.makeStream(of: Void.self)
        let stream = try await runner.start(mode: .videos, name: "export") { _ in
            for await _ in gate.stream { break }
            return JobSummary()
        }
        await #expect(throws: JobRunnerError.busy(ActiveJob(mode: .videos, name: "export"))) {
            _ = try await runner.start(mode: .photos, name: "scan") { _ in JobSummary() }
        }
        gate.continuation.yield()
        _ = await collect(stream)
        #expect(await runner.active == nil)
        _ = await collect(try await runner.start(mode: .photos, name: "scan") { _ in JobSummary() })
    }

    @Test func reportsProgressThenOutcomeAndLogsTheRun() async throws {
        let keepAwake = FakeKeepAwake()
        let (runner, log) = try runner(keepAwake)
        let events = await collect(try await runner.start(mode: .photos, name: "scan", albumSnapshot: { ["photoDuplicated": 4] }) { context in
            #expect(keepAwake.held == 1)
            context.progress(1, of: 2)
            context.message("half way")
            return JobSummary(scope: "olderThan 90", counts: ["rated": 2])
        })
        let summary = JobSummary(scope: "olderThan 90", counts: ["rated": 2])
        #expect(events == [.progress(JobProgress(done: 1, total: 2)), .message("half way"), .finished(.completed(summary))])
        #expect(keepAwake.held == 0)
        #expect(keepAwake.total == 1)
        let record = try #require(await log.records().first)
        #expect(record.run == 1 && record.mode == .photos && record.task == "scan" && record.outcome == "completed")
        #expect(record.scope == "olderThan 90" && record.counts == ["rated": 2] && record.albums == ["photoDuplicated": 4])
    }

    @Test func cancelStopsTheJobAndIsLogged() async throws {
        let keepAwake = FakeKeepAwake()
        let (runner, log) = try runner(keepAwake)
        let stream = try await runner.start(mode: .videos, name: "export") { context in
            while true {
                try await Task.sleep(for: .milliseconds(5))
                try context.checkCancellation()
            }
        }
        await runner.cancel()
        let events = await collect(stream)
        #expect(events.last == .finished(.cancelled(nil)))
        #expect(keepAwake.held == 0)
        #expect(await log.records().first?.outcome == "cancelled")
    }

    @Test func failureIsReportedAndLogged() async throws {
        struct Boom: Error {}
        let (runner, log) = try runner()
        let events = await collect(try await runner.start(mode: .videos, name: "export") { _ in throw Boom() })
        guard case .finished(.failed) = events.last else { Issue.record("expected failure, got \(events)"); return }
        #expect(await log.records().first?.outcome == "failed")
    }
}

@MainActor
struct AppModelTests {
    private func model(_ library: FakeLibrary, dir: URL = temporaryDirectory()) throws -> AppModel {
        try AppModel(dataDirectory: dir, library: library, keepAwake: FakeKeepAwake(), settingsDebounce: .milliseconds(1))
    }

    @Test func launchRequestsAccessThenCreatesTheThreeAlbums() async throws {
        let library = FakeLibrary(status: .notDetermined, grantOnRequest: .authorized)
        let model = try model(library)
        await model.launch()
        #expect(model.hasFullAccess)
        #expect(Set(library.createdNames) == ["video-to-delete", "photo-low-quality", "photo-duplicated"])
        let stored = model.settings.settings
        for ref in [stored.videos.album, stored.photos.albums.lowQuality, stored.photos.albums.duplicated] {
            #expect(ref.id.flatMap { library.albums[$0]?.title } == ref.name)
        }
    }

    @Test(arguments: [LibraryAuthorization.denied, .limited, .restricted])
    func withoutFullAccessNothingIsWritten(_ status: LibraryAuthorization) async throws {
        let library = FakeLibrary(status: status)
        let model = try model(library)
        await model.launch()
        #expect(!model.hasFullAccess)
        #expect(library.createdNames.isEmpty)
    }

    @Test func checkAgainPicksUpAccessGrantedInSystemSettings() async throws {
        let library = FakeLibrary(status: .denied)
        let model = try model(library)
        await model.launch()
        library.setStatus(.authorized)
        await model.checkAccessAgain()
        #expect(model.hasFullAccess)
        #expect(library.createdNames.count == 3)
    }

    @Test func relaunchFindsAlbumsByIDEvenAfterRename() async throws {
        let library = FakeLibrary()
        let dir = temporaryDirectory()
        let first = try model(library, dir: dir)
        await first.launch()
        first.settings.flush()
        let id = try #require(first.settings.settings.videos.album.id)
        library.rename(id, to: "Videos to delete")

        let second = try model(library, dir: dir)
        await second.launch()
        #expect(library.createdNames.count == 3)
        #expect(second.settings.settings.videos.album.id == id)
    }

    @Test func deletedAlbumIsRecreated() async throws {
        let library = FakeLibrary()
        let model = try model(library)
        await model.launch()
        let id = try #require(model.settings.settings.photos.albums.duplicated.id)
        library.remove(id)
        await model.checkAccessAgain()
        #expect(library.createdNames.filter { $0 == "photo-duplicated" }.count == 2)
        #expect(model.settings.settings.photos.albums.duplicated.id != id)
    }

    @Test func aJobInOneModeBlocksBothModes() async throws {
        let model = try model(FakeLibrary())
        await model.launch()
        let gate = AsyncStream.makeStream(of: Void.self)
        #expect(await model.jobs.start(mode: .videos, name: "test job") { _ in
            for await _ in gate.stream { break }
            return JobSummary()
        })
        #expect(model.jobs.isBusy)
        #expect(model.jobs.active?.mode == .videos)
        #expect(await model.jobs.start(mode: .photos, name: "test job") { _ in JobSummary() } == false)
        #expect(await model.jobs.start(mode: .videos, name: "test job") { _ in JobSummary() } == false)

        gate.continuation.yield()
        #expect(await eventually { !model.jobs.isBusy })
        #expect(await model.jobs.start(mode: .photos, name: "test job") { _ in JobSummary() })
    }

    @Test func activityComparesAlbumSizesWithTheLastRun() async throws {
        let library = FakeLibrary()
        let model = try model(library)
        await model.launch()
        let videoID = try #require(model.settings.settings.videos.album.id)
        library.setSize(videoID, 50)
        #expect(await model.jobs.start(mode: .videos, name: "export") { _ in JobSummary(counts: ["marked": 50]) })
        #expect(await eventually { model.runs.count == 1 })
        #expect(model.runs.first?.albums["videoToDelete"] == 50)

        library.setSize(videoID, 12)
        await model.refreshActivity()
        let row = try #require(model.albumSummary.first { $0.role == .videoToDelete })
        #expect(row.current == 12 && row.atLastRun == 50 && row.change == -38)
    }

    @Test func resetKeepsAlbumsResolved() async throws {
        let library = FakeLibrary()
        let model = try model(library)
        await model.launch()
        model.settings.update { $0.videos.olderThanDays = 7 }
        await model.resetAllSettings()
        #expect(model.settings.settings.videos.olderThanDays == 90)
        #expect(model.settings.settings.videos.album.id != nil)
        #expect(library.createdNames.count == 3)
    }
}

struct InvariantTests {
    @Test func noCodeDeletesFromPhotos() throws {
        let sources = URL(filePath: #filePath).deletingLastPathComponent().appending(path: "../../Sources").standardizedFileURL
        let files = try #require(FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil))
            .compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
        #expect(!files.isEmpty)
        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            for call in ["deleteAssets", "deleteAssetCollections", "deleteCollectionLists"] {
                #expect(!text.contains(call), "\(file.lastPathComponent) calls \(call)")
            }
        }
    }
}
