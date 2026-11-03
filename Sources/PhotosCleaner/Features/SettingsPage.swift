import AppKit
import CleanerCore
import SwiftUI

struct SettingsPage: View {
    let model: AppModel
    @State private var confirmingReset = false
    @State private var albumNames: [AlbumRole: String] = [:]

    private var settings: AppSettings { model.settings.settings }

    var body: some View {
        Form {
            Section("Videos") {
                LabeledContent("Export folder") {
                    VStack(alignment: .trailing, spacing: 6) {
                        Text(model.videos.folder.path).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                        HStack {
                            FolderBadge(state: model.videos.folderState)
                            Button("Choose…", action: chooseFolder)
                            Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([model.videos.folder]) }
                                .disabled(model.videos.folderState == .willBeCreated)
                        }
                    }
                }
                TextField("File name", text: binding(\.videos.nameTemplate), prompt: Text(NamingEngine.defaultTemplate))
                Text("Preview: \(NamingEngine.render(settings.videos.nameTemplate, day: "2026-02-28", filename: "IMG_0579.MOV"))  ·  tokens: \(NamingEngine.tokens.joined(separator: " "))")
                    .font(.caption).foregroundStyle(.secondary)
                Picker("Parallel exports", selection: binding(\.videos.parallelExports)) {
                    ForEach(VideoSettings.parallelExportsRange, id: \.self) { Text("\($0)").tag($0) }
                }
                .pickerStyle(.segmented)
                albumField(.videoToDelete)
            }

            Section("Photos") {
                LabeledContent("Camera photos per run") {
                    TextField("", value: clamped(\.photos.cameraPhotosPerRun, PhotoSettings.cameraPhotosPerRunRange), format: .number)
                        .frame(width: 100).multilineTextAlignment(.trailing)
                }
                LabeledContent("Star thresholds") {
                    HStack {
                        ForEach(0..<4, id: \.self) { index in
                            TextField("", value: threshold(index), format: .number.precision(.fractionLength(2)))
                                .frame(width: 60).multilineTextAlignment(.trailing)
                        }
                    }
                }
                Text("Scores run from −1 to 1. Below the first value is 1★, from the last value up is 5★.")
                    .font(.caption).foregroundStyle(.secondary)
                if settings.photos.starThresholds != settings.photos.starThresholds.sorted() {
                    Text("Each threshold must be at least the one before it.").font(.caption).foregroundStyle(.red)
                }
                albumField(.photoLowQuality)
                albumField(.photoDuplicated)
            }

            Section("Data") {
                LabeledContent("Folder", value: model.dataDirectory.path)
                HStack {
                    Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([model.settings.fileURL]) }
                    Spacer()
                    Button("Reset All Settings…", role: .destructive) { confirmingReset = true }
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
        .disabled(model.jobs.isBusy)
        .navigationTitle("Settings")
        .onAppear(perform: loadAlbumNames)
        .confirmationDialog("Reset all settings to their defaults?", isPresented: $confirmingReset) {
            Button("Reset", role: .destructive) {
                Task {
                    await model.resetAllSettings()
                    model.videos.refreshFolder()
                    loadAlbumNames()
                }
            }
        } message: {
            Text("Albums, photos and exported files aren't touched.")
        }
    }

    private func albumField(_ role: AlbumRole) -> some View {
        TextField(label(role), text: Binding(get: { albumNames[role] ?? "" }, set: { albumNames[role] = $0 }))
            .onSubmit { Task { await model.renameAlbum(role, to: albumNames[role] ?? "") } }
    }

    private func label(_ role: AlbumRole) -> String {
        switch role {
        case .videoToDelete: "Album"
        case .photoLowQuality: "Low-quality album"
        case .photoDuplicated: "Similar-shots album"
        }
    }

    private func loadAlbumNames() {
        for role in AlbumRole.allCases { albumNames[role] = model.settings.settings[keyPath: role.keyPath].name }
    }

    private func binding<Value>(_ keyPath: WritableKeyPath<AppSettings, Value>) -> Binding<Value> {
        Binding(get: { model.settings.settings[keyPath: keyPath] },
                set: { value in model.settings.update { $0[keyPath: keyPath] = value } })
    }

    private func clamped(_ keyPath: WritableKeyPath<AppSettings, Int>, _ range: ClosedRange<Int>) -> Binding<Int> {
        Binding(get: { model.settings.settings[keyPath: keyPath] },
                set: { value in model.settings.update { $0[keyPath: keyPath] = min(max(value, range.lowerBound), range.upperBound) } })
    }

    private func threshold(_ index: Int) -> Binding<Double> {
        Binding(get: { model.settings.settings.photos.starThresholds[index] },
                set: { value in model.settings.update { $0.photos.starThresholds[index] = min(max(value, -1), 1) } })
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = model.videos.folder
        panel.prompt = "Use Folder"
        if panel.runModal() == .OK, let url = panel.url { model.videos.chooseFolder(url) }
    }
}
