import AppKit
import CleanerCore
import SwiftUI

enum Page: String, CaseIterable, Identifiable {
    case videos, photos, activity

    var id: String { rawValue }

    var title: String {
        switch self {
        case .videos: "Export & Cleanup"
        case .photos: "Rating & Similar Shots"
        case .activity: "Activity"
        }
    }

    var icon: String {
        switch self {
        case .videos: "video"
        case .photos: "photo.stack"
        case .activity: "list.bullet.rectangle"
        }
    }
}

struct RootView: View {
    let model: AppModel
    @SceneStorage("page") private var page = Page.videos

    var body: some View {
        if model.hasFullAccess {
            NavigationSplitView {
                List(selection: Binding(get: { page }, set: { page = $0 ?? .videos })) {
                    Section("Videos") { row(.videos) }
                    Section("Photos") { row(.photos) }
                    Section("App") { row(.activity) }
                }
                .navigationSplitViewColumnWidth(min: 180, ideal: 200)
            } detail: {
                switch page {
                case .videos: VideoPage(model: model)
                case .photos: PhotoPage(model: model)
                case .activity: ActivityView(model: model)
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) { StatusBar(model: model, page: page) }
        } else {
            AccessBlockedView(model: model)
        }
    }

    private func row(_ page: Page) -> some View {
        Label(page.title, systemImage: page.icon).tag(page)
    }
}

struct StatusBar: View {
    let model: AppModel
    let page: Page

    var body: some View {
        HStack(spacing: 12) {
            Label("Photos: full access", systemImage: "checkmark.circle")
            Divider().frame(height: 14)
            if let active = model.jobs.active {
                ProgressView().controlSize(.mini)
                Text("Busy: \(active.mode.title) \(active.name) · Keeping Mac awake")
            } else {
                Text("Idle")
            }
            Divider().frame(height: 14)
            Text(detail).lineLimit(1).truncationMode(.middle)
            Spacer()
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.bar)
    }

    private var folderState: String {
        switch model.videos.folderState {
        case .writable: "writable ✓"
        case .willBeCreated: "will be created on first export"
        case .notWritable(let reason): "✗ \(reason)"
        }
    }

    private var detail: String {
        switch page {
        case .videos:
            "Export folder \(folderState) · \(model.videos.freeSpace.map { bytes($0) + " free" } ?? "free space unknown")"
        case .photos:
            model.settings.settings.photos.resumeAfter.map { "Continuing after \($0.formatted(date: .abbreviated, time: .omitted))" }
                ?? "Starting from the oldest photo"
        case .activity:
            "Data folder: \(model.dataDirectory.path)"
        }
    }
}

struct AccessBlockedView: View {
    let model: AppModel

    var body: some View {
        ContentUnavailableView {
            Label("Photos Cleaner needs full access to Photos", systemImage: "photo.badge.exclamationmark")
        } description: {
            Text("It reads your library to find videos to export and photos to rate, and adds items to its own albums. It never deletes anything. Allow full access in System Settings › Privacy & Security › Photos.")
        } actions: {
            Button("Open System Settings") {
                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Photos")!)
            }
            .buttonStyle(.borderedProminent)
            Button("Check Again") { Task { await model.checkAccessAgain() } }
        }
    }
}
