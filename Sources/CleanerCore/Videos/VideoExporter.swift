import CryptoKit
import Foundation

public enum VideoRowStatus: Equatable, Sendable {
    case pending, marked, kept, exporting, exported, alreadyLocal
    case failed(String)

    public var label: String {
        switch self {
        case .pending: "pending"
        case .marked: "marked"
        case .kept: "kept (3★+)"
        case .exporting: "exporting…"
        case .exported: "exported"
        case .alreadyLocal: "already local"
        case .failed(let reason): "failed: \(reason)"
        }
    }
}

public struct VideoRow: Equatable, Sendable, Identifiable {
    public let id: String
    public let date: Date?
    public let name: String
    public let size: Int?
    public var status: VideoRowStatus
    public var file: String?

    init(_ video: LibraryVideo, status: VideoRowStatus, file: String? = nil) {
        id = video.id
        date = video.creationDate
        name = video.original?.filename ?? "untitled"
        let sizes = video.resources.compactMap(\.size)
        size = sizes.isEmpty ? nil : sizes.reduce(0, +)
        self.status = status
        self.file = file
    }
}

public enum VideoExportError: Error, LocalizedError, Equatable {
    case folder(String)
    case fileSystem(String)
    case album(String)
    case download(String)
    case verification(String)
    case missingOriginal

    /// These mean every further video would fail too, so the job stops instead of skipping the video.
    var isFatal: Bool {
        switch self {
        case .folder, .fileSystem, .album: true
        case .download, .verification, .missingOriginal: false
        }
    }

    public var errorDescription: String? {
        switch self {
        case .folder(let message): "Export folder: \(message)"
        case .fileSystem(let message): "Writing to the export folder failed: \(message)"
        case .album(let message): "Updating video-to-delete failed: \(message)"
        case .download(let message): message
        case .verification(let message): "Verification failed: \(message)"
        case .missingOriginal: "The video has no original resource"
        }
    }
}

public struct VideoExportPlan: Sendable {
    public var folder: URL
    public var template: String
    public var parallel: Int
    public var albumID: String
    public var cutoff: Date
    public var olderThanDays: Int

    public init(folder: URL, template: String, parallel: Int, albumID: String, cutoff: Date, olderThanDays: Int) {
        self.folder = folder
        self.template = template
        self.parallel = parallel
        self.albumID = albumID
        self.cutoff = cutoff
        self.olderThanDays = olderThanDays
    }
}

public struct VideoExporter: Sendable {
    public static let keepRating = 3

    let library: any PhotoLibraryService
    var retryDelays: [Duration]
    var markBatch: Int
    var timeZone: TimeZone

    public init(library: any PhotoLibraryService, retryDelays: [Duration] = [.seconds(5), .seconds(30), .seconds(120)],
                markBatch: Int = 10, timeZone: TimeZone = .current) {
        self.library = library
        self.retryDelays = retryDelays
        self.markBatch = markBatch
        self.timeZone = timeZone
    }

    public func scan(cutoff: Date, albumID: String?) async -> [VideoRow] {
        var members = Set<String>()
        if let albumID { members = await library.albumMembers(id: albumID) }
        return await library.videos(createdBefore: cutoff).map { video in
            if video.rating >= Self.keepRating { return VideoRow(video, status: .kept) }
            return VideoRow(video, status: members.contains(video.id) ? .marked : .pending)
        }
    }

