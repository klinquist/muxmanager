# Changelog

Changes are listed by app version and build number, newest first.

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
