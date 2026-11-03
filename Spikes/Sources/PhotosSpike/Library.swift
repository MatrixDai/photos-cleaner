import AppKit
import Foundation
import ImageIO
import Photos

struct HeaderRead: Sendable {
    var properties: [String: any Sendable]?
    var bytes = 0
    var seconds = 0.0
    var error: String?
}

struct DataRead: Sendable {
    var bytes = 0
    var seconds = 0.0
    var progressCalls = 0
    var error: String?
}

final class Locked<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value
    init(_ value: Value) { self.value = value }
    func with<R>(_ body: (inout Value) -> R) -> R {
        lock.lock()
        defer { lock.unlock() }
        return body(&value)
    }
}

enum Library {
    static func fetch(_ type: PHAssetMediaType, in range: ClosedRange<Date>?, limit: Int) -> [PHAsset] {
        let options = PHFetchOptions()
        options.includeHiddenAssets = false
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: true)]
        var predicates = [NSPredicate(format: "mediaType == %d", type.rawValue)]
        if let range {
            predicates.append(NSPredicate(format: "creationDate >= %@ AND creationDate < %@",
                                          range.lowerBound as NSDate, range.upperBound as NSDate))
        }
        options.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: predicates)
        var assets: [PHAsset] = []
        PHAsset.fetchAssets(with: options).enumerateObjects { asset, _, stop in
            if !asset.mediaSubtypes.contains(.photoScreenshot) { assets.append(asset) }
            if assets.count >= limit { stop.pointee = true }
        }
        return assets
    }

    /// PhotoKit runs the block on its own queue, so it must not inherit the caller's main-actor isolation.
    static func change(_ block: @escaping @Sendable () -> Void) async throws {
        try await PHPhotoLibrary.shared().performChanges(block)
    }

    static func original(of asset: PHAsset) -> PHAssetResource? {
        let wanted: PHAssetResourceType = asset.mediaType == .video ? .video : .photo
        return PHAssetResource.assetResources(for: asset).first { $0.type == wanted }
    }

    static func isLocal(_ resource: PHAssetResource) async -> Bool {
        let options = PHAssetResourceRequestOptions()
        options.isNetworkAccessAllowed = false
        let state = Locked((resumed: false, id: PHAssetResourceDataRequestID(0)))
        return await withCheckedContinuation { continuation in
            let id = PHAssetResourceManager.default().requestData(for: resource, options: options, dataReceivedHandler: { _ in
                let first = state.with { s -> Bool in
                    defer { s.resumed = true }
                    return !s.resumed
                }
                if first {
                    PHAssetResourceManager.default().cancelDataRequest(state.with { $0.id })
                    continuation.resume(returning: true)
                }
            }, completionHandler: { error in
                let first = state.with { s -> Bool in
                    defer { s.resumed = true }
                    return !s.resumed
                }
                if first { continuation.resume(returning: error == nil) }
            })
            state.with { $0.id = id }
        }
    }

    static func readHeader(_ resource: PHAssetResource) async -> HeaderRead {
        let options = PHAssetResourceRequestOptions()
        options.isNetworkAccessAllowed = true
        let start = Date()
        let state = Locked((source: CGImageSourceCreateIncremental(nil), data: Data(), resumed: false,
                            id: PHAssetResourceDataRequestID(0)))

        @Sendable func parsed(_ source: CGImageSource, _ data: Data, final: Bool) -> [String: Any]? {
            CGImageSourceUpdateData(source, data as CFData, final)
            guard let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any] else { return nil }
            let hasTIFF = props[kCGImagePropertyTIFFDictionary as String] != nil
            let hasEXIF = props[kCGImagePropertyExifDictionary as String] != nil
            return hasTIFF || (hasEXIF && data.count > 512 * 1024) || final ? props : nil
        }

        return await withCheckedContinuation { continuation in
            let id = PHAssetResourceManager.default().requestData(for: resource, options: options, dataReceivedHandler: { chunk in
                let found = state.with { s -> HeaderRead? in
                    guard !s.resumed else { return nil }
                    s.data.append(chunk)
                    guard let props = parsed(s.source, s.data, final: false) else { return nil }
                    s.resumed = true
                    return HeaderRead(properties: sendable(props), bytes: s.data.count,
                                      seconds: Date().timeIntervalSince(start))
                }
                guard let found else { return }
                PHAssetResourceManager.default().cancelDataRequest(state.with { $0.id })
                continuation.resume(returning: found)
            }, completionHandler: { error in
                let result = state.with { s -> HeaderRead? in
                    guard !s.resumed else { return nil }
                    s.resumed = true
                    let props = s.data.isEmpty ? nil : parsed(s.source, s.data, final: true)
                    return HeaderRead(properties: sendable(props), bytes: s.data.count,
                                      seconds: Date().timeIntervalSince(start), error: error?.localizedDescription)
                }
                if let result { continuation.resume(returning: result) }
            })
            state.with { $0.id = id }
        }
    }

    static func download(_ resource: PHAssetResource, to file: URL? = nil) async -> DataRead {
        let options = PHAssetResourceRequestOptions()
        options.isNetworkAccessAllowed = true
        let progress = Locked(0)
        options.progressHandler = { _ in progress.with { $0 += 1 } }
        let start = Date()
        if let file {
            do {
                try await PHAssetResourceManager.default().writeData(for: resource, toFile: file, options: options)
                let size = (try? FileManager.default.attributesOfItem(atPath: file.path)[.size] as? Int) ?? 0
                return DataRead(bytes: size, seconds: Date().timeIntervalSince(start), progressCalls: progress.with { $0 })
            } catch {
                return DataRead(seconds: Date().timeIntervalSince(start), progressCalls: progress.with { $0 },
                                error: error.localizedDescription)
            }
        }
        let bytes = Locked(0)
        return await withCheckedContinuation { continuation in
            PHAssetResourceManager.default().requestData(for: resource, options: options, dataReceivedHandler: { chunk in
                bytes.with { $0 += chunk.count }
            }, completionHandler: { error in
                continuation.resume(returning: DataRead(bytes: bytes.with { $0 }, seconds: Date().timeIntervalSince(start),
                                                        progressCalls: progress.with { $0 }, error: error?.localizedDescription))
            })
        }
    }

    static func image(_ asset: PHAsset, side: CGFloat) async -> CGImage? {
        let options = PHImageRequestOptions()
        options.deliveryMode = .highQualityFormat
        options.resizeMode = .fast
        options.isNetworkAccessAllowed = true
        let resumed = Locked(false)
        return await withCheckedContinuation { continuation in
            PHImageManager.default().requestImage(for: asset, targetSize: CGSize(width: side, height: side),
                                                  contentMode: .aspectFit, options: options) { image, info in
                if (info?[PHImageResultIsDegradedKey] as? Bool) == true { return }
                let first = resumed.with { r -> Bool in
                    defer { r = true }
                    return !r
                }
                if first { continuation.resume(returning: image?.cgImage(forProposedRect: nil, context: nil, hints: nil)) }
            }
        }
    }

    static func saveJPEG(_ image: CGImage, to url: URL) {
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.jpeg" as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary)
        CGImageDestinationFinalize(destination)
    }

    fileprivate static func sendable(_ props: [String: Any]?) -> [String: any Sendable]? {
        guard let props else { return nil }
        let tiff = props[kCGImagePropertyTIFFDictionary as String] as? [String: Any] ?? [:]
        var copy: [String: String] = [:]
        for key in [kCGImagePropertyTIFFMake, kCGImagePropertyTIFFModel] {
            if let value = tiff[key as String] as? String { copy[key as String] = value }
        }
        return [kCGImagePropertyTIFFDictionary as String: copy]
    }
}

extension PHAsset: @retroactive @unchecked Sendable {}
extension PHAssetResource: @retroactive @unchecked Sendable {}
