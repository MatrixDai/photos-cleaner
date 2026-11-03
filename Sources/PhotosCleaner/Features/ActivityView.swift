import AppKit
import CleanerCore
import SwiftUI

struct ActivityView: View {
    let model: AppModel
    @State private var confirmingReset = false

    var body: some View {
        Form {
            Section("Albums") {
                if let error = model.albumError {
                    Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
                }
                ForEach(model.albumSummary) { row in
                    LabeledContent(row.name, value: describe(row))
                }
            }
            Section("Runs") {
                if model.runs.isEmpty {
                    Text("No runs yet.").foregroundStyle(.secondary)
                }
                ForEach(model.runs, id: \.run) { record in
                    VStack(alignment: .leading, spacing: 2) {
                        Text("#\(record.run) \(record.mode.title) · \(record.task) · \(record.outcome)")
                        Text(details(record)).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            Section("Data") {
                LabeledContent("Folder", value: model.dataDirectory.path)
                HStack {
                    Button("Reveal in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([model.settings.fileURL])
                    }
                    Button("Reset All Settings…", role: .destructive) { confirmingReset = true }
                        .disabled(model.jobs.isBusy)
                }
                if let corrupt = model.settings.recoveredCorruptFile {
                    Text("settings.json couldn't be read, so defaults were loaded. The old file was kept as \(corrupt.lastPathComponent).")
                        .foregroundStyle(.orange)
                }
                if let error = model.settings.saveError {
                    Text("Couldn't save settings: \(error)").foregroundStyle(.red)
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Activity")
        .task { await model.refreshActivity() }
        .confirmationDialog("Reset all settings to their defaults?", isPresented: $confirmingReset) {
            Button("Reset", role: .destructive) { Task { await model.resetAllSettings() } }
        } message: {
            Text("Albums, photos and exported files aren't touched.")
        }
    }

    private func describe(_ row: AlbumSummaryRow) -> String {
        guard let current = row.current else { return "not found" }
        guard let change = row.change, change != 0 else { return "\(current) items" }
        return "\(current) items, \(abs(change)) \(change < 0 ? "fewer" : "more") than after the last run"
    }

    private func details(_ record: RunRecord) -> String {
        let when = record.start.formatted(date: .abbreviated, time: .shortened)
        let seconds = Int(record.end.timeIntervalSince(record.start))
        let counts = record.counts.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: ", ")
        return [when, "\(seconds) s", counts, record.error ?? ""].filter { !$0.isEmpty }.joined(separator: " · ")
    }
}
