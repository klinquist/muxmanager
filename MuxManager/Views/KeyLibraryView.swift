import SwiftUI
import UniformTypeIdentifiers
import MuxCore

struct KeyLibraryView: View {
    @EnvironmentObject private var library: LibraryStore
    @Environment(\.dismiss) private var dismiss
    @State private var adding = false
    @State private var selected: SSHKeyRecord?
    @State private var error: String?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(library.visibleKeys) { key in
                        Button { selected = key } label: {
                            Label {
                                VStack(alignment: .leading) {
                                    Text(key.name).foregroundStyle(.primary)
                                    Text(key.publicKey.split(separator: " ").first.map(String.init) ?? "SSH key")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                            } icon: { Image(systemName: "key.horizontal").foregroundStyle(.mint) }
                        }
                        .contextMenu {
                            Button("Copy public key", systemImage: "doc.on.doc") { UIPasteboard.general.string = key.publicKey }
                            Button("Delete key", systemImage: "trash", role: .destructive) {
                                do { try library.removeKey(key) } catch { self.error = error.localizedDescription }
                            }
                        }
                    }
                    Button("Generate or import key", systemImage: "plus") { adding = true }
                } footer: {
                    Text("Private keys and imported passphrases are stored in Keychain and sync through iCloud Keychain. Copy a public key to install it in the host's authorized_keys file.")
                }
            }
            .navigationTitle("SSH keys")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .sheet(isPresented: $adding) { AddKeyView() }
            .sheet(item: $selected) { key in PublicKeyView(key: key) }
            .alert("SSH key", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
                Button("OK") { error = nil }
            } message: { Text(error ?? "") }
        }
    }
}

private struct AddKeyView: View {
    @EnvironmentObject private var library: LibraryStore
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var importing = false
    @State private var privateKey = ""
    @State private var passphrase = ""
    @State private var filePicker = false
    @State private var error: String?
    @State private var saving = false

    var body: some View {
        NavigationStack {
            Form {
                Section { TextField("Key name", text: $name) }
                Section {
                    Picker("Source", selection: $importing) {
                        Text("Generate Ed25519").tag(false)
                        Text("Import OpenSSH key").tag(true)
                    }.pickerStyle(.segmented)
                    if importing {
                        Button("Choose private key file", systemImage: "doc") { filePicker = true }
                        TextEditor(text: $privateKey).font(.system(.caption, design: .monospaced)).frame(minHeight: 150)
                            .privacySensitive()
                            .accessibilityLabel("OpenSSH private key")
                        SecureField("Passphrase, if encrypted", text: $passphrase)
                    } else {
                        Text("Generate a new key on this device, then copy its public key to your hosts. The private key stays in Keychain.")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                }
                if let error { Text(error).foregroundStyle(.red) }
            }
            .textInputAutocapitalization(.never).autocorrectionDisabled()
            .navigationTitle("Add SSH key")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(saving ? "Saving…" : "Save") { save() }
                        .disabled(saving || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || importing && privateKey.isEmpty)
                }
            }
            .fileImporter(isPresented: $filePicker, allowedContentTypes: [.data, .plainText]) { result in
                do {
                    let url = try result.get()
                    let granted = url.startAccessingSecurityScopedResource()
                    defer { if granted { url.stopAccessingSecurityScopedResource() } }
                    let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                    guard size < 256 * 1024 else { throw MuxError.message("Choose a private key smaller than 256 KB.") }
                    privateKey = try String(contentsOf: url, encoding: .utf8)
                } catch { self.error = error.localizedDescription }
            }
        }
    }
    private func save() {
        saving = true
        let source = privateKey, phrase = passphrase, label = name.trimmingCharacters(in: .whitespacesAndNewlines), shouldImport = importing
        Task {
            do {
                // bcrypt passphrase derivation can be expensive; keep it off the UI thread.
                let pair = try await Task.detached(priority: .userInitiated) {
                    if shouldImport { return try SSHKeys.importKey(source, passphrase: phrase.isEmpty ? nil : phrase, name: label) }
                    return SSHKeys.generate(name: label)
                }.value
                try library.saveKey(pair.0, material: pair.1)
                privateKey = ""; passphrase = ""; dismiss()
            } catch { self.error = error.localizedDescription; saving = false }
        }
    }
}

private struct PublicKeyView: View {
    let key: SSHKeyRecord
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            Form {
                Section("Public key") {
                    Text(key.publicKey).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                    Button("Copy public key", systemImage: "doc.on.doc") { UIPasteboard.general.string = key.publicKey }
                    ShareLink(item: key.publicKey) { Label("Share public key", systemImage: "square.and.arrow.up") }
                }
                Section {
                    Text("Add this public key as one line in ~/.ssh/authorized_keys on each host where you want to use it. Mux Manager does not change that file automatically.")
                }
            }
            .navigationTitle(key.name)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }
}
