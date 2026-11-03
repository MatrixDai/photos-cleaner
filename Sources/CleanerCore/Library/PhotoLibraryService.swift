import Foundation

public enum LibraryAuthorization: Sendable, Equatable {
    case notDetermined, authorized, limited, denied, restricted
}

/// Everything the app does to the Photos library goes through here, and there is deliberately no delete.
public protocol PhotoLibraryService: Sendable {
    func authorization() -> LibraryAuthorization
    func requestAuthorization() async -> LibraryAuthorization
    func albumTitle(id: String) async -> String?
    func albumID(named name: String) async -> String?
    func createAlbum(named name: String) async throws -> String
    func albumSize(id: String) async -> Int?
    func albumMembers(id: String) async -> Set<String>
    func addAssets(_ ids: [String], toAlbum albumID: String) async throws
    func removeAssets(_ ids: [String], fromAlbum albumID: String) async throws
    func videos(createdBefore cutoff: Date) async -> [LibraryVideo]
    func resourceData(assetID: String, kind: LibraryVideoResource.Kind) -> AsyncThrowingStream<Data, any Error>
}

public struct LibraryVideoResource: Equatable, Sendable {
    public enum Kind: String, Sendable {
        case original, edited
    }

    public var kind: Kind
    public var filename: String?
    public var size: Int?

    public init(kind: Kind, filename: String?, size: Int?) {
        self.kind = kind
        self.filename = filename
        self.size = size
    }
}

public struct LibraryVideo: Equatable, Sendable, Identifiable {
    public var id: String
    public var creationDate: Date?
    public var rating: Int
    public var resources: [LibraryVideoResource]

    public init(id: String, creationDate: Date?, rating: Int, resources: [LibraryVideoResource]) {
        self.id = id
        self.creationDate = creationDate
        self.rating = rating
        self.resources = resources
    }

    public var original: LibraryVideoResource? { resources.first { $0.kind == .original } }
    public var edited: LibraryVideoResource? { resources.first { $0.kind == .edited } }
}

public enum AlbumRole: String, CaseIterable, Sendable {
    case videoToDelete, photoLowQuality, photoDuplicated

    public var keyPath: WritableKeyPath<AppSettings, AlbumRef> {
        switch self {
        case .videoToDelete: \.videos.album
        case .photoLowQuality: \.photos.albums.lowQuality
        case .photoDuplicated: \.photos.albums.duplicated
        }
    }
}

public struct AlbumService: Sendable {
    let library: any PhotoLibraryService

    public init(library: any PhotoLibraryService) {
        self.library = library
    }

    public func resolve(_ ref: AlbumRef) async throws -> AlbumRef {
        if let id = ref.id, await library.albumTitle(id: id) != nil { return ref }
        if let id = await library.albumID(named: ref.name) { return AlbumRef(name: ref.name, id: id) }
        return AlbumRef(name: ref.name, id: try await library.createAlbum(named: ref.name))
    }
}
