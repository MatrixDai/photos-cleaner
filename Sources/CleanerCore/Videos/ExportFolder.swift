import CryptoKit
import Foundation

public enum FolderState: Equatable, Sendable {
    case writable
    case willBeCreated
    case notWritable(String)
}

public enum WritableCheck {
    public static let tempFolderName = ".photoscleaner-tmp"

    public static func check(_ folder: URL) -> FolderState {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDirectory) else { return .willBeCreated }
        guard isDirectory.boolValue else { return .notWritable("\(folder.lastPathComponent) is a file, not a folder") }
        let probe = folder.appending(path: ".photoscleaner-write-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: probe) }
        do {
            try Data([0x2A]).write(to: probe)
            return try Data(contentsOf: probe) == Data([0x2A]) ? .writable : .notWritable("The test file read back wrong")
        } catch {
            return .notWritable(error.localizedDescription)
        }
    }

    public static func freeSpace(_ folder: URL) -> Int64? {
        var url = folder
        while !FileManager.default.fileExists(atPath: url.path), url.pathComponents.count > 1 {
            url = url.deletingLastPathComponent()
        }
        let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey])
        return values?.volumeAvailableCapacityForImportantUsage ?? values?.volumeAvailableCapacity.map(Int64.init)
    }

    public static func removeStaleTemporaryFiles(in folder: URL, olderThan age: TimeInterval = 24 * 3600, now: Date = .now) {
        let temp = folder.appending(path: tempFolderName)
        guard let files = try? FileManager.default.contentsOfDirectory(at: temp, includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
        for file in files {
            let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? now
            if now.timeIntervalSince(modified) > age { try? FileManager.default.removeItem(at: file) }
        }
    }
}

public enum FileHasher {
    public static func sha256(of file: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 4 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hex(hasher.finalize())
    }

    public static func hex(_ digest: SHA256.Digest) -> String {
        digest.map { String(format: "%02x", $0) }.joined()
    }
}

/// The files already in the export folder, indexed by size so a hash is only ever computed for a size match.
public actor ExportFolder {
    public let root: URL
    public let temporary: URL
    private var bySize: [Int: [URL]] = [:]
    private var hashes: [URL: String] = [:]

    public init(root: URL) {
        self.root = root
        temporary = root.appending(path: WritableCheck.tempFolderName, directoryHint: .isDirectory)
        let keys: [URLResourceKey] = [.fileSizeKey, .isRegularFileKey]
        let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])
        while let file = files?.nextObject() as? URL {
            guard let values = try? file.resourceValues(forKeys: Set(keys)), values.isRegularFile == true,
                  let size = values.fileSize else { continue }
            bySize[size, default: []].append(file.standardizedFileURL)
        }
    }

    public var fileCount: Int { bySize.values.reduce(0) { $0 + $1.count } }

    public func duplicate(size: Int, sha256: String) throws -> URL? {
        for candidate in bySize[size] ?? [] where try hash(candidate) == sha256 {
            return candidate
        }
        return nil
    }

    public func place(_ temp: URL, at relativePath: String, size: Int, sha256: String) throws -> URL {
        // Recreating a vanished root would write onto the boot disk when an external export volume is unmounted.
        guard FileManager.default.fileExists(atPath: root.path) else { throw CocoaError(.fileNoSuchFile, userInfo: [NSFilePathErrorKey: root.path]) }
        var target = root.appending(path: relativePath)
        var number = 2
        while FileManager.default.fileExists(atPath: target.path) {
            target = root.appending(path: NamingEngine.numbered(relativePath, number))
            number += 1
        }
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: temp, to: target)
        let placed = target.standardizedFileURL
        bySize[size, default: []].append(placed)
        hashes[placed] = sha256
        return placed
    }

    public func forget(_ file: URL, size: Int) {
        let standardized = file.standardizedFileURL
        bySize[size]?.removeAll { $0 == standardized }
        hashes[standardized] = nil
    }

    public func relativePath(of file: URL) -> String {
        let rootPath = root.standardizedFileURL.path
        let path = file.standardizedFileURL.path
        return path.hasPrefix(rootPath + "/") ? String(path.dropFirst(rootPath.count + 1)) : path
    }

    private func hash(_ file: URL) throws -> String {
        if let known = hashes[file] { return known }
        let value = try FileHasher.sha256(of: file)
        hashes[file] = value
        return value
    }
}
