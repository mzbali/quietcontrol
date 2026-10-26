# Latest: v0.4.1 (29), 26 October 2026: Equalizer + mode editor redesign (steps 3–4 of 4)

Built and unit-tested (33 pass), device build succeeded; NOT installed (ChatGPT
was testing build 28 on the iPhone). Equalizer: curve with gradient fill, dashed
guide, value bubble while dragging, "saves when you let go" hint; Reset toolbar and
presets sheet replaced by an inline Presets grid (Custom/Current card when nothing
matches, Flat, saved presets with mini curves, Save current, long-press Delete).
Mode editor: hero with name, "Edited · not saved", 10-segment StrengthMeter
(tap/drag, saved-level marker, accessibility adjustable), Wind Block extras row,
nav Save + sticky "Save <mode>" button, dismiss blocked while dirty; Quiet/Aware
show a read-only lock note. NoiseControlBar removed. Renders: build/v29-eq-*.png,
build/v29-editor-dark.png. Same write paths (applyEQ/resetEQ/saveMode).

Build-28 ChatGPT test: Auto-Off Never→20→Never and Remember My Mode On→Off→On
passed (clean read-backs in build/v28-lifecycle.jsonl, 22:49:16–22:49:37). Settings
footer was unreachable below the fold, so build 29 moves Connection details and
Diagnostics into a toolbar "…" menu. At 22:50:00 the QC itself dropped BLE
(CBError 7), 38 s after the Auto-Off restore, with no app traffic; all devices then
showed unavailable. Hypothesis (unconfirmed): writing 20 minutes while the QC had
already been idle >20 min armed a shutdown that writing Never did not cancel.
Do not write short Auto-Off values again until this is understood.

Build 29 installed and tested by the Codex test thread (23:02–23:08): Settings "…"
menu, EQ page (drag, Save current "Mine" −1/+7/+2 kept on phone, Flat, re-apply,
restore −1/+4/+2), mode editor (unsaved state, saved marker, dismiss blocked,
Cancel discards, save 7 then restore 5, Wind Block off, Quiet lock note) all pass.
Not verifiable by automation: drag value bubble and mint band label while held.
A 23:05:43 drop was CBError 6 (link supervision timeout, no app traffic) and
auto-reconnected in 18 s, unlike the 22:50 CBError 7 drop. Source now also shows
the app version in Device & about (not yet installed).

# Latest: v0.4.1 (28), 26 October 2026: Settings redesign (step 2 of 4)

Settings sheet: headphone identity card (opens Device & about), iOS-style tinted
icon rows, Auto-Off as an inline chip row (accessibility sizes keep the list
page), Remember My Mode with detail line, Connection toggles, and a quiet footer
with Connection details and Diagnostics. Same setPreference write paths. Installed
and viewed on the iPhone (build/v28-settings-phone.png); no setting writes made.
Testing workflow from now on: the user runs a test brief in ChatGPT via iPhone
Mirroring and pastes back the report. Next: Equalizer, then mode editor.

# Latest: v0.4.1 (26), 26 October 2026: Home redesign tested on the iPhone

Driven through iPhone Mirroring (CGEvent clicks + window screenshots; helpers in
build/mirror-tools, T3 Code has Screen Recording/Accessibility). Passed: layout,
Focus/Quiet switching with hero meter (5 of 10 / Max), hold-to-edit opens the
editor without switching, long-press Disconnect, reconnect, offline "Last used" state.
Swap to unreachable LBRLAPTOP5048 found a real bug: restoring the MacBook was
rejected with BMAP ERROR 08 while the QC kept paging. Builds 25/26 add stop
request [4.2] + bounded restore retries (8 x 3 s); build 26 restored the MacBook
automatically after ~17 s with a clear toast. Baseline restored: Quiet, Gorilla +
MacBook (active audio). NOT yet tested: a successful swap and Undo (needs the
laptop on and nearby). Logs: build/v24/v25/v26-swap-session.json.

