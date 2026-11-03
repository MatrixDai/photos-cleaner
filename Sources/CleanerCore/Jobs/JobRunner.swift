import Foundation

public struct JobProgress: Equatable, Sendable {
    public var done: Int
    public var total: Int?
    public var item: String?

    public init(done: Int, total: Int?, item: String? = nil) {
        self.done = done
        self.total = total
        self.item = item
    }
}

public struct JobSummary: Equatable, Sendable {
    public var scope: String?
    public var counts: [String: Int]

    public init(scope: String? = nil, counts: [String: Int] = [:]) {
        self.scope = scope
        self.counts = counts
    }
}

public enum JobOutcome: Equatable, Sendable {
    case completed(JobSummary)
    case cancelled(JobSummary?)
    case failed(String)

    var label: String {
        switch self {
        case .completed: "completed"
        case .cancelled: "cancelled"
        case .failed: "failed"
        }
    }
}

public enum JobEvent: Equatable, Sendable {
    case progress(JobProgress)
    case message(String)
    case finished(JobOutcome)
}

public struct JobContext: Sendable {
    let emit: @Sendable (JobEvent) -> Void

    public func progress(_ done: Int, of total: Int?, item: String? = nil) {
        emit(.progress(JobProgress(done: done, total: total, item: item)))
    }

    public func message(_ text: String) {
        emit(.message(text))
    }

    public func checkCancellation() throws {
        try Task.checkCancellation()
    }
}

public struct ActiveJob: Equatable, Sendable {
    public let mode: JobMode
    public let name: String
}

public enum JobRunnerError: Error, Equatable {
    case busy(ActiveJob)
}

public typealias JobWork = @Sendable (JobContext) async throws -> JobSummary
public typealias AlbumSnapshot = @Sendable () async -> [String: Int]

public actor JobRunner {
    public private(set) var active: ActiveJob?
    private var task: Task<Void, Never>?
    private let keepAwake: any KeepAwake
    private let runLog: RunLog

    public init(runLog: RunLog, keepAwake: any KeepAwake = ProcessKeepAwake()) {
        self.runLog = runLog
        self.keepAwake = keepAwake
    }

    public func start(mode: JobMode, name: String, albumSnapshot: AlbumSnapshot? = nil,
                      work: @escaping JobWork) throws(JobRunnerError) -> AsyncStream<JobEvent> {
        if let active { throw .busy(active) }
        let job = ActiveJob(mode: mode, name: name)
        active = job
        let (stream, continuation) = AsyncStream.makeStream(of: JobEvent.self)
        let hold = keepAwake.hold(reason: "Photos Cleaner: \(mode.title) \(name)")
        let started = Date.now
        task = Task {
            let context = JobContext(emit: { continuation.yield($0) })
            let outcome: JobOutcome
            do {
                let summary = try await work(context)
                outcome = Task.isCancelled ? .cancelled(summary) : .completed(summary)
            } catch is CancellationError {
                outcome = .cancelled(nil)
            } catch {
                outcome = .failed(String(describing: error))
            }
            hold.release()
            await self.record(job, outcome: outcome, started: started, albumSnapshot: albumSnapshot)
            continuation.yield(.finished(outcome))
            continuation.finish()
        }
        return stream
    }

    public func cancel() {
        task?.cancel()
    }

    private func record(_ job: ActiveJob, outcome: JobOutcome, started: Date, albumSnapshot: AlbumSnapshot?) async {
        let summary: JobSummary? = switch outcome {
        case .completed(let summary): summary
        case .cancelled(let summary): summary
        case .failed: nil
        }
        var error: String?
        if case .failed(let message) = outcome { error = message }
        let albums = await albumSnapshot?() ?? [:]
        let record = RunRecord(run: await runLog.nextRunID(), mode: job.mode, task: job.name, scope: summary?.scope,
                               start: started, end: .now, outcome: outcome.label, counts: summary?.counts ?? [:],
                               albums: albums, error: error)
        try? await runLog.append(record)
        active = nil
        task = nil
    }
}
