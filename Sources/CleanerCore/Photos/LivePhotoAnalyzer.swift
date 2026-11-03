import AppKit
import Foundation
import ImageIO
import Photos
import Vision

public struct LivePhotoAnalyzer: PhotoAnalyzing {
    public static let derivativeSide: CGFloat = 1024

    public init() {}

    public func cameraTags(_ photoID: String) async throws -> CameraTags {
        guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [photoID], options: nil).firstObject,
              let original = PHAssetResource.assetResources(for: asset).first(where: { $0.type == .photo }) else {
            throw CocoaError(.fileNoSuchFile)
        }
        return try await Self.readTags(original)
    }

    public func aestheticsScore(_ photoID: String) async throws -> Double {
        guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [photoID], options: nil).firstObject else {
            throw CocoaError(.fileNoSuchFile)
        }
        guard let image = await Self.derivative(asset, side: Self.derivativeSide) else { throw CocoaError(.fileReadUnknown) }
        return Double(try await CalculateImageAestheticsScoresRequest().perform(on: image).overallScore)
    }

    static func derivative(_ asset: PHAsset, side: CGFloat) async -> CGImage? {
        let options = PHImageRequestOptions()
        options.deliveryMode = .highQualityFormat
        options.resizeMode = .fast
        options.isNetworkAccessAllowed = true
        let resumed = LockedValue(false)
        return await withCheckedContinuation { continuation in
            PHImageManager.default().requestImage(for: asset, targetSize: CGSize(width: side, height: side),
                                                  contentMode: .aspectFit, options: options) { image, info in
                if (info?[PHImageResultIsDegradedKey] as? Bool) == true { return }
                guard !resumed.get() else { return }
                resumed.set(true)
                continuation.resume(returning: image?.cgImage(forProposedRect: nil, context: nil, hints: nil))
            }
        }
    }

    /// Stops once the EXIF is parsed; for an iCloud-only original PhotoKit has already downloaded the whole file by then.
    private static func readTags(_ resource: PHAssetResource) async throws -> CameraTags {
        let options = PHAssetResourceRequestOptions()
        options.isNetworkAccessAllowed = true
        let state = HeaderState()
        return try await withCheckedThrowingContinuation { continuation in
            let request = PHAssetResourceManager.default().requestData(for: resource, options: options, dataReceivedHandler: { chunk in
                guard let tags = state.append(chunk) else { return }
                PHAssetResourceManager.default().cancelDataRequest(state.request)
                continuation.resume(returning: tags)
            }, completionHandler: { error in
                guard let result = state.finish(error: error) else { return }
                continuation.resume(with: result)
            })
            state.request = request
        }
    }
}

private final class HeaderState: @unchecked Sendable {
    private let lock = NSLock()
    private let source = CGImageSourceCreateIncremental(nil)
    private var data = Data()
    private var resumed = false
    private var _request = PHAssetResourceDataRequestID(0)

    var request: PHAssetResourceDataRequestID {
        get { lock.withLock { _request } }
        set { lock.withLock { _request = newValue } }
    }

    func append(_ chunk: Data) -> CameraTags? {
        lock.withLock {
            guard !resumed else { return nil }
            data.append(chunk)
            guard let properties = parse(final: false) else { return nil }
            resumed = true
            return CameraTags(properties: properties)
        }
    }

    func finish(error: (any Error)?) -> Result<CameraTags, any Error>? {
        lock.withLock {
            guard !resumed else { return nil }
            resumed = true
            if let error { return .failure(error) }
            return .success(CameraTags(properties: parse(final: true) ?? [:]))
        }
    }

    private func parse(final: Bool) -> [String: Any]? {
        CGImageSourceUpdateData(source, data as CFData, final)
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any] else { return nil }
        if final || properties[kCGImagePropertyTIFFDictionary as String] != nil { return properties }
        return properties[kCGImagePropertyExifDictionary as String] != nil && data.count > 512 * 1024 ? properties : nil
    }
}
