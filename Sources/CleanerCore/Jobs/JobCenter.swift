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
        guard active == nil else { return false }
        let job = ActiveJob(mode: mode, name: name)
        active = job
        progress = nil
        lastMessage = nil
        let stream: AsyncStream<JobEvent>
        do {
            stream = try await runner.start(mode: mode, name: name, albumSnapshot: albumSnapshot, work: work)
        } catch {
            active = nil
            return false
        }
        Task {
            for await event in stream {
                switch event {
                case .progress(let update): progress = update
                case .message(let text): lastMessage = text
                case .finished(let outcome):
                    let finished = FinishedJob(job: job, outcome: outcome)
                    active = nil
                    progress = nil
                    lastFinished = finished
                    onFinish?(finished)
                }
            }
        }
        return true
    }

    public func cancel() async {
        await runner.cancel()
    }
}
