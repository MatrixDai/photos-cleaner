import Foundation
import Observation

@MainActor
@Observable
public final class PhotoModel {
    public private(set) var tally: RatingTally?
    public private(set) var notice: String?
    public private(set) var startedAt: Date?
    public private(set) var finishedAt: Date?
    public var reRate = false
    public var reRateFrom: Date
    public var reRateTo: Date

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
        let today = now()
        reRateTo = today
        reRateFrom = Calendar.current.date(byAdding: .month, value: -1, to: today) ?? today
    }

    public var scopeError: String? {
        do {
            _ = try scope()
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    public var isRunning: Bool { jobs.active?.mode == .photos }

    public var canRun: Bool { !jobs.isBusy && scopeError == nil }

    public func run() async {
        guard canRun, let scope = try? scope() else { return }
        let rating = PhotoRatingRun(library: library, analyzer: analyzer, scope: scope, thresholds: settings.settings.photos.starThresholds)
        let final = LockedValue<RatingTally?>(nil)
        let report: @Sendable (RatingTally) -> Void = { [weak self] tally in
            Task { @MainActor in self?.receive(tally) }
        }
        tally = nil
        notice = nil
        startedAt = now()
        finishedAt = nil
        let finished = await jobs.run(mode: .photos, name: "rate") { context in
            let tally = try await rating.run(context: context) { tally in
                final.set(tally)
                report(tally)
            }
            return JobSummary(scope: scope.label, counts: tally.counts)
        }
        finishedAt = now()
        tally = final.get() ?? tally
        guard let finished else { return }
        notice = message(for: finished.outcome, scope: scope)
    }

    private func receive(_ update: RatingTally) {
        guard isRunning, update.processed >= (tally?.processed ?? 0) else { return }
        tally = update
    }

    private func message(for outcome: JobOutcome, scope: RatingScope) -> String {
        let rated = tally?.rated ?? 0
        switch outcome {
        case .completed:
            if tally?.total == 0 { return scope.isReRate ? "No photos were taken in this range." : "Every photo already has stars." }
            return "Rated \(rated.formatted()) photos. In Photos, filter by 1★ or 2★ to review and delete the low ones."
        case .cancelled:
            return "Cancelled after rating \(rated.formatted()) photos." + (scope.isReRate ? "" : " Run again to continue with the rest.")
        case .failed(let message):
            return message
        }
    }

    private func scope() throws -> RatingScope {
        reRate ? try RatingScope.reRate(from: reRateFrom, to: reRateTo, timeZone: timeZone) : .unrated
    }
}
