import Foundation
import Photos

public struct LivePhotoLibrary: PhotoLibraryService {
    public init() {}

    public func authorization() -> LibraryAuthorization {
        Self.map(PHPhotoLibrary.authorizationStatus(for: .readWrite))
    }

    public func requestAuthorization() async -> LibraryAuthorization {
        Self.map(await PHPhotoLibrary.requestAuthorization(for: .readWrite))
    }

    public func albumTitle(id: String) async -> String? {
        guard let album = PHAssetCollection.fetchAssetCollections(withLocalIdentifiers: [id], options: nil).firstObject else {
            return nil
        }
        return album.localizedTitle ?? ""
    }

    public func albumID(named name: String) async -> String? {
        var found: String?
        PHCollectionList.fetchTopLevelUserCollections(with: nil).enumerateObjects { collection, _, stop in
            guard let album = collection as? PHAssetCollection, album.assetCollectionType == .album,
                  album.localizedTitle == name else { return }
            found = album.localIdentifier
            stop.pointee = true
        }
        return found
    }

    public func createAlbum(named name: String) async throws -> String {
        let created = LockedValue<String?>(nil)
        try await Self.change {
            let request = PHAssetCollectionChangeRequest.creationRequestForAssetCollection(withTitle: name)
            created.set(request.placeholderForCreatedAssetCollection.localIdentifier)
        }
        guard let id = created.get() else { throw CocoaError(.featureUnsupported) }
        return id
    }

    public func albumSize(id: String) async -> Int? {
        guard let album = PHAssetCollection.fetchAssetCollections(withLocalIdentifiers: [id], options: nil).firstObject else {
            return nil
        }
        return PHAsset.fetchAssets(in: album, options: nil).count
    }

    /// PhotoKit runs the block on its own queue; a block that inherited main-actor isolation would trap there.
    static func change(_ block: @escaping @Sendable () -> Void) async throws {
        try await PHPhotoLibrary.shared().performChanges(block)
    }

    private static func map(_ status: PHAuthorizationStatus) -> LibraryAuthorization {
        switch status {
        case .authorized: .authorized
        case .limited: .limited
        case .denied: .denied
        case .restricted: .restricted
        default: .notDetermined
        }
    }
}

final class LockedValue<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value

    init(_ value: Value) {
        self.value = value
    }

    func get() -> Value {
        lock.withLock { value }
    }

    func set(_ newValue: Value) {
        lock.withLock { value = newValue }
    }
}
