#!/bin/bash
set -euo pipefail
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
quietcontrol_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$quietcontrol_root"
quietcontrol_mode="${1:-simulator}"
case "$quietcontrol_mode" in
  simulator)
    xcodebuild -project QuietControl.xcodeproj -scheme QuietControl -configuration Debug \
      -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' \
      -derivedDataPath build/Simulator CODE_SIGNING_ALLOWED=NO build
    ;;
  device)
    xcodebuild -project QuietControl.xcodeproj -scheme QuietControl -configuration Debug \
      -sdk iphoneos -destination 'generic/platform=iOS' -derivedDataPath build/Device -allowProvisioningUpdates build
    ;;
  archive)
    xcodebuild -project QuietControl.xcodeproj -scheme QuietControl -configuration Release \
      -destination 'generic/platform=iOS' -archivePath build/QuietControl.xcarchive -derivedDataPath build/Archive -allowProvisioningUpdates archive
    xcodebuild -exportArchive -archivePath build/QuietControl.xcarchive \
      -exportOptionsPlist Configuration/ExportOptions.plist -exportPath build/Export -allowProvisioningUpdates
    ;;
  unsigned)
    xcodebuild -project QuietControl.xcodeproj -scheme QuietControl -configuration Release \
      -sdk iphoneos -destination 'generic/platform=iOS' -derivedDataPath build/Unsigned \
      CODE_SIGNING_ALLOWED=NO build
    mkdir -p build/UnsignedPackage/Payload
    ditto build/Unsigned/Build/Products/Release-iphoneos/QuietControl.app build/UnsignedPackage/Payload/QuietControl.app
    ditto -c -k --keepParent build/UnsignedPackage/Payload build/QuietControl-unsigned.ipa
    printf '%s\n' 'Unsigned package: build/QuietControl-unsigned.ipa (requires signing before installation).'
    ;;
  *) printf '%s\n' 'Usage: scripts/build.sh [simulator|device|archive|unsigned]' >&2; exit 2 ;;
esac

