import CryptoKit
import Foundation
@testable import CleanerCore

struct FakeError: Error, LocalizedError {
    var message = "network connection lost"
    var errorDescription: String? { message }
}

final class FakeLibrary: PhotoLibraryService, @unchecked Sendable {
    struct Album {
        var title: String
        var members: Set<String> = []
    }

    struct Content {
        var data: Data
        var failuresLeft = 0
        var hangs = false
    }

    private let lock = NSLock()
    private var _status: LibraryAuthorization
    private var _grantOnRequest: LibraryAuthorization
    private var _albums: [String: Album] = [:]
    private var _created: [String] = []
    private var _videos: [LibraryVideo] = []
    private var _content: [String: Content] = [:]
    private var _addBatches: [[String]] = []
    private var _downloads: [String] = []
    private var _photos: [LibraryPhoto] = []
    private var _ratingBatches: [[String: Int]] = []
    private var nextID = 1
    var onDownload: (@Sendable (String) -> Void)?

    init(status: LibraryAuthorization = .authorized, grantOnRequest: LibraryAuthorization = .authorized) {
        _status = status
        _grantOnRequest = grantOnRequest
    }

    var albums: [String: Album] { lock.withLock { _albums } }
    var createdNames: [String] { lock.withLock { _created } }
    var addBatches: [[String]] { lock.withLock { _addBatches } }
    var downloads: [String] { lock.withLock { _downloads } }
    var ratingBatches: [[String: Int]] { lock.withLock { _ratingBatches } }

    func addPhoto(_ id: String, created: Date, rating: Int = 0, screenshot: Bool = false) {
        lock.withLock { _photos.append(LibraryPhoto(id: id, creationDate: created, rating: rating, isScreenshot: screenshot)) }
    }

    func rating(_ id: String) -> Int? {
        lock.withLock { _photos.first { $0.id == id }?.rating }
    }

    func setPhotoRating(_ id: String, _ rating: Int) {
        lock.withLock {
            if let index = _photos.firstIndex(where: { $0.id == id }) { _photos[index].rating = rating }
        }
    }

    func photos(_ query: PhotoQuery) async -> [LibraryPhoto] {
        lock.withLock {
            _photos.filter { photo in
                guard let date = photo.creationDate, query.contains(date) else { return false }
                return !query.unratedOnly || photo.rating == 0
            }
            .sorted { $0.creationDate! < $1.creationDate! }
        }
    }

    func ratings(of ids: [String]) async -> [String: Int] {
        lock.withLock {
            Dictionary(uniqueKeysWithValues: _photos.filter { ids.contains($0.id) }.map { ($0.id, $0.rating) })
        }
    }

    func setRatings(_ ratings: [String: Int]) async throws {
        lock.withLock {
            _ratingBatches.append(ratings)
            for (id, rating) in ratings {
                if let index = _photos.firstIndex(where: { $0.id == id }) { _photos[index].rating = rating }
            }
        }
    }

    func setStatus(_ status: LibraryAuthorization) { lock.withLock { _status = status } }

    @discardableResult
    func addAlbum(_ title: String, members: Set<String> = []) -> String {
        lock.withLock {
            let id = "album-\(nextID)/L0/040"
            nextID += 1
            _albums[id] = Album(title: title, members: members)
            return id
        }
    }

    func rename(_ id: String, to title: String) { lock.withLock { _albums[id]?.title = title } }
    func remove(_ id: String) { lock.withLock { _ = _albums.removeValue(forKey: id) } }
    func setMembers(_ id: String, _ members: Set<String>) { lock.withLock { _albums[id]?.members = members } }

    @discardableResult
    func addVideo(_ id: String, created: Date, rating: Int = 0, filename: String = "IMG_0001.MOV", content: Data,
                  edited: Data? = nil, reportedSize: Int? = nil, failures: Int = 0, hangs: Bool = false) -> LibraryVideo {
        var resources = [LibraryVideoResource(kind: .original, filename: filename, size: reportedSize ?? content.count)]
        if let edited { resources.append(LibraryVideoResource(kind: .edited, filename: "FullSizeRender.mov", size: edited.count)) }
        let video = LibraryVideo(id: id, creationDate: created, rating: rating, resources: resources)
        lock.withLock {
            _videos.append(video)
            _content["\(id)#original"] = Content(data: content, failuresLeft: failures, hangs: hangs)
            if let edited { _content["\(id)#edited"] = Content(data: edited) }
        }
        return video
    }

    func setRating(_ id: String, _ rating: Int) {
        lock.withLock {
            guard let index = _videos.firstIndex(where: { $0.id == id }) else { return }
            _videos[index].rating = rating
        }
    }

    func authorization() -> LibraryAuthorization { lock.withLock { _status } }

