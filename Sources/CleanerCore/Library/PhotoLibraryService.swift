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
}

public enum AlbumRole: String, CaseIterable, Sendable {
    case videoToDelete, photoLowQuality, photoDuplicated

    var keyPath: WritableKeyPath<AppSettings, AlbumRef> {
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
