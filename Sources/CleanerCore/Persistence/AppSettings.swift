import Foundation

public struct AlbumRef: Codable, Equatable, Sendable {
    public var name: String
    public var id: String?

    public init(name: String, id: String? = nil) {
        self.name = name
        self.id = id
    }
}

public struct FolderRef: Codable, Equatable, Sendable {
    public var path: String
    public var bookmark: Data?

    public init(path: String, bookmark: Data? = nil) {
        self.path = path
        self.bookmark = bookmark
    }
}

public struct AppSettings: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1

    public var schemaVersion = AppSettings.currentSchemaVersion
    public var videos = VideoSettings()
    public var photos = PhotoSettings()

    public init() {}

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = AppSettings()
        schemaVersion = container.value(.schemaVersion, default: defaults.schemaVersion)
        videos = container.value(.videos, default: defaults.videos)
        photos = container.value(.photos, default: defaults.photos)
    }
}

public struct VideoSettings: Codable, Equatable, Sendable {
    public static let olderThanDaysRange = 1...3650
    public static let parallelExportsRange = 1...4

    public var exportDir = FolderRef(path: FileManager.default.homeDirectoryForCurrentUser
        .appending(path: "Downloads/PhotosCleaner/Videos").path)
    public var olderThanDays = 90
    public var nameTemplate = "{yyyy}/{yyyy}-{MM}-{dd} {filename}"
    public var parallelExports = 2
    public var album = AlbumRef(name: "video-to-delete")

    public init() {}

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = VideoSettings()
        exportDir = container.value(.exportDir, default: defaults.exportDir)
        olderThanDays = container.value(.olderThanDays, default: defaults.olderThanDays).clamped(to: Self.olderThanDaysRange)
        nameTemplate = container.value(.nameTemplate, default: defaults.nameTemplate)
        parallelExports = container.value(.parallelExports, default: defaults.parallelExports).clamped(to: Self.parallelExportsRange)
        album = container.value(.album, default: defaults.album)
    }
}

public struct PhotoAlbums: Codable, Equatable, Sendable {
    public var duplicated = AlbumRef(name: "photo-duplicated")

    public init() {}

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = PhotoAlbums()
        duplicated = container.value(.duplicated, default: defaults.duplicated)
    }
}

public struct PhotoSettings: Codable, Equatable, Sendable {
    public var starThresholds = [-0.3, 0.0, 0.3, 0.6]
    public var albums = PhotoAlbums()

    public init() {}

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = PhotoSettings()
        let thresholds = container.value(.starThresholds, default: defaults.starThresholds)
        starThresholds = thresholds.count == defaults.starThresholds.count && thresholds == thresholds.sorted()
            ? thresholds : defaults.starThresholds
        albums = container.value(.albums, default: defaults.albums)
    }
}

extension KeyedDecodingContainer {
    /// A missing or malformed field falls back to its default, so one bad value never discards the rest of the file.
    func value<T: Decodable>(_ key: Key, default fallback: T) -> T {
        (try? decodeIfPresent(T.self, forKey: key)) ?? fallback
    }
}

extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
