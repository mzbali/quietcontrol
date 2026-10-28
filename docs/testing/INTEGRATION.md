# Final evidence integration specification

Goal: one strict preinstall command verifies current source before a phone install
is considered. No physical-device claim, CI purchase, retries, generic bypasses,
new app instrumentation or production-data access. Preserve existing runner
failure/timeout, discovery, exact leaf, simulator ownership, cleanup, Release
exclusion and source-fingerprint guarantees.

Final ownership: scripts/verify-ui.py, scripts/tests/test_verify_ui.py,
docs/testing/journeys.json, docs/testing/README.md. Existing verify.sh interface
unchanged; parent handles repo PLAN/PROFILE/aggregate PR text.

Use stable source/test enumeration and final reviewed UI/fault contracts as
inputs, not stale intermediate counts. Expect24 session and17 UI if no test names
changed. Existing two pending-transport unit tests remain the ONLY blanket
no-container allowlist. Every other ID needs explicit evidence, including
negative scenarios and invalid configuration.

Extend manifest with strictly validated additive fields for:
- one or more required named run specifications per test; each unique prefix,
  final scenario/reset and ordered scenario/launch history. Existing singular run
  remains supported or migrate all entries coherently, with no silent defaults
  that weaken known assertions. Require exact expected run set; unmatched extra,
  duplicate, missing, ambiguous or reused run folders fail.
- explicit file expectations: valid structured snapshot, exact corrupt bytes,
  intentional absence; exact retained recovery journal data, or confirmed removal;
  absence is checked, not ignored. Parse JSON strictly and reject unknown keys,
  invalid types or impossible combinations in manifest and evidence.
- real peripheral firmware/activeAudio/preferences, mode strength/wind, defaults
  preset state where claimed. Isolated UserDefaults may require exporting the
  corresponding Library/Preferences plist in addition to Application Support.
- scoped ordered packet/event counts: anchors so startup reads cannot satisfy a
  post-write GET; SET -> response -> independent GET -> response. Exact count,
  no-outbound-between bounds, no-outbound scenario, unknown/missing event failure.
  Reconstruct segmented BMAP when fragment/coalesced proof requires it; validate
  production LifecycleDiagnostics RX records for faulted modes separately from
  fake outgoing/incoming packet markers. Don't infer actual decoder success from
  fake emit alone or a test-authored event alone.
- explicit invalid-configuration evidence for exactly that UI test: retained
  xcresult journey attachment for both bad scenario and bad runID, explicit error
  screenshot/outcome, and proof no valid harness run directories or radio traffic.
  Missing container is never silently a pass; no generic artifacts:false escape.
- xcresult text attachments: require12 unique audit contexts, parse raw issues
  independently, recompute counts (reported=ignored+failed), reject enabled/unknown
  exemption or any failure; only disabled contrast is eligible. Require current
  screenshots plus large-editor before/after hero geometry and clear-Wind evidence
  from the corrected source. Reject missing/duplicate contexts, corrupt summaries,
  nonfinite/impossible frames, unstable geometry, Save-disabled claims. No accepted
  field or old blanket color/coordinate exemptions.

Export container/evidence before a later install overwrites it. Session lane
currently runs all session tests together; export its entire run set once and map
every ID/subrun exactly. UI runs per journey; export after each, filter only newly
created runs while verifying same-ID relaunch history within that journey.
Extract actual xcresult attachment manifest names and associated test identity;
avoid matching a successful attachment from the wrong test, stale xcresult or run.
Screenshots may have no extension in tool export; report correct actual paths.

Regression checks must target acceptance bugs, not mirror implementation:
multi-run missing/extra/ambiguous evidence; exact corrupt/absent file expectations;
wrong journal/preset/firmware state; startup-satisfied GET/order/counts; invalid
configuration missing proof; forged audit counts/enabled exemption/missing context;
geometry mismatch; fragment decoder evidence missing. Retain all existing32 checks.

Acceptance: focused host rule tests, real strict preinstall once at final source,
exact discovery24+17, core33, zero failed/skipped/disabled, Release no fixtures/test
bundles; preserve failed first attempts. Record source fingerprint and verify same
content after clean commit, cleanup only owned UUID. Minimum iOS17 and compact
runtime absence BLOCKED coverage, never silently counted. Held EQ bubble video and
real BLE/audio/buttons/background/firmware timing remain unverified, not satisfied
by packet logs. Final verdict/report must distinguish gate PASS from those limits.
