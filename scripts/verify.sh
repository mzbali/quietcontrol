#!/bin/bash
set -euo pipefail

# QuietControl pre-install verification entry point.
# Logic lives in scripts/verify-ui.py so the same rules can be unit tested.
quietcontrol_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

if [[ ! -x "$DEVELOPER_DIR/usr/bin/xcodebuild" ]]; then
  printf 'BLOCKED: full Xcode not found at %s/usr/bin/xcodebuild\n' "$DEVELOPER_DIR" >&2
  printf 'Set DEVELOPER_DIR to a complete Xcode installation.\n' >&2
  exit 3
fi

exec /usr/bin/env python3 "$quietcontrol_root/scripts/verify-ui.py" "$@"
