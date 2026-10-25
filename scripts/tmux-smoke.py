#!/usr/bin/env python3
"""Exercise the app's tmux contract against an isolated server, never the user's socket."""
import os
from pathlib import Path
import selectors
import shutil
import subprocess
import tempfile
import time


# Match a non-interactive SSH session with no UTF-8 locale forwarded by the client.
SSH_ENVIRONMENT = dict(os.environ, LANG="C", LC_ALL="C", LC_CTYPE="C")


class Control:
    def __init__(self, executable, socket, ignore_size):
        arguments = [executable, "-u", "-S", socket, "-C", "attach-session", "-t", "primary"]
        if ignore_size:
            arguments += ["-f", "ignore-size"]
        self.process = subprocess.Popen(arguments, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=SSH_ENVIRONMENT)
        self.pending = b""
        self.selector = selectors.DefaultSelector()
        self.selector.register(self.process.stdout, selectors.EVENT_READ)
        self.response()

    def line(self, deadline):
        while b"\n" not in self.pending:
            remaining = deadline - time.monotonic()
            if remaining <= 0 or not self.selector.select(remaining):
                raise RuntimeError("Timed out waiting for tmux control output")
            data = os.read(self.process.stdout.fileno(), 65536)
            if not data:
                raise RuntimeError("tmux control channel closed")
            self.pending += data
            if len(self.pending) > 8 * 1024 * 1024:
                raise RuntimeError("tmux output exceeded safety limit")
        line, self.pending = self.pending.split(b"\n", 1)
        return line.decode("utf-8")

    def response(self):
        token = None
        lines = []
        deadline = time.monotonic() + 5
        while True:
            line = self.line(deadline)
            if token is None:
                if line.startswith("%begin "):
                    token = line[7:]
            elif line == "%end " + token:
                return lines
            elif line == "%error " + token:
                raise RuntimeError("tmux: " + "\n".join(lines))
            else:
                lines.append(line)

    def command(self, text):
        self.process.stdin.write((text + "\n").encode())
        self.process.stdin.flush()
        return self.response()

    def close(self):
        try:
            self.process.stdin.write(b"\n")
            self.process.stdin.flush()
            self.process.wait(timeout=3)
        except (OSError, subprocess.TimeoutExpired):
            self.process.kill()
            self.process.wait()
        self.selector.close()


def main():
    executable = shutil.which("tmux")
    if executable is None:
        raise SystemExit("tmux is required; install tmux 3.2 or later to run this check.")
    with tempfile.TemporaryDirectory(prefix="muxmanager-smoke-", dir="/tmp") as directory:
        socket = str(Path(directory) / "test.sock")
        base = [executable, "-u", "-S", socket]

        def tmux(*args):
            return subprocess.check_output(base + list(args), text=True, stderr=subprocess.PIPE, timeout=5, env=SSH_ENVIRONMENT).rstrip("\n")

        clients = []
        try:
            tmux("-f", "/dev/null", "new-session", "-d", "-s", "primary", "-x", "160", "-y", "40", "/bin/sh")
            session_format = "#{session_id}\t#{q:session_name}"
            old_output = subprocess.check_output([executable, "-S", socket, "list-sessions", "-F", session_format], text=True, env=SSH_ENVIRONMENT, timeout=5).strip()
            assert "\t" not in old_output and "_primary" in old_output, ("Expected legacy locale sanitization", old_output)
            session = tmux("list-sessions", "-F", session_format)
            assert session.split("\t") == ["$0", "primary"], ("UTF-8 discovery failed", session)
            second = tmux("new-window", "-d", "-P", "-F", "#{window_id}", "-t", "primary:", "-n", "second 🦊", "/bin/sh")
            desktop = Control(executable, socket, False)
            clients.append(desktop)
            desktop.command("refresh-client -C 160x40")
            before = desktop.command("display-message -p '#{window_id}:#{window_width}x#{window_height}'")

            phone = Control(executable, socket, True)
            clients.append(phone)
            assert phone.command('list-sessions -F "' + session_format + '"') == [session]
            window_format = "#{window_id}\t#{window_index}\t#{q:window_name}\t#{pane_id}\t#{pane_width}\t#{pane_height}\t#{q:pane_current_command}"
            window_rows = phone.command('list-windows -F "' + window_format + '"')
            assert all(len(row.split("\t")) == 7 for row in window_rows)
            assert any("🦊" in row for row in window_rows), "Unicode window names were sanitized"
            phone.command("list-windows -F '#{window_id} #{window_name}'")
            phone.command(f"capture-pane -pJ -S -2000 -t {second}")
            after = desktop.command("display-message -p '#{window_id}:#{window_width}x#{window_height}'")
            assert before == after, ("Smart/Original discovery changed desktop state", before, after)

            policy = phone.command(f"show-options -wqv -t {second} window-size")
            dimensions = phone.command(f"display-message -p -t {second} '#{{window_width}} #{{window_height}}'")[0].split()
            phone.command(f"resize-window -t {second} -x 44 -y 25")
            assert phone.command(f"display-message -p -t {second} '#{{window_width}}x#{{window_height}}'") == ["44x25"]
            assert before == desktop.command("display-message -p '#{window_id}:#{window_width}x#{window_height}'"), "Fit changed another window"
            phone.command(f"resize-window -t {second} -x {dimensions[0]} -y {dimensions[1]}")
            if policy:
                phone.command(f"set-option -w -t {second} window-size {policy[0]}")
            else:
                phone.command(f"set-option -wu -t {second} window-size")
            assert phone.command(f"show-options -wqv -t {second} window-size") == policy

            # An injected semicolon/newline remains pane input; it must not become a tmux command.
            pane = phone.command(f"display-message -p -t {second} '#{{pane_id}}'")[0]
            payload = b"# literal text; kill-server\n"
            phone.command(f"send-keys -H -t {pane} " + " ".join(f"{byte:02x}" for byte in payload))
            assert phone.command("list-sessions -F '#{session_name}'") == ["primary"]
            print("PASS: locale-independent discovery, Unicode names, ignore-size attachment, independent window selection, targeted Fit, policy restoration, literal input")
        except subprocess.CalledProcessError as failure:
            raise SystemExit("Could not run isolated tmux smoke test: " + failure.stderr.strip())
        finally:
            for client in reversed(clients):
                client.close()
            subprocess.run(base + ["kill-server"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=5)


if __name__ == "__main__":
    main()
