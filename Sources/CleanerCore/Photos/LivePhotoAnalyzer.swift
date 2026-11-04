import AppKit
import Foundation
import Photos
import Vision

public struct LivePhotoAnalyzer: PhotoAnalyzing {
    public static let derivativeSide: CGFloat = 1024
    public static let printSide = 512

    public init() {}

    public func analyze(_ photoID: String, featurePrint: Bool) async throws -> PhotoAnalysis {
        guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [photoID], options: nil).firstObject else {
            throw CocoaError(.fileNoSuchFile)
        }
        guard let image = await Self.derivative(asset, side: Self.derivativeSide) else { throw CocoaError(.fileReadUnknown) }
        let score = Double(try await CalculateImageAestheticsScoresRequest().perform(on: image).overallScore)
        guard featurePrint, let small = Self.scaled(image, maxSide: Self.printSide) else { return PhotoAnalysis(score: score) }
        let observation = try await GenerateImageFeaturePrintRequest(.revision2).perform(on: small)
        return PhotoAnalysis(score: score, print: VisionPrint(observation: observation))
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

    static func scaled(_ image: CGImage, maxSide: Int) -> CGImage? {
        let ratio = min(1, Double(maxSide) / Double(max(image.width, image.height)))
        let width = max(1, Int(Double(image.width) * ratio)), height = max(1, Int(Double(image.height) * ratio))
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }
}

struct VisionPrint: SimilarityPrint {
    let observation: FeaturePrintObservation

    func distance(to other: any SimilarityPrint) -> Double? {
        guard let other = other as? VisionPrint else { return nil }
        return try? observation.distance(to: other.observation)
    }
}
