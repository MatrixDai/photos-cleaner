import Foundation
@testable import CleanerCore

final class FakeLibrary: PhotoLibraryService, @unchecked Sendable {
    struct Album {
        var title: String
        var size: Int
    }

    private let lock = NSLock()
    private var _status: LibraryAuthorization
    private var _grantOnRequest: LibraryAuthorization
    private var _albums: [String: Album] = [:]
    private var _created: [String] = []
    private var nextID = 1

    init(status: LibraryAuthorization = .authorized, grantOnRequest: LibraryAuthorization = .authorized) {
        _status = status
        _grantOnRequest = grantOnRequest
    }

    var albums: [String: Album] { lock.withLock { _albums } }
    var createdNames: [String] { lock.withLock { _created } }

    func setStatus(_ status: LibraryAuthorization) { lock.withLock { _status = status } }

    @discardableResult
    func addAlbum(_ title: String, size: Int = 0) -> String {
        lock.withLock {
            let id = "album-\(nextID)/L0/040"
            nextID += 1
            _albums[id] = Album(title: title, size: size)
            return id
        }
    }

    func rename(_ id: String, to title: String) { lock.withLock { _albums[id]?.title = title } }
    func remove(_ id: String) { lock.withLock { _ = _albums.removeValue(forKey: id) } }
    func setSize(_ id: String, _ size: Int) { lock.withLock { _albums[id]?.size = size } }

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

    func albumSize(id: String) async -> Int? { lock.withLock { _albums[id]?.size } }
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
    let url = FileManager.default.temporaryDirectory.appending(path: "cleaner-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
    return url
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
