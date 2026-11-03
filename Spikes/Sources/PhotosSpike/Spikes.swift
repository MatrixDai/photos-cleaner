import AppKit
import AVFoundation
import Foundation
import ObjCCatch
import Photos
import SpikeKit
import Vision

extension SpikeRunner {
    private func f(_ value: Double, _ digits: Int = 2) -> String { String(format: "%.\(digits)f", value) }

    private func stats(_ name: String, _ values: [Double], unit: String = "s") {
        guard !values.isEmpty else { return say("\(name): no samples") }
        say("\(name): n=\(values.count) min \(f(values.min()!)) median \(f(percentile(values, 0.5)!)) p90 \(f(percentile(values, 0.9)!)) max \(f(values.max()!)) \(unit)")
    }

    private func day(_ date: Date?) -> String {
        date?.formatted(.iso8601.year().month().day()) ?? "?"
    }

    private func confirm(_ message: String) -> Bool {
        let alert = NSAlert()
        alert.messageText = "This spike writes to your Photos library"
        alert.informativeText = message
        alert.addButton(withTitle: "Continue")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    private func pause(_ message: String) {
        let alert = NSAlert()
        alert.messageText = message
        alert.addButton(withTitle: "Continue")
        alert.runModal()
    }

    func ratingAPI() async {
        await run("rating-api") {
            let images = Library.fetch(.image, in: range, limit: .max)
            let start = Date()
            var counts: [Int: Int] = [:]
            for asset in images { counts[asset.rating.rawValue, default: 0] += 1 }
            say("Images in scope, screenshots excluded: \(images.count)")
            say("In-memory read of `rating`: \(f(Date().timeIntervalSince(start))) s; counts by rawValue \(counts.sorted { $0.key < $1.key })")
            for clause in ["rating == 0", "rating > 0", "rating >= 3"] {
                let options = PHFetchOptions()
                options.predicate = NSPredicate(format: "mediaType == %d AND \(clause)", PHAssetMediaType.image.rawValue)
                var count = -1
                let started = Date()
                let exception = SpikeCatchException { count = PHAsset.fetchAssets(with: options).count }
                say("Predicate `\(clause)`: " + (exception.map { "REJECTED — \($0)" }
                    ?? "count \(count) in \(f(Date().timeIntervalSince(started))) s (whole library, screenshots included)"))
            }
        }
    }

    func videoDates() async {
        await run("video-datasize-dates") {
            let videos = Library.fetch(.video, in: range, limit: .max)
            let resources = videos.compactMap { video in Library.original(of: video).map { (video, $0) } }
            say("Videos in scope: \(videos.count); with an original resource: \(resources.count)")
            say("dataSize present: \(resources.filter { $0.1.dataSize != nil }.count), missing: \(resources.filter { $0.1.dataSize == nil }.count)")
            var cloudOnly: [(PHAsset, PHAssetResource)] = []
            let probed = resources.prefix(sample)
            for item in probed where !(await Library.isLocal(item.1)) { cloudOnly.append(item) }
            say("Of \(probed.count) probed: local \(probed.count - cloudOnly.count), iCloud-only \(cloudOnly.count); iCloud-only with dataSize \(cloudOnly.filter { $0.1.dataSize != nil }.count)")

            let pool = (cloudOnly.isEmpty ? Array(resources) : cloudOnly)
                .sorted { ($0.1.dataSize ?? .max) < ($1.1.dataSize ?? .max) }.prefix(10)
            let tmp = FileManager.default.temporaryDirectory.appending(path: "photos-spike-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: tmp) }
            say("\n| PHAsset day (system tz) | filename | dataSize | bytes | progress calls | s | QuickTime creationDate | QT day | offset s | AVAsset.creationDate |")
            say("|---|---|---|---|---|---|---|---|---|---|")
            for (video, resource) in pool {
                let file = tmp.appending(path: UUID().uuidString + ".mov")
                let read = await Library.download(resource, to: file)
                var quickTime = "–", parsedDay = "–", offset = "–", avDate = "–"
                if read.error == nil {
                    let asset = AVURLAsset(url: file)
                    let metadata = (try? await asset.load(.metadata)) ?? []
                    let item = AVMetadataItem.metadataItems(from: metadata, filteredByIdentifier: .quickTimeMetadataCreationDate).first
                    if let raw = try? await item?.load(.stringValue) {
                        quickTime = raw
                        let parsed = QuickTimeDate(raw)
                        parsedDay = parsed?.day ?? "unparsed"
                        offset = parsed?.utcOffsetSeconds.map(String.init) ?? "none"
                    }
                    if let creation = try? await asset.load(.creationDate), let value = try? await creation.load(.stringValue) {
                        avDate = value
                    }
                }
                say("| \(day(video.creationDate)) | \(resource.filename ?? "?") | \(resource.dataSize.map(String.init) ?? "nil") | \(read.bytes) | \(read.progressCalls) | \(f(read.seconds, 1)) | \(quickTime) | \(parsedDay) | \(offset) | \(avDate)\(read.error.map { " ERROR \($0)" } ?? "") |")
                try? FileManager.default.removeItem(at: file)
            }
        }
    }

    func exifCost() async {
        await run("exif-cost") {
            let images = Library.fetch(.image, in: range, limit: sample * 3)
            var local: [PHAssetResource] = [], cloud: [PHAssetResource] = []
            for asset in images {
                guard let resource = Library.original(of: asset) else { continue }
                if await Library.isLocal(resource) { local.append(resource) } else { cloud.append(resource) }
            }
            say("Probed \(local.count + cloud.count) originals: local \(local.count), iCloud-only \(cloud.count) (\(f(Double(cloud.count) * 100 / Double(max(1, local.count + cloud.count)), 1))%)")

            let fullSet = Array(cloud.suffix(min(20, cloud.count / 2)))
            let headerSet = Array(cloud.dropLast(fullSet.count).prefix(sample))
            var models: [String: Int] = [:]
            var camera = 0, nonCamera = 0, failed = 0
            func tally(_ read: HeaderRead) {
                guard let props = read.properties else { failed += 1; return }
                let tags = CameraEXIF.makeAndModel(props)
                if tags.make != nil || tags.model != nil {
                    camera += 1
                    models["\(tags.make ?? "?") \(tags.model ?? "?")", default: 0] += 1
                } else {
                    nonCamera += 1
                }
            }

            var seconds: [Double] = [], kilobytes: [Double] = [], fraction: [Double] = []
            for (index, resource) in headerSet.enumerated() {
                let read = await Library.readHeader(resource)
                tally(read)
                seconds.append(read.seconds)
                kilobytes.append(Double(read.bytes) / 1024)
                if let size = resource.dataSize, size > 0 { fraction.append(Double(read.bytes) / Double(size)) }
                if index % 25 == 24 { say("… \(index + 1)/\(headerSet.count) iCloud header reads") }
            }
            stats("iCloud-only header read time", seconds)
            stats("iCloud-only header bytes delivered", kilobytes, unit: "KB")
            stats("Header bytes / file size", fraction, unit: "")

            var localSeconds: [Double] = []
            for resource in local.prefix(sample) {
                let read = await Library.readHeader(resource)
                tally(read)
                localSeconds.append(read.seconds)
            }
            stats("Local header read time", localSeconds)

            var fullSeconds: [Double] = [], megabytes: [Double] = []
            for resource in fullSet {
                let read = await Library.download(resource)
                fullSeconds.append(read.seconds)
                megabytes.append(Double(read.bytes) / 1_048_576)
            }
            stats("iCloud-only FULL download time", fullSeconds)
            stats("iCloud-only FULL download size", megabytes, unit: "MB")

            say("Camera (Make/Model present): \(camera); no Make/Model: \(nonCamera); unreadable: \(failed)")
            say("Top cameras: " + models.sorted { $0.value > $1.value }.prefix(10).map { "\($0.key) ×\($0.value)" }.joined(separator: ", "))
        }
    }

    func aesthetics() async {
        await run("aesthetics") {
            let request = CalculateImageAestheticsScoresRequest()
            say("CalculateImageAestheticsScoresRequest revision: \(request.revision)")
            say("| day | score | utility | fetch s | vision s |")
            say("|---|---|---|---|---|")
            var scores: [Double] = []
            for asset in Library.fetch(.image, in: range, limit: 20) {
                let started = Date()
                guard let image = await Library.image(asset, side: 1024) else { say("| \(day(asset.creationDate)) | no image | | | |"); continue }
                let fetched = Date()
                let observation = try await request.perform(on: image)
                scores.append(Double(observation.overallScore))
                say("| \(day(asset.creationDate)) | \(f(Double(observation.overallScore), 3)) | \(observation.isUtility) | \(f(fetched.timeIntervalSince(started))) | \(f(Date().timeIntervalSince(fetched))) |")
            }
            stats("Scores", scores, unit: "")
        }
    }

    func calibration() async {
        await run("similarity-calibration") {
            let dir = reportDir.appending(path: "calibration", directoryHint: .isDirectory)
            try? FileManager.default.removeItem(at: dir)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let images = Library.fetch(.image, in: range, limit: 2000)
            let sequences = Sequences.split(images, date: { $0.creationDate ?? .distantPast }, maxGap: 30).filter { $0.count >= 2 }
            let printed = sequences.reduce(0) { $0 + $1.count }
            let request = GenerateImageFeaturePrintRequest()
            say("Photos: \(images.count); sequences of 2+ within 30 s: \(sequences.count) holding \(printed) photos; feature-print revision \(request.revision)")

            func file(_ asset: PHAsset) -> String { asset.localIdentifier.replacingOccurrences(of: "/", with: "_") + ".jpg" }
            var nearest: [Double] = []
            var pairs: [(a: PHAsset, b: PHAsset, distance: Double)] = []
            var done = 0
            for sequence in sequences {
                var prints: [FeaturePrintObservation?] = []
                for asset in sequence {
                    var observation: FeaturePrintObservation?
                    if let image = await Library.image(asset, side: 512) {
                        Library.saveJPEG(image, to: dir.appending(path: file(asset)))
                        observation = try? await request.perform(on: image)
                    }
                    prints.append(observation)
                    done += 1
                    if done % 100 == 0 { say("… \(done)/\(printed) printed") }
                }
                var best = Array(repeating: Double.infinity, count: sequence.count)
                for i in sequence.indices {
                    for j in sequence.indices where j > i {
                        guard let dateI = sequence[i].creationDate, let dateJ = sequence[j].creationDate,
                              dateJ.timeIntervalSince(dateI) <= 30 else { break }
                        guard let pi = prints[i], let pj = prints[j], let distance = try? pi.distance(to: pj) else { continue }
                        pairs.append((sequence[i], sequence[j], distance))
                        best[i] = min(best[i], distance)
                        best[j] = min(best[j], distance)
                    }
                }
                nearest += best.filter(\.isFinite)
            }
            stats("Nearest-neighbour distance within 30 s", nearest, unit: "")
            guard let top = nearest.max(), top > 0 else { return say("No pairs to calibrate.") }
            var histogram = Histogram(lower: 0, upper: (top * 10).rounded(.up) / 10, bins: 20)
            nearest.forEach { histogram.add($0) }
            say("\n| nearest-neighbour distance | photos |\n|---|---|")
            for (index, count) in histogram.counts.enumerated() {
                let range = histogram.range(ofBin: index)
                say("| \(f(range.lowerBound, 3))–\(f(range.upperBound, 3)) | \(count) \(String(repeating: "█", count: min(60, count))) |")
            }

            var bands = Histogram(lower: 0, upper: histogram.range(ofBin: histogram.counts.count - 1).upperBound, bins: 10)
            pairs.forEach { bands.add($0.distance) }
            var html = "<html><head><meta charset='utf-8'><title>Similarity calibration</title></head><body style='font-family:-apple-system;margin:24px'>"
            html += "<h1>Similarity calibration</h1><p>\(pairs.count) pairs within 30 s. Feature-print revision \(request.revision). For each band, judge whether the pairs are retakes of the same shot.</p>"
            for index in bands.counts.indices {
                let range = bands.range(ofBin: index)
                let inBand = pairs.filter { bands.bin(for: $0.distance) == index }
                html += "<h2>Distance \(f(range.lowerBound, 3))–\(f(range.upperBound, 3)) · \(inBand.count) pairs</h2>"
                for pair in inBand.shuffled().prefix(8) {
                    let gap = (pair.b.creationDate ?? .now).timeIntervalSince(pair.a.creationDate ?? .now)
                    html += "<div style='display:inline-block;margin:8px;text-align:center;font-size:12px'><img src='\(file(pair.a))' height='150'> <img src='\(file(pair.b))' height='150'><br>d = \(f(pair.distance, 3)) · \(Int(gap)) s apart · \(day(pair.a.creationDate))</div>"
                }
            }
            html += "</body></html>"
            try html.write(to: dir.appending(path: "index.html"), atomically: true, encoding: .utf8)
            say("Sample pairs: \(dir.appending(path: "index.html").path)")
        }
    }

    func ratingWrites() async {
        guard confirm("Sets a rating on 6 unrated photos (the newest in scope), then sets them back to unrated. Watch for system prompts while it runs.") else { return }
        await run("rating-writes") {
            let photos = Array(Library.fetch(.image, in: range, limit: .max).filter { $0.rating == .unset }.suffix(6))
            guard photos.count == 6 else { return say("Need 6 unrated photos in scope; found \(photos.count).") }
            let ids = photos.map(\.localIdentifier)
            say("Photos used: " + photos.map { day($0.creationDate) }.joined(separator: ", "))

            let batch = Array(ids.prefix(3))
            var started = Date()
            try await PHPhotoLibrary.shared().performChanges {
                PHAsset.fetchAssets(withLocalIdentifiers: batch, options: nil).enumerateObjects { asset, _, _ in
                    PHAssetChangeRequest(for: asset).rating = .three
                }
            }
            say("Step 1: one performChanges rating 3 photos 3★: \(f(Date().timeIntervalSince(started))) s")

            started = Date()
            for id in ids.suffix(3) {
                try await PHPhotoLibrary.shared().performChanges {
                    PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil).enumerateObjects { asset, _, _ in
                        PHAssetChangeRequest(for: asset).rating = .four
                    }
                }
            }
            say("Step 2: three performChanges, one photo each, 4★: \(f(Date().timeIntervalSince(started))) s")
            let readBack = PHAsset.fetchAssets(withLocalIdentifiers: ids, options: nil)
            var ratings: [Int] = []
            readBack.enumerateObjects { asset, _, _ in ratings.append(asset.rating.rawValue) }
            say("Read back: \(ratings)")

            pause("Ratings are set on 6 photos taken \(photos.map { day($0.creationDate) }.joined(separator: ", ")). To check Shared Library sync, look at them on another participant's device now. Continue restores them to unrated.")
            try await PHPhotoLibrary.shared().performChanges {
                PHAsset.fetchAssets(withLocalIdentifiers: ids, options: nil).enumerateObjects { asset, _, _ in
                    PHAssetChangeRequest(for: asset).rating = .unset
                }
            }
            var restored: [Int] = []
            PHAsset.fetchAssets(withLocalIdentifiers: ids, options: nil).enumerateObjects { asset, _, _ in restored.append(asset.rating.rawValue) }
            say("Restored: \(restored)")
            say("Record in docs/spikes.md which steps showed a prompt, and whether one prompt covered several photos.")
        }
    }

    private static let albumKey = "spikeAlbumID"

    func albums() async {
        guard confirm("Creates the album \"photos-cleaner-spike\", adds the 50 newest photos in scope, removes them again, and leaves the empty album for the rename check.") else { return }
        await run("albums") {
            let photos = Array(Library.fetch(.image, in: range, limit: .max).suffix(50))
            let ids = photos.map(\.localIdentifier)
            let created = Locked<String?>(nil)
            try await PHPhotoLibrary.shared().performChanges {
                let request = PHAssetCollectionChangeRequest.creationRequestForAssetCollection(withTitle: "photos-cleaner-spike")
                created.with { $0 = request.placeholderForCreatedAssetCollection.localIdentifier }
            }
            guard let albumID = created.with({ $0 }) else { return say("Album creation returned no id") }
            UserDefaults.standard.set(albumID, forKey: Self.albumKey)
            say("Created album id \(albumID)")

            try await PHPhotoLibrary.shared().performChanges {
                guard let album = PHAssetCollection.fetchAssetCollections(withLocalIdentifiers: [albumID], options: nil).firstObject else { return }
                PHAssetCollectionChangeRequest(for: album)?.addAssets(PHAsset.fetchAssets(withLocalIdentifiers: ids, options: nil))
            }
            let album = PHAssetCollection.fetchAssetCollections(withLocalIdentifiers: [albumID], options: nil).firstObject!
            var members = Set<String>()
            PHAsset.fetchAssets(in: album, options: nil).enumerateObjects { asset, _, _ in members.insert(asset.localIdentifier) }
            say("Added \(members.count) of \(ids.count)")
            let missing = photos.filter { !members.contains($0.localIdentifier) }
            if !missing.isEmpty { say("Not added: " + missing.map { day($0.creationDate) }.joined(separator: ", ")) }

            pause("The album holds \(members.count) photos. In Photos, check whether Shared Library photos appear in \"photos-cleaner-spike\". Continue removes them.")
            try await PHPhotoLibrary.shared().performChanges {
                guard let album = PHAssetCollection.fetchAssetCollections(withLocalIdentifiers: [albumID], options: nil).firstObject else { return }
                PHAssetCollectionChangeRequest(for: album)?.removeAssets(PHAsset.fetchAssets(withLocalIdentifiers: ids, options: nil))
            }
            say("After removal: \(PHAsset.fetchAssets(in: album, options: nil).count) members")
            say("Next: rename the album in Photos, then press Check album rename.")
        }
    }

    func albumRenameCheck() async {
        await run("album-rename") {
            guard let id = UserDefaults.standard.string(forKey: Self.albumKey) else { return say("Run the Albums spike first.") }
            if let album = PHAssetCollection.fetchAssetCollections(withLocalIdentifiers: [id], options: nil).firstObject {
                say("Found by localIdentifier; current title \"\(album.localizedTitle ?? "?")\"")
            } else {
                say("NOT found by localIdentifier \(id)")
            }
        }
    }

    func deleteSpikeAlbum() async {
        await run("album-delete") {
            guard let id = UserDefaults.standard.string(forKey: Self.albumKey) else { return say("No spike album recorded.") }
            try await PHPhotoLibrary.shared().performChanges {
                PHAssetCollectionChangeRequest.deleteAssetCollections(PHAssetCollection.fetchAssetCollections(withLocalIdentifiers: [id], options: nil))
            }
            UserDefaults.standard.removeObject(forKey: Self.albumKey)
            say("Deleted the spike album; its photos are untouched.")
        }
    }
}
