import Foundation
import Testing
@testable import CleanerCore

struct NamingEngineTests {
    private let template = NamingEngine.defaultTemplate

    @Test func defaultTemplate() {
        #expect(NamingEngine.render(template, day: "2026-02-28", filename: "IMG_0579.MOV") == "2026/2026-02-28 IMG_0579.MOV")
    }

    @Test func allTokens() {
        #expect(NamingEngine.render("{yyyy}/{MM}/{dd}-{basename}.{ext}", day: "2026-02-28", filename: "IMG_0579.MOV")
            == "2026/02/28-IMG_0579.MOV")
    }

    @Test func slashAndColonInTheFilenameBecomeUnderscores() {
        #expect(NamingEngine.render(template, day: "2026-02-28", filename: "trip/day:1.mov") == "2026/2026-02-28 trip_day_1.mov")
    }

    @Test func namesAreNormalizedToNFC() {
        let decomposed = "Cafe\u{301}.mov"
        let rendered = NamingEngine.render(template, day: "2026-02-28", filename: decomposed)
        #expect(rendered == "2026/2026-02-28 Caf\u{e9}.mov")
        #expect(rendered.unicodeScalars.count == "2026/2026-02-28 Caf\u{e9}.mov".unicodeScalars.count)
    }

    @Test func componentsAreTrimmed() {
        #expect(NamingEngine.render(" {yyyy} / {filename} ", day: "2026-02-28", filename: "  IMG_1.MOV ") == "2026/IMG_1.MOV")
    }

    @Test(arguments: ["../{filename}", "/{filename}", "./{filename}", "{yyyy}/../../{filename}"])
    func pathsNeverLeaveTheExportFolder(_ template: String) {
        let rendered = NamingEngine.render(template, day: "2026-02-28", filename: "IMG_1.MOV")
        #expect(!rendered.hasPrefix("/"))
        #expect(!rendered.split(separator: "/").contains(".."))
        #expect(rendered.hasSuffix("IMG_1.MOV"))
    }

    @Test func missingExtensionIsAppended() {
        #expect(NamingEngine.render("{yyyy}/{basename}", day: "2026-02-28", filename: "IMG_1.MOV") == "2026/IMG_1.MOV")
    }

    @Test func missingFilename() {
        #expect(NamingEngine.render(template, day: "2026-02-28", filename: nil) == "2026/2026-02-28 video.mov")
    }

    @Test func editedAndCollisionSuffixesGoBeforeTheExtension() {
        #expect(NamingEngine.edited("2026/2026-02-28 IMG_1.MOV") == "2026/2026-02-28 IMG_1 (edited).MOV")
        #expect(NamingEngine.numbered("2026/2026-02-28 IMG_1.MOV", 2) == "2026/2026-02-28 IMG_1 (2).MOV")
        #expect(NamingEngine.numbered("2026/noext", 3) == "2026/noext (3)")
    }
}

struct CaptureDateResolverTests {
    private let shanghai = TimeZone(identifier: "Asia/Shanghai")!
    private let utc = TimeZone(identifier: "UTC")!
    private let lateUTC = ISO8601DateFormatter().date(from: "2026-02-28T15:30:00Z")!

    @Test func quickTimeOffsetGivesTheLocalRecordingDay() {
        let metadata = VideoMetadataDates(quickTime: "2026-02-28T23:30:00+0800")
        #expect(CaptureDateResolver.resolve(metadata, photosDate: lateUTC, timeZone: utc) == CaptureDate(day: "2026-02-28", source: .quicktime))
    }

    @Test func unparseableQuickTimeFallsBackToAVAsset() {
        let metadata = VideoMetadataDates(quickTime: "Feb 28", assetCreationString: "2026-02-27T10:00:00-0500")
        #expect(CaptureDateResolver.resolve(metadata, photosDate: lateUTC) == CaptureDate(day: "2026-02-27", source: .avasset))
    }

    @Test func avAssetDateUsesTheSystemTimeZone() {
        let metadata = VideoMetadataDates(assetCreationDate: lateUTC)
        #expect(CaptureDateResolver.resolve(metadata, photosDate: nil, timeZone: shanghai) == CaptureDate(day: "2026-02-28", source: .avasset))
    }

