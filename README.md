# Mux Manager

**Your tmux windows, comfortably readable on iPhone and iPad.**

Mux Manager is a native SSH client built around the sessions already running on your computers. Browse windows by name, check a long-running task, read a coding assistant’s output, and send the next command from your phone.

Its **Smart** view wraps terminal text to your screen while preserving colors and the remote window’s dimensions. Your desktop terminal can keep its layout while you read on a smaller screen. Switch to **Original** for the existing grid, or explicitly resize with **Fit device**.

[Website](https://klinquist.github.io/muxmanager/) · [Changelog](CHANGELOG.md) · [Support / GitHub Issues](https://github.com/klinquist/muxmanager/issues) · [Privacy](https://klinquist.github.io/muxmanager/privacy/) · [MIT license](LICENSE)

<p align="center">
  <img src="docs/assets/iphone.png" width="260" alt="Mux Manager on iPhone: colored terminal output with Smart reflow">
  <img src="docs/assets/ipad.png" width="405" alt="Mux Manager on iPad: tmux window sidebar alongside terminal output">
</p>

*Real simulator captures with fictional hosts and sample terminal content.*

- Connect directly or through a saved bastion, with password authentication or generated/imported SSH keys.
- Browse, create, and rename tmux sessions and windows using a native sidebar.
- Read colored output, zoom text, scroll history, and hide the keyboard when you need more room.
- Tap web links in terminal output to open them in your default browser, including links wrapped across terminal rows.
- Compose commands in a native input box or use direct keys. Best-effort zsh/bash autocomplete returns readable completions to the input box without installing a remote helper.
- Keep saved connections and key metadata in sync automatically using private CloudKit, with credentials in iCloud Keychain.

Requires **iOS/iPadOS 17 or later**, an SSH-accessible host, and **tmux 3.2 or later**. No remote plugin or OpenAI API key is required. This project is independent of OpenAI and the tmux project.

## Open and run

Open `MuxManager.xcodeproj` and select the **MuxManager** scheme. The deployment target is iOS/iPadOS 17. The upstream bundle identifier is `com.linquist.muxmanager`. For your own signed build, copy `Config/Local.xcconfig.example` to the ignored `Config/Local.xcconfig` and set your team, unique bundle identifier, and registered CloudKit container. Never commit signing credentials or personal connection data.

1. Select your development team in Signing & Capabilities.
2. Register and select the CloudKit container `iCloud.com.linquist.muxmanager`. If you use another container, set `CLOUD_CONTAINER_IDENTIFIER` in `Config/Local.xcconfig` (copy the example) or the target's build settings.
3. In the CloudKit development schema, create record type **MuxRecord** with fields `kind` (String), `payload` (Bytes), and `modifiedAt` (Date). Enable a Queryable index on `recordName` (the schema field `___recordID`) so the private database can be queried. Deploy the schema, including its indexes, to production before TestFlight. The first sync queries this type before saving records, so a missing schema prevents upload even in Development.
4. Build and run on an iPhone or iPad. Grant local-network access when connecting to a LAN host. Sign in to iCloud and enable iCloud Keychain to test sync between devices.

Sync runs automatically when the app becomes active, after edits, and periodically while active to receive changes and retry failures. There is no manual sync control or routine sync status in the interface. Saved connections work locally when CloudKit is unavailable. Settings and public-key metadata use the private CloudKit database. Passwords, private keys, and imported key passphrases use synchronizable Keychain items. Drafts, output, and host trust decisions never enter CloudKit. The app does not require an OpenAI account or API key; it interacts with the Codex process already running on your computer.

## Connect

The target host needs SSH and **tmux 3.2 or later**. Linux and macOS are supported, including common Homebrew tmux locations. No helper, tmux plugin, or Codex modification is installed remotely.

- Add or edit a connection and choose password authentication or an SSH key. Use **Generate or import key** there to manage keys. The importer supports unencrypted OpenSSH Ed25519/RSA keys and bcrypt/AES-128-CTR or AES-256-CTR encrypted keys. Other key formats produce an error.
- Copy the public key into the host's `~/.ssh/authorized_keys` using your existing administrative workflow. The app does not modify that file automatically.
- To reach an inside host, first save the outside/bastion host as a direct connection, then select it under **Connect through** on the target. Forwarding must be allowed on the bastion; the target hostname is resolved from the bastion side.
- Verify the fingerprint separately for the bastion and target. A first-seen or changed key stops the handshake; trusting it starts a fresh connection. Trust is local to each device.
- Open the host, choose a session if there are several, and select a window. On iPhone, use the navigation sidebar/back button to return to the window list. iPad keeps the sidebar visible when space allows.

Window selection and input target stable tmux IDs without changing the session's selected window. Only creating or explicitly renaming a window/session changes its organization. Split-pane management is omitted; a split window displays its active pane.

Every tmux invocation explicitly enables UTF-8 output with `-u`. Non-interactive SSH sessions may not inherit a UTF-8 locale; without this flag tmux can replace the discovery field separators and Unicode names with underscores. Malformed nonempty discovery output is reported as an error rather than being mistaken for an empty server.

## Display and input

| Control | Behavior |
| --- | --- |
| **Smart** | Uses tmux's reconstructed screen/history and soft-wrap markers to rewrap text locally, preserving ANSI foreground/background colors and text styles. Explicit line breaks remain. Shell columns, long filenames, tables, and code wrap to the local reading width. Use Original when grid alignment matters. |
| **Fit device** | Changes the selected remote window's dimensions. This affects other clients viewing that window. |
| **Original** | Shows the existing remote grid with horizontal/vertical scrolling. |
| **Conversation view** (window menu) | Interprets recognizable Codex prompt/response markers, preserving other output as terminal content. |
| **Compose** | Draft multiline text and tap Send. Enter on the phone keyboard inserts a newline. Up/Down recall this window’s submitted commands without sending them. |
| **Tab completion** | At a recognizable empty zsh/bash prompt, forwards a single-line draft and Tab without Enter, reads the completed line, clears the temporary remote input, and returns the text to the native composer while preserving keyboard focus. No host installation. |
| **Terminal** | Hides the composer and sends each key immediately to the remote window. Esc, Tab, Shift-Tab, arrows, Ctrl, Ctrl-C, and Enter are available above the keyboard; Tab uses the terminal’s native completion. Works with Smart, Original, and Fit device. |
| **Paste** (clipboard button) | Pastes text directly into the selected terminal, including multiline text. Hardware Command-V is supported while the terminal has keyboard focus. Paste uses tmux’s bracketed-paste handling, without appending an extra Enter; programs without bracketed-paste support interpret pasted newlines themselves. |
| **Web links** | Tap an HTTP/HTTPS link in Smart, Conversation, Original, or Fit to open it through the system browser. Long-press or double-tap to select text; an active selection takes priority in the terminal grid. |

Pinch to change text size, or use the text-size menu. **Live**, below the reading area, aligns the latest line with the bottom of the visible viewport after layout, including keyboard and font changes. Scrolling pauses automatic following. The keyboard-down button hides the keyboard while keeping the selected input mode. In Compose, tap the message field to reopen it. In Terminal, tap the live output or the keyboard button; when reading or selecting text, use the keyboard button to resume direct typing. Switching back to Compose restores your unfinished draft. Closing the selected remote window returns to the window list, including when the final window/session exits.

In Fit and Original, vertical drags scroll terminal history; the outer viewport handles horizontal panning without pausing live updates. Reading history holds the displayed capture steady while new output arrives. Tap **Live** or send terminal input (including the arrow buttons and direct keyboard input) to display the newest capture and resume following.

Long-press output, drag the selection handles across lines, then tap **Copy**. Smart supports a continuous selection across paragraphs, code, and tables; Conversation keeps adjacent assistant paragraphs in one selectable response. Selecting text pauses Live updates so the selection stays steady. Original and Fit support copying with the software keyboard hidden. Tap **Live** to return to the newest output.

Each host has a **Connect/Disconnect** button on its right. Disconnecting removes its session and window list and clears the displayed terminal, while preserving saved connections and drafts.

While connecting, progress appears below the host and in its workspace: connecting to the jump host, connecting onward to the target, finding/checking tmux, and loading sessions and windows. The same milestones appear in Connection diagnostics. Messages clear when the attempt finishes or is disconnected.

Backgrounding pauses polling and parks SSH for a best-effort **10-minute** window. It restores app-owned Fit sizing, switches Fit to Original, and silences pane output for this app's tmux control client. On return, it validates and reuses a healthy connection, or reconnects if the connection is unavailable or the retention window has elapsed. Explicit Disconnect stays disconnected, and submitted input is never replayed. iOS decides how much background runtime to grant; when that time expires, the app releases its runtime request and leaves sockets parked for possible reuse after suspension. Ten minutes of active execution or uninterrupted networking is not guaranteed.

Returning from the background resumes **Live** in the selected window and displays the latest captured output automatically.

Enable **Info → Codex notifications → Notify when Codex needs attention**, then allow notifications in iOS. This device-local option watches the active pane of Codex windows across all sessions on connected hosts, including windows outside the sidebar’s selected session. It detects a visible working state followed by a stable ready prompt or input/approval dialog. Alerts show the host and window name; tapping one opens that window by its saved IDs and resumes Live. A closed window is reported rather than recreated. No host script, Codex configuration change, OpenAI API call, or remote push service is required.

Screen polling is limited to recently used Codex windows. New candidates get a baseline; generic Node processes get a one-time screen check and are excluded unless the screen identifies Codex. Polling pauses after **2 minutes idle** (ready, waiting for input, or unrecognized output) or **30 minutes since the window was last opened or used**, including working windows. A visible working state resets the idle timer. Opening the window, tapping its notification, or sending terminal/composer input reactivates checks. Once paused, work started from another SSH client can be missed until you reopen the window. Window/process discovery continues about every 6 seconds; eligible screen reads retain the existing round-robin limit of 8 panes followed by a 1.5-second pause. No host helper is installed.

Detection is best effort: it can misread custom layouts or miss very short tasks, wrapper processes, non-active split panes, or work completed while disconnected/suspended. An already-idle screen establishes a baseline on connect/restart, so old completed tasks do not flood notifications. Screen contents remain in memory; notifications contain names/IDs and a generic status, without terminal response text. Monitoring uses bounded round-robin reads, including during the iOS-granted background-runtime interval, and stops at runtime expiration. It does not keep iOS awake or promise ten minutes of monitoring.

Smart and Original attach with tmux's `ignore-size` client flag and never send remote resize commands. Rotation, the keyboard, and zoom only affect remote dimensions while Fit is selected. Fit records the prior dimensions and whether the sizing policy was inherited. It restores app-owned changes when leaving Fit, switching windows, disconnecting, or backgrounding while the connection remains usable. Another client's changed dimensions/policy or a restarted tmux server prevents stale restoration. A pending lease is saved locally for reconnect recovery. A sudden network loss cannot guarantee immediate restoration without a remote helper.

The composer uses a uniquely named tmux buffer and `paste-buffer -p -r -d`, so tmux adds bracketed-paste markers when the target application supports them. It then sends Enter once. A program without bracketed-paste support receives literal multiline text using its normal input behavior. Direct keys use `send-keys -H`; shell characters and newlines cannot become tmux commands. Failed or interrupted sends are never automatically replayed. Check the terminal before resending an unconfirmed command. A lost connection can leave a named paste buffer behind on the host.

With a hardware keyboard, **Return sends the composer** and **Shift+Return inserts a new line at the cursor**. The software keyboard's Return and pasted line breaks stay in the draft. Return used to confirm text conversion is left to the input method. Sending uses the same checks as the send icon and keeps the composer focused. **Shift+Tab in Terminal sends back-tab** to the remote program; the on-screen Shift-Tab button does the same. **Up/Down recall previous/next submitted commands**, including multiline text, and Down past the newest restores the unfinished draft. In a multiline draft, ordinary vertical caret movement remains available until the first/last visual line. The on-screen Up/Down buttons also recall history in Compose; in Terminal they always go directly to the host. History is bounded to 100 entries per window, kept only in memory, and is not synchronized or saved to disk.

## Current limits

- Native autocomplete reads the screen rather than a shell editing-buffer API. Custom prompts/key bindings, vi editing modes, completion menus, wide Unicode, another client typing, or slow completion can prevent a reliable round trip. The app keeps the draft and asks you to inspect the remote line using Terminal mode if it cannot confirm the result or cleanup. It never sends Enter during completion. No shell integration is installed or required.

- Conversation mode is an inferred view of terminal content, not a structured Codex API integration. It cannot reliably identify every Codex version, separate every message, or recover content absent from tmux history. Approvals are never inferred or automatically answered. Use Terminal/direct keys for interactive choices.
- The display is rebuilt from bounded tmux snapshots, refreshed at most approximately three times per second when output changes. Up to 2,000 history rows plus the visible screen are loaded. Extremely fast output can exceed that history, and screen rewrites can replace earlier content.
- Smart rendering cannot recover semantic paragraphs or code boundaries that a TUI has discarded. Applications that hard-wrap their own paragraphs can retain those line breaks. Original and Fit provide access to the underlying screen.
- iOS can suspend the app or terminate background networking before the 10-minute retention window ends. tmux processes continue remotely; unavailable connections reconnect on return. There is no background daemon, push notification service, SSH agent forwarding, arbitrary tunnel UI, keyboard-interactive MFA, SFTP browser, or multi-bastion chain in this MVP.
- RSA key parsing is supported by Citadel, but its pinned SSH stack uses legacy `ssh-rsa` signatures. Modern hosts often disable that algorithm. Prefer generated Ed25519 keys; an RSA-only host may need a future SSH-stack update.
- Successful App Store/TestFlight distribution still requires your signing, CloudKit provisioning/schema, and export-compliance configuration in App Store Connect.

## Architecture and dependencies

`Sources/MuxCore` is a dependency-free Swift package containing the byte-oriented control parser, serialized command queue, discovery/input encoding, presentation projections, merge rules, and resize restoration model. `MuxManager` contains the SwiftUI application and Apple Keychain/CloudKit integrations.

There are **two direct external libraries and twelve resolved external packages in total**. See the committed `MuxManager.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved` for exact revisions.

| Package | Purpose |
| --- | --- |
| SwiftTerm 1.19.0 | UIKit terminal emulation, colors, selection, and keyboard support. Pinned to the stable 1.x API. |
| Citadel 0.12.1 | SSH transport, bastion forwarding, and OpenSSH key parsing. |
| swift-nio-ssh (Wellz26 fork) | Citadel's SSH protocol implementation, including its RSA extension. |
| swift-nio | SSH networking and buffers. |
| swift-crypto, swift-asn1 | Cryptographic primitives and key formats. |
| BigInt | Citadel's RSA support. |
| swift-atomics, swift-collections, swift-system | Networking/runtime support. |
| swift-log | SSH/network logging infrastructure. |
| swift-argument-parser | SwiftTerm's command-line tooling dependency; not used by the app's GUI. |

No UI, persistence, analytics, reflow, or conversation parsing packages are used. Third-party licenses remain in their SwiftPM checkouts; `THIRD_PARTY_NOTICES.md` lists the upstream projects and license families.

## Checks

For an empty list on another device, open **Info → iCloud diagnostics** to see the last attempted/successful sync, container identifier, local record counts, and the latest error. Reports omit connection values and credentials. Sync remains automatic. The empty state explains a failed sync instead of suggesting that no saved connections exist.

Xcode development builds and TestFlight/App Store builds normally use separate CloudKit databases. Deploying the schema copies record types, fields, and indexes, **not saved user records**. Both devices need the same Apple Account, iCloud enabled for the app, and builds using the same CloudKit environment. Keep the original app installed while resolving a sync problem so its local connections remain available.

For connection/discovery problems, open **Info → Connection diagnostics** on the main page, or **⋯ → Connection diagnostics** in a workspace. Reconnect to record the SSH route, target identity, selected environment fields, tmux path/version/socket, raw discovery rows, parsed counts, session selection, and capture metadata. The Capture line reports remote history size/limit, alternate-screen state, returned grid/joined line counts, and remote dimensions without recording terminal text. Use **Refresh** for a fresh read-only discovery pass and **Copy log** to share the report manually. Unchanged polling results are suppressed; the log is bounded and stays in memory. It includes host/user identifiers, paths, and session/window names, but excludes passwords, private keys, pane contents, and submitted input. With multiple sessions, use the session picker before expecting a window list.

Lifecycle entries also report background preparation, the end of iOS-granted runtime, and whether foregrounding reused or reconnected SSH.

```sh
swift test
python3 scripts/tmux-smoke.py
xcodebuild -project MuxManager.xcodeproj -scheme MuxManager \
  -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build
```

The smoke test creates and destroys its own isolated tmux server; it never connects to your normal tmux socket. It requires permission to create a local Unix socket. Device acceptance checks are in `VALIDATION.md`.

The checked-in project opens without a project generator. If adding files programmatically, `python3 scripts/generate-project.py` regenerates it using only Python's standard library and preserves bundle/signing/container overrides. Regenerate the icon with `swiftc scripts/generate-icon.swift -o /tmp/mux-icon && /tmp/mux-icon`.

## Contributing and support

Questions, bug reports, and feature requests belong in [GitHub Issues](https://github.com/klinquist/muxmanager/issues). Include your device/OS, app and tmux versions, display mode, and reproduction steps. Issues are public: redact diagnostic hostnames, usernames, paths, and terminal contents. Never include private keys, passwords, or tokens.

Pull requests are welcome. Keep remote-size preservation explicit, avoid automatically answering terminal approvals, and keep dependencies focused. Run the checks relevant to your changes and describe any live-device checks you could not perform.

The project is available under the [MIT license](LICENSE). Third-party libraries retain their own licenses; see [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).

## App Store media tooling

The dependency-free capture, composition, and App Store API tooling lives in `scripts/app-store`. See its [usage instructions](scripts/app-store/README.md). Generated output, API receipts, credentials, and local signing overrides are ignored by Git. Marketing screenshots use Debug-only fixtures that do not connect to hosts or read real saved data.

To upload a new signed build from a normal macOS Terminal, set your local `ASC_KEY_ID`, `ASC_ISSUER_ID`, and optional `ASC_KEY_PATH`, increment the version/build in `Config/Base.xcconfig`, then run `./scripts/upload-app-store-build.sh`. The script archives, exports with Apple’s system packaging tools, and uploads using API-key authentication. Export compliance is assessed separately for the actual encryption and distribution territories; the script does not automatically declare the app exempt or submit App Review.
