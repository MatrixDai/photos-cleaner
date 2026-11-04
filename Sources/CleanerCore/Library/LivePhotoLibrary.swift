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

    public func albumMembers(id: String) async -> Set<String> {
        guard let album = PHAssetCollection.fetchAssetCollections(withLocalIdentifiers: [id], options: nil).firstObject else {
            return []
        }
        var members = Set<String>()
        PHAsset.fetchAssets(in: album, options: nil).enumerateObjects { asset, _, _ in members.insert(asset.localIdentifier) }
        return members
    }

    public func addAssets(_ ids: [String], toAlbum albumID: String) async throws {
        try await Self.change {
            guard let album = PHAssetCollection.fetchAssetCollections(withLocalIdentifiers: [albumID], options: nil).firstObject else { return }
            PHAssetCollectionChangeRequest(for: album)?.addAssets(PHAsset.fetchAssets(withLocalIdentifiers: ids, options: nil))
        }
    }

    public func removeAssets(_ ids: [String], fromAlbum albumID: String) async throws {
        try await Self.change {
            guard let album = PHAssetCollection.fetchAssetCollections(withLocalIdentifiers: [albumID], options: nil).firstObject else { return }
            PHAssetCollectionChangeRequest(for: album)?.removeAssets(PHAsset.fetchAssets(withLocalIdentifiers: ids, options: nil))
        }
    }

    public func videos(createdBefore cutoff: Date) async -> [LibraryVideo] {
        let options = PHFetchOptions()
        options.includeHiddenAssets = false
        options.predicate = NSPredicate(format: "mediaType == %d AND creationDate < %@", PHAssetMediaType.video.rawValue, cutoff as NSDate)
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: true)]
        var videos: [LibraryVideo] = []
        PHAsset.fetchAssets(with: options).enumerateObjects { asset, _, _ in
            let resources = PHAssetResource.assetResources(for: asset).compactMap { resource -> LibraryVideoResource? in
                guard let kind = Self.kind(of: resource.type) else { return nil }
                return LibraryVideoResource(kind: kind, filename: resource.filename, size: resource.dataSize)
            }
            videos.append(LibraryVideo(id: asset.localIdentifier, creationDate: asset.creationDate,
                                       rating: asset.rating.rawValue, resources: resources))
        }
        return videos
    }

    public func resourceData(assetID: String, kind: LibraryVideoResource.Kind) -> AsyncThrowingStream<Data, any Error> {
        AsyncThrowingStream { continuation in
            guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [assetID], options: nil).firstObject,
                  let resource = PHAssetResource.assetResources(for: asset).first(where: { Self.kind(of: $0.type) == kind }) else {
                continuation.finish(throwing: CocoaError(.fileNoSuchFile))
                return
            }
            let options = PHAssetResourceRequestOptions()
            options.isNetworkAccessAllowed = true
            let request = PHAssetResourceManager.default().requestData(for: resource, options: options, dataReceivedHandler: { chunk in
                continuation.yield(chunk)
            }, completionHandler: { error in
                continuation.finish(throwing: error)
            })
            continuation.onTermination = { termination in
                if case .cancelled = termination { PHAssetResourceManager.default().cancelDataRequest(request) }
            }
        }
    }

    public func photos(_ query: PhotoQuery) async -> [LibraryPhoto] {
        let options = PHFetchOptions()
        options.includeHiddenAssets = false
        var predicates = [NSPredicate(format: "mediaType == %d", PHAssetMediaType.image.rawValue)]
        if let range = query.range {
            predicates.append(NSPredicate(format: "creationDate >= %@ AND creationDate < %@",
                                          range.lowerBound as NSDate, range.upperBound as NSDate))
        }
        if query.unratedOnly { predicates.append(NSPredicate(format: "rating == 0")) }
        options.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: predicates)
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        var photos: [LibraryPhoto] = []
        PHAsset.fetchAssets(with: options).enumerateObjects { asset, _, _ in
            photos.append(LibraryPhoto(id: asset.localIdentifier, creationDate: asset.creationDate, rating: asset.rating.rawValue,
                                       isScreenshot: asset.mediaSubtypes.contains(.photoScreenshot)))
        }
        return photos
    }

    public func ratings(of ids: [String]) async -> [String: Int] {
        var ratings: [String: Int] = [:]
        PHAsset.fetchAssets(withLocalIdentifiers: ids, options: nil).enumerateObjects { asset, _, _ in
            ratings[asset.localIdentifier] = asset.rating.rawValue
        }
        return ratings
    }

    public func setRatings(_ ratings: [String: Int]) async throws {
        try await Self.change {
            PHAsset.fetchAssets(withLocalIdentifiers: Array(ratings.keys), options: nil).enumerateObjects { asset, _, _ in
                PHAssetChangeRequest(for: asset).rating = PHAsset.Rating(rawValue: ratings[asset.localIdentifier] ?? 0) ?? .unset
            }
        }
    }

    private static func kind(of type: PHAssetResourceType) -> LibraryVideoResource.Kind? {
        switch type {
        case .video: .original
        case .fullSizeVideo: .edited
        default: nil
        }
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
