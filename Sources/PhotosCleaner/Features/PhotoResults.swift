import CleanerCore
import SwiftUI

struct PhotoResults: View {
    let model: AppModel
    @State private var selection: Set<String> = []
    @State private var sortOrder = [KeyPathComparator(\PhotoRow.date)]
    @State private var previewing: String?

    private var photos: PhotoModel { model.photos }

    private var rows: [PhotoRow] {
        photos.photosToRate.map { PhotoRow(photo: $0) }.sorted(using: sortOrder)
    }

    var body: some View {
        if let tally = photos.autoTally {
            AutoRatePanel(model: model, tally: tally)
        } else if let scan = photos.scan, scan.refusal == nil, !photos.photosToRate.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(summary(scan)).font(.callout).foregroundStyle(.secondary)
                    StarCountsRow(counts: photos.starCounts, adjusted: photos.adjustedCount)
                    if scan.scope.isDateRange, scan.alreadyRated > 0 {
                        Label("\(scan.alreadyRated.formatted()) photos in this range already have stars; they will be re-rated.",
                              systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 12)
                table
            }
            .sheet(item: Binding(get: { previewing.map(PreviewID.init) }, set: { previewing = $0?.id })) { item in
                PhotoPreview(model: model, ids: rows.map(\.id), current: item.id)
            }
        } else {
            ContentUnavailableView {
                Label(photos.scan == nil ? "No scan yet" : "Nothing to rate", systemImage: "photo.stack")
            } description: {
                Text(photos.notice ?? "Scan checks each photo's camera EXIF and scores it with Vision. It changes nothing in Photos.")
            }
        }
    }

    private var table: some View {
        Table(rows, selection: $selection, sortOrder: $sortOrder) {
            TableColumn("") { row in Thumbnail(model: model, photo: row.photo) }
                .width(56)
            TableColumn("Taken", value: \.date) { row in
                Text(row.photo.date?.formatted(date: .abbreviated, time: .shortened) ?? "–")
            }
            .width(min: 140, ideal: 170)
            TableColumn("Score", value: \.score) { row in
                Text(row.score.formatted(.number.precision(.fractionLength(2)))).monospacedDigit()
            }
            .width(60)
            TableColumn("Stars", value: \.suggested) { row in
                StarPicker(stars: photos.stars(row.photo), adjusted: photos.isAdjusted(row.photo)) { photos.setStars($0, for: row.photo) }
            }
            .width(min: 130, ideal: 150)
            TableColumn("Now", value: \.current) { row in
                Text(row.current == 0 ? "–" : String(repeating: "★", count: row.current)).foregroundStyle(.secondary)
            }
            .width(70)
        }
        .contextMenu(forSelectionType: String.self) { ids in
            if let id = ids.first { Button("Preview") { previewing = id } }
        } primaryAction: { ids in
            previewing = ids.first
        }
        .disabled(model.jobs.isBusy)
    }

    private func summary(_ scan: PhotoScanResult) -> String {
        var parts = ["\(scan.photos.count.formatted()) camera photos scored"]
        if scan.nonCamera > 0 { parts.append("\(scan.nonCamera.formatted()) non-camera skipped") }
        if scan.screenshots > 0 { parts.append("\(scan.screenshots.formatted()) screenshots skipped") }
        if scan.failed > 0 { parts.append("\(scan.failed.formatted()) couldn't be analyzed") }
        if !scan.scope.isDateRange, let resume = scan.resumeAfter {
            parts.append("up to \(resume.formatted(date: .abbreviated, time: .omitted))")
        }
        parts.append("double-click a photo to review it")
        return parts.joined(separator: " · ")
    }
}

private struct AutoRatePanel: View {
    let model: AppModel
    let tally: AutoRateTally

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "star.leadinghalf.filled").font(.largeTitle).foregroundStyle(.secondary)
            Text(model.photos.isAutoRunning ? "Auto rate and resume · round \(tally.rounds + 1)" : "Auto rate and resume")
                .font(.title3)
            Text("\(tally.rated.formatted()) photos rated so far" + resumeText).foregroundStyle(.secondary)
            StarCountsRow(counts: tally.starCounts, adjusted: 0)
            if let notice = model.photos.notice {
                Text(notice).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 520)
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var resumeText: String {
        model.settings.settings.photos.resumeAfter.map { " · up to \($0.formatted(date: .abbreviated, time: .omitted))" } ?? ""
    }
}

private struct PreviewID: Identifiable {
    let id: String
}

struct PhotoRow: Identifiable {
    let photo: AnalyzedPhoto
    var id: String { photo.id }
    var date: Date { photo.date ?? .distantPast }
    var score: Double { photo.score }
    var current: Int { photo.rating }
    var suggested: Double { photo.score }
}

private struct StarCountsRow: View {
    let counts: [Int: Int]
    let adjusted: Int

    var body: some View {
        HStack(spacing: 18) {
            ForEach(1...5, id: \.self) { stars in
                HStack(spacing: 4) {
                    Text(String(repeating: "★", count: stars)).foregroundStyle(.yellow)
                    Text((counts[stars] ?? 0).formatted()).monospacedDigit()
                }
            }
            if adjusted > 0 { Text("\(adjusted.formatted()) adjusted by you").foregroundStyle(Color.accentColor) }
        }
        .font(.callout)
    }
}

struct StarPicker: View {
    let stars: Int
    let adjusted: Bool
    var size: Font = .body
    let set: (Int) -> Void

