import CleanerCore
import SwiftUI

struct PhotoPage: View {
    let model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            PhotoScopeView(model: model).padding(16)
            Divider()
            PhotoResults(model: model)
            Divider()
            PhotoActionBar(model: model).padding(12)
        }
        .navigationTitle("Photos · Rating & Similar Shots")
    }
}

private struct PhotoScopeView: View {
    let model: AppModel

    private var scope: PhotoScopeSetting { model.settings.settings.photos.scope }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("Scope", selection: kind) {
                HStack {
                    Text("Older than")
                    TextField("", value: days, format: .number).frame(width: 70)
                    Stepper("days", value: days, in: VideoSettings.olderThanDaysRange)
                }
                .tag(PhotoScopeSetting.Kind.olderThan)
                HStack {
                    Text("Taken from")
                    DatePicker("", selection: date(\.from, fallback: defaultFrom), displayedComponents: .date).labelsHidden()
                    Text("to")
                    DatePicker("", selection: date(\.to, fallback: .now), displayedComponents: .date).labelsHidden()
                }
                .tag(PhotoScopeSetting.Kind.dateRange)
            }
            .pickerStyle(.radioGroup)
            if scope.kind == .olderThan {
                HStack {
                    Text(model.settings.settings.photos.resumeAfter.map { "Continuing after \($0.formatted(date: .abbreviated, time: .shortened))" }
                        ?? "Starting from the oldest unrated photo")
                    if model.settings.settings.photos.resumeAfter != nil {
                        Button("Start Over") { model.photos.startOver() }.buttonStyle(.link)
                    }
                }
                .font(.caption).foregroundStyle(.secondary)
            }
            if scope.kind == .dateRange {
                if let from = scope.from, let to = scope.to, to < from {
                    Label("The end date is before the start date.", systemImage: "exclamationmark.triangle").foregroundStyle(.red)
                }
                Label("A date range re-rates every photo in it, overwriting existing stars, and regroups its similar shots.",
                      systemImage: "info.circle")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .disabled(model.jobs.isBusy)
        .onChange(of: scope) { model.photos.scopeChanged() }
    }

    private var defaultFrom: Date { Calendar.current.date(byAdding: .month, value: -1, to: .now)! }

    private var kind: Binding<PhotoScopeSetting.Kind> {
        Binding(get: { scope.kind }, set: { kind in
            model.settings.update {
                $0.photos.scope.kind = kind
                if kind == .dateRange {
                    $0.photos.scope.from = $0.photos.scope.from ?? Self.day(defaultFrom)
                    $0.photos.scope.to = $0.photos.scope.to ?? Self.day(.now)
                }
            }
        })
    }

    private var days: Binding<Int> {
        let range = VideoSettings.olderThanDaysRange
        return Binding(get: { scope.olderThanDays },
                       set: { value in model.settings.update { $0.photos.scope.olderThanDays = min(max(value, range.lowerBound), range.upperBound) } })
    }

    private func date(_ keyPath: WritableKeyPath<PhotoScopeSetting, String?>, fallback: Date) -> Binding<Date> {
        Binding(get: { scope[keyPath: keyPath].flatMap(Self.parse) ?? fallback },
                set: { value in model.settings.update { $0.photos.scope[keyPath: keyPath] = Self.day(value) } })
    }

    private static let dayFormat = Date.ISO8601FormatStyle(timeZone: .current).year().month().day().dateSeparator(.dash)

    private static func day(_ date: Date) -> String {
        date.formatted(dayFormat)
    }

    private static func parse(_ day: String) -> Date? {
        try? dayFormat.parse(day)
    }
}
