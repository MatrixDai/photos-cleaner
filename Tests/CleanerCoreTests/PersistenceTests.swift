import Foundation
import Testing
@testable import CleanerCore

struct AppSettingsTests {
    private func decode(_ json: String) throws -> AppSettings {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(AppSettings.self, from: Data(json.utf8))
    }

    @Test func emptyObjectGivesDefaults() throws {
        #expect(try decode("{}") == AppSettings())
    }

    @Test func missingFieldsKeepTheRest() throws {
        let settings = try decode(#"{"videos": {"olderThanDays": 30}, "photos": {"cameraPhotosPerRun": 500}}"#)
        #expect(settings.videos.olderThanDays == 30)
        #expect(settings.videos.album == AlbumRef(name: "video-to-delete"))
        #expect(settings.photos.cameraPhotosPerRun == 500)
        #expect(settings.photos.starThresholds == [-0.3, 0.0, 0.3, 0.6])
    }

    @Test func malformedFieldFallsBackAlone() throws {
        let settings = try decode(#"{"videos": {"olderThanDays": "soon", "parallelExports": 3}}"#)
        #expect(settings.videos.olderThanDays == 90)
        #expect(settings.videos.parallelExports == 3)
    }

    @Test func outOfRangeValuesAreClamped() throws {
        let settings = try decode(#"{"videos": {"olderThanDays": 0, "parallelExports": 9}, "photos": {"cameraPhotosPerRun": 5}}"#)
        #expect(settings.videos.olderThanDays == 1)
        #expect(settings.videos.parallelExports == 4)
        #expect(settings.photos.cameraPhotosPerRun == 100)
    }

    @Test(arguments: ["[0.1, 0.2]", "[0.6, 0.3, 0.0, -0.3]"])
    func invalidThresholdsFallBack(_ thresholds: String) throws {
        let settings = try decode(#"{"photos": {"starThresholds": \#(thresholds)}}"#)
        #expect(settings.photos.starThresholds == [-0.3, 0.0, 0.3, 0.6])
    }

    @Test func roundTrip() throws {
        var settings = AppSettings()
        settings.photos.scope.kind = .dateRange
        settings.photos.scope.from = "2026-10-01"
        settings.photos.scope.to = "2026-10-31"
        settings.photos.resumeAfter = Date(timeIntervalSince1970: 1_700_000_000)
        settings.videos.album.id = "X/L0/040"
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let json = String(decoding: try encoder.encode(settings), as: UTF8.self)
        #expect(try decode(json) == settings)
    }
}

@MainActor
struct SettingsStoreTests {
    @Test func createsMissingDirectoryAndStartsWithDefaults() throws {
        let dir = temporaryDirectory().appending(path: "nested/.photos-cleaner")
        let store = try SettingsStore(directory: dir)
        #expect(FileManager.default.fileExists(atPath: dir.path))
        #expect(store.settings == AppSettings())
        #expect(store.recoveredCorruptFile == nil)
    }

    @Test func sectionsSurviveRelaunchIndependently() throws {
        let dir = temporaryDirectory()
        let first = try SettingsStore(directory: dir)
        first.update { $0.videos.olderThanDays = 30 }
        first.flush()

        let second = try SettingsStore(directory: dir)
        second.update { $0.photos.cameraPhotosPerRun = 2_000 }
        second.flush()

        let third = try SettingsStore(directory: dir)
        #expect(third.settings.videos.olderThanDays == 30)
        #expect(third.settings.photos.cameraPhotosPerRun == 2_000)
    }

    @Test func corruptFileIsKeptAsideAndDefaultsLoad() throws {
        let dir = temporaryDirectory()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("{ not json".utf8).write(to: dir.appending(path: "settings.json"))

        let store = try SettingsStore(directory: dir)
        #expect(store.settings == AppSettings())
        let corrupt = try #require(store.recoveredCorruptFile)
        #expect(corrupt.lastPathComponent.hasPrefix("settings.corrupt-"))
        #expect(try String(contentsOf: corrupt, encoding: .utf8) == "{ not json")
        #expect(!FileManager.default.fileExists(atPath: dir.appending(path: "settings.json").path))
    }

    @Test func savesAreDebounced() async throws {
        let dir = temporaryDirectory()
        let store = try SettingsStore(directory: dir, debounce: .milliseconds(200))
        for days in 10...15 { store.update { $0.videos.olderThanDays = days } }
        #expect(!FileManager.default.fileExists(atPath: store.fileURL.path))

        let saved = await eventually { (try? SettingsStore(directory: dir).settings.videos.olderThanDays) == 15 }
        #expect(saved)
    }

    @Test func unchangedUpdateDoesNotWrite() async throws {
        let dir = temporaryDirectory()
        let store = try SettingsStore(directory: dir, debounce: .milliseconds(10))
        store.update { $0.videos.olderThanDays = 90 }
        try await Task.sleep(for: .milliseconds(100))
        #expect(!FileManager.default.fileExists(atPath: store.fileURL.path))
    }

    @Test func resetRestoresDefaults() throws {
        let store = try SettingsStore(directory: temporaryDirectory())
        store.update { $0.photos.scope.kind = .dateRange }
        store.reset()
        #expect(store.settings == AppSettings())
    }
}

struct RunLogTests {
    private func record(_ run: Int, outcome: String = "completed") -> RunRecord {
        RunRecord(run: run, mode: .photos, task: "scan", start: Date(timeIntervalSince1970: 1_700_000_000),
                  end: Date(timeIntervalSince1970: 1_700_000_060), outcome: outcome, counts: ["rated": run])
    }

    @Test func appendsAndReadsBack() async throws {
        let dir = temporaryDirectory()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let log = RunLog(fileURL: dir.appending(path: "runs.jsonl"))
        #expect(await log.records().isEmpty)
        #expect(await log.nextRunID() == 1)
        try await log.append(record(1))
        try await log.append(record(2, outcome: "cancelled"))
        #expect(await log.records() == [record(1), record(2, outcome: "cancelled")])
        #expect(await log.nextRunID() == 3)
    }

    @Test func cutOffLineIsSkippedAndNotJoinedToTheNext() async throws {
        let dir = temporaryDirectory()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appending(path: "runs.jsonl")
        let log = RunLog(fileURL: url)
        try await log.append(record(1))
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(#"{"run":2,"mode":"pho"#.utf8))
        try handle.close()

        #expect(await log.records() == [record(1)])
        try await log.append(record(3))
        #expect(await log.records() == [record(1), record(3)])
    }

    @Test func missingOptionalFieldsGetDefaults() async throws {
        let dir = temporaryDirectory()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appending(path: "runs.jsonl")
        try Data(#"{"run":7,"mode":"videos","task":"export","start":"2026-11-03T10:00:00Z","end":"2026-11-03T10:05:00Z"}"#.utf8 + [10]).write(to: url)
        let records = await RunLog(fileURL: url).records()
        #expect(records.count == 1)
        #expect(records.first?.outcome == "unknown")
        #expect(records.first?.counts == [:])
    }
}
