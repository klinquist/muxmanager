#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h:h}"
python3 scripts/app-store/capture.py "$@"
ruby scripts/app-store/upload.rb --upload
