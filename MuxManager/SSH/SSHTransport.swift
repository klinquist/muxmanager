import Foundation
import Citadel
import Crypto
import NIO
import NIOSSH
import MuxCore

struct HostKeyChallenge: Identifiable, Sendable {
    let id = UUID()
    let endpoint: String
    let publicKey: String
    let fingerprint: String
    let previousFingerprint: String?
}

struct RemoteCommandFailure: LocalizedError {
    let status: Int
    let diagnostic: String
    var errorDescription: String? { diagnostic.isEmpty ? "Remote command failed (\(status))." : diagnostic }
    var isNoServer: Bool {
        status == 1 && (diagnostic.contains("no server running") || diagnostic.contains("No such file or directory"))
    }
}

private final class HostValidator: NIOSSHClientServerAuthenticationDelegate, @unchecked Sendable {
    let endpoint: String
    let challenge: @Sendable (HostKeyChallenge) -> Void
    init(endpoint: String, challenge: @escaping @Sendable (HostKeyChallenge) -> Void) {
        self.endpoint = endpoint; self.challenge = challenge
    }
    func validateHostKey(hostKey: NIOSSHPublicKey, validationCompletePromise: EventLoopPromise<Void>) {
        do {
            let publicKey = String(openSSHPublicKey: hostKey)
            let known = try SecretStore().read("trust:\(endpoint)", synchronized: false)
                .flatMap { String(data: $0, encoding: .utf8) }
            if known == publicKey { validationCompletePromise.succeed(()); return }
            challenge(HostKeyChallenge(endpoint: endpoint, publicKey: publicKey,
                                       fingerprint: Self.fingerprint(publicKey),
                                       previousFingerprint: known.map(Self.fingerprint)))
            // Don't hold the SSH handshake open while the user checks a fingerprint.
            validationCompletePromise.fail(MuxError.message("Verify the host fingerprint to connect."))
        } catch { validationCompletePromise.fail(error) }
    }
    private static func fingerprint(_ text: String) -> String {
        let parts = text.split(separator: " ")
        guard parts.count > 1, let bytes = Data(base64Encoded: String(parts[1])) else { return "Invalid public key" }
        return "SHA256:" + Data(SHA256.hash(data: bytes)).base64EncodedString().replacingOccurrences(of: "=", with: "")
    }
}

enum SSHKeys {
    static func generate(name: String) -> (SSHKeyRecord, SavedKeyMaterial) {
        let key = Curve25519.Signing.PrivateKey()
        let publicKey = String(openSSHPublicKey: NIOSSHPrivateKey(ed25519Key: key).publicKey)
        return (SSHKeyRecord(name: name, publicKey: publicKey),
                SavedKeyMaterial(privateKey: key.makeSSHRepresentation(comment: "Mux Manager"), passphrase: nil))
    }
    static func importKey(_ text: String, passphrase: String?, name: String) throws -> (SSHKeyRecord, SavedKeyMaterial) {
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "\r\n", with: "\n")
        let decrypt = passphrase.flatMap { $0.isEmpty ? nil : Data($0.utf8) }
        let publicKey: NIOSSHPublicKey
        if let key = try? Curve25519.Signing.PrivateKey(sshEd25519: normalized, decryptionKey: decrypt) {
            publicKey = NIOSSHPrivateKey(ed25519Key: key).publicKey
        } else if let key = try? Insecure.RSA.PrivateKey(sshRsa: normalized, decryptionKey: decrypt) {
            publicKey = NIOSSHPrivateKey(custom: key).publicKey
        } else {
            throw MuxError.message("Could not read this OpenSSH Ed25519 or RSA private key. Check its passphrase. Supported encrypted keys use AES-128-CTR or AES-256-CTR.")
        }
        return (SSHKeyRecord(name: name, publicKey: String(openSSHPublicKey: publicKey)),
                SavedKeyMaterial(privateKey: normalized, passphrase: passphrase))
    }
    static func authentication(username: String, material: SavedKeyMaterial) throws -> SSHAuthenticationMethod {
        let decrypt = material.passphrase.flatMap { $0.isEmpty ? nil : Data($0.utf8) }
        if let key = try? Curve25519.Signing.PrivateKey(sshEd25519: material.privateKey, decryptionKey: decrypt) {
            return .ed25519(username: username, privateKey: key)
        }
        if let key = try? Insecure.RSA.PrivateKey(sshRsa: material.privateKey, decryptionKey: decrypt) {
            return .rsa(username: username, privateKey: key)
        }
        throw MuxError.message("The SSH key could not be unlocked. Import it again with the correct passphrase.")
    }
}

@MainActor
final class SSHTransport {
    var diagnostic: ((String) -> Void)?
    var onDisconnect: (() -> Void)?
    var isConnected: Bool { client?.isConnected == true }
    private var connectionGeneration = UUID()
    private var client: SSHClient?
    private var jump: SSHClient?
    private var streamTask: Task<Void, Never>?
    private var channel: ControlChannel?
    private var controlGeneration = UUID()
    private(set) var tmuxPath = "tmux"

