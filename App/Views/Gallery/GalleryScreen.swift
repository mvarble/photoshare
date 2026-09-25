import PhotoSyncCore
import SwiftUI

/// Two panes: the timeline grid and a large preview. Arrow keys move, Space imports.
struct GalleryScreen: View {
    @Environment(AppModel.self) private var model
    @State private var columns = 3

    var body: some View {
        @Bindable var model = model
        VStack(spacing: 0) {
            HSplitView {
                ThumbnailGrid(columns: $columns)
                    .frame(minWidth: 260, idealWidth: 380, maxWidth: 700)
                PreviewPane()
                    .frame(minWidth: 480)
            }
            StatusFooter()
        }
        .overlay(alignment: .top) {
            if let toast = model.toast {
                Text(toast)
                    .font(.headline)
                    .padding(.horizontal, 16).padding(.vertical, 10)
                    .background(.regularMaterial, in: Capsule())
                    .padding(.top, 16)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.easeOut(duration: 0.2), value: model.toast)
        // Arrow keys and Space are menu shortcuts (PhotoSyncApp), so they work
        // no matter which pane has keyboard focus.
        .onChange(of: columns, initial: true) { _, c in model.gridColumns = c }
        .confirmationDialog(
            "This photo is already in your Photos library.",
            isPresented: Binding(get: { model.confirmDuplicateFor != nil }, set: { if !$0 { model.confirmDuplicateFor = nil } }),
            titleVisibility: .visible
        ) {
            Button("Add Another Copy") {
                if let id = model.confirmDuplicateFor { model.reimport(id) }
                model.confirmDuplicateFor = nil
            }
            Button("Cancel", role: .cancel) { model.confirmDuplicateFor = nil }
        } message: {
            Text("Adding it again will create a second copy in Photos.")
        }
    }
}
