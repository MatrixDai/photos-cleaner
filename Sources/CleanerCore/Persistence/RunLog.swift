import Foundation

public enum JobMode: String, Codable, Sendable, CaseIterable {
    case videos, photos

    public var title: String {
        switch self {
        case .videos: "Videos"
        case .photos: "Photos"
        }
    }
}

public struct RunRecord: Codable, Equatable, Sendable {
    public var run: Int
    public var mode: JobMode
    public var task: String
    public var scope: String?
    public var start: Date
    public var end: Date
    public var outcome: String
    public var counts: [String: Int]
    public var albums: [String: Int]
    public var error: String?

    public init(run: Int, mode: JobMode, task: String, scope: String? = nil, start: Date, end: Date,
                outcome: String, counts: [String: Int] = [:], albums: [String: Int] = [:], error: String? = nil) {
        self.run = run
        self.mode = mode
        self.task = task
        self.scope = scope
        self.start = start
        self.end = end
        self.outcome = outcome
        self.counts = counts
        self.albums = albums
        self.error = error
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        run = try container.decode(Int.self, forKey: .run)
        mode = try container.decode(JobMode.self, forKey: .mode)
        task = try container.decode(String.self, forKey: .task)
        start = try container.decode(Date.self, forKey: .start)
        end = try container.decode(Date.self, forKey: .end)
        scope = container.value(.scope, default: nil)
        outcome = container.value(.outcome, default: "unknown")
        counts = container.value(.counts, default: [:])
        albums = container.value(.albums, default: [:])
        error = container.value(.error, default: nil)
    }
}

public actor RunLog {
    public let fileURL: URL

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    public func records() -> [RunRecord] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return data.split(separator: UInt8(ascii: "\n")).compactMap { try? decoder.decode(RunRecord.self, from: Data($0)) }
    }

    public func nextRunID() -> Int {
        (records().map(\.run).max() ?? 0) + 1
    }

    public func append(_ record: RunRecord) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        encoder.dateEncodingStrategy = .iso8601
        var line = try encoder.encode(record)
        line.append(UInt8(ascii: "\n"))

        if !FileManager.default.fileExists(atPath: fileURL.path) {
            FileManager.default.createFile(atPath: fileURL.path, contents: nil)
        }
        let handle = try FileHandle(forUpdating: fileURL)
        defer { try? handle.close() }
        let end = try handle.seekToEnd()
        if end > 0 {
            try handle.seek(toOffset: end - 1)
            if try handle.read(upToCount: 1) != Data([UInt8(ascii: "\n")]) {
                line.insert(UInt8(ascii: "\n"), at: 0)
            }
            try handle.seekToEnd()
        }
        try handle.write(contentsOf: line)
        try handle.synchronize()
    }
}
