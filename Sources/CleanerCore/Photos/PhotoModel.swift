import Foundation
import Observation

@MainActor
@Observable
public final class PhotoModel {
    public private(set) var scan: PhotoScanResult?
    public private(set) var notice: String?

    @ObservationIgnored private let settings: SettingsStore
    @ObservationIgnored private let jobs: JobCenter
    @ObservationIgnored private let library: any PhotoLibraryService
    @ObservationIgnored private let analyzer: any PhotoAnalyzing
    @ObservationIgnored private let now: @Sendable () -> Date
    @ObservationIgnored private let timeZone: TimeZone

    public init(settings: SettingsStore, jobs: JobCenter, library: any PhotoLibraryService, analyzer: any PhotoAnalyzing,
                now: @escaping @Sendable () -> Date = { .now }, timeZone: TimeZone = .current) {
        self.settings = settings
        self.jobs = jobs
        self.library = library
        self.analyzer = analyzer
        self.now = now
        self.timeZone = timeZone
    }

    public var thresholds: [Double] { settings.settings.photos.starThresholds }

    public var scopeError: String? {
        do {
            _ = try resolvedScope()
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    public var canScan: Bool { !jobs.isBusy && scopeError == nil }

    public var photosToRate: [AnalyzedPhoto] {
        guard let scan, scan.refusal == nil else { return [] }
        return scan.scope.isDateRange ? scan.photos : scan.photos.filter { $0.rating == 0 }
    }

    public var canRate: Bool { !jobs.isBusy && !photosToRate.isEmpty }

    public var starCounts: [Int: Int] {
        StarRater.counts(photosToRate.map(\.score), thresholds: thresholds)
    }

    public var lowQualityCount: Int {
        starCounts.filter { PhotoRater.lowQualityStars.contains($0.key) }.values.reduce(0, +)
    }

    public func scan() async {
        notice = nil
        guard let scope = try? resolvedScope() else { return }
        let scanner = PhotoScanner(library: library, analyzer: analyzer, limit: settings.settings.photos.cameraPhotosPerRun)
        let found = LockedValue<PhotoScanResult?>(nil)
        let finished = await jobs.run(mode: .photos, name: "scan") { context in
            let result = try await scanner.scan(scope, context: context)
            found.set(result)
            return JobSummary(scope: scope.label, counts: [
                "camera": result.photos.count, "nonCamera": result.nonCamera, "screenshots": result.screenshots,
                "failed": result.failed, "alreadyRated": result.alreadyRated,
            ])
        }
        guard let finished, case .completed = finished.outcome, let result = found.get() else {
            if let finished, case .failed(let message) = finished.outcome { notice = message }
            return
        }
        scan = result
        if let refusal = result.refusal {
            notice = refusal
        } else if result.photos.isEmpty {
            notice = scope.isDateRange ? "No camera photos in this range."
                : "No more unrated photos older than \(settings.settings.photos.scope.olderThanDays) days."
        }
    }

    public func rateAndMark() async {
        guard let scan, canRate, let lowQuality = settings.settings.photos.albums.lowQuality.id else { return }
        let duplicated = settings.settings.photos.albums.duplicated.id
        let thresholds = thresholds
        let rater = PhotoRater(library: library)
        let finished = await jobs.run(mode: .photos, name: "rate & mark") { context in
            try await rater.rateAndMark(scan, thresholds: thresholds, lowQualityAlbum: lowQuality, duplicatedAlbum: duplicated, context: context)
        }
        guard let finished, case .completed(let summary) = finished.outcome else { return }
        if !scan.scope.isDateRange, let resume = scan.resumeAfter {
            settings.update { $0.photos.resumeAfter = resume }
        }
        self.scan = nil
        notice = "Rated \(summary.counts["rated"] ?? 0) photos; added \(summary.counts["addedLowQuality"] ?? 0) to photo-low-quality."
    }

    public func revertCount(_ roles: Set<AlbumRole>) async -> Int {
        await PhotoReverter(library: library).members(of: albumIDs(roles)).count
    }

    public func revert(_ roles: Set<AlbumRole>) async {
        let albums = albumIDs(roles)
        guard !albums.isEmpty else { return }
        let reverter = PhotoReverter(library: library)
        let finished = await jobs.run(mode: .photos, name: "revert") { context in
            try await reverter.revert(albums: albums, context: context)
        }
        if let finished, case .completed(let summary) = finished.outcome {
            scan = nil
            notice = "Cleared \(summary.counts["cleared"] ?? 0) ratings and emptied \(albums.count) album\(albums.count == 1 ? "" : "s")."
        }
    }

    public func startOver() {
        settings.update { $0.photos.resumeAfter = nil }
        scan = nil
        notice = nil
    }

    public func scopeChanged() {
        scan = nil
        notice = nil
    }

    private func albumIDs(_ roles: Set<AlbumRole>) -> [String] {
        AlbumRole.allCases.filter { roles.contains($0) && $0 != .videoToDelete }
            .compactMap { settings.settings[keyPath: $0.keyPath].id }
    }

    private func resolvedScope() throws -> ResolvedPhotoScope {
        try PhotoScope.resolve(settings.settings.photos.scope, resumeAfter: settings.settings.photos.resumeAfter,
                               now: now(), timeZone: timeZone)
    }
}
