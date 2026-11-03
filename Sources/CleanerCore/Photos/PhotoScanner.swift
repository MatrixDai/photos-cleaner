import Foundation

public struct AnalyzedPhoto: Equatable, Sendable, Identifiable {
    public var id: String
    public var date: Date?
    public var score: Double
    public var rating: Int

    public init(id: String, date: Date?, score: Double, rating: Int) {
        self.id = id
        self.date = date
        self.score = score
        self.rating = rating
    }
}

public struct PhotoScanResult: Equatable, Sendable {
    public var scope: ResolvedPhotoScope
    public var photos: [AnalyzedPhoto] = []
    public var screenshots = 0
    public var nonCamera = 0
    public var failed = 0
    public var cameraInRange = 0
    public var resumeAfter: Date?
    public var reachedEnd = false
    public var refusal: String?

    public var alreadyRated: Int { photos.filter { $0.rating != 0 }.count }
}

public enum PhotoScanError: Error, LocalizedError, Equatable {
    case analysisFailing(String)

    public var errorDescription: String? {
        switch self {
        case .analysisFailing(let message): "Every photo so far failed to analyze, so the scan stopped: \(message)"
        }
    }
}

public struct PhotoScanner: Sendable {
    public static let sequenceGap: TimeInterval = 30
    public static let concurrentAnalyses = 4
    static let abortAfterFailures = 8

    let library: any PhotoLibraryService
    let analyzer: any PhotoAnalyzing
    let limit: Int

    public init(library: any PhotoLibraryService, analyzer: any PhotoAnalyzing, limit: Int) {
        self.library = library
        self.analyzer = analyzer
        self.limit = limit
    }

    enum Analysis: Equatable {
        case screenshot, nonCamera
        case failed(String)
        case camera(CameraTags)
        case scored(Double)
    }

    public func scan(_ scope: ResolvedPhotoScope, context: JobContext) async throws -> PhotoScanResult {
        let candidates = await library.photos(scope.query)
        return scope.isDateRange
            ? try await scanRange(candidates, scope: scope, context: context)
            : try await scanOldest(candidates, scope: scope, context: context)
    }

    /// Takes the oldest unrated camera photos until the limit, then on to the end of that shot sequence, so a group is never split across runs.
    private func scanOldest(_ candidates: [LibraryPhoto], scope: ResolvedPhotoScope, context: JobContext) async throws -> PhotoScanResult {
        var result = PhotoScanResult(scope: scope)
        var index = 0
        var lastExamined: Date?
        var stopped = false
        while index < candidates.count, !stopped {
            let batch = Array(candidates[index..<min(index + Self.concurrentAnalyses, candidates.count)])
            let analyses = try await analyze(batch, score: true)
            for (photo, analysis) in zip(batch, analyses) {
                if result.photos.count >= limit {
                    guard let previous = lastExamined, let date = photo.creationDate,
                          date.timeIntervalSince(previous) <= Self.sequenceGap else {
                        stopped = true
                        break
                    }
                }
                if let date = photo.creationDate { lastExamined = date }
                index += 1
                tally(analysis, photo, into: &result)
            }
            try checkFailing(result, succeeded: result.photos.count + result.nonCamera)
            context.progress(result.photos.count, of: limit, item: lastExamined?.formatted(date: .abbreviated, time: .omitted))
        }
        result.reachedEnd = index >= candidates.count
        result.resumeAfter = lastExamined ?? scope.resumeFloor
        result.cameraInRange = result.photos.count
        return result
    }

    private func scanRange(_ candidates: [LibraryPhoto], scope: ResolvedPhotoScope, context: JobContext) async throws -> PhotoScanResult {
        var result = PhotoScanResult(scope: scope)
        var camera: [LibraryPhoto] = []
        for start in stride(from: 0, to: candidates.count, by: Self.concurrentAnalyses) {
            let batch = Array(candidates[start..<min(start + Self.concurrentAnalyses, candidates.count)])
            for (photo, analysis) in zip(batch, try await analyze(batch, score: false)) {
                if case .camera = analysis { camera.append(photo) } else { tally(analysis, photo, into: &result) }
            }
            try checkFailing(result, succeeded: camera.count + result.nonCamera)
            context.progress(start + batch.count, of: candidates.count, item: "Checking cameras")
        }
        result.cameraInRange = camera.count
        result.reachedEnd = true
        guard camera.count <= limit else {
            result.refusal = "This range has \(camera.count.formatted()) camera photos; the limit is \(limit.formatted()). Narrow the range."
            return result
        }
        for start in stride(from: 0, to: camera.count, by: Self.concurrentAnalyses) {
            let batch = Array(camera[start..<min(start + Self.concurrentAnalyses, camera.count)])
            for (photo, analysis) in zip(batch, try await analyze(batch, score: true, knownCamera: true)) {
                tally(analysis, photo, into: &result)
            }
            try checkFailing(result, succeeded: result.photos.count + result.nonCamera)
            context.progress(result.photos.count, of: camera.count, item: "Scoring")
        }
        return result
    }

    private func tally(_ analysis: Analysis, _ photo: LibraryPhoto, into result: inout PhotoScanResult) {
        switch analysis {
        case .screenshot: result.screenshots += 1
        case .nonCamera: result.nonCamera += 1
        case .failed: result.failed += 1
        case .camera: break
        case .scored(let score): result.photos.append(AnalyzedPhoto(id: photo.id, date: photo.creationDate, score: score, rating: photo.rating))
        }
    }

    /// Only an unbroken run of failures from the start aborts; a few failures among successes are skipped and logged.
    private func checkFailing(_ result: PhotoScanResult, succeeded: Int) throws {
        if succeeded == 0, result.failed >= Self.abortAfterFailures {
            throw PhotoScanError.analysisFailing(lastError.get() ?? "unknown error")
        }
    }

    private let lastError = LockedValue<String?>(nil)

    private func analyze(_ batch: [LibraryPhoto], score: Bool, knownCamera: Bool = false) async throws -> [Analysis] {
        try await withThrowingTaskGroup(of: (Int, Analysis).self) { group in
            for (offset, photo) in batch.enumerated() {
                group.addTask { (offset, try await analyze(photo, score: score, knownCamera: knownCamera)) }
            }
            var results = [Analysis](repeating: .nonCamera, count: batch.count)
            for try await (offset, analysis) in group { results[offset] = analysis }
            return results
        }
    }

    private func analyze(_ photo: LibraryPhoto, score: Bool, knownCamera: Bool) async throws -> Analysis {
        if photo.isScreenshot { return .screenshot }
        do {
            if !knownCamera {
                let tags = try await analyzer.cameraTags(photo.id)
                guard tags.isCamera else { return .nonCamera }
                if !score { return .camera(tags) }
            }
            return .scored(try await analyzer.aestheticsScore(photo.id))
        } catch {
            if Task.isCancelled { throw CancellationError() }
            lastError.set(error.localizedDescription)
            return .failed(error.localizedDescription)
        }
    }
}

extension ResolvedPhotoScope {
    var resumeFloor: Date? {
        if case .olderThan(_, _, let after) = self { return after }
        return nil
    }
}
