#!/usr/bin/env python3
"""Collect upstream license texts from an existing, resolved SwiftPM checkout directory."""
from pathlib import Path
import sys

root = Path(__file__).resolve().parent.parent
checkouts = Path(sys.argv[1])
projects = ["SwiftTerm", "Citadel", "swift-nio-ssh", "swift-nio", "swift-crypto", "swift-asn1",
            "BigInt", "swift-atomics", "swift-collections", "swift-system", "swift-log", "swift-argument-parser"]
parts = ["Mux Manager — Open Source Licenses\n\nExact package revisions are recorded in Package.resolved.\n"]
for project in projects:
    directory = checkouts / project
    files = [directory / name for name in ["LICENSE", "LICENSE.txt", "LICENSE.md", "NOTICE.txt"] if (directory / name).is_file()]
    if project == "swift-crypto":
        for name in ["Sources/CCryptoBoringSSL/LICENSE", "Sources/CCryptoBoringSSL/LICENSE.txt"]:
            if (directory / name).is_file():
                files.append(directory / name)
    if not files:
        raise SystemExit("Missing license for " + project)
    parts.append("\n" + "=" * 72 + "\n" + project + "\n" + "=" * 72 + "\n")
    for file in files:
        parts.append(str(file.relative_to(directory)) + "\n\n" + file.read_text() + "\n")
output = root / "MuxManager/Resources/ThirdPartyNotices.txt"
output.parent.mkdir(exist_ok=True)
output.write_text("\n".join(parts))
print("Wrote " + str(output.relative_to(root)))
