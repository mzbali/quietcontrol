# Hardware acceptance record

Verified 23 October 2026 on iPhone 15 Plus with standard Bose QuietComfort
Headphones: model 884367-0100, firmware 1.0.6-80+f5f219b. Direct BLE only.

## Confirmed with actual phone replies

| Check | Result |
| --- | --- |
| Manufacturer/model | Bose Corporation / 884367-0100 |
| BLE service | FEBE |
| Command endpoint | C65B8F2F-AEE2-4C89-B758-BC4892D6F2D8 (secure read/write/notify) |
| Firmware read | 1.0.6-80+f5f219b |
| Battery read | 90% during the control proof |
| Mode discovery | Quiet, Aware and a configured Focus mode; prince 47-byte layout |
| Quiet / Aware | Both switches confirmed using subsequent current-mode reads |
| EQ read | Bass −1, mid +4, treble +2 |
| EQ write | Bass −1 → 0 confirmed, then 0 → −1 confirmed |
| Restoration | Final Quiet and EQ [−1, +4, +2] exactly matched the starting values |
| Protocol tests | 19 tests passed, zero failures; includes observed Focus, audio-only/control-only states, multipoint flags and slot selection |
| Builds | Simulator and signed physical-device builds passed |
| Physical installation | Development-signed app installed and launched on paired iPhone 15 Plus |
| Initial v0.1 cold launch | Build 3 reconnected in 3255 ms; read battery 90%, Quiet and EQ [−1, +4, +2] |
| IPA export | Development archive/export succeeded; final UI export is built from the current sources |
| Local data | Reports retrieved directly from the app container; no cloud endpoint used |

Ordinary command reply times in the proof were 63–98 ms. The GetAll-modes
transaction took 632 ms, including the deliberate 500 ms collection window.
These are individual transport transactions, not an end-to-end comparison with
the official app. Final app connection timing is recorded in SessionDiagnostics.

The proof is retained locally in `build/ControlProof-phone.json` (Git ignored).
It contains confirmed state before/after, packet events and timing. The original
discovery report is `build/Phone-inspection.json`.

## v0.2 connection controls and UI

Verified using the same phone/QC on 23 October 2026:

| Check | Result |
| --- | --- |
| Paired list and names | Four entries matched the Bose app's list |
| Controller status | Status 3 = audio + BLE controller; status 2 = BLE controller without audio |
| Connect / disconnect | Independent device-info reads confirmed both states |
| Disconnect all | Audio connections removed while BMAP battery/device reads still worked |
| Multipoint | SETGET off/on, independently read back as 06 / 07; enabled bit is bit 0 |
| Recovery | Starting connected set and multipoint restored; two matching snapshots required |
| Direct source routing | Not supported: [4.12] returned ERROR 04; action remains unavailable |
| Background / return | Backgrounded at 12:50:26 UTC; foreground at 12:51:54 UTC; same control link retained, no reconnect |
| UI | Home prioritizes modes/devices; EQ has its own curve/sliders page; light/dark and larger-text simulator review |
| Final mode/EQ check | Build 13 passed Quiet/Aware and EQ write/read-back; restored starting Focus (index 2) and EQ [−1, +4, +2] |

The successful device check is `build/DeviceControlProof-final.json`, with its
session capture in `build/SessionDevices-final.json` (build 12). Background
retention is recorded in `build/Background-retention-final.json`. Build 13 adds
larger-text layout refinements and retains the same verified device commands.
The final build's mode/EQ check and session are `build/ControlProof-v2-final.json`
and `build/Session-v2-final.json`.

Connect/disconnect, Disconnect all and multipoint gates are stored per headphone
and firmware after verification. Starting connections are restored after a test;
media playback may need resuming. Normal user changes are left as requested.
See [device-management formats and boundaries](DEVICE_MANAGEMENT.md).

## Remaining manual checks

- Switch the configured Focus mode through the final UI and return to Quiet.
- Confirm music remains uninterrupted while changing modes/EQ.
- Background/reopen was verified. Long screen locking, headphone power cycling and Bluetooth off/on recovery still need manual checks.
- Disable internet while leaving Bluetooth on, then use the controls.
- Deny/re-enable Bluetooth permission on a disposable test installation if desired.

No headphone power cycle, network-setting change or listening continuity is claimed
from source inspection alone. Final UI cold launch/reconnection was confirmed
from the phone's session report, retained locally in
`build/SessionDiagnostics-final.json` (Git ignored).

## Recovery and protocol boundaries

The control check saves the original bass/mode before any setting change. It
restores and reads them back, and retains a recovery checkpoint if interrupted.
Normal user changes are not temporary tests and are left as requested.

