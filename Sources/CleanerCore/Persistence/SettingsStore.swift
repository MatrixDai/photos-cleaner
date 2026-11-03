import Foundation
import Observation

@MainActor
@Observable
public final class SettingsStore {
    public private(set) var settings: AppSettings
    public private(set) var recoveredCorruptFile: URL?
    public private(set) var saveError: String?
    public let fileURL: URL

    @ObservationIgnored private let debounce: Duration
    @ObservationIgnored private var pendingSave: Task<Void, Never>?

    public init(directory: URL, debounce: Duration = .milliseconds(500)) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        fileURL = directory.appending(path: "settings.json")
        self.debounce = debounce
        (settings, recoveredCorruptFile) = Self.load(fileURL)
    }

    public func update(_ change: (inout AppSettings) -> Void) {
        var updated = settings
        change(&updated)
        guard updated != settings else { return }
        settings = updated
        scheduleSave()
    }

    public func reset() {
        update { $0 = AppSettings() }
    }

    public func flush() {
        pendingSave?.cancel()
        pendingSave = nil
        write()
    }

    private func scheduleSave() {
        pendingSave?.cancel()
        pendingSave = Task { [debounce] in
            try? await Task.sleep(for: debounce)
            guard !Task.isCancelled else { return }
            self.write()
        }
    }

    private func write() {
        do {
            try Self.encoder.encode(settings).write(to: fileURL, options: .atomic)
            saveError = nil
        } catch {
            saveError = error.localizedDescription
        }
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    private static func load(_ url: URL) -> (AppSettings, URL?) {
        guard let data = try? Data(contentsOf: url) else { return (AppSettings(), nil) }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let settings = try? decoder.decode(AppSettings.self, from: data) { return (settings, nil) }
        let stamp = Date.now.formatted(.iso8601.year().month().day().dateSeparator(.dash).time(includingFractionalSeconds: false).timeSeparator(.omitted))
        let corrupt = url.deletingLastPathComponent().appending(path: "settings.corrupt-\(stamp).json")
        try? FileManager.default.moveItem(at: url, to: corrupt)
        return (AppSettings(), corrupt)
    }
}
