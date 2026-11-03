import Foundation

public enum StarRater {
    /// A score equal to a threshold belongs to the higher band: with −0.3 as the first threshold, −0.3 is 2★.
    public static func stars(for score: Double, thresholds: [Double]) -> Int {
        1 + thresholds.prefix(4).filter { score >= $0 }.count
    }

    public static func counts(_ scores: [Double], thresholds: [Double]) -> [Int: Int] {
        var counts = Dictionary(uniqueKeysWithValues: (1...5).map { ($0, 0) })
        for score in scores { counts[stars(for: score, thresholds: thresholds), default: 0] += 1 }
        return counts
    }
}
