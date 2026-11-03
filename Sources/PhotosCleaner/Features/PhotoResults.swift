import Charts
import CleanerCore
import SwiftUI

struct PhotoResults: View {
    let model: AppModel

    private var photos: PhotoModel { model.photos }

    var body: some View {
        if let scan = photos.scan, scan.refusal == nil, !photos.photosToRate.isEmpty {
            VStack(alignment: .leading, spacing: 14) {
                Text(summary(scan)).font(.callout).foregroundStyle(.secondary)
                ScoreHistogram(model: model)
                    .frame(height: 220)
                StarCountsTable(counts: photos.starCounts, lowQuality: photos.lowQualityCount)
                if scan.scope.isDateRange, scan.alreadyRated > 0 {
                    Label("\(scan.alreadyRated.formatted()) photos in this range already have stars; they will be re-rated.",
                          systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                }
                Spacer(minLength: 0)
            }
            .padding(16)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        } else {
            ContentUnavailableView {
                Label(photos.scan == nil ? "No scan yet" : "Nothing to rate", systemImage: "photo.stack")
            } description: {
                Text(photos.notice ?? "Scan checks each photo's camera EXIF and scores it with Vision. It changes nothing in Photos.")
            }
        }
    }

    private func summary(_ scan: PhotoScanResult) -> String {
        var parts = ["\(scan.photos.count.formatted()) camera photos scored"]
        if scan.nonCamera > 0 { parts.append("\(scan.nonCamera.formatted()) non-camera skipped") }
        if scan.screenshots > 0 { parts.append("\(scan.screenshots.formatted()) screenshots skipped") }
        if scan.failed > 0 { parts.append("\(scan.failed.formatted()) couldn't be analyzed") }
        if !scan.scope.isDateRange, let resume = scan.resumeAfter {
            parts.append("up to \(resume.formatted(date: .abbreviated, time: .omitted))")
        }
        return parts.joined(separator: " · ")
    }
}

private struct ScoreHistogram: View {
    let model: AppModel
    @State private var dragging: Int?

    private static let binWidth = 0.05
    private static let colors: [Color] = [.red, .orange, .yellow, .mint, .green]

    private var thresholds: [Double] { model.photos.thresholds }

    private var bins: [(center: Double, count: Int, stars: Int)] {
        var counts = [Int](repeating: 0, count: Int(2 / Self.binWidth))
        for photo in model.photos.photosToRate {
            let index = min(max(Int((photo.score + 1) / Self.binWidth), 0), counts.count - 1)
            counts[index] += 1
        }
        return counts.enumerated().map { index, count in
            let center = -1 + (Double(index) + 0.5) * Self.binWidth
            return (center, count, StarRater.stars(for: center, thresholds: thresholds))
        }
    }

    var body: some View {
        Chart {
            ForEach(bins, id: \.center) { bin in
                BarMark(x: .value("Score", bin.center), y: .value("Photos", bin.count), width: .ratio(0.9))
                    .foregroundStyle(Self.colors[bin.stars - 1].opacity(0.7))
            }
            ForEach(Array(thresholds.enumerated()), id: \.offset) { index, value in
                RuleMark(x: .value("Threshold", value))
                    .foregroundStyle(dragging == index ? Color.accentColor : .primary.opacity(0.6))
                    .lineStyle(StrokeStyle(lineWidth: dragging == index ? 3 : 2))
                    .annotation(position: .top) {
                        Text(value.formatted(.number.precision(.fractionLength(2)))).font(.caption2.monospacedDigit())
                    }
            }
        }
        .chartXScale(domain: -1...1)
        .chartXAxisLabel("Aesthetics score — drag a line to move a star threshold")
        .chartYAxisLabel("Photos")
        .chartOverlay { proxy in
            GeometryReader { geometry in
                Rectangle().fill(.clear).contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 0)
                        .onChanged { drag in move(to: drag.location, proxy: proxy, geometry: geometry) }
                        .onEnded { _ in dragging = nil })
            }
        }
        .disabled(model.jobs.isBusy)
    }

    private func move(to location: CGPoint, proxy: ChartProxy, geometry: GeometryProxy) {
        guard let frame = proxy.plotFrame else { return }
        let x = location.x - geometry[frame].origin.x
        guard let score: Double = proxy.value(atX: x) else { return }
        let index = dragging ?? thresholds.enumerated().min { abs($0.element - score) < abs($1.element - score) }!.offset
        dragging = index
        let lower = index > 0 ? thresholds[index - 1] : -1
        let upper = index < thresholds.count - 1 ? thresholds[index + 1] : 1
        let value = (min(max(score, lower), upper) * 100).rounded() / 100
        model.settings.update { $0.photos.starThresholds[index] = value }
    }
}

