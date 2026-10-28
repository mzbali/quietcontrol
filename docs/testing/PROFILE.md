# QuietControl delegation profile

- Repository: /Users/mzbali/projects/quietcontrol; GitHub mzbali/quietcontrol.
- Native SwiftUI iOS 17+ app, CoreBluetooth Bose FEBE/prince protocol. No server/DB.
- Read AGENTS.md and docs/testing/README.md for the current testing/phone policy,
  then PLAN.md for design. Hardware observations and unresolved device-specific
  cautions live in docs/HARDWARE_CHECK.md. Verify live Git/build state as needed.
- Inherited AGENTS rules: prefer rg/fd; no AI attribution in commits or PRs;
  one topic in this parent conversation. No new top-level threads or hand relays.
- Provider: acpRegistry_opencode_v2; model opencode-go/deepseek-v4.1-flash.
- Toolchain: export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer.
- Core tests: ./scripts/test.sh (baseline 33 pass).
- Simulator build: ./scripts/build.sh simulator.
- Unsigned Release device build: xcodebuild -project QuietControl.xcodeproj
  -scheme QuietControl -configuration Release -sdk iphoneos
  -destination 'generic/platform=iOS' -derivedDataPath build/VerificationRelease
  CODE_SIGNING_ALLOWED=NO build.
- Session/UI: QuietControl.xctestplan contains24 app-hosted session tests and17UI
  journeys, including12 accessibility audits. Use ./scripts/verify.sh
  core|session|ui|preinstall; see README.md for the runner's evidence and acceptance.
  Every executable ID must be manifested before a host run can pass. Adding tests
  without mapping must fail closed. Raw xcodebuild is diagnostic/intermediate:
  xcodebuild test -project QuietControl.xcodeproj -scheme QuietControl
  -testPlan QuietControl -destination 'platform=iOS Simulator,id=<owned-UUID>'
  -derivedDataPath build/<unique-run> -resultBundlePath build/<unique-result>.xcresult
  -parallel-testing-enabled NO CODE_SIGNING_ALLOWED=NO. Report exact destination,
  test identifiers/counts, and xcresult path. All testing synthetic and simulator-only.
- Data copy: none. Never fetch phone app data, pairing addresses, or real reports.
- Pages: Home, Equalizer, Focus editor, Headphone Settings, Connection details,
  Diagnostics. Use native XCUITest, not web browser tools or iPhone Mirroring.
- Routine simulator QA leaves the real phone available. A full preinstall PASS
  permits an already-authorized installation without an extra Mirroring gate;
  the user checks real headphone behavior during normal use and reports bugs.
  Use real-phone computer use only for a specific device-only investigation or
  requested acceptance, with a bounded session coordinated with the user.
- User target: iOS 27; simulator acceptance used iOS 27.1. The app's iOS 17 minimum
  is a separate compatibility limit. Do not present hardware behavior as proven.
- Available baseline: Xcode 27.1, iOS 27.1 iPhone Duo runtime. Create a dedicated
  simulator; leave the existing booted simulator and unrelated apps untouched.
- Preserve: release/device paths; existing preview/render flags; confirmed-only
  device/EQ state; serial IO; one pending reconnect; capability/firmware gates;
  snapshot compatibility; recovery journals/gates; presets; gestures; accessibility.
- Keep local signing config, profiles, generated reports, build products ignored.
- Merge rule: rebase merge, no AI attribution. No merges by implementation tasks.
- Test/delegate tasks do not authorize real-phone installation, radio writes,
  provisioning, paid CI or deployment. Follow existing user authorization for any
  separate installation; do not infer it from a passing test gate.
