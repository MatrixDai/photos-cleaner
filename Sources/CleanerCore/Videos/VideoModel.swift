import Foundation
import Observation

@MainActor
@Observable
public final class VideoModel {
    public private(set) var rows: [VideoRow] = []
    public private(set) var scannedAt: Date?
    public private(set) var folderState: FolderState = .willBeCreated
    public private(set) var freeSpace: Int64?

    @ObservationIgnored private let settings: SettingsStore
    @ObservationIgnored private let jobs: JobCenter
    @ObservationIgnored private let exporter: VideoExporter
    @ObservationIgnored private let now: @Sendable () -> Date

    public init(settings: SettingsStore, jobs: JobCenter, exporter: VideoExporter, now: @escaping @Sendable () -> Date = { .now }) {
        self.settings = settings
        self.jobs = jobs
        self.exporter = exporter
        self.now = now
    }

    public var folder: URL {
        settings.settings.videos.exportDir.resolvedURL
    }

    public var pending: [VideoRow] { rows.filter { $0.status == .pending } }

    public var pendingBytes: Int { pending.compactMap(\.size).reduce(0, +) }

    public var exceedsFreeSpace: Bool {
        guard let freeSpace else { return false }
        return Int64(pendingBytes) > freeSpace
    }

    public var canExport: Bool {
        guard !jobs.isBusy, scannedAt != nil, !pending.isEmpty else { return false }
        if case .notWritable = folderState { return false }
        return true
    }

    public func launch() {
        refreshFolder()
        WritableCheck.removeStaleTemporaryFiles(in: folder)
    }

    public func refreshFolder() {
        let ref = settings.settings.videos.exportDir
        let resolved = ref.refreshed()
        if resolved != ref { settings.update { $0.videos.exportDir = resolved } }
        folderState = WritableCheck.check(folder)
        freeSpace = WritableCheck.freeSpace(folder)
    }

    public func chooseFolder(_ url: URL) {
        settings.update { $0.videos.exportDir = FolderRef(url: url) }
        rows = []
        scannedAt = nil
        refreshFolder()
    }

    public func scan() async {
        let cutoff = cutoffDate
        let days = settings.settings.videos.olderThanDays
        let albumID = settings.settings.videos.album.id
        let exporter = exporter
        let found = LockedValue<[VideoRow]>([])
        guard await jobs.run(mode: .videos, name: "scan", work: { context in
            let rows = await exporter.scan(cutoff: cutoff, albumID: albumID)
            found.set(rows)
            let pending = rows.filter { $0.status == .pending }
            context.progress(rows.count, of: rows.count)
            return JobSummary(scope: "olderThan \(days)", counts: [
                "videos": rows.count, "pending": pending.count, "marked": rows.filter { $0.status == .marked }.count,
                "kept": rows.filter { $0.status == .kept }.count,
            ])
        }) != nil else { return }
        rows = found.get()
        scannedAt = now()
        refreshFolder()
    }

    public func exportAndMark() async {
        refreshFolder()
        guard let albumID = settings.settings.videos.album.id, canExport else { return }
        let video = settings.settings.videos
        let plan = VideoExportPlan(folder: folder, template: video.nameTemplate, parallel: video.parallelExports,
                                   albumID: albumID, cutoff: cutoffDate, olderThanDays: video.olderThanDays)
        let exporter = exporter
        let sink: @Sendable (VideoRow) -> Void = { [weak self] row in
            Task { @MainActor in self?.apply(row) }
        }
        await jobs.run(mode: .videos, name: "export") { context in
            try await exporter.run(plan, context: context, update: sink)
        }
        refreshFolder()
    }

    private var cutoffDate: Date {
        now().addingTimeInterval(-Double(settings.settings.videos.olderThanDays) * 86_400)
    }

    private func apply(_ row: VideoRow) {
        guard let index = rows.firstIndex(where: { $0.id == row.id }) else { return }
        rows[index] = row
    }
}

extension FolderRef {
    public init(url: URL) {
        self.init(path: url.standardizedFileURL.path, bookmark: try? url.bookmarkData())
    }

    /// The bookmark follows a renamed folder; the path covers a volume that was unmounted and remounted.
    public var resolvedURL: URL {
        if let bookmark {
            var stale = false
            if let url = try? URL(resolvingBookmarkData: bookmark, options: [.withoutUI, .withoutMounting], bookmarkDataIsStale: &stale),
               FileManager.default.fileExists(atPath: url.path) {
                return url
            }
        }
        return URL(filePath: path, directoryHint: .isDirectory)
    }

    func refreshed() -> FolderRef {
        let url = resolvedURL
        guard FileManager.default.fileExists(atPath: url.path) else { return self }
        let current = FolderRef(url: url)
        return current.path == path ? self : current
    }
}
