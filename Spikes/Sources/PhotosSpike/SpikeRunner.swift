import Foundation
import Observation
import Photos

@MainActor
@Observable
final class SpikeRunner {
    var log = ""
    var busy: String?
    var useRange = false
    var from = Calendar.current.date(byAdding: .year, value: -1, to: .now)!
    var to = Date.now
    var sample = 200
    var authorization = PHPhotoLibrary.authorizationStatus(for: .readWrite)

    let reportDir = FileManager.default.homeDirectoryForCurrentUser
        .appending(path: ".photos-cleaner/spikes", directoryHint: .isDirectory)
    private var reportFile: URL?

    var range: ClosedRange<Date>? {
        guard useRange else { return nil }
        let start = Calendar.current.startOfDay(for: from)
        let end = Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: to))!
        return start...end
    }

    func requestAccess() async {
        authorization = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
    }

    func run(_ name: String, _ body: @MainActor () async throws -> Void) async {
        guard busy == nil else { return }
        busy = name
        try? FileManager.default.createDirectory(at: reportDir, withIntermediateDirectories: true)
        reportFile = reportDir.appending(path: "\(name).md")
        try? Data().write(to: reportFile!)
        say("# \(name) — \(Date.now.formatted(.iso8601))")
        say("Scope: \(range.map { "\($0.lowerBound.formatted(date: .numeric, time: .omitted))–\(to.formatted(date: .numeric, time: .omitted))" } ?? "whole library"), sample \(sample)")
        do {
            try await body()
        } catch {
            say("ERROR: \(error)")
        }
        say("Report: \(reportFile!.path)\n")
        busy = nil
    }

    func say(_ line: String) {
        log += line + "\n"
        if let reportFile, let handle = try? FileHandle(forWritingTo: reportFile) {
            handle.seekToEndOfFile()
            handle.write(Data((line + "\n").utf8))
            try? handle.close()
        }
    }
}