# Latest: v0.4.1 (24), 26 October 2026: Home redesign (step 1 of 4)

Home now has the gear in the header (no nav title), a current-mode hero with a
10-step cancellation meter, and a segmented picker (Quiet → custom → Aware; hold
to edit). Devices: the controller iPhone keeps its switch; other devices are a
pick-one list. Tapping a disconnected device when slots are full and exactly
one non-phone device can make room swaps in one tap via
connectAudioDevice(_:replacing:), with a 5 s Undo toast. Otherwise the existing
chooser opens. Disconnect via context menu / VoiceOver action. EQ row is inline
at 176 x 48 pt. Renders: build/v24-home-*.png; 684.5 pt of 795 fits at 430 pt.
33 tests, simulator and device builds pass; signature verified. NOT installed:
the iPhone was locked (devicectl 1016). The swap/undo has not been run on hardware.
Next planned: Settings → Equalizer → mode editor (see build/ui-concepts/plan.html).

# Latest: v0.4.1 (23), 26 October 2026

Headphone Settings gains a Power section: Auto-Off picker (5/20/40 min, 1 h,
3 h, Never → [1.4] minutes) and Remember My Mode toggle ([31.5] only; [1.14]
is never written). Both are read with the other preferences, written via the
existing setPreference GET → SETGET → independent GET path and gated to
884367-0100 / 1.0.6-80+f5f219b. Home unchanged. Bose-app footer note removed.
33 tests, device and simulator builds pass; signature verified. Installed and
launched normally (no flags) at 17:35 UTC; QC was not reachable at that time,
so the new rows were not yet seen with live values. Simulator screenshots came
out black in this session; no visual review of the new section yet.
Still untested: 5/40/60/180 values on hardware, real idle shutdown, power-on
mode behavior. Profile expires 30 October 2026 11:11:58 UTC. IPA still build 18.

# Latest investigation: v0.4.1 (22)

Build 22 installed; device build passed. Explicit DEBUG one-shot verification
confirmed Auto-Off write/read-back [1.4] and Remember My Mode [31.5].
Do not write the latter through [1.14] alone: accepted but [31.5] stays unchanged.
[31.5] writes update both. Original Never/On restored and independently confirmed
at 21:50:30 UTC; current mode 00 unchanged. Normal launch without flags completed.
No new UI controls. Timed shutdown/power-on behavior still untested.
Read BOSE_REPLACEMENT_RESEARCH.md and HARDWARE_CHECK.md for reports and
interruption journal/one-shot gate details. Build-18 IPA remains exported archive.

# Current investigation: v0.4.1 (20)

Build 20 adds DEBUG-only once-per-session --inspect-power-preferences (GET only),
no UI changes and no new setting writes. Device build/signature verified and
installed. Both settings compared through Bose on 25 October 2026:
- Auto-Off Never -> 20 Minutes -> Never: [1.4] 00 -> 14 -> 00.
- Remember My Mode On -> Off -> On: [1.14]/[31.5] 01 -> 00 -> 01.
- Current mode and [31.4] stayed 00. Both original settings restored and read
  independently at 21:41:48 UTC; build/v20-power-restored.json (ignored).
Normal launch without flags completed after inspection. See
BOSE_REPLACEMENT_RESEARCH.md for evidence and remaining write/behavior checks.
Build-18 IPA remains the previous exported archive.

# Latest sizing adjustment: v0.4.1 (19)

User requested the EQ size before the final shrinking iteration: Home row now
58 pt minimum height with a 154 x 42 pt curve, retaining full width and inline
title. Device build passed; installed and launched normally on 25 October 2026.
Build-18 archive below remains the previous exported IPA.

# Current source: v0.4.1 (18), 25 October 2026

This is the latest presentation update. Build 18 includes the approved compact
battery, bottom feedback and EQ preview; Diagnostics, Connection details and
About contents stay unchanged. Device/simulator builds and 33 tests pass.
Signed build-18 IPA exported to build/Export/QuietControl.ipa; signatures verified.

