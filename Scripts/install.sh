#!/bin/bash
set -euo pipefail
source_root="$(cd "$(dirname "$0")/.." && pwd -P)"
exec /usr/bin/python3 "$source_root/tools/conductor_install.py" install --source "$source_root" "$@"
