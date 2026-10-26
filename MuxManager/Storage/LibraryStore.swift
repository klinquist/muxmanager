import Foundation
import Combine
import MuxCore
import OSLog

@MainActor
final class LibraryStore: ObservableObject {
    @Published private(set) var profiles: [ConnectionProfile] = []
    @Published private(set) var keys: [SSHKeyRecord] = []
    @Published var error: String?
    @Published private(set) var lastSyncAttempt: Date?
    @Published private(set) var lastSuccessfulSync: Date?
    @Published private(set) var lastSyncError: String?
    let secrets = SecretStore()
    private let directory: URL
    private let cloud: CloudSync?
    private var syncTask: Task<Void, Never>?
    private var revision = 0
    private var syncing = false
    private let logger = Logger(subsystem: "com.linquist.muxmanager", category: "iCloud")

    private struct Library: Codable {
        var profiles: [ConnectionProfile]
        var keys: [SSHKeyRecord]
    }

    #if DEBUG
    static var screenshotScene: String? {
        let arguments = ProcessInfo.processInfo.arguments
        let index = arguments.firstIndex(of: "--mux-screenshot-scene")
        let argument = index.flatMap { $0 + 1 < arguments.count ? arguments[$0 + 1] : nil }
        let value = ProcessInfo.processInfo.environment["MUX_SCREENSHOT_SCENE"] ?? argument
        return ["hosts", "smart", "original", "fit", "connection", "preview", "shell", "history", "history-original", "connecting", "connecting-hosts"].contains(value ?? "") ? value : nil
    }
    #endif