- Battery icon: 24 x 13 pt, proportional fill. Green >=50%, yellow 20–49%,
  red <20%, with darker tones for legibility in light appearance.
- Bottom toasts hug their content, use action-specific icons/messages and fade
  with 7 pt motion. Reduce Motion uses fade only. VoiceOver keeps a longer timeout.
- Home EQ is a slim 46 pt row with Equalizer left and 116 x 32 pt curve/point
  values right. Accessibility layout expands rather than shrinking labels.
- No Bluetooth verification tests ran for this presentation update. Existing
  serial transactions, confirmation reads and one-shot recovery guards remain.
- Build 18 installed and launched normally on the iPhone on 25 October 2026.
  Installed version independently queried; final session at 21:01:46 UTC confirms
  0.4.1 (18), four paired/two connected devices and multipoint on. No voice-prompt
  writes. Evidence: ignored build/v18-final-session.json.

The v0.4.0 handover below describes the underlying controls and hardware evidence.

---

# Current handover: v0.4.0 (17), 25 October 2026

This supersedes the historical v0.3 handover below. The project remains local,
with no Git commits or remote, and all signing/build/report exclusions remain.

## Current source and delivery

Install status: final v0.4.0 build 17 installed and launched normally on the
iPhone 15 Plus on 25 October 2026. Installed version independently queried.
The final session report (build/v4-final-session.json, 17:47:59 UTC) confirms
Bluetooth recovery, four paired/two connected devices, multipoint enabled and
zero voice-prompt writes. No verification flags were passed to the final launch.

- Version 0.4.0 build 17. Device and simulator builds pass; 33 package tests pass.
- Signed IPA exported to build/Export/QuietControl.ipa; device and archive app
  signatures verified. Profile still expires 30 October 2026 at 11:11:58 UTC.
- Dark-first native Home keeps three modes, four devices and the EQ summary.
  More is now Headphone Settings; technical checks are nested under Diagnostics.
- Tap a mode to switch; hold to open its editor directly. No mode-list page.
  Custom modes have the Bose-style filled noise-control bar, Wind Block and
  explicit Save/Cancel. Quiet/Aware remain fixed. Wind Block forces maximum ANC.
- EQ uses draggable curve points, integer values, local personal presets and
  Reset. Writes happen on release. Large text uses stacked summary values.
- Self Voice, button shortcut and voice prompts read/write through independent
  confirmation. Self Voice and shortcut reversible checks passed with restoration.
  Auto-Off and Remember My Mode still require the Bose app; do not claim support.
- Mode editing was verified on the physical QC and restored. The direct Home
  long press, draft/Cancel behavior and EQ curve writes (-1 -> 0 -> -1 bass)
  were reviewed on the iPhone. Original Quiet, Focus strength 5/Wind Block off,
  EQ [-1,+4,+2], Medium Self Voice, battery shortcut and voice prompts off retained.
- Dark Home/editor/EQ screenshots are local under build/v4-phone-*.png.
  Reports: v4-mode-editing-proof.json, v4-preference-proof.json,
  v4-stable-session.json and v4-tests.log (all ignored).
- IMPORTANT incident: an early preference test waited for a STATUS even though
  the voice setting applied without it, then reconnects repeated the test and
  recovery, causing spoken on/off loops. The process was stopped and voice
  prompts restored off. Preference writes now allow an absent acknowledgement
  and always GET/read back; launch tests and automatic recovery have once-per-
  session gates, tested across reconnects. The verifier no longer toggles voice
  prompts. Do not rerun audible tests casually.
- No pairing entries or audio host connections were changed by this update.
  The firmware's direct-routing limitation and remaining physical radio QA gaps
  from v0.3 still apply. Shortcut packet changes are confirmed; all physical
  button actions/Spotify behavior still need manual checking.

