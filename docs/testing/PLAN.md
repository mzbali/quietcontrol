# QuietControl pre-install testing

Status: Wave 1 integrated into the testing base on 28 October 2026; Wave 2 pending.
Baseline: main `3e154d9`; 33 SwiftPM tests and Debug simulator build pass.
No UI-test target exists at baseline. No phone installation is part of this phase.

## Goal and acceptance

Make native simulator XCUITest the normal UI regression check before installation.
Exercise the actual SwiftUI screens and QuietComfortSession command/confirmation
logic. Replace the radio boundary with a scripted, stateful Bose peripheral; do
not make a second implementation of the UI or a session that simply reports success.
Simulator coverage cannot prove actual BLE, sound, firmware timing, hardware
buttons, or iOS background restoration. Report physical acceptance separately.

Reuse MusicSync's disposable simulator, explicit opt-in, isolated state, focused
journeys, xcresult accounting, retained evidence, and independent data assertions.
Improve it here with fresh fixtures per test, controlled faults, relaunch, and
accessibility coverage. No production-data copy is needed: all peripheral names,
addresses, metadata, settings, and snapshots are synthetic.

## Architecture decisions

1. Keep production CoreBluetooth behavior and current user features. Add a small
   byte-transport boundary; avoid a broad application rewrite. It may initially
   adapt the existing live transport code rather than move every callback at once.
2. The shared request machinery must still perform Bose BLE segmentation,
   reassembly, BMAP decoding, response matching, timeouts, serialization, and
   operation invalidation. The simulated peripheral receives outgoing segments
   and returns notification segments through that same machinery. Never stub
   `request`, `selectMode`, `applyEQ`, or `setPreference` to return success.
3. Transport responsibilities: stable peripheral identity, connection/radio events,
   identity metadata, negotiated write constraints/readiness, outgoing BLE segments,
   incoming notifications, and link teardown. No subclassing Apple CB classes.
   Existing discovery and OS restoration callbacks remain physical-only coverage
   unless specifically covered by an adapter-level test.
4. Inject defaults and snapshot/report roots. Production defaults remain standard;
   production paths remain unchanged. Use a clock/sleeper seam where timeout and
   ordering tests need controlled time; never globally disable delays/animations or
   reduce production timeout values to make tests pass.
5. Test configuration and the simulated peripheral compile only under
   `DEBUG && targetEnvironment(simulator)`. Explicit test configuration must be
   prepared before any @StateObject, probe, view, or storage consumer is created.
   No simulator test launch may instantiate a real CBCentralManager, including
   Connection inspection. Keep existing preview/render flags working separately.
6. Add meaningful accessibility identifiers/values to actual controls. UI tests
   navigate and act through those controls. Test configuration may select starting
   state and transport faults, but must not perform the journey's action for it.

### Stable test configuration contract

- Launch argument: `--quietcontrol-ui-testing`.
- Environment: `QUIETCONTROL_TEST_SCENARIO`, `QUIETCONTROL_TEST_RUN_ID`,
  `QUIETCONTROL_TEST_RESET` (`1` to reset that run only).
- Run IDs: nonempty ASCII letters/digits/hyphens only, at most 64 characters;
  invalid/missing configuration fails clearly. No silent production fallback.
- Defaults suite: `uk.co.mzbali.quietcontrol.ui-tests.<run-id>`.
- Files: app Application Support/QuietControlUITests/<run-id>/, containing
  isolated snapshots, reports, `transport.jsonl`, and `peripheral-state.json`.
- Each test creates a fresh run ID. Persistence tests reuse that ID across
  relaunch with RESET omitted. Cleanup never clears the production defaults suite.
- Synthetic baseline: Bose Corporation, 884367-0100, 1.0.6-80+f5f219b;
  battery 90; Quiet=0, Aware=1, Focus=2; Focus strength 5/Wind Block off;
  EQ [-1,+4,+2]; iPhone and MacBook Pro connected; Work laptop disconnected;
  multipoint on. Use invented UUID/MAC values, never user's real identifiers.
- Initial scenarios: `connected`, `mode-rejected`, `mode-unconfirmed` (write
  accepted, independent GET still reports Quiet), and `offline-cached`.
- Transcript: monotonic sequence number, direction/event, encoded bytes where
  applicable, and session/connection identity. State artifact includes current
  mode/EQ/devices and is independently read by the host runner. Use literal golden
  fixtures in tests for important packets rather than only round-tripping the
  production encoder. Additional fields/scenarios are additive and documented.

## Wave 1: foundation and one real UI journey

One delegate, because this wave changes shared interfaces and Xcode configuration.
Main model owns the design above; the delegate implements these specified seams.

- Add byte transport/environment and simulator fixture; adapt session IO without
  replacing the command state machine. Inject storage and required timing seams.
- Wire the test environment into app construction and probe isolation. In the
  existing views only replace storage access with the environment and add stable
  mode/status identifiers. Preserve presentation and gesture behavior.
- Add app-hosted session tests and a native XCUITest target/shared test plan.
- Session tests: Quiet -> Aware -> independent GET -> confirmed Aware; explicit
  rejection; accepted-but-unconfirmed write; cached state without live authority;
  serialized refresh/action. Verify transcript and persisted state as applicable.
- UI journey: launch connected at Quiet; tap Aware; wait for confirmed Aware;
  assert app state and independent GET in the transcript; relaunch and show cached
  profile offline with controls disabled. Add precise failure UI tests for rejected
  and unconfirmed writes: no success toast or false selected mode.
