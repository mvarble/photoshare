import PhotoSyncCore
import SwiftUI

struct ThumbnailGrid: View {
    @Environment(AppModel.self) private var model
    @Binding var columns: Int
    static let spacing: CGFloat = 4

    var body: some View {
        GeometryReader { geo in
            // The scrollbar is always shown (see AlwaysVisibleScroller), so leave room for it.
            let width = geo.size.width - 8 - AlwaysVisibleScroller.width
            let cols = max(1, Int(width / 120))
            let side = (width - CGFloat(cols - 1) * Self.spacing) / CGFloat(cols)
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVGrid(columns: Array(repeating: GridItem(.fixed(side), spacing: Self.spacing), count: cols),
                              spacing: Self.spacing,
                              pinnedViews: [.sectionHeaders]) {
                        ForEach(model.timeline.sections) { section in
                            Section {
                                ForEach(model.timeline.entries[section.range]) { entry in
                                    ThumbnailCell(entry: entry, side: side)
                                        .id(entry.id)
                                }
                            } header: {
                                MonthHeader(section: section)
                            }
                        }
                    }
                    .padding(.horizontal, 4)
                    .padding(.bottom, 4)
                    .background(AlwaysVisibleScroller())
                }
                .scrollIndicators(.visible)
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

/// Sticky "September, 2026" header; stays pinned while scrolling through that month.
struct MonthHeader: View {
    let section: MonthSection

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(section.title).font(.headline)
            Spacer()
            Text("\(section.range.count.formatted()) photos")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity)
        .background(.bar)
    }
}

/// macOS hides overlay scrollbars until you scroll. Switch the grid's
/// underlying NSScrollView to a permanently visible (legacy-style) scroller so
/// the scrollbar always shows where you are in the timeline.
struct AlwaysVisibleScroller: NSViewRepresentable {
    static let width = NSScroller.scrollerWidth(for: .regular, scrollerStyle: .legacy)

    func makeNSView(context: Context) -> NSView { NSView() }

    func updateNSView(_ view: NSView, context: Context) {
        DispatchQueue.main.async {
            guard let scrollView = view.enclosingScrollView else { return }
            scrollView.hasVerticalScroller = true
            scrollView.autohidesScrollers = false
            if scrollView.scrollerStyle != .legacy { scrollView.scrollerStyle = .legacy }
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