Read README.md, docs/HARDWARE_CHECK.md and docs/design/NEXT_CONTROLS_PLAN.md for
usage, evidence and the design discussion. Source changes are in
App/QuietControlView.swift, App/QuietComfortSession.swift, the shared protocol and
connection-policy files, and their tests. Keep all work local unless asked.

---

# Historical v0.3 handover

Prepared 25 October 2026 for a fresh Codex thread.

## Project and intent

- Repository: `/Users/mzbali/projects/quietcontrol`.
- QuietControl is a native SwiftUI/CoreBluetooth remote for the user's standard
  Bose QuietComfort Headphones, model **884367-0100**. This is not QC45, Ultra,
  or an earbud. The work began as a discussion of Bose's `bosectl` protocol and
  became a sideloadable iPhone app because the official Bose app felt slow.
- The app should make connecting/monitoring the QC, switching the paired audio
  hosts, choosing Quiet/Aware/Focus, and adjusting EQ quick and dependable.
- Bundle identifier: `uk.co.mzbali.quietcontrol`; deployment target iOS 17.
- Source release: **0.3.0 (build 16)**. Xcode project and Swift package live in
  this folder; see `README.md`, `docs/DEVICE_MANAGEMENT.md`, and
  `docs/HARDWARE_CHECK.md` for the user-facing guide and protocol record.

## What was implemented

- A calmer, compact Home: fixed connection status, Focus/Aware on top, full-width
  Quiet, four saved devices, and a separate EQ page. Additional devices open in
  View all. Larger text can scroll rather than shrinking controls.
- Connection states include Connecting, Waiting for QC, Connected, Auto-connect
  paused, Bluetooth off, Permission needed, and setup/attention states. The
  eight-second connection presentation becomes quiet waiting; a single pending
  CoreBluetooth connection request stays alive for the remembered QC.
- Auto-connect pause survives app launches. Background/foreground transitions
  preserve pending connection intent. A BLE disconnect is not considered proof
  that the headphone power switch was used, so the app does not say “Powered off”.
- A versioned, validated local snapshot saves confirmed mode names, device names,
  EQ, identity, firmware, battery and last-seen time atomically in Application
  Support and excludes it from backup. Offline controls are disabled and cached
  device statuses/battery are not represented as live.
- Background reads no longer dim the Home controls. A user action tapped during
  a read queues behind the serial Bluetooth transaction rather than overlapping
  it or dropping the tap. User actions give short in-app confirmation toasts.
- Confirmed Bluetooth functions include paired-device enumeration and audio
  connection/disconnection, multipoint, mode and EQ read/write. Direct audio
  source routing is unsupported by this firmware (`[4.12]` returned ERROR 04);
  connect hosts in QuietControl, then start playback on the host to hear.
- Upstream MIT license notices are included in the app and repository.

## Verified hardware and behavior

The user's iPhone 15 Plus (iPhone15,5) and standard QC were used on 23 October
2026. The headphone reported Bose Corporation, model 884367-0100, firmware
`1.0.6-80+f5f219b`, and BLE service FEBE. The secure BMAP control endpoint was
confirmed. The app read Quiet/Aware/Focus and EQ `[-1, +4, +2]`; Quiet/Aware
commands and a reversible bass write were read back and confirmed.

The user physically tested turning QC off, waiting, closing/reopening the app
while QC was off, seeing the saved Focus/four devices/EQ, then turning QC on and
letting the app recover automatically. CoreBluetooth reported disconnect code
7; the app kept a pending request and recovered without manual pairing. No
reliable Bose-specific shutdown event was identified.

After recovery, the user noticed Home controls dimming several times. The log
showed successful status reads and no intervening mode write or link loss. The
fix separated refresh presentation from action progress and queued an action.
Build 16's on-phone regression report passed: a mode action during a real
background read stayed available, queued, was confirmed by the QC, and retained
the original mode and connection. Evidence: ignored local file
`build/v3-refresh-interaction-proof.json`.

