import CleanerCore
import SwiftUI

struct PhotoPage: View {
    let model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            PhotoOptionsView(model: model).padding(16)
            Divider()
            RatingPanel(model: model)
            Divider()
            PhotoActionBar(model: model).padding(12)
        }
        .navigationTitle("Photos · Rating & Similar Shots")
    }
}

private struct PhotoOptionsView: View {
    let model: AppModel

    private var photos: PhotoModel { model.photos }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Toggle("Re-rate photos taken from", isOn: Binding(get: { photos.reRate }, set: { photos.reRate = $0 }))
                    .toggleStyle(.checkbox)
                HStack(spacing: 8) {
                    DatePicker("", selection: Binding(get: { photos.reRateFrom }, set: { photos.reRateFrom = $0 }),
                               displayedComponents: .date).labelsHidden()
                    Text("to")
                    DatePicker("", selection: Binding(get: { photos.reRateTo }, set: { photos.reRateTo = $0 }),
                               displayedComponents: .date).labelsHidden()
                }
                .opacity(photos.reRate ? 1 : 0.45)
                .disabled(!photos.reRate)
            }
            .fixedSize()
            infoLine
                .font(.caption)
                .frame(maxWidth: .infinity, minHeight: 32, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .disabled(model.jobs.isBusy)
    }

    @ViewBuilder private var infoLine: some View {
        if let error = photos.scopeError {
            Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
        } else if photos.reRate {
            Label("Every photo in this range is rated again, overwriting its existing stars. Use a short range to try new thresholds.",
                  systemImage: "exclamationmark.triangle")
                .foregroundStyle(.orange)
        } else {
            Label("Rates every photo without stars, newest first. Photos that already have stars are left alone.",
                  systemImage: "info.circle")
                .foregroundStyle(.secondary)
        }
    }
}

private struct RatingPanel: View {
    let model: AppModel

    private var photos: PhotoModel { model.photos }

    var body: some View {
        if let tally = photos.tally {
            VStack(spacing: 16) {
                HStack(spacing: 28) {
                    ForEach(1...5, id: \.self) { stars in
                        VStack(spacing: 4) {
                            Text(String(repeating: "★", count: stars)).foregroundStyle(.yellow)
                            Text((tally.stars[stars] ?? 0).formatted()).font(.title2).monospacedDigit()
                        }
                    }
                }
                Text(ratedLine(tally)).foregroundStyle(.secondary)
                Text(statusLine(tally)).font(.callout).foregroundStyle(.secondary).monospacedDigit()
                if let notice = photos.notice {
                    Text(notice).multilineTextAlignment(.center).frame(maxWidth: 520)
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ContentUnavailableView {
                Label("Nothing rated yet", systemImage: "star.leadinghalf.filled")
            } description: {
                Text(photos.notice ?? "Rate scores each photo with Vision and writes its stars as it goes. Cancel any time; the next run continues with the photos still unrated.")
            }
        }
    }

    private func ratedLine(_ tally: RatingTally) -> String {
        var parts = ["\(tally.rated.formatted()) rated"]
        if tally.overwritten > 0 { parts.append("\(tally.overwritten.formatted()) existing stars overwritten") }
        if tally.screenshots > 0 { parts.append("\(tally.screenshots.formatted()) screenshots skipped") }
        if tally.failed > 0 { parts.append("\(tally.failed.formatted()) couldn't be analyzed") }
        return parts.joined(separator: " · ")
    }

    private func statusLine(_ tally: RatingTally) -> String {
        var parts = ["\(tally.processed.formatted()) of \(tally.total.formatted()) photos"]
        if let date = tally.currentDate { parts.append("now at \(date.formatted(date: .abbreviated, time: .omitted))") }
        if let started = photos.startedAt {
            parts.append(Duration.seconds((photos.finishedAt ?? .now).timeIntervalSince(started))
                .formatted(.time(pattern: .hourMinuteSecond)))
        }
        return parts.joined(separator: " · ")
    }
}

private struct PhotoActionBar: View {
    let model: AppModel
    @State private var confirmingReRate = false

    private var photos: PhotoModel { model.photos }

    var body: some View {
        HStack {
            Button("Rate Photos") {
                if photos.reRate { confirmingReRate = true } else { Task { await photos.run() } }
            }
            .disabled(!photos.canRun)
            .keyboardShortcut("r", modifiers: .command)
            Spacer()
            JobProgressView(jobs: model.jobs, mode: .photos)
        }
        .confirmationDialog("Re-rate every photo in this range?", isPresented: $confirmingReRate) {
            Button("Re-rate") { Task { await photos.run() } }
        } message: {
            Text("Existing stars in the range are overwritten with the stars from the current thresholds.")
        }
    }
}
