import CoreGraphics
import Foundation
import Observation

@MainActor
@Observable
public final class PhotoModel {
    public private(set) var scan: PhotoScanResult?
    public private(set) var notice: String?
    public private(set) var adjustedStars: [String: Int] = [:]

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

    public func suggestedStars(_ photo: AnalyzedPhoto) -> Int {
        StarRater.stars(for: photo.score, thresholds: thresholds)
    }

    public func stars(_ photo: AnalyzedPhoto) -> Int {
        adjustedStars[photo.id] ?? suggestedStars(photo)
    }

    public func isAdjusted(_ photo: AnalyzedPhoto) -> Bool {
        adjustedStars[photo.id] != nil
    }

    /// Setting a photo back to its suggestion drops the adjustment, so later threshold changes apply to it again.
    public func setStars(_ stars: Int, for photo: AnalyzedPhoto) {
        guard (1...5).contains(stars) else { return }
        adjustedStars[photo.id] = stars == suggestedStars(photo) ? nil : stars
    }

    public var adjustedCount: Int {
        photosToRate.filter { adjustedStars[$0.id] != nil }.count
    }

    public var starCounts: [Int: Int] {
        var counts = Dictionary(uniqueKeysWithValues: (1...5).map { ($0, 0) })
        for photo in photosToRate { counts[stars(photo), default: 0] += 1 }
        return counts
    }

    public func image(_ photo: AnalyzedPhoto, side: Int) async -> CGImage? {
        await library.image(for: photo.id, side: side)
    }


    public func scan() async {
        notice = nil
        adjustedStars = [:]
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
        guard let scan, canRate else { return }
        let stars = Dictionary(uniqueKeysWithValues: photosToRate.map { ($0.id, self.stars($0)) })
        let adjusted = adjustedCount
        let rater = PhotoRater(library: library)
        let finished = await jobs.run(mode: .photos, name: "rate & mark") { context in
            var summary = try await rater.rateAndMark(scan, stars: stars, context: context)
            summary.counts["adjusted"] = adjusted
            return summary
        }
        guard let finished, case .completed(let summary) = finished.outcome else { return }
        if !scan.scope.isDateRange, let resume = scan.resumeAfter {
            settings.update { $0.photos.resumeAfter = resume }
        }
        self.scan = nil
        adjustedStars = [:]
        notice = "Rated \(summary.counts["rated"] ?? 0) photos. In Photos, filter by 1★ or 2★ to review and delete the low ones."
    }

    public func startOver() {
        settings.update { $0.photos.resumeAfter = nil }
        scopeChanged()
    }

    public func scopeChanged() {
        scan = nil
        notice = nil
        adjustedStars = [:]
    }

    private func resolvedScope() throws -> ResolvedPhotoScope {
        try PhotoScope.resolve(settings.settings.photos.scope, resumeAfter: settings.settings.photos.resumeAfter,
                               now: now(), timeZone: timeZone)
    }
}