The final recorded Swift package run passed **31 tests**. The Home was measured
at 591.5 pt for the connected/waiting/connecting/paused/permission layouts with
three modes and four devices, fitting a 430 pt-wide layout at normal text size.
Larger text and dark appearance were visually reviewed in the available
simulator. The installed runtime could not boot an iPhone 15 Plus simulator, so
that visual check was not a native 15 Plus simulator session.

See `docs/HARDWARE_CHECK.md` for historical v0.1/v0.2 evidence as well as v0.3
acceptance notes. Physical out-of-range recovery and Bluetooth off/on remain
unverified; automated state tests do not prove those radio scenarios.

## Build, signing, install

The developer machine was an M1 Pro Mac with Xcode 27.1. Set the Xcode developer
directory explicitly if command line tools select another Xcode:

```sh
cd /Users/mzbali/projects/quietcontrol
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
./scripts/test.sh
./scripts/build.sh simulator
./scripts/build.sh device
./scripts/build.sh archive
```

The scripts use Xcode's local signing configuration. `Configuration/Local.xcconfig`
is gitignored and contains the personal team setting; do not copy it into a
handover or commit it. The public template is `Configuration/Local.xcconfig.example`.
Archive exports the signed IPA to `build/Export/QuietControl.ipa`.

The IPA was exported and codesign-verified on 23 October. Its embedded personal
development profile expired **30 October 2026 at 11:11:58 UTC**. Re-sign with a
renewed profile before installing after expiry. A development-signed IPA is
installable only on devices covered by its provisioning profile. Last recorded
install/launch on the user's iPhone was build 16 on 23 October; verify the
device's present state if it matters to follow-up work.

Previous physical install/launch pattern (use the iPhone currently attached and
its current device identifier):

```sh
xcrun devicectl device install app --device <DEVICE_UDID> \
  build/Device/Build/Products/Debug-iphoneos/QuietControl.app
xcrun devicectl device process launch --device <DEVICE_UDID> \
  --terminate-existing uk.co.mzbali.quietcontrol
```

Build/archive products and reports under `build/` are gitignored. On-device
session/proof reports are in Files → On My iPhone → QuietControl and can also be
copied from the app data container using `devicectl`.

## Repository / publishing status

- No Git commit exists yet; the `main` branch has no commits and all project
  source/docs show as untracked. There is no Git remote configured.
- No source was pushed to GitHub, and the project has not been published. Do not
  claim a GitHub repository or PR exists. The user mentioned they have a GitHub
  connector, but did not ask to publish this app.
- If publication is requested later, first create/review the initial commit,
  ensure `Configuration/Local.xcconfig`, signing artifacts, build products, and
  device reports remain excluded, then create/configure a remote and publish
  only with the user's explicit instruction.

## Good next steps

1. If continuing QA, first inspect this handover and the current `git status`,
   attached iPhone, installed build, and signing profile expiry.
2. Ask the user to try one more QC power off/on cycle if they want final
   confirmation that the build 16 dimming fix feels right in ordinary use.
3. If desired, test out-of-range and system Bluetooth off/on recovery on the
   physical phone, and test Focus plus music continuity. Existing mode/device
   verification can interrupt playback while it restores device connections.
4. Do not change Bluetooth pairings as part of install or ordinary reconnect.
   Keep the source-routing limitation visible and do not invent model support.
5. Do not push, publish, or create a remote without an explicit request.

## Prompt for the next thread

> Continue the QuietControl project in `/Users/mzbali/projects/quietcontrol`.
> Read `docs/HANDOVER.md`, `README.md`, `docs/HARDWARE_CHECK.md`, and
> `docs/DEVICE_MANAGEMENT.md` first. Verify current repo/device/signing state
> before making changes. The latest delivered app was 0.3.0 build 16, installed
> on the user's iPhone 15 Plus and exported as `build/Export/QuietControl.ipa`.
> Keep the project local unless I explicitly ask to publish it.
