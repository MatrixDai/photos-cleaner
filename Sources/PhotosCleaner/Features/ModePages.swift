import CleanerCore
import SwiftUI

struct VideoPage: View {
    let model: AppModel

    var body: some View {
        ModePage(model: model, mode: .videos, title: "Videos · Export & Cleanup",
                 placeholder: "Export settings and results arrive in Phase 2.",
                 actions: ["Scan", "Export & Mark"])
    }
}

struct PhotoPage: View {
    let model: AppModel

    var body: some View {
        ModePage(model: model, mode: .photos, title: "Photos · Rating & Similar Shots",
                 placeholder: "Scope, thresholds and results arrive in Phases 3 and 4.",
                 actions: ["Scan", "Rate & Mark", "Revert…"])
    }
}

private struct ModePage: View {
    let model: AppModel
    let mode: JobMode
    let title: String
    let placeholder: String
    let actions: [String]

    var body: some View {
        VStack(spacing: 0) {
            ContentUnavailableView(title, systemImage: mode == .videos ? "video" : "photo.stack",
                                   description: Text(placeholder))
            Divider()
            ActionBar(jobs: model.jobs, mode: mode, actions: actions)
        }
        .navigationTitle(title)
    }
}

private struct ActionBar: View {
    let jobs: JobCenter
    let mode: JobMode
    let actions: [String]

    var body: some View {
        HStack {
            ForEach(actions, id: \.self) { Button($0) {}.disabled(true) }
            Button("Run Test Job") { Task { await jobs.start(mode: mode, name: "test job", work: testJob) } }
                .disabled(jobs.isBusy)
                .help("Phase 1 placeholder: a 10-second job that only reports progress")
            Spacer()
            if let active = jobs.active {
                if active.mode == mode {
                    ProgressView(value: Double(jobs.progress?.done ?? 0), total: Double(jobs.progress?.total ?? 1))
                        .frame(width: 160)
                    Text("\(jobs.progress?.done ?? 0)/\(jobs.progress?.total ?? 0)").monospacedDigit()
                    Button("Cancel") { Task { await jobs.cancel() } }
                        .keyboardShortcut(".", modifiers: .command)
                } else {
                    Text("\(active.mode.title) is busy").foregroundStyle(.secondary)
                }
            }
        }
        .padding(12)
    }
}

private let testJob: JobWork = { context in
    let steps = 20
    for step in 1...steps {
        try await Task.sleep(for: .milliseconds(500))
        context.progress(step, of: steps)
    }
    return JobSummary(counts: ["steps": steps])
}
