import PhotoSyncCore
import SwiftUI

struct ThumbnailGrid: View {
    @Environment(AppModel.self) private var model
    @Binding var columns: Int
    static let spacing: CGFloat = 4

    var body: some View {
        GeometryReader { geo in
            let cols = max(1, Int((geo.size.width - 8) / 120))
            let side = (geo.size.width - 8 - CGFloat(cols - 1) * Self.spacing) / CGFloat(cols)
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVGrid(columns: Array(repeating: GridItem(.fixed(side), spacing: Self.spacing), count: cols),
                              spacing: Self.spacing) {
                        ForEach(model.timeline.entries) { entry in
                            ThumbnailCell(entry: entry, side: side)
                                .id(entry.id)
                        }
                    }
                    .padding(4)
                }
                .onChange(of: model.timeline.selectedID) { _, id in
                    guard let id else { return }
                    withAnimation(.easeInOut(duration: 0.15)) { proxy.scrollTo(id, anchor: .center) }
                }
                .onAppear {
                    if let id = model.timeline.selectedID { proxy.scrollTo(id, anchor: .center) }
                }
            }
            .onAppear { columns = cols }
            .onChange(of: cols) { _, c in columns = c }
        }
        .overlay {
            if model.timeline.entries.isEmpty {
                ContentUnavailableView {
                    Label(model.isScanning ? "Finding your photos…" : "No photos yet", systemImage: "photo.on.rectangle")
                } description: {
                    if let p = model.scanProgress, p.filesToRead > 0 {
                        Text("\(p.filesRead.formatted()) of \(p.filesToRead.formatted()) checked")
                    }
                }
            }
        }
    }
}

struct ThumbnailCell: View {
    @Environment(AppModel.self) private var model
    let entry: PhotoEntry
    let side: CGFloat
    @State private var image: NSImage?

    var body: some View {
        let selected = model.timeline.selectedID == entry.id
        ZStack(alignment: .bottomTrailing) {
            Rectangle().fill(.quaternary)
            if let image {
                Image(nsImage: image).resizable().scaledToFill()
            }
            StatusBadge(status: model.timeline.status(entry.id))
                .padding(5)
        }
        .frame(width: side, height: side)
        .clipped()
        .overlay {
            RoundedRectangle(cornerRadius: 3)
                .strokeBorder(selected ? Color.accentColor : .clear, lineWidth: 3)
        }
        .contentShape(Rectangle())
        .onTapGesture { model.timeline.select(entry.id) }
        .contextMenu {
            Button("Add to Photos") { model.importPhoto(entry.id) }
            Button("Import Again…") {
                model.timeline.select(entry.id)
                model.requestImportAgain()
            }
        }
        .task(id: entry.contentKey) {
            guard let svc = model.thumbnails else { return }
            var data = await svc.cachedThumbnail(for: entry)
            if data == nil {
                // Don't start downloads for cells that are just flying past.
                try? await Task.sleep(for: .milliseconds(150))
                if Task.isCancelled { return }
                data = await svc.thumbnail(for: entry)
            }
            guard let data, !Task.isCancelled else { return }
            // Decode at display size: thousands of cells can be created while scrolling.
            let px = Int(side * 2)
            if let cg = await Task.detached(operation: { ImageCoding.downsample(data, maxPixel: px) }).value {
                image = NSImage(cgImage: cg, size: .zero)
            }
        }
        .onDisappear { image = nil }
    }
}

/// Small corner badge. Imported is the one she looks for, so it's the boldest.
struct StatusBadge: View {
    let status: PhotoStatus

    var body: some View {
        switch status {
        case .notImported: EmptyView()
        case .queued, .importing:
            Image(systemName: "arrow.down.circle.fill")
                .symbolRenderingMode(.palette).foregroundStyle(.white, .blue)
                .font(.title3).symbolEffect(.pulse)
        case .imported:
            Image(systemName: "checkmark.circle.fill")
                .symbolRenderingMode(.palette).foregroundStyle(.white, .green)
                .font(.title3).shadow(radius: 2)
        case .changedSinceImport:
            Image(systemName: "exclamationmark.circle.fill")
                .symbolRenderingMode(.palette).foregroundStyle(.white, .orange)
                .font(.title3).shadow(radius: 2)
                .help("Imported before, but the photo on the server has changed since.")
        case .failed(let why):
            Image(systemName: "xmark.circle.fill")
                .symbolRenderingMode(.palette).foregroundStyle(.white, .red)
                .font(.title3).shadow(radius: 2)
                .help(why)
        }
    }
}
