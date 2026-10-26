#!/bin/bash
set -euo pipefail
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
quietcontrol_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$quietcontrol_root"
xcrun swift test --package-path Packages/QuietComfortCore --scratch-path build/CoreTests

