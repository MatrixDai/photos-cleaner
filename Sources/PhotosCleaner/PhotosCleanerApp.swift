import AppKit
import CleanerCore
import SwiftUI

@main
struct PhotosCleanerApp: App {
    @State private var model: AppModel? = try? AppModel(dataDirectory: AppModel.defaultDataDirectory,
                                                         library: LivePhotoLibrary())

    var body: some Scene {
        Window("Photos Cleaner", id: "main") {
            Group {
                if let model {
                    RootView(model: model)
                        .task { await model.launch() }
                        .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
                            model.settings.flush()
                        }
                } else {
                    ContentUnavailableView("Can't open \(AppModel.defaultDataDirectory.path)",
                                           systemImage: "exclamationmark.triangle",
                                           description: Text("Photos Cleaner keeps its settings and run log there."))
                }
            }
            .frame(minWidth: 900, minHeight: 600)
        }
        .defaultSize(width: 1100, height: 720)
        .commands { CommandGroup(replacing: .newItem) {} }
    }
}
