# QuietControl agent instructions

## Testing and keeping the user's phone available

- Use native XCUITest and the stateful synthetic peripheral on the Mac's simulator
  for routine development. Do not default to computer use or iPhone Mirroring of
  the real phone. Read [the testing guide](docs/testing/README.md) for commands,
  evidence requirements and physical limits.
- Run focused checks while iterating. Before an app build is installed on the
  phone, require `./scripts/verify.sh preinstall` to pass for the source being
  installed. A passing gate makes the build eligible for an already-authorized
  installation; it does not itself authorize installing or deploying anything.
- Phone builds take their signing from the gitignored `Configuration/Local.xcconfig`
  (its `[sdk=iphoneos*]` settings may set the team, bundle ID and profile). Build
  for the device as usual and install with `xcrun devicectl device install app`;
  if that signing has no debugger entitlement, Xcode's Run cannot attach. Never
  commit signing files or move those settings into tracked config.
- CI runs `core`, `session` and every UI journey except `access` on each PR, so
  don't run those lanes on the Mac just to open a PR; let CI do it.
- CI builds with the runner's Xcode 26, the Mac with Xcode 27. A long SwiftUI modifier chain can
  type-check here and fail there ("unable to type-check this expression in reasonable time", #18):
  give a big row or control its own small function with typed locals instead of one inline chain.
- The user's target is iOS 27; acceptance has run on iOS 27.1. The app's iOS 17
  deployment minimum is a separate compatibility concern, not the requested phone
  target. Report the actual runtime used and any unavailable coverage honestly.
- Simulator testing must leave the user's real phone available for normal use.
  Do not require it to stay unlocked, idle or connected to Mirroring during the
  simulator run. Installation may need brief device interaction; it must not turn
  into an extended agent-driven phone QA session by default.
- After an authorized installation, the user can use the app normally, check real
  headphone behavior and report bugs. Do not impose a routine Mirroring QA pass
  before the user can receive a simulator-tested build.
- Reserve real-phone computer use / Mirroring for a specific device-only bug or
  explicitly requested hardware acceptance. Explain the concrete need, keep the
  session bounded and coordinate phone availability with the user.
- Simulator PASS does not prove physical BLE, sound, firmware timing, buttons or
  background behavior. Keep these limits explicit without making every untested
  hardware behavior an automatic blocker to an otherwise authorized installation.
  Genuine failing tests or known relevant defects still need resolution.
- Preserve the specific cautions in [the hardware record](docs/HARDWARE_CHECK.md).
  Do not repeat short Auto-Off writes while the recorded shutdown incident is
  unresolved; simulator coverage does not close that hardware question.
- Documentation-only changes need documentation checks, not the full native suite.
  Do not claim an old test run verified a later app-code change.

## Shell and Git

- Prefer `rg` over `grep` and `fd` over `find`.
- A tracked pre-push hook compiles the app and UI tests (`xcodebuild build-for-testing`) before a push; enable it once per clone with `git config core.hooksPath .githooks`.
- Never add AI attribution to commits, PRs or code.

## Thread hygiene

- Keep planning, implementation, testing and related bugs in one topic thread.
- Only when the user switches topics, first reply with:
  "🧹 New topic — start a new thread (or fork this one)." and a 5–10 line handoff.
  Still answer briefly if it is a quick question.
