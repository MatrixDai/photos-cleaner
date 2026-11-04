import AppKit
import Foundation
import Photos
import Vision

public struct LivePhotoAnalyzer: PhotoAnalyzing {
    public static let derivativeSide: CGFloat = 1024

    public init() {}

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
}