    @Test func noMetadataFallsBackToPhotosInTheSystemTimeZone() {
        let date = ISO8601DateFormatter().date(from: "2026-02-28T16:30:00Z")!
        #expect(CaptureDateResolver.resolve(VideoMetadataDates(), photosDate: date, timeZone: shanghai) == CaptureDate(day: "2026-03-01", source: .photos))
        #expect(CaptureDateResolver.resolve(VideoMetadataDates(), photosDate: date, timeZone: utc) == CaptureDate(day: "2026-02-28", source: .photos))
    }

    @Test func noDateAtAll() {
        #expect(CaptureDateResolver.resolve(VideoMetadataDates(), photosDate: nil).day == "0000-00-00")
    }
}

struct ExportFolderTests {
    private func folder(_ files: [String: Data]) throws -> URL {
        let root = temporaryDirectory()
        for (path, data) in files {
            let url = root.appending(path: path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url)
        }
        return root
    }

    @Test func findsIdenticalContentUnderAnotherName() async throws {
        let content = randomData()
        let root = try folder(["old/icloudpd/VID_1.mov": content])
        let index = ExportFolder(root: root)
        let found = try await index.duplicate(size: content.count, sha256: sha256(content))
        #expect(found?.lastPathComponent == "VID_1.mov")
    }

    @Test func sameSizeDifferentContentIsNotADuplicate() async throws {
        let root = try folder(["a.mov": randomData(5_000)])
        let other = randomData(5_000)
        #expect(try await ExportFolder(root: root).duplicate(size: other.count, sha256: sha256(other)) == nil)
    }

    @Test func differentSizeIsNeverADuplicate() async throws {
        let content = randomData(5_000)
        let root = try folder(["a.mov": content])
        #expect(try await ExportFolder(root: root).duplicate(size: 4_999, sha256: sha256(content)) == nil)
    }

    @Test func hiddenAndTemporaryFilesAreIgnored() async throws {
        let content = randomData()
        let root = try folder([".photoscleaner-tmp/x.mov": content, ".DS_Store": content])
        let index = ExportFolder(root: root)
        #expect(await index.fileCount == 0)
        #expect(try await index.duplicate(size: content.count, sha256: sha256(content)) == nil)
    }

    @Test func placeNeverOverwrites() async throws {
        let root = try folder(["2026/2026-02-28 IMG_1.MOV": Data("first".utf8)])
        let index = ExportFolder(root: root)
        let temp = root.appending(path: "incoming.tmp")
        try Data("second".utf8).write(to: temp)
        let placed = try await index.place(temp, at: "2026/2026-02-28 IMG_1.MOV", size: 6, sha256: sha256(Data("second".utf8)))
        #expect(placed.lastPathComponent == "2026-02-28 IMG_1 (2).MOV")
        #expect(try String(contentsOf: root.appending(path: "2026/2026-02-28 IMG_1.MOV"), encoding: .utf8) == "first")
    }

    @Test func placeRefusesWhenTheRootIsGone() async throws {
        let root = try folder(["keep.txt": Data("x".utf8)])
        let index = ExportFolder(root: root)
        let temp = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try Data("video".utf8).write(to: temp)
        try FileManager.default.removeItem(at: root)
        await #expect(throws: (any Error).self) {
            _ = try await index.place(temp, at: "2026/a.mov", size: 5, sha256: "")
        }
        #expect(!FileManager.default.fileExists(atPath: root.path))
    }
}

struct WritableCheckTests {
    @Test func missingFolderWillBeCreated() {
        #expect(WritableCheck.check(temporaryDirectory()) == .willBeCreated)
    }

    @Test func writableFolderLeavesNoProbeBehind() throws {
        let dir = temporaryDirectory()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        #expect(WritableCheck.check(dir) == .writable)
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path).isEmpty)
    }

    @Test func readOnlyFolderAndFileAreNotWritable() throws {
        let dir = temporaryDirectory()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appending(path: "file")
        try Data().write(to: file)
        guard case .notWritable = WritableCheck.check(file) else { Issue.record("a file is not a folder"); return }
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: dir.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.path) }
        guard case .notWritable = WritableCheck.check(dir) else { Issue.record("read-only folder reported writable"); return }
    }

    @Test func staleTemporaryFilesAreRemoved() throws {
        let dir = temporaryDirectory()
        let temp = dir.appending(path: WritableCheck.tempFolderName)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        let old = temp.appending(path: "old.mov")
        let fresh = temp.appending(path: "fresh.mov")
        try Data().write(to: old)
        try Data().write(to: fresh)
        try FileManager.default.setAttributes([.modificationDate: Date.now.addingTimeInterval(-25 * 3600)], ofItemAtPath: old.path)
        WritableCheck.removeStaleTemporaryFiles(in: dir)
        #expect(!FileManager.default.fileExists(atPath: old.path))
        #expect(FileManager.default.fileExists(atPath: fresh.path))
    }
}

