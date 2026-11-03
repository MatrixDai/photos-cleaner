import AppKit
import CleanerCore
import SwiftUI

struct VideoPage: View {
    let model: AppModel
    @State private var confirmingFreeSpace = false

    private var videos: VideoModel { model.videos }
    var body: some View {
        VStack(spacing: 0) {
            VideoSettingsView(model: model)
                .padding(16)
            Divider()
            VideoResults(rows: videos.rows, scanned: videos.scannedAt != nil)
            Divider()
            actionBar.padding(12)
        }
        .navigationTitle("Videos · Export & Cleanup")
        .alert("Not enough free space", isPresented: $confirmingFreeSpace) {
            Button("Export Anyway") { Task { await videos.exportAndMark() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The videos to export total \(bytes(Int64(videos.pendingBytes))), but the export folder's volume has \(bytes(videos.freeSpace ?? 0)) free. Export stops when the disk fills up.")
        }
    }

    private var actionBar: some View {
        HStack {
            Button("Scan") { Task { await videos.scan() } }
                .disabled(model.jobs.isBusy)
                .keyboardShortcut("r", modifiers: .command)
            Button(videos.pending.isEmpty ? "Export & Mark" : "Export & Mark \(videos.pending.count) videos") {
                if videos.exceedsFreeSpace { confirmingFreeSpace = true } else { Task { await videos.exportAndMark() } }
            }
            .disabled(!videos.canExport)
            Spacer()
            JobProgressView(jobs: model.jobs, mode: .videos)
        }
    }
}

private struct VideoSettingsView: View {
    let model: AppModel

    var body: some View {
        HStack {
            Text("Older than")
            TextField("", value: days, format: .number).frame(width: 70)
            Stepper("days", value: days, in: VideoSettings.olderThanDaysRange)
            Spacer()
        }
        .disabled(model.jobs.isBusy)
    }

    private var days: Binding<Int> {
        let range = VideoSettings.olderThanDaysRange
        return Binding(get: { model.settings.settings.videos.olderThanDays },
                       set: { value in model.settings.update { $0.videos.olderThanDays = min(max(value, range.lowerBound), range.upperBound) } })
    }
}

struct FolderBadge: View {
    let state: FolderState

    var body: some View {
        switch state {
        case .writable: Label("Writable", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
        case .willBeCreated: Label("Created on first export", systemImage: "folder.badge.plus").foregroundStyle(.secondary)
        case .notWritable(let reason): Label(reason, systemImage: "xmark.octagon.fill").foregroundStyle(.red)
        }
    }
}

private struct VideoResults: View {
    let rows: [VideoRow]
    let scanned: Bool

    var body: some View {
        if !scanned {
            ContentUnavailableView("No scan yet", systemImage: "video",
                                   description: Text("Scan lists the videos older than the set number of days. It changes nothing."))
        } else if rows.isEmpty {
            ContentUnavailableView("No videos older than the set number of days", systemImage: "checkmark.circle")
        } else {
            Table(rows) {
                TableColumn("Date") { Text($0.date?.formatted(date: .abbreviated, time: .omitted) ?? "–") }.width(110)
                TableColumn("Name", value: \.name)
                TableColumn("Size") { Text($0.size.map { bytes(Int64($0)) } ?? "–").monospacedDigit() }.width(80)
                TableColumn("Status") { row in
                    Text(row.status.label).foregroundStyle(color(row.status)).help(row.status.label)
                }
                .width(min: 120, ideal: 160)
                TableColumn("File") { Text($0.file ?? "").lineLimit(1).truncationMode(.middle).help($0.file ?? "") }
            }
        }
    }

    private func color(_ status: VideoRowStatus) -> Color {
        switch status {
        case .failed: .red
        case .exported, .alreadyLocal, .marked: .green
        case .kept: .secondary
        case .pending, .exporting: .primary
        }
    }
}

struct JobProgressView: View {
    let jobs: JobCenter
    let mode: JobMode

    var body: some View {
        if let active = jobs.active {
            if active.mode == mode {
                if let item = jobs.progress?.item { Text(item).lineLimit(1).foregroundStyle(.secondary) }
                ProgressView(value: Double(jobs.progress?.done ?? 0), total: Double(max(1, jobs.progress?.total ?? 1)))
                    .frame(width: 160)
                Text("\(jobs.progress?.done ?? 0)/\(jobs.progress?.total ?? 0)").monospacedDigit()
                Button("Cancel") { Task { await jobs.cancel() } }
                    .keyboardShortcut(".", modifiers: .command)
            } else {
                Text("\(active.mode.title) is busy").foregroundStyle(.secondary)
            }
        } else if let finished = jobs.lastFinished, finished.job.mode == mode {
            Text(describe(finished)).foregroundStyle(.secondary).lineLimit(1)
        }
    }

    private func describe(_ finished: FinishedJob) -> String {
        switch finished.outcome {
        case .completed(let summary): "\(finished.job.name) done · " + counts(summary)
        case .cancelled(let summary): "\(finished.job.name) cancelled" + (summary.map { " · " + counts($0) } ?? "")
        case .failed(let message): "\(finished.job.name) failed: \(message)"
        }
    }

    private func counts(_ summary: JobSummary) -> String {
        summary.counts.filter { $0.value > 0 }.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: ", ")
    }
}

func bytes(_ count: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: count, countStyle: .file)
}
