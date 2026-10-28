# QuietControl delegation profile

- Repository: /Users/mzbali/projects/quietcontrol; GitHub mzbali/quietcontrol.
- Native SwiftUI iOS 17+ app, CoreBluetooth Bose FEBE/prince protocol. No server/DB.
- Read docs/testing/PLAN.md and README.md; docs/HANDOVER.md is historical context,
  with some stale Git/release claims. Verify live Git/build state when relevant.
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
- Session/UI: QuietControl.xctestplan on the QuietControl scheme contains seven
  app-hosted session tests and four UI journeys at the reviewed foundation.
  Use xcodebuild test -project QuietControl.xcodeproj -scheme QuietControl
  -testPlan QuietControl -destination 'platform=iOS Simulator,id=<owned-UUID>'
  -derivedDataPath build/<unique-run> -resultBundlePath build/<unique-result>.xcresult
  -parallel-testing-enabled NO CODE_SIGNING_ALLOWED=NO. Report exact destination,
  test identifiers/counts, and xcresult path. All testing synthetic and simulator-only.
- Data copy: none. Never fetch phone app data, pairing addresses, or real reports.
- Pages: Home, Equalizer, Focus editor, Headphone Settings, Connection details,
  Diagnostics. Use native XCUITest, not web browser tools or iPhone Mirroring.
- Available baseline: Xcode 27.1, iOS 27.1 iPhone Duo runtime. Create a dedicated
  simulator; leave the existing booted simulator and unrelated apps untouched.
- Preserve: release/device paths; existing preview/render flags; confirmed-only
  device/EQ state; serial IO; one pending reconnect; capability/firmware gates;
  snapshot compatibility; recovery journals/gates; presets; gestures; accessibility.
- Keep local signing config, profiles, generated reports, build products ignored.
- Merge rule: rebase merge, no AI attribution. No merges by implementation tasks.
- No real-phone installation, radio writes, provisioning, paid CI, or deployment.