    func connect(profile: ConnectionProfile, library: LibraryStore,
                 onProgress: (String) -> Void,
                 onChallenge: @escaping @Sendable (HostKeyChallenge) -> Void) async throws {
        let generation = UUID(); connectionGeneration = generation
        onProgress("Preparing SSH credentials…")
        try profile.validate(in: library.profiles)
        diagnostic?("Target \(profile.name): \(profile.username)@\(profile.hostname):\(profile.port); authentication=\(profile.authentication.rawValue)")
        let settings = try settings(profile, library: library, onChallenge: onChallenge)
        do {
            if let id = profile.bastionID {
                guard let bastion = library.visibleProfiles.first(where: { $0.id == id }) else {
                    throw MuxError.message("The saved bastion is missing.")
                }
                diagnostic?("Connecting bastion \(bastion.name): \(bastion.username)@\(bastion.hostname):\(bastion.port); authentication=\(bastion.authentication.rawValue)")
                onProgress("Connecting to jump host \(bastion.name)…")
                let gateway = try await SSHClient.connect(to: try self.settings(bastion, library: library, onChallenge: onChallenge))
                jump = gateway
                watch(gateway, generation: generation)
                diagnostic?("Bastion authenticated; opening SSH forwarding to \(profile.hostname):\(profile.port)")
                onProgress("Jump host \(bastion.name) connected. Connecting to \(profile.name)…")
                client = try await gateway.jump(to: settings)
            } else {
                diagnostic?("Connecting directly")
                onProgress("Connecting to \(profile.name)…")
                client = try await SSHClient.connect(to: settings)
            }
            diagnostic?("Target SSH authenticated")
            if let client { watch(client, generation: generation) }
            onProgress("SSH connected. Finding tmux on \(profile.name)…")
            let found = try await execute("if command -v tmux >/dev/null 2>&1; then command -v tmux; elif [ -x /opt/homebrew/bin/tmux ]; then echo /opt/homebrew/bin/tmux; elif [ -x /usr/local/bin/tmux ]; then echo /usr/local/bin/tmux; elif [ -x /usr/local/homebrew/bin/tmux ]; then echo /usr/local/homebrew/bin/tmux; else exit 127; fi")
            guard let path = found.split(separator: "\n").last, !path.isEmpty else {
                throw MuxError.message("Install tmux 3.2 or later on this host.")
            }
            tmuxPath = String(path)
            diagnostic?("Resolved tmux executable: \(tmuxPath)")
            onProgress("Checking tmux version…")
            let version = try await tmux("-V")
            diagnostic?("tmux client version: \(version.trimmingCharacters(in: .whitespacesAndNewlines))")
            diagnostic?("tmux clients force UTF-8 output (-u), independent of SSH locale")
            guard TmuxVersion(version)?.isSupported == true else {
                throw MuxError.message("This host needs tmux 3.2 or later. Found: \(version.trimmingCharacters(in: .whitespacesAndNewlines))")
            }
        } catch { diagnostic?("SSH/bootstrap failed: \(error.localizedDescription)"); await disconnect(); throw error }
    }

    private func watch(_ client: SSHClient, generation: UUID) {
        client.onDisconnect { [weak self] in
            Task { @MainActor in
                guard let self, self.connectionGeneration == generation else { return }
                self.onDisconnect?()
            }
        }
    }

    static func canRetry(_ error: Error) -> Bool {
        if error is AuthenticationFailed || error is MuxError || error is RemoteCommandFailure { return false }
        if let failure = error as? SSHClientError {
            switch failure {
            case .channelCreationFailed: return true
            default: return false
            }
        }
        if let failure = error as? CitadelError {
            switch failure {
            case .unauthorized, .invalidSignature, .invalidMac, .cryptographicError, .unsupported: return false
            default: break
            }
        }
        return true
    }

    /// Named fields only; never dump the full environment or read pane contents.
    func collectEnvironmentDiagnostics() async {
        let probes = [
            ("remote identity/environment", "printf 'hostname='; hostname; printf 'user='; id -un; printf 'uid='; id -u; printf 'SHELL=%s\\nPATH=%s\\nLANG=%s\\nLC_ALL=%s\\nLC_CTYPE=%s\\nTMUX=%s\\nTMUX_TMPDIR=%s\\nXDG_RUNTIME_DIR=%s\\n' \"$SHELL\" \"$PATH\" \"$LANG\" \"$LC_ALL\" \"$LC_CTYPE\" \"$TMUX\" \"$TMUX_TMPDIR\" \"$XDG_RUNTIME_DIR\""),
            ("default tmux server", TmuxCommand.invocation(executable: tmuxPath, arguments: "-N display-message -p 'server-version=#{version} socket=#{socket_path} pid=#{pid}'"))
        ]
        for (label, command) in probes {
            do {
                let output = try await execute(command)
                diagnostic?("\(label): \(output.trimmingCharacters(in: .newlines))")
            } catch { diagnostic?("\(label) failed: \(error.localizedDescription)") }
        }
    }