struct VideoExporterTests {
    private let utc = TimeZone(identifier: "UTC")!
    private let now = ISO8601DateFormatter().date(from: "2026-11-03T12:00:00Z")!

    private func day(_ string: String) -> Date {
        ISO8601DateFormatter().date(from: string + "T10:00:00Z")!
    }

    private func setup() -> (FakeLibrary, String, URL) {
        let library = FakeLibrary()
        let album = library.addAlbum("video-to-delete")
        return (library, album, temporaryDirectory().appending(path: "Videos"))
    }

    private func run(_ library: FakeLibrary, album: String, folder: URL, parallel: Int = 2) async throws -> (JobSummary, [VideoRow]) {
        let exporter = VideoExporter(library: library, retryDelays: [.zero, .zero, .zero], markBatch: 10, timeZone: utc)
        let plan = VideoExportPlan(folder: folder, template: NamingEngine.defaultTemplate, parallel: parallel, albumID: album,
                                   cutoff: now.addingTimeInterval(-90 * 86_400), olderThanDays: 90)
        let rows = LockedValue<[VideoRow]>([])
        let summary = try await exporter.run(plan, context: JobContext(emit: { _ in })) { row in rows.set(rows.get() + [row]) }
        return (summary, rows.get())
    }

    private func files(_ folder: URL) throws -> [String: Data] {
        var out: [String: Data] = [:]
        let enumerator = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles])
        while let url = enumerator?.nextObject() as? URL {
            guard (try url.resourceValues(forKeys: [.isRegularFileKey])).isRegularFile == true else { continue }
            out[String(url.standardizedFileURL.path.dropFirst(folder.standardizedFileURL.path.count + 1))] = try Data(contentsOf: url)
        }
        return out
    }

    @Test func exportsTwentyVideosVerifiedAndMarkedInBatchesOfTen() async throws {
        let (library, album, folder) = setup()
        var contents: [String: Data] = [:]
        for index in 1...20 {
            let data = randomData(3_000 + index)
            contents[String(format: "2025/2025-01-%02d IMG_%04d.MOV", index, index)] = data
            library.addVideo("v\(index)", created: day(String(format: "2025-01-%02d", index)), filename: String(format: "IMG_%04d.MOV", index), content: data)
        }
        let (summary, _) = try await run(library, album: album, folder: folder)
        #expect(summary.counts["exported"] == 20 && summary.counts["marked"] == 20 && summary.counts["failed"] == 0)
        let written = try files(folder)
        #expect(Set(written.keys) == Set(contents.keys))
        for (path, data) in contents { #expect(written[path].map(sha256) == sha256(data)) }
        #expect(library.albums[album]?.members.count == 20)
        #expect(library.addBatches.map(\.count) == [10, 10])
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.appending(path: ".photoscleaner-tmp").path).isEmpty)
    }

    @Test func editedVersionIsExportedAlongsideTheOriginal() async throws {
        let (library, album, folder) = setup()
        library.addVideo("v1", created: day("2025-03-01"), filename: "IMG_0001.MOV", content: randomData(), edited: randomData(4_000))
        _ = try await run(library, album: album, folder: folder)
        #expect(Set(try files(folder).keys) == ["2025/2025-03-01 IMG_0001.MOV", "2025/2025-03-01 IMG_0001 (edited).MOV"])
        #expect(library.albums[album]?.members == ["v1"])
    }

    @Test func videoAlreadyPresentUnderAnotherNameIsNotCopiedAgain() async throws {
        let (library, album, folder) = setup()
        let content = randomData()
        try FileManager.default.createDirectory(at: folder.appending(path: "icloudpd"), withIntermediateDirectories: true)
        try content.write(to: folder.appending(path: "icloudpd/VID_OLD.mov"))
        library.addVideo("v1", created: day("2025-03-01"), content: content)
        let (summary, rows) = try await run(library, album: album, folder: folder)
        #expect(summary.counts["alreadyLocal"] == 1 && summary.counts["marked"] == 1)
        #expect(Set(try files(folder).keys) == ["icloudpd/VID_OLD.mov"])
        #expect(rows.last?.status == .alreadyLocal && rows.last?.file == "icloudpd/VID_OLD.mov")
    }

    @Test func sameNameDifferentContentGetsASuffix() async throws {
        let (library, album, folder) = setup()
        library.addVideo("v1", created: day("2025-03-01"), content: randomData(3_000))
        library.addVideo("v2", created: day("2025-03-01").addingTimeInterval(60), content: randomData(3_100))
        _ = try await run(library, album: album, folder: folder, parallel: 1)
        #expect(Set(try files(folder).keys) == ["2025/2025-03-01 IMG_0001.MOV", "2025/2025-03-01 IMG_0001 (2).MOV"])
    }

    @Test func twoAssetsWithIdenticalContentShareOneFile() async throws {
        let (library, album, folder) = setup()
        let content = randomData()
        library.addVideo("v1", created: day("2025-03-01"), content: content)
        library.addVideo("v2", created: day("2025-03-02"), filename: "copy.MOV", content: content)
        _ = try await run(library, album: album, folder: folder, parallel: 1)
        #expect(try files(folder).count == 1)
        #expect(library.albums[album]?.members == ["v1", "v2"])
    }

    @Test func rerunExportsNothingNew() async throws {
        let (library, album, folder) = setup()
        library.addVideo("v1", created: day("2025-03-01"), content: randomData())
        _ = try await run(library, album: album, folder: folder)
        let downloads = library.downloads.count
        let (summary, _) = try await run(library, album: album, folder: folder)
        #expect(summary.counts["videos"] == 0)
        #expect(library.downloads.count == downloads)
    }

    @Test func keptVideosAreSkippedAndLeaveTheAlbum() async throws {
        let (library, album, folder) = setup()
        library.addVideo("v1", created: day("2025-03-01"), content: randomData())
        library.addVideo("v2", created: day("2025-03-02"), rating: 3, content: randomData())
        _ = try await run(library, album: album, folder: folder)
        #expect(library.albums[album]?.members == ["v1"])
        library.setRating("v1", 4)
        let (summary, _) = try await run(library, album: album, folder: folder)
        #expect(summary.counts["keptRemoved"] == 1)
        #expect(library.albums[album]?.members.isEmpty == true)
        #expect(!library.downloads.contains("v2#original"))
    }

    @Test func downloadErrorsAreRetriedThreeTimes() async throws {
        let (library, album, folder) = setup()
        library.addVideo("v1", created: day("2025-03-01"), content: randomData(), failures: 3)
        let (summary, _) = try await run(library, album: album, folder: folder)
        #expect(summary.counts["exported"] == 1)
        #expect(library.downloads.filter { $0 == "v1#original" }.count == 4)
    }

    @Test func aVideoThatKeepsFailingIsNotMarkedAndIsRetriedNextRun() async throws {
        let (library, album, folder) = setup()
        library.addVideo("v1", created: day("2025-03-01"), content: randomData(), failures: 4)
        library.addVideo("v2", created: day("2025-03-02"), content: randomData())
        let (summary, rows) = try await run(library, album: album, folder: folder)
        #expect(summary.counts["failed"] == 1 && summary.counts["exported"] == 1)
        #expect(library.albums[album]?.members == ["v2"])
        guard case .failed = rows.last(where: { $0.id == "v1" })?.status else { Issue.record("v1 should fail"); return }
        #expect(try files(folder).count == 1)

        let (second, _) = try await run(library, album: album, folder: folder)
        #expect(second.counts["exported"] == 1)
        #expect(library.albums[album]?.members == ["v1", "v2"])
    }

    @Test func sizeDifferentFromPhotosFailsVerification() async throws {
        let (library, album, folder) = setup()
        library.addVideo("v1", created: day("2025-03-01"), content: randomData(3_000), reportedSize: 9_999)
        let (summary, _) = try await run(library, album: album, folder: folder)
        #expect(summary.counts["failed"] == 1)
        #expect(try files(folder).isEmpty)
        #expect(library.albums[album]?.members.isEmpty == true)
    }

    @Test func folderVanishingMidRunAbortsAndKeepsEarlierMarks() async throws {
        let (library, album, folder) = setup()
        library.addVideo("v1", created: day("2025-03-01"), content: randomData())
        library.addVideo("v2", created: day("2025-03-02"), content: randomData())
        library.onDownload = { id in if id == "v2" { try? FileManager.default.removeItem(at: folder) } }
        await #expect(throws: VideoExportError.self) {
            _ = try await run(library, album: album, folder: folder, parallel: 1)
        }
        #expect(library.albums[album]?.members == ["v1"])
        #expect(!FileManager.default.fileExists(atPath: folder.path))
    }

    @Test func cancelStopsAndKeepsVerifiedMarks() async throws {
        let (library, album, folder) = setup()
        library.addVideo("v1", created: day("2025-03-01"), content: randomData())
        library.addVideo("v2", created: day("2025-03-02"), content: randomData(), hangs: true)
        let task = Task { try await run(library, album: album, folder: folder, parallel: 1) }
        let started = await waitUntil { library.downloads.contains("v2#original") }
        #expect(started)
        task.cancel()
        let (summary, _) = try await task.value
        #expect(summary.counts["exported"] == 1)
        #expect(library.albums[album]?.members == ["v1"])
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.appending(path: ".photoscleaner-tmp").path).isEmpty)
    }

    @Test func scanIsReadOnlyAndClassifiesVideos() async throws {
        let (library, album, folder) = setup()
        library.addVideo("v1", created: day("2025-03-01"), content: randomData())
        library.addVideo("v2", created: day("2025-03-02"), rating: 5, content: randomData())
        library.addVideo("v3", created: day("2025-03-03"), content: randomData())
        library.addVideo("recent", created: now.addingTimeInterval(-10 * 86_400), content: randomData())
        library.setMembers(album, ["v3"])
        let rows = await VideoExporter(library: library).scan(cutoff: now.addingTimeInterval(-90 * 86_400), albumID: album)
        #expect(rows.map(\.id) == ["v1", "v2", "v3"])
        #expect(rows.map(\.status) == [.pending, .kept, .marked])
        #expect(library.downloads.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: folder.path))
    }

    private func waitUntil(_ condition: @Sendable () -> Bool) async -> Bool {
        for _ in 0..<500 {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }
}

