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
  container before any later test installation can replace it. The runner parses
  `test-config.json`, `transport.jsonl`, `peripheral-state.json` and
  `LastConfirmedState.json` strictly (duplicate JSON keys are rejected). It checks
  the synthetic identity, run ID, defaults suite, scenario order, monotonic sequence,
  required/forbidden/ordered BMAP packets, confirmed mode/EQ snapshot values, and
  paired devices. Rejection and unconfirmed cases must not contain a confirmed-Aware
  packet, and the unconfirmed case must show an independent GET after the write
  rather than treating the write acknowledgement as confirmation.
- **Offline relaunch:** the transcript must contain the connected launch followed by
  the offline-cached relaunch, with no outbound segments or BMAP frames after the
  offline launch. A screenshot/toast alone is never accepted.
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
artifacts/ui-<journey>/      exported app container for that journey
artifacts/session/           exported app container for the session lane
DerivedData/                 build products for this run only
ReleaseDerivedData/          unsigned Release device build (preinstall)
```

`summary.json` records the destination UUID/runtime/device type, Xcode version,
selected test IDs and counts, elapsed time, coverage gaps and the Release exclusion
check. If a `preinstall` run passes, its `summary.json` is the acceptance record for
that source fingerprint.

## UI manifest

`docs/testing/journeys.json` is the maintained list. A journey entry looks like:

```json
{
  "name": "modes",
  "test": "QuietControlUITests/QuietControlUITests/testTappingAwareUsesRealControlAndConfirmsWithIndependentGet()",
  "run": { "prefix": "aware-", "scenario": "connected", "reset": true },
  "expect": {
    "snapshot": { "lastMode": 1, "eq": [-1, 4, 2] },
    "peripheral": { "connected": true, "mode": 1, "eq": [-1, 4, 2], "multipoint": true },
    "transcript": {
      "scenarios": ["connected"],
      "order": [
        "outbound:1f0305020100",
        "inbound:1f03030101",
        "outbound:1f030100",
        "inbound:1f03030101"
      ],
      "forbidden": ["inbound:1f03030101"]
    }
  }
}
```

- `run.prefix` matches the UI test's run ID prefix; `run.scenario`/`run.reset` are the
  final `test-config.json` values. `run.artifacts: false` is for tests that do not
  write app-container evidence (for example pending-connection tests).
- `expect.transcript.order` must occur in order; `required`/`forbidden` apply anywhere;
  `noOutboundScenarios` forbids outbound bytes for a scenario;
  `forbiddenMessages` rejects transcript event text.
- `expect.snapshot` and `expect.peripheral` check the confirmed snapshot and fixture
  state independently of the UI.

The schema is additive. A new UI or session test must be added to the manifest (with
its expected packets/state) before it is accepted; unrelated new keys are rejected so
the schema stays explicit.

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
