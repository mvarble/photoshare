import PhotoSyncCore
import SwiftUI

@main
struct PhotoSyncApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup("PhotoSync") {
            RootView()
                .environment(model)
                .frame(minWidth: 900, minHeight: 560)
                .task { await model.start() }
        }
        .windowToolbarStyle(.unifiedCompact)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandMenu("Photo") {
                // Plain-key shortcuts are only enabled in the gallery, so they
                // never steal typing from the setup form.
                Button("Add to Photos") { model.importSelected() }
                    .keyboardShortcut(.space, modifiers: [])
                    .disabled(!model.isReady)
                Button("Import Again…") { model.requestImportAgain() }
                    .disabled(!model.canImportAgain)
                Divider()
                Button("Previous Photo") { model.timeline.move(by: -1) }
                    .keyboardShortcut(.leftArrow, modifiers: [])
                    .disabled(!model.isReady)
                Button("Next Photo") { model.timeline.move(by: 1) }
                    .keyboardShortcut(.rightArrow, modifiers: [])
                    .disabled(!model.isReady)
                Button("Photo Above") { model.timeline.move(by: -model.gridColumns) }
                    .keyboardShortcut(.upArrow, modifiers: [])
                    .disabled(!model.isReady)
                Button("Photo Below") { model.timeline.move(by: model.gridColumns) }
                    .keyboardShortcut(.downArrow, modifiers: [])
                    .disabled(!model.isReady)
                Divider()
                Button("Check Server for New Photos") { model.rescan() }
                    .keyboardShortcut("r")
                    .disabled(!model.isReady)
            }
            #if DEBUG
            CommandMenu("Debug") {
                Button("Revert Test Imports…") { Task { await model.revertTestImports() } }
                Button("Show Connection Settings") { model.showSetup() }
            }
            #endif
        }
    }
}

struct RootView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        switch model.phase {
        case .loading: ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        case .setup: SetupView()
        case .gallery: GalleryScreen()
        }
    }
}
