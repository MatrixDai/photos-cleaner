import Foundation
import Observation

public struct AlbumSummaryRow: Equatable, Sendable, Identifiable {
    public let role: AlbumRole
    public let name: String
    public let current: Int?
    public let atLastRun: Int?

    public var id: String { role.rawValue }

    public var change: Int? {
        guard let current, let atLastRun else { return nil }
        return current - atLastRun
    }
}

@MainActor
@Observable
public final class AppModel {
    public let settings: SettingsStore
    public let jobs: JobCenter
    public let dataDirectory: URL
    public private(set) var authorization: LibraryAuthorization
    public private(set) var albumError: String?
    public private(set) var runs: [RunRecord] = []
    public private(set) var albumSummary: [AlbumSummaryRow] = []

    @ObservationIgnored private let library: any PhotoLibraryService
    @ObservationIgnored private let runLog: RunLog

    public init(dataDirectory: URL, library: any PhotoLibraryService, keepAwake: any KeepAwake = ProcessKeepAwake(),
                settingsDebounce: Duration = .milliseconds(500)) throws {
        self.dataDirectory = dataDirectory
        self.library = library
        settings = try SettingsStore(directory: dataDirectory, debounce: settingsDebounce)
        runLog = RunLog(fileURL: dataDirectory.appending(path: "runs.jsonl"))
        jobs = JobCenter(runner: JobRunner(runLog: runLog, keepAwake: keepAwake))
        authorization = library.authorization()
        jobs.albumSnapshot = { [weak self] in await self?.albumSizes() ?? [:] }
        jobs.onFinish = { [weak self] _ in Task { await self?.refreshActivity() } }
    }

    public static var defaultDataDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser.appending(path: ".photos-cleaner", directoryHint: .isDirectory)
    }

    public var hasFullAccess: Bool { authorization == .authorized }

    public func launch() async {
        if authorization == .notDetermined {
            authorization = await library.requestAuthorization()
        }
        await afterAccessCheck()
    }

    public func checkAccessAgain() async {
        authorization = library.authorization()
        await afterAccessCheck()
    }

    public func resetAllSettings() async {
        settings.reset()
        await ensureAlbums()
    }

    public func refreshActivity() async {
        runs = await runLog.records().reversed()
        let sizes = await albumSizes()
        let lastRun = runs.first { !$0.albums.isEmpty }
        albumSummary = AlbumRole.allCases.map { role in
            AlbumSummaryRow(role: role, name: settings.settings[keyPath: role.keyPath].name,
                            current: sizes[role.rawValue], atLastRun: lastRun?.albums[role.rawValue])
        }
    }

    private func afterAccessCheck() async {
        guard hasFullAccess else { return }
        await ensureAlbums()
        await refreshActivity()
    }

    private func ensureAlbums() async {
        let service = AlbumService(library: library)
        albumError = nil
        for role in AlbumRole.allCases {
            let ref = settings.settings[keyPath: role.keyPath]
            do {
                let resolved = try await service.resolve(ref)
                if resolved != ref { settings.update { $0[keyPath: role.keyPath] = resolved } }
            } catch {
                albumError = "Couldn't set up the album \"\(ref.name)\": \(error.localizedDescription)"
            }
        }
    }

    private func albumSizes() async -> [String: Int] {
        var sizes: [String: Int] = [:]
        for role in AlbumRole.allCases {
            if let id = settings.settings[keyPath: role.keyPath].id, let size = await library.albumSize(id: id) {
                sizes[role.rawValue] = size
            }
        }
        return sizes
    }
}
