import SwiftUI
import MuxCore

struct ConnectionEditor: View {
    @EnvironmentObject private var library: LibraryStore
    @Environment(\.dismiss) private var dismiss
    @State var profile: ConnectionProfile
    @State private var password = ""
    @State private var showKeys = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("Connection") {
                    TextField("Name", text: $profile.name)
                    TextField("Hostname or IP address", text: $profile.hostname)
                        .textContentType(.URL).keyboardType(.URL)
                    TextField("Port", value: $profile.port, format: .number.grouping(.never)).keyboardType(.numberPad)
                    TextField("Username", text: $profile.username).textContentType(.username)
                }
                Section {
                    Picker("Authentication", selection: $profile.authentication) {
                        Text("SSH key").tag(AuthenticationKind.key)
                        Text("Password").tag(AuthenticationKind.password)
                    }
                    if profile.authentication == .key {
                        Picker("Key", selection: $profile.keyID) {
                            Text("Choose key").tag(UUID?.none)
                            ForEach(library.visibleKeys) { key in Text(key.name).tag(Optional(key.id)) }
                        }
                        Button("Generate or import key", systemImage: "key.horizontal") { showKeys = true }
                    } else {
                        SecureField(library.profiles.contains(where: { $0.id == profile.id }) ? "Password (leave blank to keep saved)" : "Password", text: $password)
                            .textContentType(.password)
                    }
                } header: { Text("Authentication") } footer: {
                    Text("Saved credentials sync through iCloud Keychain. Host fingerprints are verified separately on each device.")
                }
                Section {
                    Picker("Connect through", selection: $profile.bastionID) {
                        Text("Direct connection").tag(UUID?.none)
                        ForEach(library.visibleProfiles.filter { $0.id != profile.id && $0.bastionID == nil }) { bastion in
                            Text(bastion.name).tag(Optional(bastion.id))
                        }
                    }
                } header: { Text("Bastion") } footer: {
                    Text("Save the outside host as its own connection, then choose it here for an inside host. Each host uses its own credentials.")
                }
                if let error { Section { Text(error).foregroundStyle(.red) } }
            }
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .navigationTitle(library.profiles.contains(where: { $0.id == profile.id }) ? "Edit connection" : "Add connection")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        do {
                            profile.name = profile.name.trimmingCharacters(in: .whitespacesAndNewlines)
                            profile.hostname = profile.hostname.trimmingCharacters(in: .whitespacesAndNewlines)
                            profile.username = profile.username.trimmingCharacters(in: .whitespacesAndNewlines)
                            if profile.authentication == .password && password.isEmpty && !library.profiles.contains(where: { $0.id == profile.id }) {
                                throw MuxError.message("Enter a password for this connection.")
                            }
                            try library.save(profile, password: profile.authentication == .password && !password.isEmpty ? password : nil)
                            dismiss()
                        } catch { self.error = error.localizedDescription }
                    }
                }
            }
        }.sheet(isPresented: $showKeys) { KeyLibraryView() }
    }
}