    var body: some View {
        HStack(spacing: 2) {
            ForEach(1...5, id: \.self) { value in
                Button { set(value) } label: {
                    Image(systemName: value <= stars ? "star.fill" : "star")
                        .foregroundStyle(value <= stars ? (adjusted ? Color.accentColor : .yellow) : .secondary)
                }
                .buttonStyle(.plain)
                .help(adjusted ? "Adjusted by you" : "Suggested by the thresholds")
            }
        }
        .font(size)
    }
}

private struct Thumbnail: View {
    let model: AppModel
    let photo: AnalyzedPhoto
    @State private var image: CGImage?

    var body: some View {
        Group {
            if let image {
                Image(decorative: image, scale: 2).resizable().scaledToFill()
            } else {
                Rectangle().fill(.quaternary)
            }
        }
        .frame(width: 44, height: 44)
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .task(id: photo.id) { image = await model.photos.image(photo, side: 120) }
    }
}

private struct PhotoPreview: View {
    let model: AppModel
    let ids: [String]
    @State var current: String
    @State private var image: CGImage?
    @Environment(\.dismiss) private var dismiss

    init(model: AppModel, ids: [String], current: String) {
        self.model = model
        self.ids = ids
        _current = State(initialValue: current)
    }

    private var photo: AnalyzedPhoto? { model.photos.photosToRate.first { $0.id == current } }
    private var index: Int { ids.firstIndex(of: current) ?? 0 }

    var body: some View {
        VStack(spacing: 12) {
            ZStack {
                Rectangle().fill(.black.opacity(0.85))
                if let image {
                    Image(decorative: image, scale: 1).resizable().scaledToFit()
                } else {
                    ProgressView()
                }
            }
            .frame(minWidth: 720, minHeight: 480)
            if let photo {
                HStack(spacing: 16) {
                    Button { step(-1) } label: { Image(systemName: "chevron.left") }
                        .keyboardShortcut(.leftArrow, modifiers: [])
                        .disabled(index == 0)
                    Text("\(index + 1) of \(ids.count)").monospacedDigit().foregroundStyle(.secondary)
                    Button { step(1) } label: { Image(systemName: "chevron.right") }
                        .keyboardShortcut(.rightArrow, modifiers: [])
                        .disabled(index >= ids.count - 1)
                    Divider().frame(height: 18)
                    Text(photo.date?.formatted(date: .abbreviated, time: .shortened) ?? "–")
                    Text("score \(photo.score.formatted(.number.precision(.fractionLength(2))))").monospacedDigit().foregroundStyle(.secondary)
                    Spacer()
                    StarPicker(stars: model.photos.stars(photo), adjusted: model.photos.isAdjusted(photo), size: .title2) {
                        model.photos.setStars($0, for: photo)
                    }
                    Text(model.photos.isAdjusted(photo) ? "adjusted" : "suggested").font(.caption).foregroundStyle(.secondary)
                        .frame(width: 64, alignment: .leading)
                    Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
                }
                ForEach(1...5, id: \.self) { stars in
                    Button("") { model.photos.setStars(stars, for: photo) }
                        .keyboardShortcut(KeyEquivalent(Character("\(stars)")), modifiers: [])
                        .frame(width: 0, height: 0).opacity(0)
                }
            }
        }
        .padding(16)
        .task(id: current) {
            image = nil
            if let photo { image = await model.photos.image(photo, side: 1600) }
        }
    }

    private func step(_ delta: Int) {
        let next = index + delta
        guard ids.indices.contains(next) else { return }
        current = ids[next]
    }
}

struct PhotoActionBar: View {
    let model: AppModel
    @State private var confirmingRate = false
    @State private var confirmingAuto = false

    private var photos: PhotoModel { model.photos }

    var body: some View {
        HStack {
            Button(photos.autoRateApplies ? "Scan & Rate" : "Scan") {
                if photos.autoRateApplies { confirmingAuto = true } else { Task { await photos.scan() } }
            }
            .disabled(!photos.canScan)
            .keyboardShortcut("r", modifiers: .command)
            Button(photos.photosToRate.isEmpty ? "Rate & Mark" : "Rate & Mark \(photos.photosToRate.count.formatted()) photos") {
                confirmingRate = true
            }
            .disabled(!photos.canRate)
            Spacer()
            JobProgressView(jobs: model.jobs, mode: .photos)
        }
        .confirmationDialog(rateTitle, isPresented: $confirmingRate) {
            Button("Rate & Mark") { Task { await photos.rateAndMark() } }
        } message: {
            Text(rateMessage)
        }
        .confirmationDialog("Auto rate all unrated photos older than \(model.settings.settings.photos.scope.olderThanDays) days?",
                            isPresented: $confirmingAuto) {
            Button("Scan & Rate") { Task { await photos.scan() } }
        } message: {
            Text("Rounds of \(model.settings.settings.photos.cameraPhotosPerRun.formatted()) camera photos are scanned and rated with the suggested stars, without review, until none are left or you cancel. Stars already set are kept.")
        }
    }

    private var rateTitle: String {
        "Rate \(photos.photosToRate.count.formatted()) photos?"
    }

    private var rateMessage: String {
        var lines: [String] = []
        if photos.adjustedCount > 0 { lines.append("\(photos.adjustedCount.formatted()) of them use the stars you set.") }
        if let scan = photos.scan, scan.scope.isDateRange, scan.alreadyRated > 0 {
            lines.append("This overwrites \(scan.alreadyRated.formatted()) existing ratings in the range.")
        } else {
            lines.append("Only unrated photos are rated; stars already set are kept.")
        }
        return lines.joined(separator: " ")
    }
}
