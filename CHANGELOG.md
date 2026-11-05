# Changelog

Changes are listed by app version and build number, newest first.

## 1.0 (19) — 2026-11-05

- Echo single-row Codex prompt edits immediately on Mac while waiting for tmux, then reconcile remote captures without duplicating input. Clear predictions on failed input, window/connection changes, unsupported controls, and a two-second timeout.
- Show the solid cursor at enabled Codex prompts even when the remote app hides its terminal cursor, including while typing locally in Smart, Original, and Fit window.

## 1.0 (18) — 2026-11-02

- Use steady cursors throughout the Mac app, without pulsing. Keep the Smart cursor tied to held screen content when Live is paused.
- Preserve written trailing spaces when mapping the Smart cursor, including the space after an empty shell prompt. Keep a blank cursor line visible while trimming unused rows below it.

## 1.0 (17) — 2026-11-02

- Fix the Mac Xcode project's local MuxCore package-product reference and its generator.
- Show a visible cursor in Smart Terminal mode on iPhone, iPad, and Mac. Keep Original/Fit cursor coordinates tied to captured history rather than viewport height.
- Refresh terminal output promptly after typing/output events. Coalesce adjacent unsent keystrokes on slower connections while preserving paste ordering and reconnect safeguards.
- Add a built-in, device-only This Mac connection using local tmux and the user's shell, with no SSH server, saved credential, or iCloud connection record. Create a local session when no tmux server is running.
- Widen the Mac Add/Edit Connection dialog so field labels fit. Keep native scrollback position when panning horizontally and pause Live when scrolling vertically.

## 1.0 (16) — 2026-11-01 — macOS

- Make the Mac app terminal-only. Remove the Compose input box, Send button, spelling controls, and input-mode switcher. iPhone/iPad keep Compose.
- Focus the terminal when opening a tmux window. Return, Tab, arrows, and Shift-Tab go directly to the remote shell or TUI.
- Keep Smart, Original, and Fit window display modes. Click unselected Smart output or use Focus terminal to resume typing after selecting text.

## 1.0 (15) — 2026-11-01 — macOS

- Add a native macOS app for Apple Silicon and Intel, requiring macOS 15 or later, with no new dependencies.
- Share SSH, bastion connections, key management, tmux discovery, automatic reconnect, iCloud/Keychain sync, and optional Codex notifications with iPhone/iPad.
- Add an AppKit terminal and continuous selectable Smart output, with colors, web links, multiline Copy, native Paste, and pinned remote columns in Original.
- Add native Compose with Return/Shift-Return, command history, shell completion, spelling/autocorrect, and desktop keyboard shortcuts. Fit window remains the explicit remote-resize mode.
- Keep connections running while another Mac app is active; disconnect cleanly on Quit. Terminal mouse interaction remains local to selection and scrolling.
- Add a separate Mac Xcode project and isolated native control/rendering and reconnect tests.

## 1.0 (14) — 2026-10-31

- Enable automatic word correction in Compose alongside spell checking. The ABC toggle controls both and remembers the device's preference.
- Preserve marked-text composition when toggling correction; Terminal input stays literal.

## 1.0 (13) — 2026-10-31

- Show an immediate spinner and Sending status when Compose submits, including on slow connections. Reserve the send before scheduling SSH work to reject duplicate taps or Return presses.
- Keep the draft until acknowledgement; failed sends retain it with an unconfirmed-send warning and no automatic replay.
- Enable Compose spelling checks by default. The ABC toggle remembers the device's preference, preserves the draft/caret, and leaves terminal input literal. Automatic text replacement stays off.

## 1.0 (12) — 2026-10-31

- Automatically reconnect dropped SSH and tmux control connections with retries backing off to 30 seconds.
- Restore the same session/window and unfinished draft, refresh Live, and keep terminal input disabled until recovery completes. Submitted commands and keystrokes are never replayed.
- Keep Disconnect available during recovery. Explicit Disconnect cancels retries; authentication and host-verification failures pause for attention. Backgrounded apps retry when active again.
- If the previous tmux session/window closed while disconnected, return to its list rather than creating or selecting another window.

## 1.0 (11) — 2026-10-31

- Limit notification screen checks to Codex panes; stop checking generic Node processes after a screen fails to identify Codex.
- Pause checks after 2 minutes idle or 30 minutes since a window was opened or used. Opening the window or sending input resumes monitoring; visible working states reset the idle timer.
- Keep the existing polling rate for eligible windows and recognize unbranded approval dialogs after a Node process has been identified as Codex.

## 1.0 (10) — 2026-10-31

- Added explicit short-tap handling for web links in Smart and Conversation, with hit testing against the text's rendered link rectangles.
- Disable the terminal keyboard tap gesture in Compose so it does not compete with text interactions.
- Preserve long-press/double-tap selection; blank space and active selections do not open links.

## 1.0 (9) — 2026-10-31

- Added tappable HTTP/HTTPS links in Smart, Conversation, Original, and Fit views, opening through the system's default browser.
- Recognize complete URLs across wrapped terminal rows while retaining native text selection and multiline Copy.

## 1.0 (8) — 2026-10-31

- Added optional local notifications when Codex finishes working or waits for input/approval, with the host and window name.
- Tap a notification to open its tmux window and resume Live output.
- Monitor Codex windows across sessions without installing anything on SSH hosts. Enable notifications under Info → Codex notifications. Detection is best effort and stops when iOS suspends the app or ends its background runtime.

## 1.0 (7) — 2026-10-30

- Added the terminal clipboard button and hardware Command-V for pasting, including multiline and Unicode text, without an extra submission.
- Added hardware and on-screen Shift-Tab for Codex and other terminal programs.

## 1.0 (6) — 2026-10-27

- Added a Terminal input mode that hides the composer and sends keys directly to the selected tmux window.
- Added per-window command history to the composer: Up/Down recall commands and restore an unfinished draft.

## 1.0 (5) — 2026-10-27

- Enabled continuous multiline selection and Copy across Smart output, including paragraphs, code, and blank lines.
- Preserve selections while output streams, with read-only Copy in Original and Fit.
- Refresh the selected window and resume Live automatically after returning from the background.