    func requestAuthorization() async -> LibraryAuthorization {
        lock.withLock {
            _status = _grantOnRequest
            return _status
        }
    }

    func albumTitle(id: String) async -> String? { lock.withLock { _albums[id]?.title } }

    func albumID(named name: String) async -> String? {
        lock.withLock { _albums.first { $0.value.title == name }?.key }
    }

    func createAlbum(named name: String) async throws -> String {
        lock.withLock { _created.append(name) }
        return addAlbum(name)
    }

    func albumSize(id: String) async -> Int? { lock.withLock { _albums[id]?.members.count } }

    func albumMembers(id: String) async -> Set<String> { lock.withLock { _albums[id]?.members ?? [] } }

    func addAssets(_ ids: [String], toAlbum albumID: String) async throws {
        lock.withLock {
            _addBatches.append(ids)
            _albums[albumID]?.members.formUnion(ids)
        }
    }

    func removeAssets(_ ids: [String], fromAlbum albumID: String) async throws {
        lock.withLock { _albums[albumID]?.members.subtract(ids) }
    }

    func videos(createdBefore cutoff: Date) async -> [LibraryVideo] {
        lock.withLock { _videos.filter { ($0.creationDate ?? .distantFuture) < cutoff }.sorted { $0.creationDate! < $1.creationDate! } }
    }

    func resourceData(assetID: String, kind: LibraryVideoResource.Kind) -> AsyncThrowingStream<Data, any Error> {
        let key = "\(assetID)#\(kind.rawValue)"
        let (content, fails) = lock.withLock { () -> (Content?, Bool) in
            _downloads.append(key)
            guard var content = _content[key] else { return (nil, false) }
            let fails = content.failuresLeft > 0
            if fails { content.failuresLeft -= 1 }
            _content[key] = content
            return (content, fails)
        }
        onDownload?(assetID)
        return AsyncThrowingStream { continuation in
            guard let content else { return continuation.finish(throwing: FakeError(message: "no such resource")) }
            let chunks = stride(from: 0, to: content.data.count, by: 1000).map { content.data[$0..<min($0 + 1000, content.data.count)] }
            if fails {
                if let first = chunks.first { continuation.yield(Data(first)) }
                return continuation.finish(throwing: FakeError())
            }
            if content.hangs {
                if let first = chunks.first { continuation.yield(Data(first)) }
                return
            }
            for chunk in chunks { continuation.yield(Data(chunk)) }
            continuation.finish()
        }
    }
}

final class FakeKeepAwake: KeepAwake, @unchecked Sendable {
    private let lock = NSLock()
    private var _held = 0
    private var _total = 0

    var held: Int { lock.withLock { _held } }
    var total: Int { lock.withLock { _total } }

    func hold(reason: String) -> any KeepAwakeHold {
        lock.withLock {
            _held += 1
            _total += 1
        }
        return Hold(owner: self)
    }

    private struct Hold: KeepAwakeHold {
        let owner: FakeKeepAwake
        func release() { owner.lock.withLock { owner._held -= 1 } }
    }
}

func temporaryDirectory() -> URL {
    FileManager.default.temporaryDirectory.appending(path: "cleaner-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
}

func sha256(_ data: Data) -> String {
    FileHasher.hex(SHA256.hash(data: data))
}

func randomData(_ count: Int = 5_000) -> Data {
    Data((0..<count).map { _ in UInt8.random(in: 0...255) })
}

@MainActor
func eventually(timeout: Duration = .seconds(5), _ condition: () async -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return await condition()
}

final class FakeAnalyzer: PhotoAnalyzing, @unchecked Sendable {
    private let lock = NSLock()
    private var scores: [String: Double] = [:]
    private var nonCamera: Set<String> = []
    private var failing: Set<String> = []
    private var _tagCalls: [String] = []
    private var _scoreCalls: [String] = []

    var tagCalls: [String] { lock.withLock { _tagCalls } }
    var scoreCalls: [String] { lock.withLock { _scoreCalls } }

    func camera(_ id: String, score: Double) { lock.withLock { scores[id] = score } }
    func notCamera(_ id: String) { lock.withLock { _ = nonCamera.insert(id) } }
    func fail(_ id: String) { lock.withLock { _ = failing.insert(id) } }

    func cameraTags(_ photoID: String) async throws -> CameraTags {
        try lock.withLock {
            _tagCalls.append(photoID)
            if failing.contains(photoID) { throw FakeError(message: "iCloud download failed") }
            return nonCamera.contains(photoID) ? CameraTags(make: nil, model: nil) : CameraTags(make: "Apple", model: "iPhone")
        }
    }

    func aestheticsScore(_ photoID: String) async throws -> Double {
        lock.withLock {
            _scoreCalls.append(photoID)
            return scores[photoID] ?? 0
        }
    }
}
