import Foundation
import ImageIO
import Testing
@testable import SpikeKit

struct QuickTimeDateTests {
    private func parsed(_ raw: String) -> (String, Int?)? {
        QuickTimeDate(raw).map { ($0.day, $0.utcOffsetSeconds) }
    }

    @Test func offsetWithoutColon() throws {
        let (day, offset) = try #require(parsed("2026-02-28T23:14:05+0800"))
        #expect(day == "2026-02-28" && offset == 8 * 3600)
    }

    @Test func offsetWithColonAndFraction() throws {
        let (day, offset) = try #require(parsed("2026-02-28T23:14:05.123-05:30"))
        #expect(day == "2026-02-28" && offset == -(5 * 3600 + 1800))
    }

    @Test func utcZulu() throws {
        let (day, offset) = try #require(parsed("2026-03-01T00:10:00Z"))
        #expect(day == "2026-03-01" && offset == 0)
    }

    @Test func missingOffset() throws {
        let (day, offset) = try #require(parsed("2026-03-01T00:10:00"))
        #expect(day == "2026-03-01" && offset == nil)
    }

    @Test(arguments: ["", "2026-02-28", "28/02/2026 23:14", "2026-02-28T23:14:05+8"])
    func rejectsMalformed(_ raw: String) {
        #expect(QuickTimeDate(raw) == nil)
    }
}

struct CameraEXIFTests {
    private func props(make: String?, model: String?) -> [String: Any] {
        var tiff: [String: Any] = [:]
        tiff[kCGImagePropertyTIFFMake as String] = make
        tiff[kCGImagePropertyTIFFModel as String] = model
        return [kCGImagePropertyTIFFDictionary as String: tiff]
    }

    @Test func makeAndModel() {
        #expect(CameraEXIF.isCamera(props(make: "Apple", model: "iPhone 17 Pro")))
    }

    @Test func modelOnly() {
        #expect(CameraEXIF.isCamera(props(make: nil, model: "ILCE-7M4")))
    }

    @Test func blankTagsAreNotACamera() {
        #expect(!CameraEXIF.isCamera(props(make: "  ", model: "")))
    }

    @Test func noTIFFDictionary() {
        #expect(!CameraEXIF.isCamera([kCGImagePropertyPixelWidth as String: 1024]))
    }
}

struct SequencesTests {
    private let start = Date(timeIntervalSince1970: 1_700_000_000)

    @Test func gapExactlyAtLimitStaysTogether() {
        let dates = [0, 30, 60].map { start.addingTimeInterval($0) }
        #expect(Sequences.split(dates, date: { $0 }, maxGap: 30).count == 1)
    }

    @Test func gapOverLimitSplits() {
        let dates = [0, 10, 41, 50, 200].map { start.addingTimeInterval($0) }
        let sizes = Sequences.split(dates, date: { $0 }, maxGap: 30).map(\.count)
        #expect(sizes == [2, 2, 1])
    }

    @Test func emptyInput() {
        #expect(Sequences.split([Date](), date: { $0 }, maxGap: 30).isEmpty)
    }
}

struct HistogramTests {
    @Test func binsAndClamping() {
        var histogram = Histogram(lower: 0, upper: 1, bins: 4)
        [-0.5, 0, 0.24, 0.25, 0.99, 1.0, 7].forEach { histogram.add($0) }
        #expect(histogram.counts == [3, 1, 0, 3])
        #expect(histogram.range(ofBin: 1) == 0.25...0.5)
    }

    @Test func percentiles() {
        #expect(percentile([5, 1, 3], 0.5) == 3)
        #expect(percentile([], 0.5) == nil)
    }
}