    init() {
        let identifier = Bundle.main.object(forInfoDictionaryKey: "CloudContainerIdentifier") as? String ?? "iCloud.com.linquist.muxmanager"
        #if DEBUG
        if Self.screenshotScene != nil {
            // Never read or write the user's library, Keychain, or CloudKit in captures.
            cloud = nil
            directory = FileManager.default.temporaryDirectory.appendingPathComponent("MuxManagerScreenshots", isDirectory: true)
            let keyID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
            let gatewayID = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
            keys = [SSHKeyRecord(id: keyID, name: "Personal Ed25519", publicKey: "Sample public key metadata")]
            profiles = [
                ConnectionProfile(name: "Build server", hostname: "build.internal", username: "dev", keyID: keyID, bastionID: gatewayID),
                ConnectionProfile(id: gatewayID, name: "Gateway", hostname: "gateway.example.com", username: "dev", keyID: keyID),
                ConnectionProfile(name: "Home lab", hostname: "homelab.example.com", username: "dev", keyID: keyID)
            ]
            return
        }
        #endif
        cloud = CloudSync(identifier: identifier)
        directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MuxManager", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let file = directory.appendingPathComponent("library.json")
            if FileManager.default.fileExists(atPath: file.path) {
                let library = try JSONDecoder().decode(Library.self, from: Data(contentsOf: file))
                profiles = library.profiles; keys = library.keys
            }
        } catch { self.error = "Could not load saved connections: \(error.localizedDescription)" }
    }
    var visibleProfiles: [ConnectionProfile] { profiles.filter { !$0.deleted }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending } }
    var visibleKeys: [SSHKeyRecord] { keys.filter { !$0.deleted } }

    var syncDiagnostics: String {
        let identifier = Bundle.main.object(forInfoDictionaryKey: "CloudContainerIdentifier") as? String ?? "iCloud.com.linquist.muxmanager"
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        let formatter = ISO8601DateFormatter()
        return """
        Mux Manager \(version) (\(build)) — iCloud diagnostics
        Container: \(identifier)
        Saved connections on this device: \(visibleProfiles.count)
        SSH key metadata on this device: \(visibleKeys.count)
        Last attempt: \(lastSyncAttempt.map { formatter.string(from: $0) } ?? "Not attempted this launch")
        Last success: \(lastSuccessfulSync.map { formatter.string(from: $0) } ?? "No successful sync this launch")
        Last error: \(lastSyncError ?? "None recorded")

        Sync runs automatically while the app is active and after edits.
        Xcode development builds and TestFlight/App Store builds normally use separate CloudKit databases. Development records are not copied when a schema is deployed.
        Credentials sync separately through iCloud Keychain.
        This report excludes saved host details, terminal content, and credentials.
        """
    }

    func save(_ profile: ConnectionProfile, password: String?) throws {
        try profile.validate(in: profiles)
        if let password { try secrets.write(Data(password.utf8), account: "password:\(profile.id)") }
        var updated = profile; updated.modifiedAt = Date()
        var next = profiles; next.removeAll { $0.id == updated.id }; next.append(updated)
        try persist(profiles: next, keys: keys)
        profiles = next; revision += 1; scheduleSync()
    }
    func saveKey(_ record: SSHKeyRecord, material: SavedKeyMaterial) throws {
        try secrets.write(JSONEncoder().encode(material), account: "key:\(record.id)")
        var next = keys; next.removeAll { $0.id == record.id }; next.append(record)
        try persist(profiles: profiles, keys: next)
        keys = next; revision += 1; scheduleSync()
    }
    func remove(_ profile: ConnectionProfile) throws {
        if profiles.contains(where: { !$0.deleted && $0.bastionID == profile.id }) {
            throw MuxError.message("This connection is used as a bastion. Update its target connections first.")
        }
        var tombstone = profile; tombstone.deleted = true; tombstone.modifiedAt = Date()
        var next = profiles; next.removeAll { $0.id == profile.id }; next.append(tombstone)
        try persist(profiles: next, keys: keys); profiles = next; revision += 1
        try secrets.delete("password:\(profile.id)")
        scheduleSync()
    }
    func removeKey(_ key: SSHKeyRecord) throws {
        guard !profiles.contains(where: { !$0.deleted && $0.keyID == key.id }) else {
            throw MuxError.message("Update the connections using this key before removing it.")
        }
        var deleted = key; deleted.deleted = true; deleted.modifiedAt = Date()
        var next = keys; next.removeAll { $0.id == key.id }; next.append(deleted)
        try persist(profiles: profiles, keys: next); keys = next; revision += 1
        try secrets.delete("key:\(key.id)"); scheduleSync()
    }
    func keyMaterial(_ id: UUID) throws -> SavedKeyMaterial {
        guard let data = try secrets.read("key:\(id)") else {
            throw MuxError.message("This key has not arrived through iCloud Keychain yet. Try again after sync, or import it on this device.")
        }
        return try JSONDecoder().decode(SavedKeyMaterial.self, from: data)
    }
    /// Runs only while the app is active. Edits also schedule an earlier, debounced sync.
    /// Periodic reconciliation receives edits from other devices and retries offline failures.
    func runAutomaticSync() async {
        #if DEBUG
        if Self.screenshotScene != nil { return }
        #endif
        while !Task.isCancelled {
            await synchronize()
            do { try await Task.sleep(nanoseconds: 60_000_000_000) } catch { return }
        }
    }

    private func synchronize() async {
        guard let cloud, !syncing, !Task.isCancelled else { return }
        syncing = true
        lastSyncAttempt = Date()
        defer { syncing = false }
        let startingRevision = revision
        do {
            let remote = try await cloud.synchronize(profiles: profiles, keys: keys)
            // Edits made while the network request was in flight must survive.
            let mergedProfiles = ProfileMerge.merge(local: profiles, remote: remote.profiles)
            let mergedKeys = ProfileMerge.keys(local: keys, remote: remote.keys)
            try persist(profiles: mergedProfiles, keys: mergedKeys)
            profiles = mergedProfiles; keys = mergedKeys
            lastSuccessfulSync = Date(); lastSyncError = nil
            if startingRevision != revision { scheduleSync() }
        } catch {
            if !Task.isCancelled {
                lastSyncError = error.localizedDescription
                logger.debug("Automatic sync deferred: \(error.localizedDescription, privacy: .private)")
            }
        }
    }
    private func scheduleSync() {
        syncTask?.cancel()
        syncTask = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: 1_000_000_000) } catch { return }
            await self?.synchronize()
        }
    }
    private func persist(profiles: [ConnectionProfile], keys: [SSHKeyRecord]) throws {
        let data = try JSONEncoder().encode(Library(profiles: profiles, keys: keys))
        try data.write(to: directory.appendingPathComponent("library.json"), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
    func readLocal<T: Decodable>(_ type: T.Type, name: String) -> T? {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent(name)) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }
    func writeLocal<T: Encodable>(_ value: T, name: String) throws {
        try JSONEncoder().encode(value).write(to: directory.appendingPathComponent(name), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
}
