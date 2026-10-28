# Native pre-install verification

`scripts/verify.sh` is the repeatable check that runs before installing QuietControl
on a phone. It drives the real app and `QuietComfortSession` against the stateful
synthetic peripheral, retains independent transcripts/snapshots, and writes an
inspectable run directory. It does not install on a phone, touch the radio, or
deploy anything.

The design and acceptance criteria are in [PLAN.md](PLAN.md); the local toolchain
and physical limits are in [PROFILE.md](PROFILE.md).

## Commands

```sh
./scripts/verify.sh core        # core SwiftPM tests (all of them)
./scripts/verify.sh session     # all app-hosted session tests in the manifest
./scripts/verify.sh ui          # all UI journeys in the manifest
./scripts/verify.sh ui --only modes --only offline
./scripts/verify.sh preinstall  # core + all session + all UI + unsigned Release device build
```

`ui` accepts repeated `--only <journey>` selections. An unknown or empty journey
fails before the simulator is created. `preinstall` rejects `--only` (partial
selection is not a pre-install acceptance) and always runs every session and UI
test plus the unsigned Release device build.

Exit codes:

| Code | Meaning |
| --- | --- |
| 0 | PASS: every selected test was discovered, executed, passed, and was not skipped; all artifact checks passed. |
| 1 | FAIL: a test, artifact, discovery, build, or cleanup rule failed. |
| 2 | Usage error (bad lane/selection/preinstall partial selection). |
| 3 | BLOCKED: required local environment is missing (full Xcode/tool, compatible runtime/device, disk space). |
| 130 | BLOCKED: interrupted; cleanup was still attempted. |

## What is checked

- **Discovery:** Xcode test enumeration is compared with `docs/testing/journeys.json`.
  Every manifest test must be discovered and every executable test must be in the
  manifest. Duplicate tests, disabled manifest tests, stale entries, and unknown new
  tests fail. The baseline suite size is never hardcoded.
- **Execution:** `xcresult` must report exactly the selected tests, all passed,
  zero failed, zero skipped, zero expected failures, on the run's own simulator.
  A test that is missing from the `xcresult` fails even when xcodebuild exits 0.
- **Independent evidence:** each session run and each UI journey copies the app data
  container (Application Support plus `Library/Preferences`) before any later test
  installation can replace it. The runner parses `test-config.json`,
  `transport.jsonl`, `peripheral-state.json`, `LastConfirmedState.json`,
  `LifecycleDiagnostics.jsonl`, `PreferenceRecovery.json` and the isolated defaults
  plist strictly; duplicate JSON keys, non-finite numbers and unknown fields are
  rejected. It checks the synthetic identity, run ID, defaults suite, final
  scenario/reset, scenario order, monotonic sequence, required/forbidden/ordered
  packets (including explicit segment headers), exact counts scoped after a write
  anchor, and no-outbound windows. Confirmed snapshot values, Focus strength/wind,
  firmware, active audio, paired devices and preference payloads are checked
  independently. Rejection and unconfirmed cases must not contain a confirmed-Aware
  packet, and the unconfirmed case must show an independent GET after the write
  rather than treating the write acknowledgement as confirmation.
- **Multiple runs:** a test may declare several required subruns (for example
  first-run/radio-off/permission-denied or three preference-recovery subcases). Every
  run directory created by the lane must be claimed exactly once; missing, extra,
  ambiguous or reused folders fail. Same-ID relaunches are checked through the final
  `test-config.json` and the complete scenario history. The two in-memory pending
  transport tests remain the only blanket no-container exceptions. Where the test
  source deliberately reuses one prefix for two tests, the manifest declares a
  `sharedPrefixGroup` and identifies each directory by a unique packet token; an
  ambiguous directory fails.
- **Offline relaunch:** the transcript must contain the connected launch followed by
  the offline-cached relaunch, with no outbound segments or BMAP frames after the
  offline launch. A screenshot/toast alone is never accepted.
- **Explicit file states:** snapshots are required to be valid, intentionally
  corrupt with the exact seeded bytes, or intentionally absent. Preference recovery
  journals must be byte-identical to the seed, or confirmed removed. Preset
  persistence is read from the exported isolated `Library/Preferences` plist, not
  inferred from the UI.