private struct StarCountsTable: View {
    let counts: [Int: Int]
    let lowQuality: Int

    var body: some View {
        Grid(alignment: .trailing, horizontalSpacing: 24, verticalSpacing: 6) {
            GridRow {
                Text("")
                ForEach(1...5, id: \.self) { Text(String(repeating: "★", count: $0)).foregroundStyle(.secondary) }
            }
            GridRow {
                Text("Photos this scan").gridColumnAlignment(.leading)
                ForEach(1...5, id: \.self) { Text((counts[$0] ?? 0).formatted()).monospacedDigit() }
            }
        }
        Text("Rate & Mark adds the \(lowQuality.formatted()) photos at 1★–2★ to photo-low-quality.")
            .font(.caption).foregroundStyle(.secondary)
    }
}

struct PhotoActionBar: View {
    let model: AppModel
    @State private var confirmingRate = false
    @State private var revertSheet = false

    private var photos: PhotoModel { model.photos }

    var body: some View {
        HStack {
            Button("Scan") { Task { await photos.scan() } }
                .disabled(!photos.canScan)
                .keyboardShortcut("r", modifiers: .command)
            Button(photos.photosToRate.isEmpty ? "Rate & Mark" : "Rate & Mark \(photos.photosToRate.count.formatted()) photos") {
                confirmingRate = true
            }
            .disabled(!photos.canRate)
            Button("Revert…") { revertSheet = true }
                .disabled(model.jobs.isBusy)
            Spacer()
            JobProgressView(jobs: model.jobs, mode: .photos)
        }
        .confirmationDialog(rateTitle, isPresented: $confirmingRate) {
            Button("Rate & Mark") { Task { await photos.rateAndMark() } }
        } message: {
            Text(rateMessage)
        }
        .sheet(isPresented: $revertSheet) { RevertSheet(model: model) }
    }

    private var rateTitle: String {
        "Rate \(photos.photosToRate.count.formatted()) photos and add \(photos.lowQualityCount.formatted()) to photo-low-quality?"
    }

    private var rateMessage: String {
        guard let scan = photos.scan, scan.scope.isDateRange, scan.alreadyRated > 0 else {
            return "Only unrated photos are rated; stars already set are kept."
        }
        return "This overwrites \(scan.alreadyRated.formatted()) existing ratings in the range."
    }
}

private struct RevertSheet: View {
    let model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var roles: Set<AlbumRole> = [.photoLowQuality, .photoDuplicated]
    @State private var count: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Revert Photos mode").font(.headline)
            Toggle(model.settings.settings.photos.albums.lowQuality.name, isOn: binding(.photoLowQuality))
            Toggle(model.settings.settings.photos.albums.duplicated.name, isOn: binding(.photoDuplicated))
            Text(count.map { "Clear the ratings of \($0.formatted()) photos and remove them from \(roles.count) album\(roles.count == 1 ? "" : "s")? Ratings outside the albums stay; to change them, scan their date range again." }
                 ?? "Counting…")
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                Button("Revert", role: .destructive) {
                    let selected = roles
                    dismiss()
                    Task { await model.photos.revert(selected) }
                }
                .disabled(roles.isEmpty || count == nil)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 420)
        .task(id: roles) { count = await model.photos.revertCount(roles) }
    }

    private func binding(_ role: AlbumRole) -> Binding<Bool> {
        Binding(get: { roles.contains(role) }, set: { if $0 { roles.insert(role) } else { roles.remove(role) } })
    }
}
