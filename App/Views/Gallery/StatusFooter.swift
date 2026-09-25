import PhotoSyncCore
import SwiftUI

struct StatusFooter: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 12) {
            if let problem = model.problem {
                Label(problem, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .lineLimit(1)
                Button("Try Again") { model.problem = nil; model.rescan() }
                    .controlSize(.small).focusable(false)
            } else if model.isScanning {
                ProgressView().controlSize(.small)
                Text(scanText).foregroundStyle(.secondary)
            } else {
                Text("\(model.timeline.entries.count.formatted()) photos · \(model.timeline.importedCount.formatted()) in Photos")
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text("← → to browse · Space to add")
                .foregroundStyle(.tertiary)
        }
        .font(.callout)
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .background(.bar)
    }

    private var scanText: String {
        guard let p = model.scanProgress else { return "Checking for new photos…" }
        switch p.phase {
        case .listing: return "Checking for new photos… \(p.filesFound.formatted()) found"
        case .reading: return "Reading new photos… \(p.filesRead.formatted()) of \(p.filesToRead.formatted())"
        case .pairing, .done: return "Almost done…"
        }
    }
}