- **Fault evidence:** production `LifecycleDiagnostics` RX counts are validated for
  the fragmented/coalesced receive path separately from fake packet markers and
  test-authored events. Nine inbound segments with headers `80`..`88` and exactly
  six production RX `1f 06 03 2f` frames (three setup, three after release) are
  required, so a fake emit alone cannot pass.
- **xcresult attachments:** the runner exports the attachment manifest per UI
  journey and associates each attachment with its actual test. The accessibility
  journey must produce twelve unique audit contexts, twelve current screenshots,
  wind-clear and before-audit screenshots, and the five-frame large-editor geometry.
  Audit summaries are parsed independently: `reported == ignored + failed`, no
  enabled issue may be ignored, only a contrast issue on an actually disabled element
  may be ignored, and frames must be finite/possible with `before == after`.
- **Invalid configuration:** the negative UI test has its own narrow evidence rule.
  It must retain both `journey-invalid-run` and `journey-invalid-scenario` text
  attachments naming the actual `QUIETCONTROL_TEST_RUN_ID` / unsupported-scenario
  message, both error screenshots, two distinct run IDs in the respective invalid and
  valid shapes, and no harness run directory or radio traffic. A missing container is
  never silently a pass and this is not a generic `artifacts:false` escape.
- **Core:** `scripts/test.sh` must report a non-zero `Executed N tests` count with
  zero failures and no skipped tests.
- **Release exclusion (preinstall):** the unsigned Release/device build must succeed;
  its binary must not contain simulator fixture symbols or strings
  (`QCTestHarness`, `QCSimulatorPeripheral`, `--quietcontrol-ui-testing`, and similar),
  and the app must not embed `.xctest` bundles.
- **Source fingerprint:** every run records the Git SHA, dirty status, dirty paths
  and a content fingerprint over tracked working-tree files plus untracked non-ignored
  files. Because it hashes contents rather than the commit SHA, committing the tested
  tree does not invalidate acceptance. The fingerprint is recomputed at the end; a
  source edit during the run fails it, and any later edit invalidates a previous
  `preinstall` acceptance.

No automatic retry-to-green is performed. A failed test is recorded once in that
run's `xcresult` and summary; no second attempt is made.

## Simulator lifecycle

The runner reads installed runtimes, prefers `iPhone Duo` on `iOS 27.1` (then the
highest installed iOS runtime compatible with the manifest), creates a uniquely
named simulator, boots it, builds-for-testing once into a per-run DerivedData path,
enumerates, and runs `test-without-building` selections on that UUID. It never uses
a pre-existing booted device, a `booted` alias, a physical device, or provisioning.

Cleanup runs in a `finally` block for errors, signals and timeouts. It shuts down and
deletes only the UUID recorded for this run, and refuses deletion if the inventory
name no longer matches the task-owned name. Unrelated simulators are untouched.

## Artifacts

Ignored `build/Verification/<run-id>/` contains:

```text
summary.json                 status, counts, source fingerprint, commands, errors
commands.log                 exact commands, exit codes and durations
logs/                        xcodebuild/simctl/nm/strings logs per command
results/*.xcresult           build test results, one per selected journey/session lane
artifacts/enumeration.json   exact discovered test identifiers
artifacts/ui-<journey>/      exported app container plus Library/Preferences for that journey
artifacts/session/           exported app container plus Library/Preferences for the session lane
attachments/ui-<journey>/    xcresult attachment manifest and exported files
DerivedData/                 build products for this run only
ReleaseDerivedData/          unsigned Release device build (preinstall)
```

`summary.json` records the destination UUID/runtime/device type, Xcode version,
selected test IDs and counts, elapsed time, coverage gaps and the Release exclusion
check. If a `preinstall` run passes, its `summary.json` is the acceptance record for
that source fingerprint.

## UI manifest

`docs/testing/journeys.json` is the maintained list (schema version 2). Every session
test and UI journey appears exactly once, and every test declares one or more required
runs. A journey entry looks like:

```json
{
  "name": "modes",
  "id": "QuietControlUITests/QuietControlUITests/testTappingAwareUsesRealControlAndConfirmsWithIndependentGet()",
  "label": "ui-modes",
  "runs": [
    {
      "prefix": "aware-",
      "scenario": "connected",
      "reset": true,
      "expect": {
        "files": { "require": ["test-config.json", "transport.jsonl"] },
        "snapshot": { "state": "present", "lastMode": 1, "eq": [-1, 4, 2] },
        "peripheral": { "connected": true, "mode": 1 },
        "transcript": {
          "scenarios": ["connected"],
          "order": ["outbound:1f0305020100", "inbound:1f03030101"],
          "counts": [
            { "token": "outbound:1f030100", "equals": 1, "after": "outbound:1f0305020100" }
          ]
        }
      }
    }
  ]
}
```

- `runs[].prefix` matches the test's run ID prefix. `scenario`/`reset` are the final
  `test-config.json` values, including same-ID relaunches. `expectedRuns` defaults to
  one. `artifacts: false` remains reserved for the two explicitly allowlisted
  in-memory pending-connection tests. `evidence: "invalid-configuration"` is reserved
  for the one negative configuration UI test and expects zero harness runs.
- `expect.files` names evidence that must exist or must not. `snapshot.state` is
  `present`, `corrupt` (with the exact seeded `literal`) or `absent`. `journal.state`
  is `present` (exact literal bytes or exact fields) or `absent`. `defaults.preset`
  reads the isolated defaults plist.
- `expect.transcript.order` must occur in order; `required`/`forbidden` apply anywhere
  (a trailing `*` makes a token a packet prefix); `noOutboundScenarios` forbids
  outbound bytes for a scenario; `forbiddenMessages` rejects event text. `counts`
  asserts exact/bounded occurrences after an anchor or an ordered list of anchors,
  optionally ending before the next matching `before` token. `outbound:*` marks
  the next outbound packet. These windows prevent setup or later reads from
  satisfying the current write's confirmation. `noOutboundBetween`
  rejects outbound traffic between two ordered anchors, optionally restricted to a
  packet prefix. `requireEvents`/`forbidEvents` match transcript messages.
  `segmentHeaders`/`segmentHeadersAfter` assert ordered inbound segment headers.
- `expect.lifecycle` requires unique, ordered before/after boundaries in the same
  log as the production RX records. Counts must match before release and after
  completion, with no additional matching RX afterward; total-only proof is rejected.
  Debug simulator trace markers bracket release; the actual decoded RX records
  establish progress, independently of a test-authored success message.
- `expect.snapshot` and `expect.peripheral` check the confirmed snapshot and fixture
  state independently of the UI, including firmware, active audio and preference
  payloads.
- `attachments` requires the accessibility audit contexts/screenshots, large-editor
  geometry, or the narrow invalid-configuration text/screenshot proof.
- A `sharedPrefixGroup` (plus a unique `sharedMatchToken` per test) is only for source
  that genuinely reuses one prefix; each directory must match exactly one test or it
  fails as ambiguous.

The schema is strict: unknown keys, wrong types, non-finite values, duplicate test
IDs, duplicate/reused prefixes, disabled tests and incompatible schema versions fail
before a simulator is created. A new UI or session test must be added to the manifest
(with its expected run set and evidence) before it is accepted.

## Coverage and physical limits

Only the installed simulator matrix can run. Today that is `iPhone Duo` on iOS 27.1.
When the minimum-OS runtime (iOS 17) or a compact device type is not installed, the
run prints and records explicit `BLOCKED` coverage entries; this is reported as absent
coverage, not as a pass and not as a reason to fail the available-device lane.

Simulator tests cannot prove:

- actual Bluetooth radio behavior, pairing, firmware timing, or BLE write constraints,
- audible noise cancellation, audio routing, or multipoint behavior on real hardware,
- physical buttons/gestures on a device,
- iOS background/state-restoration behavior on a real phone.

No phone installation, app launch on a phone, provisioning, production data, hardware
write, paid CI, or deployment is part of these commands. A passing `preinstall` run
is simulator acceptance only; physical acceptance must be reported separately.