@MainActor
struct VideoModelTests {
    @Test func scanThenExportUpdatesRowsAndCreatesTheFolder() async throws {
        let library = FakeLibrary()
        let dir = temporaryDirectory()
        let model = try AppModel(dataDirectory: dir, library: library, keepAwake: FakeKeepAwake(), settingsDebounce: .milliseconds(1),
                                 exporter: VideoExporter(library: library, retryDelays: [.zero], timeZone: TimeZone(identifier: "UTC")!))
        let folder = dir.appending(path: "Export")
        model.settings.update { $0.videos.exportDir = FolderRef(path: folder.path) }
        library.addVideo("v1", created: Date.now.addingTimeInterval(-200 * 86_400), content: randomData())
        await model.launch()

        #expect(model.videos.folderState == .willBeCreated)
        #expect(!model.videos.canExport)
        await model.videos.scan()
        #expect(model.videos.pending.count == 1)
        #expect(model.videos.canExport)
        #expect(!FileManager.default.fileExists(atPath: folder.path))

        await model.videos.exportAndMark()
        #expect(await eventually { model.videos.rows.first?.status == .exported })
        #expect(model.videos.folderState == .writable)
        #expect(await eventually { model.runs.count == 2 })
    }
}

struct QuickTimeFileTests {
    @Test func readsTheCreationDateFromARealMovie() async throws {
        let url = try #require(Bundle.module.url(forResource: "quicktime-2330-plus0800", withExtension: "mov", subdirectory: "Fixtures"))
        let metadata = await CaptureDateResolver.read(url)
        #expect(metadata.quickTime == "2026-02-28T23:30:00+0800")
        let utc = TimeZone(identifier: "UTC")!
        let photosDate = ISO8601DateFormatter().date(from: "2026-02-28T15:30:00Z")
        #expect(CaptureDateResolver.resolve(metadata, photosDate: photosDate, timeZone: utc) == CaptureDate(day: "2026-02-28", source: .quicktime))
    }
}
