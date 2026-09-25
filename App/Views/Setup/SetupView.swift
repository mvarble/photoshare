import AppKit
import PhotoSyncCore
import SwiftUI

/// One-time connection setup: server, folders, and this Mac's key.
struct SetupView: View {
    @Environment(AppModel.self) private var model
    @State private var host = ""
    @State private var port = "22"
    @State private var username = ""
    @State private var folders = "."
    @State private var key: Curve25519.Signing.PrivateKey?
    @State private var keySource = ""
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Connect to the photo server").font(.largeTitle.bold())
            Text("This is done once. After this, PhotoSync connects by itself.")
                .foregroundStyle(.secondary)

            Form {
                Section("Server") {
                    TextField("Address", text: $host, prompt: Text("photos.example.com"))
                    TextField("Port", text: $port)
                    TextField("Username", text: $username)
                    TextField("Folders", text: $folders, prompt: Text("e.g. canon-r7 (comma-separated; . for all)"))
                }
                Section("This Mac's key") {
                    HStack {
                        Button("Use Existing Key File…", action: chooseKeyFile)
                        Button("Create New Key") {
                            key = Curve25519.Signing.PrivateKey()
                            keySource = "New key. Add the line below to the server's authorized_keys."
                        }
                        Spacer()
                    }
                    if let key {
                        Text(keySource).font(.callout).foregroundStyle(.secondary)
                        HStack(alignment: .top) {
                            Text(KeyStore.publicKeyLine(key))
                                .font(.system(.caption, design: .monospaced))
                                .textSelection(.enabled)
                                .lineLimit(3)
                            Button("Copy") {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(KeyStore.publicKeyLine(key), forType: .string)
                            }
                        }
                    }
                }
            }
            .formStyle(.grouped)

            if let error {
                Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red)
            }
            HStack {
                Spacer()
                if busy { ProgressView().controlSize(.small) }
                Button("Connect", action: connect)
                    .keyboardShortcut(.defaultAction)
                    .disabled(busy || host.isEmpty || username.isEmpty || key == nil || Int(port) == nil)
            }
        }
        .padding(32)
        .frame(maxWidth: 640)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear(perform: prefill)
    }

    private func prefill() {
        guard let c = model.existingConfig else { return }
        host = c.host
        port = String(c.port)
        username = c.username
        folders = c.roots.joined(separator: ", ")
        if let k = KeyStore(url: model.paths.privateKey).load() {
            key = k
            keySource = "Using the key already set up on this Mac."
        }
    }

    private func chooseKeyFile() {
        let panel = NSOpenPanel()
        panel.showsHiddenFiles = true
        panel.canChooseDirectories = false
        panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".ssh")
        panel.message = "Choose the private key (for example id_ed25519)"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            key = try KeyStore.parseOpenSSH(String(contentsOf: url, encoding: .utf8))
            keySource = "Using \(url.lastPathComponent). Its public half must already be on the server."
            error = nil
        } catch {
            self.error = "That file isn't an unencrypted Ed25519 key."
        }
    }

    private func connect() {
        guard let key, let port = Int(port) else { return }
        let roots = folders.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        busy = true
        error = nil
        Task {
            do {
                try await model.completeSetup(host: host.trimmingCharacters(in: .whitespaces), port: port,
                                              username: username.trimmingCharacters(in: .whitespaces),
                                              roots: roots.isEmpty ? ["."] : roots, key: key)
            } catch {
                self.error = AppModel.friendly(error)
            }
            busy = false
        }
    }
}
