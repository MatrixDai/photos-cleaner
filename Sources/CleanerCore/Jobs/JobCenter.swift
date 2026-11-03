import Foundation
import Observation

public struct FinishedJob: Equatable, Sendable {
    public let job: ActiveJob
    public let outcome: JobOutcome
}

@MainActor
@Observable
public final class JobCenter {
    public private(set) var active: ActiveJob?
    public private(set) var progress: JobProgress?
    public private(set) var lastMessage: String?
    public private(set) var lastFinished: FinishedJob?

    @ObservationIgnored public var albumSnapshot: AlbumSnapshot?
    @ObservationIgnored public var onFinish: (@MainActor (FinishedJob) -> Void)?
    @ObservationIgnored private let runner: JobRunner

    public init(runner: JobRunner) {
        self.runner = runner
    }

    public var isBusy: Bool { active != nil }

    @discardableResult
    public func start(mode: JobMode, name: String, work: @escaping JobWork) async -> Bool {
        await launch(mode: mode, name: name, work: work) != nil
    }

    /// Returns nil when another job is already running.
    @discardableResult
    public func run(mode: JobMode, name: String, work: @escaping JobWork) async -> FinishedJob? {
        await launch(mode: mode, name: name, work: work)?.value ?? nil
    }

    private func launch(mode: JobMode, name: String, work: @escaping JobWork) async -> Task<FinishedJob?, Never>? {
        guard active == nil else { return nil }
        let job = ActiveJob(mode: mode, name: name)
        active = job
        progress = nil
        lastMessage = nil
        let stream: AsyncStream<JobEvent>
        do {
            stream = try await runner.start(mode: mode, name: name, albumSnapshot: albumSnapshot, work: work)
        } catch {
            active = nil
            return nil
        }
        return Task {
            var result: FinishedJob?
            for await event in stream {
                switch event {
                case .progress(let update): progress = update
                case .message(let text): lastMessage = text
                case .finished(let outcome):
                    let finished = FinishedJob(job: job, outcome: outcome)
                    active = nil
                    progress = nil
                    lastFinished = finished
                    result = finished
                    onFinish?(finished)
                }
            }
            return result
        }
    }

    public func cancel() async {
        await runner.cancel()
    }
}