    public func run(_ plan: VideoExportPlan, context: JobContext,
                    update: @escaping @Sendable (VideoRow) -> Void) async throws -> JobSummary {
        do {
            try FileManager.default.createDirectory(at: plan.folder, withIntermediateDirectories: true)
        } catch {
            throw VideoExportError.folder(error.localizedDescription)
        }
        if case .notWritable(let reason) = WritableCheck.check(plan.folder) { throw VideoExportError.folder(reason) }
        let folder = ExportFolder(root: plan.folder)
        do {
            try FileManager.default.createDirectory(at: folder.temporary, withIntermediateDirectories: true)
        } catch {
            throw VideoExportError.folder(error.localizedDescription)
        }

        let videos = await library.videos(createdBefore: plan.cutoff)
        let members = await library.albumMembers(id: plan.albumID)
        let keptMarked = videos.filter { $0.rating >= Self.keepRating && members.contains($0.id) }.map(\.id)
        if !keptMarked.isEmpty {
            do {
                try await library.removeAssets(keptMarked, fromAlbum: plan.albumID)
            } catch {
                throw VideoExportError.album(error.localizedDescription)
            }
        }
        let todo = videos.filter { $0.rating < Self.keepRating && !members.contains($0.id) }
        let tally = Tally(total: todo.count)
        let marks = MarkQueue(library: library, albumID: plan.albumID, batch: markBatch)
        context.message("\(todo.count) videos to export, \(await folder.fileCount) files already in the export folder")

        func summary() async -> JobSummary {
            var counts = await tally.counts
            counts["marked"] = await marks.marked
            counts["keptRemoved"] = keptMarked.count
            return JobSummary(scope: "olderThan \(plan.olderThanDays)", counts: counts)
        }

        do {
            try await withThrowingTaskGroup(of: Void.self) { group in
                var queue = todo.makeIterator()
                func enqueue() -> Bool {
                    guard let video = queue.next() else { return false }
                    group.addTask {
                        try await export(video, plan: plan, folder: folder, marks: marks, tally: tally, context: context, update: update)
                    }
                    return true
                }
                for _ in 0..<max(1, plan.parallel) {
                    guard enqueue() else { break }
                }
                while try await group.next() != nil {
                    _ = enqueue()
                }
            }
            try await marks.flush()
        } catch is CancellationError {
            try? await marks.flush()
            return await summary()
        } catch {
            try? await marks.flush()
            throw error
        }
        return await summary()
    }

    private func export(_ video: LibraryVideo, plan: VideoExportPlan, folder: ExportFolder, marks: MarkQueue, tally: Tally,
                        context: JobContext, update: @Sendable (VideoRow) -> Void) async throws {
        update(VideoRow(video, status: .exporting))
        var resolvedDay: CaptureDate?
        var files: [String] = []
        var allReused = true
        do {
            guard let original = video.original else { throw VideoExportError.missingOriginal }
            for resource in [original] + (video.edited.map { [$0] } ?? []) {
                let placed = try await exportResource(resource, of: video, plan: plan, folder: folder, day: &resolvedDay)
                files.append(placed.path)
                allReused = allReused && placed.reused
            }
        } catch let error as VideoExportError where !error.isFatal {
            update(VideoRow(video, status: .failed(error.localizedDescription)))
            context.progress(await tally.record(.failed), of: tally.total, item: video.original?.filename)
            return
        }
        try await marks.add(video.id)
        update(VideoRow(video, status: allReused ? .alreadyLocal : .exported, file: files.first))
        context.progress(await tally.record(allReused ? .alreadyLocal : .exported), of: tally.total, item: video.original?.filename)
    }

