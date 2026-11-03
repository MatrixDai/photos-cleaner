import AppKit
import Photos
import SwiftUI

@main
struct PhotosSpikeApp: App {
    @State private var runner = SpikeRunner()

    var body: some Scene {
        Window("Photos Cleaner Spikes", id: "main") {
            ContentView(runner: runner)
                .frame(minWidth: 820, minHeight: 600)
                .task { await runner.requestAccess() }
        }
    }
}

struct ContentView: View {
    @Bindable var runner: SpikeRunner

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Photos access: \(runner.authorization == .authorized ? "full ✓" : "not granted (\(runner.authorization.rawValue))")")
            HStack {
                Toggle("Limit to dates", isOn: $runner.useRange)
                DatePicker("From", selection: $runner.from, displayedComponents: .date).disabled(!runner.useRange)
                DatePicker("To", selection: $runner.to, displayedComponents: .date).disabled(!runner.useRange)
                Stepper("Sample \(runner.sample)", value: $runner.sample, in: 10...2000, step: 10)
            }
            Group {
                Text("Read-only").font(.headline)
                HStack {
                    button("Rating API") { await runner.ratingAPI() }
                    button("Videos: dataSize & dates") { await runner.videoDates() }
                    button("EXIF read cost") { await runner.exifCost() }
                    button("Aesthetics") { await runner.aesthetics() }
                    button("Similarity calibration") { await runner.calibration() }
                }
                Text("Writes to your library (asks first)").font(.headline)
                HStack {
                    button("Rating writes") { await runner.ratingWrites() }
                    button("Albums") { await runner.albums() }
                    button("Check album rename") { await runner.albumRenameCheck() }
                    button("Delete spike album") { await runner.deleteSpikeAlbum() }
                }
            }
            .disabled(runner.busy != nil || runner.authorization != .authorized)
            HStack {
                if let busy = runner.busy {
                    ProgressView().controlSize(.small)
                    Text("Running \(busy)…")
                }
                Spacer()
                Button("Reveal reports") {
                    try? FileManager.default.createDirectory(at: runner.reportDir, withIntermediateDirectories: true)
                    NSWorkspace.shared.activateFileViewerSelecting([runner.reportDir])
                }
            }
            ScrollView {
                Text(runner.log)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(.quaternary.opacity(0.3))
        }
        .padding()
    }

    private func button(_ title: String, _ action: @escaping @MainActor () async -> Void) -> some View {
        Button(title) { Task { await action() } }
    }
}
