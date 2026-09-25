import PhotoSyncCore
import SwiftUI

/// Large preview of the selected photo: shows the fast embedded preview at
/// once, then swaps in the full-quality one.
struct PreviewPane: View {
    @Environment(AppModel.self) private var model
    @State private var image: NSImage?
    @State private var shownFor: Int64?
    @State private var loadingFull = false

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                Color.black
                if let image, shownFor == model.timeline.selectedID {
                    Image(nsImage: image).resizable().scaledToFit()
                } else if model.timeline.selected != nil {
                    ProgressView().controlSize(.large).tint(.white)
                }
                if loadingFull {
                    VStack { Spacer(); HStack { Spacer(); ProgressView().controlSize(.small).tint(.white).padding(10) } }
                }
            }
            if let entry = model.timeline.selected {
                ImportBar(entry: entry)
            }
        }
        .task(id: model.timeline.selected?.contentKey) { await load() }
    }

    private func load() async {
        guard let entry = model.timeline.selected, let svc = model.thumbnails else { image = nil; return }
        if shownFor != entry.id { image = nil }
        if let quick = await svc.quickPreview(for: entry), !Task.isCancelled {
            image = NSImage(data: quick)
            shownFor = entry.id
        }
        // Only fetch the full-size version once she pauses on a photo; holding an
        // arrow key must not queue a 10 MB download per photo passed.
        try? await Task.sleep(for: .milliseconds(250))
        if Task.isCancelled { return }
        loadingFull = true
        defer { loadingFull = false }
        if let full = await svc.fullPreview(for: entry), !Task.isCancelled {
            image = NSImage(data: full)
            shownFor = entry.id
        }
    }
}

/// Date, position, and the one big button.
struct ImportBar: View {
    @Environment(AppModel.self) private var model
    let entry: PhotoEntry

    var body: some View {
        let status = model.timeline.status(entry.id)
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.sortDate, format: Self.dateStyle).font(.headline)
                Text("\(((model.timeline.selectedIndex ?? 0) + 1).formatted()) of \(model.timeline.entries.count.formatted())")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            switch status {
            case .imported:
                Label("In Photos", systemImage: "checkmark.circle.fill")
                    .font(.title3.weight(.semibold)).foregroundStyle(.green)
            case .queued, .importing:
                Label("Adding to Photos…", systemImage: "arrow.down.circle")
                    .font(.title3).foregroundStyle(.secondary)
            case .failed(let why):
                Text(why).font(.callout).foregroundStyle(.red).lineLimit(2)
                Button("Try Again") { model.retryFailed(entry.id) }
                    .controlSize(.large).focusable(false)
            case .changedSinceImport:
                Button("Add Updated Photo") { model.requestImportAgain() }
                    .controlSize(.large).focusable(false)
            case .notImported:
                Button {
                    model.importSelected()
                } label: {
                    Label("Add to Photos", systemImage: "plus.circle.fill")
                        .font(.title3.weight(.semibold))
                        .padding(.horizontal, 8).padding(.vertical, 2)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .focusable(false)
                .help("Space")
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(.bar)
    }

    /// EXIF times are naive wall-clock values stored as UTC; show them as-is.
    static let dateStyle: Date.FormatStyle = {
        var f = Date.FormatStyle(date: .complete, time: .shortened)
        f.timeZone = TimeZone(identifier: "UTC")!
        return f
    }()
}