    private func settings(_ profile: ConnectionProfile, library: LibraryStore,
                          onChallenge: @escaping @Sendable (HostKeyChallenge) -> Void) throws -> SSHClientSettings {
        let authentication: @Sendable () -> SSHAuthenticationMethod
        switch profile.authentication {
        case .key:
            guard let id = profile.keyID else { throw MuxError.message("Choose a key for \(profile.name).") }
            let material = try library.keyMaterial(id)
            let decrypt = material.passphrase.flatMap { $0.isEmpty ? nil : Data($0.utf8) }
            if let key = try? Curve25519.Signing.PrivateKey(sshEd25519: material.privateKey, decryptionKey: decrypt) {
                authentication = { .ed25519(username: profile.username, privateKey: key) }
            } else if let key = try? Insecure.RSA.PrivateKey(sshRsa: material.privateKey, decryptionKey: decrypt) {
                authentication = { .rsa(username: profile.username, privateKey: key) }
            } else { throw MuxError.message("Could not unlock the saved SSH key.") }
        case .password:
            guard let data = try library.secrets.read("password:\(profile.id)"), let password = String(data: data, encoding: .utf8) else {
                throw MuxError.message("Enter the password in this connection's settings, or wait for iCloud Keychain sync.")
            }
            authentication = { .passwordBased(username: profile.username, password: password) }
        }
        return SSHClientSettings(host: profile.hostname, port: profile.port, authenticationMethod: authentication,
                                 hostKeyValidator: .custom(HostValidator(endpoint: "[\(profile.hostname.lowercased())]:\(profile.port)", challenge: onChallenge)))
    }

    func execute(_ command: String) async throws -> String {
        guard let client else { throw MuxError.message("Connect to the host first.") }
        var stdout = Data(), stderr = Data()
        do {
            let output = try await client.executeCommandStream(command)
            for try await event in output {
                switch event {
                case .stdout(let buffer): stdout.append(contentsOf: buffer.readableBytesView)
                case .stderr(let buffer): stderr.append(contentsOf: buffer.readableBytesView)
                }
                guard stdout.count + stderr.count <= 8 * 1024 * 1024 else { throw MuxError.message("Remote output exceeded the safety limit.") }
            }
        } catch let failed as SSHClient.CommandFailed {
            throw RemoteCommandFailure(status: failed.exitCode, diagnostic: String(decoding: stderr, as: UTF8.self))
        }
        return String(decoding: stdout, as: UTF8.self)
    }
    func tmux(_ arguments: String) async throws -> String {
        try await execute(TmuxCommand.invocation(executable: tmuxPath, arguments: arguments))
    }

    func startControl(session: String, events: @escaping @Sendable (ControlEvent) -> Void,
                      closed: @escaping @Sendable (String) -> Void) async throws -> ControlChannel {
        await stopControl()
        guard let client else { throw MuxError.message("Connect first.") }
        let command = "exec " + TmuxCommand.invocation(executable: tmuxPath, arguments: try TmuxCommand.attach(session: session))
        diagnostic?("Opening tmux control mode: \(command)")
        let generation = UUID(); controlGeneration = generation
        return try await withCheckedThrowingContinuation { ready in
            streamTask = Task {
                var started = false
                do {
                    try await client.withExec(command) { inbound, outbound in
                        let control = ControlChannel(writer: { data in
                            try await outbound.write(ByteBuffer(bytes: data))
                        }, onEvent: { event in events(event) })
                        self.channel = control; started = true
                        self.diagnostic?("SSH exec channel ready; waiting for tmux attachment response")
                        ready.resume(returning: control)
                        for try await output in inbound {
                            if Task.isCancelled { break }
                            switch output {
                            case .stdout(let buffer): await control.receive(Data(buffer.readableBytesView))
                            case .stderr(let buffer):
                                self.diagnostic?("tmux control stderr: \(String(decoding: buffer.readableBytesView, as: UTF8.self))")
                            }
                        }
                        await control.close()
                    }
                    if self.controlGeneration == generation {
                        self.diagnostic?("tmux control channel ended")
                        closed("SSH channel closed. Reconnect to continue.")
                    }
                } catch {
                    if !started { ready.resume(throwing: error) }
                    if self.controlGeneration == generation {
                        self.diagnostic?("tmux control channel failed: \(error.localizedDescription)")
                        closed(error.localizedDescription)
                    }
                }
            }
        }
    }

    func stopControl() async {
        controlGeneration = UUID()
        if let channel { await channel.close() }
        streamTask?.cancel(); streamTask = nil; channel = nil
    }
    func disconnect() async {
        connectionGeneration = UUID()
        await stopControl()
        if let client { try? await client.close() }
        if let jump { try? await jump.close() }
        client = nil; jump = nil
    }
}
