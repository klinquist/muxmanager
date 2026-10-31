# Changelog

Changes are listed by app version and build number, newest first.

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