The initial four-byte PnP response (`01 9e 00 75`) is an abbreviated Bose
identity rather than the standard seven-byte PnP layout. It is reported as such;
a full 0x4075 product ID is not invented from those four bytes. Device identity
comes from the observed manufacturer/model, firmware and prince payload layout.

Protocol references:

- [bosectl prince notes](https://github.com/aaronsb/bosectl/blob/70570b29c1d3c9ba775b08a29eaea72385de27b5/docs/quietcomfort-headphones-prince.md)
- [bozo BLE framing](https://github.com/NerdySouth/bozo/blob/db07cad042093a4abcfb37c3f31ab6ace6137d4a/docs/BMAP.md)
- [Bose model-number listing](https://assets.bose.com/content/dam/Bose_DAM/Web/consumer_electronics/global/homepage/Terminos_y_Condiciones_Buen_Fin_Mx_2023.pdf)


## v0.3 calmer Home and quiet waiting (23 October 2026)

- Build 15 installed on the same iPhone/QC. The user completed power off,
  waiting, reopening while offline, cached Focus/four names/EQ, and power on
  automatic recovery. Lifecycle capture confirms CBErrorDomain code 7 at
  15:54:28 UTC, quiet pending request at 15:54:38, and automatic protocol
  recovery at 15:55:12. No reliable Bose shutdown event was observed, so the UI
  uses Waiting for QC. The pending radio request was retained on foreground.
- User reported repeated dimming after recovery. Logs show successful background
  snapshots/device reads, with no intervening mode write or control disconnect.
  Separate refresh/action presentation and serialized queued actions fix this.
- The 430 pt Home content measures 591.5 pt in connected, connecting, waiting,
  paused and permission states, with three modes and four devices. First setup
  measures 249 pt without invented modes/devices. Native simulator offline view
  reviewed; light/dark render measurements match. The available local simulator
  runtime cannot boot iPhone 15 Plus, so the exact-size check uses SwiftUI layout
  rendering plus the physical user's review.
- 31 package tests pass, including corrupt/incompatible snapshots, firmware and
  mode-list replacement, cached Focus/four devices/EQ, pending connection policy,
  radio/permission states, pause preference and foreground preservation.
- Physical out-of-range and system Bluetooth/permission denial remain separate
  manual checks; unit state coverage does not establish radio behavior for them.

- Final build 16 installed and launched normally. The physical refresh interaction
  regression report passes: controls remain available during a real background
  read, a mode tap queues behind the read, its reply is confirmed, the original
  mode is retained and the control link stays connected. Report retained locally
  as `build/v3-refresh-interaction-proof.json`.
- Native accessibility-large review uses stacked modes and scrollable content,
  preserving readable text; normal size dark appearance also reviewed.
- Signed v0.3.0 (16) IPA exported and signature verified. Bundled third-party MIT
  notices retained. Personal development provisioning expires 30 October 2026.


## v0.4 direct editing and dark UI (25 October 2026)

On the same iPhone 15 Plus / standard QC, firmware 1.0.6-80+f5f219b:

- Mode editing: the 39-byte prince SETGET payload preserves both prompt bytes,
  the exact name field, auto-CNC and spatial fields. A one-step Focus strength
  change and Wind Block write were independently read back, then the original
  strength 5 / Wind Block off restored. Enabling Wind Block normalized raw CNC
  to 0 (maximum cancellation), so the UI locks the full bar while wind is on.
  Evidence: ignored build/v4-mode-editing-proof.json and v4-mode-session.json.
- Direct Home long press opened Focus without switching the active Quiet mode.
  The Bose-style filled bar changed the draft and Cancel discarded it.
- Curve EQ was exercised on the physical screen: bass -1 -> 0 -> -1 was confirmed
  by independent reads; mids +4 and treble +2 retained. Evidence: ignored
  build/v4-stable-session.json. A saving indicator uses an overlay so progress
  does not move the curve.
- Self Voice and shortcut reversible write/read-back tests passed, restoring
  Medium and Battery Level. Evidence: ignored build/v4-preference-proof.json.
  The physical Action-button response for all shortcut choices is not claimed.
- Voice prompts read as off, language 1. During development a verification
  expected STATUS after SETGET, but the setting applied without that reply.
  Reconnects reran the launch check and replayed restoration, causing repeated
  spoken on/off announcements. The process was stopped, the original off setting
  restored and independently read back. Preference writes now accept an optional
  acknowledgement, always independently GET/read back, and the new mode/preference launch checks plus
  automatic recovery are bounded once per app session. Reconnects cannot rearm
  them. The automated preference verifier no longer toggles voice prompts.
- The empty slot left by the Bose app's temporary Commute creation/deletion has
  no prompt or name; it is omitted from the Home rather than shown as Mode 3.
- Auto-Off [1.4] and DefaultMode [31.4] reads alone do not establish setting
  semantics. Auto-Off and Remember My Mode are not offered as working controls.
- Dark Home, direct editor and EQ were reviewed on the physical phone through
  Mirroring. Native simulator renders provide additional light/dark and large
  text layout review; the installed simulator is iPhone Duo, not iPhone 15 Plus.

The earlier physical out-of-range and system Bluetooth off/on gaps still apply.
Do not infer listening continuity or full hardware accessibility behavior from
successful packet reads or screenshots alone.

- v0.4 package suite: 33 tests passed, including mode packet field preservation
  and the reconnect/one-shot regression. Device/simulator builds and signed IPA
  archive/export passed; provisioning expiry remains 30 October 2026 11:11:58 UTC.

Layout note: the ImageRenderer exports cannot draw UIKit-backed toggles/menus
and show placeholders there; those controls were reviewed in the actual phone
screen. At accessibility text sizes Home scrolls, and the EQ summary stacks
below its title instead of splitting the word Equalizer.

Final build 17 installed and launched normally at 17:47:59 UTC on 25 October.
Installed version independently queried. The final session confirms four paired
devices/two connected and multipoint on, with zero voice-prompt writes.
Evidence: ignored build/v4-final-session.json.


## v0.4.1 compact feedback, battery and EQ preview (25 October 2026)

- Proportional 24 x 13 pt battery with green >=50%, yellow 20–49%, red <20%.
  Native light/dark component exports reviewed at 100/50/49/20/19/0; no battery
  levels were forced on the actual headphones.
- Compact bottom feedback has contextual text and icons, 2.6-second normal
  display time, 0.22-second fade/7 pt motion, and fade-only Reduce Motion support.
  VoiceOver retains its longer announcement/display time. Feedback remains
  noninteractive and overlays the content without changing its layout.
- Home EQ row is 46 pt minimum height (expands for accessibility), with a 116 x
  32 pt curve preview. Typical values and opposite +/-10 extrema reviewed in
  native light/dark exports; the full interactive EQ page is unchanged.
- Device/simulator builds and all 33 existing package tests passed. This update
  changes presentation/feedback, not the Bluetooth transactions or diagnostics.
- Local preview evidence: build/v18-native-preview.png and native simulator
  FeedbackComponents-light/dark.png exports. The simulator is iPhone Duo;
  screenshots do not establish physical iPhone 15 Plus radio behavior.

Build 18 installed and launched normally on the physical iPhone on 25 October.
Installed version independently queried as 0.4.1 (18). The final session at
21:01:46 UTC confirms four paired/two connected devices and multipoint on, with
zero voice-prompt writes. No diagnostic verification flags were passed.
Evidence: ignored build/v18-final-session.json.

## Power-settings investigation, build 20 (25 October 2026)

DEBUG read-only probe installed and baseline saved. Bose's Remember My Mode
toggle ON -> OFF -> ON was compared against independent reads. [1.14] and
[31.5] changed 01 -> 00 -> 01, while current mode [31.3] and [31.4] remained
00. Original ON restored and confirmed in Bose and the read-back report.
No QuietControl writes were added for these settings; no power-cycle behavior
is claimed. Auto-Off Never -> 20 Minutes -> Never mapped [1.4] 00 -> 14 -> 00.
Both originals independently confirmed at 21:41:48 UTC in
build/v20-power-restored.json; Bose screenshot confirms Never. QuietControl
relaunched normally without flags. No new setting write controls enabled.
See BOSE_REPLACEMENT_RESEARCH.md.

## Power-setting write verification, builds 21/22

Auto-Off [1.4] 00 -> 14 -> 00 passed independent reads. Remember My Mode
[1.14] alone accepted changes but did not update [31.5]; this cross-check failed
and restored its original. The correct [31.5] write 01 -> 00 -> 01 passed and
updated [1.14] in tandem. Final independent inspection at 21:50:30 UTC confirms
Never/On and current mode 00 unchanged. QuietControl launched normally afterward.
Evidence: build/v21-power-proof.json, build/v21-power-session.json,
build/v22-power-proof.json, build/v22-power-restored.json (ignored).
Device builds passed; no UI controls enabled and no timed idle shutdown or
physical power-cycle semantics claimed. See BOSE_REPLACEMENT_RESEARCH.md.

## User-facing power controls, build 23 (26 October 2026)

Headphone Settings → Power now offers Auto-Off ([1.4]) and Remember My Mode
([31.5]) through the confirmed preference write path, gated to this model and
firmware. No new hardware writes were performed when adding them. Values other
than Never/20 minutes, idle shutdown and power-on behavior remain untested.