    private func exportResource(_ resource: LibraryVideoResource, of video: LibraryVideo, plan: VideoExportPlan,
                                folder: ExportFolder, day: inout CaptureDate?) async throws -> (path: String, reused: Bool) {
        let ext = (resource.filename.map { ($0 as NSString).pathExtension } ?? "").lowercased()
        var attempt = 0
        while true {
            let download: (url: URL, sha256: String, size: Int)
            do {
                download = try await downloadToTemp(video.id, resource.kind, ext: ext, folder: folder)
            } catch VideoExportError.download(let message) {
                guard attempt < retryDelays.count else { throw VideoExportError.download(message) }
                try await Task.sleep(for: retryDelays[attempt])
                attempt += 1
                continue
            }
            if let expected = resource.size, expected != download.size {
                try? FileManager.default.removeItem(at: download.url)
                throw VideoExportError.verification("downloaded \(download.size) bytes, Photos reports \(expected)")
            }
            do {
                if let existing = try await folder.duplicate(size: download.size, sha256: download.sha256) {
                    try? FileManager.default.removeItem(at: download.url)
                    return (await folder.relativePath(of: existing), true)
                }
            } catch {
                try? FileManager.default.removeItem(at: download.url)
                throw VideoExportError.fileSystem(error.localizedDescription)
            }
            if day == nil {
                day = CaptureDateResolver.resolve(await CaptureDateResolver.read(download.url), photosDate: video.creationDate, timeZone: timeZone)
            }
            var relative = NamingEngine.render(plan.template, day: day!.day, filename: video.original?.filename)
            if resource.kind == .edited { relative = NamingEngine.edited(relative) }
            let placed: URL
            do {
                placed = try await folder.place(download.url, at: relative, size: download.size, sha256: download.sha256)
            } catch {
                try? FileManager.default.removeItem(at: download.url)
                throw VideoExportError.fileSystem(error.localizedDescription)
            }
            let reread = try? FileHasher.sha256(of: placed)
            guard reread == download.sha256 else {
                try? FileManager.default.removeItem(at: placed)
                await folder.forget(placed, size: download.size)
                throw VideoExportError.verification("the written file's hash doesn't match the download")
            }
            return (await folder.relativePath(of: placed), false)
        }
    }

    private func downloadToTemp(_ assetID: String, _ kind: LibraryVideoResource.Kind, ext: String,
                                folder: ExportFolder) async throws -> (url: URL, sha256: String, size: Int) {
        let url = folder.temporary.appending(path: UUID().uuidString + (ext.isEmpty ? "" : ".\(ext)"))
        guard FileManager.default.createFile(atPath: url.path, contents: nil),
              let handle = try? FileHandle(forWritingTo: url) else {
            throw VideoExportError.fileSystem("can't create a temporary file in \(folder.temporary.path)")
        }
        var hasher = SHA256()
        var size = 0
        do {
            defer { try? handle.close() }
            do {
                for try await chunk in library.resourceData(assetID: assetID, kind: kind) {
                    do {
                        try handle.write(contentsOf: chunk)
                    } catch {
                        throw VideoExportError.fileSystem(error.localizedDescription)
                    }
                    hasher.update(data: chunk)
                    size += chunk.count
                }
            } catch let error as VideoExportError {
                throw error
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                throw VideoExportError.download(error.localizedDescription)
            }
            try Task.checkCancellation()
            do {
                try handle.synchronize()
            } catch {
                throw VideoExportError.fileSystem(error.localizedDescription)
            }
        } catch {
            try? FileManager.default.removeItem(at: url)
            throw error
        }
        return (url, FileHasher.hex(hasher.finalize()), size)
    }
}

private actor Tally {
    enum Result { case exported, alreadyLocal, failed }

    nonisolated let total: Int
    private var exported = 0
    private var alreadyLocal = 0
    private var failed = 0

    init(total: Int) {
        self.total = total
    }

    func record(_ result: Result) -> Int {
        switch result {
        case .exported: exported += 1
        case .alreadyLocal: alreadyLocal += 1
        case .failed: failed += 1
        }
        return exported + alreadyLocal + failed
    }

    var counts: [String: Int] {
        ["videos": total, "exported": exported, "alreadyLocal": alreadyLocal, "failed": failed]
    }
}

private actor MarkQueue {
    let library: any PhotoLibraryService
    let albumID: String
    let batch: Int
    private var pending: [String] = []
    private(set) var marked = 0

    init(library: any PhotoLibraryService, albumID: String, batch: Int) {
        self.library = library
        self.albumID = albumID
        self.batch = batch
    }

    func add(_ id: String) async throws {
        pending.append(id)
        if pending.count >= batch { try await flush() }
    }

    func flush() async throws {
        guard !pending.isEmpty else { return }
        let ids = pending
        pending = []
        do {
            try await library.addAssets(ids, toAlbum: albumID)
        } catch {
            pending = ids + pending
            throw VideoExportError.album(error.localizedDescription)
        }
        marked += ids.count
    }
}