- Run all 33 existing tests, the new session/UI tests with zero skips, Debug
  simulator build, and unsigned Release iOS build. Record count, logs, xcresult,
  source SHA, simulator model and runtime. Do not use the user's booted simulator.
- A fresh delegate review must PASS this wave before dependent implementation.

## Wave 2: disjoint UI and runner slices

Start only from the reviewed, committed foundation. Reconcile file lists against
actual foundation output and run the ownership checker before launch.

UI slice owns the view, fixture/environment/session extensions, session/UI tests,
and Xcode test-plan wiring. Runner slice owns scripts and testing documentation;
the exact disjoint lists live in the phase brief directory. Add journeys:

| Area | Concrete assertions |
| --- | --- |
| EQ | Drag Mid +4 -> +7; no device write until release; GET confirms +7; Flat -> [0,0,0]; named preset survives relaunch; rejected write restores confirmed values. |
| Mode editor | Long-press Focus opens without changing current mode; 5 -> 7 is unsaved until Save; Cancel preserves 5; saved 7 survives reopen; Wind Block forces 10; Quiet/Aware remain locked. |
| Devices | Pending values remain confirmed; full slots require valid replacement; swap + Undo; unreachable Work laptop restores initial iPhone/MacBook connections; control BLE remains conceptually separate from audio. |
| Settings | Correct blocks/functions and preserved payload bits; power settings disabled on unsupported firmware; no write on Cancel; no hardware writes are triggered by test launch. |
| Connection | First-run, waiting after 8 seconds with one pending request, pause/resume across relaunch, Bluetooth-off and denied states, no false 'powered off' claim. |
| Accessibility | Actual EQ/ANC gestures plus adjustable values; light/dark; large text; reach menus and bottom controls; screen audits. Preserve Reduce Motion behavior. |

Runner slice owns verification scripts and testing documentation. Add:

- `scripts/verify.sh core|session|ui|preinstall`, with explicit focused UI selection.
- Python runner builds once, creates its own compatible simulator, runs selected
  tests, inspects xcresult, exports artifacts, shuts down/deletes only its simulator.
- Require every selected test to run and pass, with zero skips. Discover and validate
  identifiers/counts from a maintained manifest, not a stale magic total. Disable
  automatic retry-to-green; a diagnostic rerun cannot erase a first-run failure.
- Independently inspect simulator test data/transcripts after the relevant test
  or export them as attachments before cleanup. Preserve all run artifacts under
  ignored build/Verification/<run-id>/, including exact commands, source SHA and
  dirty status, build identity, Xcode/runtime/model, selections and counts.
- Full preinstall also runs unsigned Release device compilation. Subsequent source
  changes invalidate acceptance. Unsupported OS/device matrix entries are BLOCKED,
  never silently skipped or represented as tested. Start on installed iPhone Duo
  iOS 27.1; add compact/minimum-supported OS lanes when compatible runtimes exist.
- No provisioning/profile changes, real-phone install, app launch on phone,
  production data, radio writes, publication, paid CI, or deployment.

## Wave 3: fault/recovery coverage

Sequential extension of fixture/session tests after Wave 2 integration. Add delayed,
missing, malformed, fragmented and stale replies; disconnect during writes;
reconnect/operation invalidation; interrupted journal restoration; firmware/device
mismatch; once-per-session restoration gates; and cache corruption. Use controlled
timing in session tests and a small representative native UI fault suite.
Existing short-Auto-Off hardware incident remains unresolved; do not repeat those
physical writes. Simulated acceptance never closes that hardware question.

## Review and completion

Use OpenCode V2 `opencode-go/deepseek-v4.1-flash` for implementation and first-pass
review. T3 child tasks with worktree isolation keep this topic in the parent; do
not create top-level threads, poll, or ask the user to relay briefs/results.
Separate reviewer task per integration/recheck. Reviewer reports PASS/FIX by
acceptance criterion; does not repair code. Main model makes final decisions.
Small fixes can be made directly; substantial fixes get a new bounded task.
Link every created/pushed PR; no delegate merges or deploys. Reviewer checks
must-survive behavior, fixture exclusion from Release, actual UI actions,
independent assertions, deterministic teardown, and no weakened failure criteria.

Final acceptance requires the entire preinstall suite, not just Wave 1 or a subset.
Report actual test counts, defects fixed, remaining BLOCKED coverage, and physical
gaps. Do not claim the phone/hardware is tested by simulator evidence.

### Wave 1 acceptance record

PR #1 was independently reviewed at eda4c7f: 33 core and 9 session/UI tests passed,
with simulator/unsigned Release builds and independent packet/snapshot checks.
Review nevertheless found a medium pending-radio-connect cancellation regression
and three low findings (quiet-wait busy presentation, duplicate toast identifier,
unused timing seams). Repair commit 7a6632b addressed all four and added two
session regressions. Core33 pass, native UI4 pass on the repaired app source,
final session7 pass, and unsigned Release build passes. A new test initially
matched startup waiting before connect; its predicate was corrected and the first
failed xcresult retained. No production criteria were weakened. PR #1 is merged
into testing/xcuitest-base, not main. Full phase acceptance remains outstanding.

## Delegation comparison requested by the user

Record per task: model/provider/options, scope/owned files, elapsed time, reported
usage/cost (or unavailable), checks run, reviewer defects/severity, fix rounds,
out-of-scope changes, and final acceptance. Existing 6.1 work was research and a
read-only MusicSync audit; DeepSeek work will be implementation/review. These are
different workloads, so describe observed fitness and rework rather than inventing
a controlled model ranking or savings percentage. Do not pay for duplicate
implementation purely to manufacture a benchmark. Compare after reviewed results.
