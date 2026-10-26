# Can QuietControl replace Bose?

Research checked 25 October 2026. Scope: standard 2023 QuietComfort Headphones,
884367-0100, prince, locally observed firmware 1.0.6-80+f5f219b.
No app changes, headphone writes, pairing changes or firmware operations performed.

## Recommendation

Aim for an independent daily controller, with official computer firmware updating
as maintenance. Do not claim complete Bose feature parity today.

## Existing local hardware evidence

See HARDWARE_CHECK.md and DEVICE_MANAGEMENT.md. Mode switching, existing custom
mode ANC/Wind Block editing, three-band EQ, battery/identity, saved host connect/
disconnect and multipoint work on this unit. Self Voice and shortcut configuration
write/read-back were verified; actual shortcut behavior for every choice was not.
Voice prompts read/write exists, but previous audible verification loop is a
reason to use deliberate single changes rather than automated repeat testing.

## Gaps worth pursuing

1. Auto-Off and Remember My Mode: official features of this model. Local reads
   [1.4]/[31.4] alone have not established write semantics. Capture baseline,
   change one option through Bose, compare independent reads, restore, then
   implement a bounded write/read-back test. Test persistence across physical
   power cycles. Auto-off additionally needs a real idle-time behavior test.
2. Custom mode creation/deletion/name choices: Bose documents two custom slots;
   upstream prince notes identify slots 2/3 and 39-byte writes. Editing an existing
   slot does not prove safe creation/deletion. Preserve full original records and
   validate the lifecycle before exposing it.
3. Product rename, voice-prompt language, stock EQ presets and paired-device
   removal: useful secondary parity. Need model-specific payload/behavior checks;
   do not use the Ultra language table or button matrix as verified prince data.
   Device removal requires a separately authorized test because it changes pairing.
4. Spotify Tap: configuration is not end-to-end functionality. Bose documents
   Spotify login/app requirements and app lifecycle constraints. Determine which
   app mediates it on iOS; no claim that changing shortcut bytes replaces this.
5. SimpleSync: official support includes this QC with Bose smart speakers and
   soundbars. This is a separate multi-product integration, unimplemented here.

## Firmware

Bose's model-specific update page currently lists 1.0.6 (14 September 2023) and
explicitly offers the computer Bose Updater as an alternative to its phone app.
This supports a path without the phone app, but we have not connected this QC to
the updater or independently checked a live update offer. The version listing
is not proof that no newer device/region-specific offer exists.

No validated prince BLE firmware updater was found in the reviewed projects.
bose-dfu tests older speakers and partially QC35 II, not this QC. Its existence
is not evidence of compatibility. Firmware transfer, image selection/validation,
resume and recovery are separate work; recommend the official updater instead.

## Before calling Bose optional

Verify the settings above that the user needs; test out-of-range and system
Bluetooth off/on recovery; resolve development-signing continuity (current
recorded profile expiry 30 October). Keep unsupported direct source routing
[4.12] visible; it returned ERROR 04 on this unit. No claim of Ultra-only ANC-off,
spatial audio, on-head sensing or new codecs based on another model's protocol.

## Sources

- Bose model-specific firmware/update guide: https://support.bose.com/s/article/quietcomfort-headphones-updating-your-headphones?language=en_US
- Official updater: https://btu.bose.com/
- Bose modes and last-used mode: https://support.bose.co.uk/article/qc-headphonearn-setting-the-adjustable-active-noise-cancellation-mode---ka08c000001bucxaaa
- Bose Auto-Off: https://www.bose.cn/zh_cn/support/articles/HC2462/productCodes/QC-HEADPHONEARN/article.html
- Bose language options: https://support.bose.co.uk/article/qc-headphonearn-changing-the-voice-prompt-language---ka08c000001buhoaaq
- Bose Spotify Tap: https://support.bose.ca/article/qc-headphonearn-using-spotify-tap---ka08c000001bxkcaai
  Caveat: this page says firmware 4.0.4 despite the model firmware page listing
  1.0.6. Treat this as a documentation inconsistency, not a firmware target.
- Bose SimpleSync compatibility: https://www.bose.com/help/using-groups
- Upstream prince protocol evidence: https://github.com/aaronsb/bosectl/blob/main/docs/quietcomfort-headphones-prince.md
- Broader (primarily Ultra 2) notes: https://github.com/aaronsb/bosectl/blob/main/NOTES.md
- Older-device USB updater and tested devices: https://github.com/tchebb/bose-dfu

Online claims distinguish official documentation, third-party reverse engineering
and this project's local hardware proof. Search results for 2nd Gen/Ultra/QC45
were excluded from claims about 884367-0100.

## Targeted power-settings investigation

- Existing physical prince report (build/v4-preferences-phone.json) reads Auto-Off
  [1.4] = 00 and DefaultMode [31.4] = 00. Neither was mapped to Bose's displayed
  setting at capture time. Do not label either based on this alone.
- bozo-proto's standby implementation writes a single byte of minutes with
  SETGET, e.g. 20 -> 14 hex. This targets QC Ultra, so it is supporting evidence
  for a prince test, not proof.
  https://github.com/NerdySouth/bozo/blob/main/crates/bozo-proto/src/protocol/standby.rs
- Independent QC45 investigation corroborates one-byte minutes and reports both
  one-byte timer and longer boolean-style [1.4] replies in the vendor parser.
  It also reports [31.4] mirroring current mode and warns that [1.14] CNC
  persistence did not control mode retention in its power-cycle tests. These
  are model-specific leads, not prince semantics.
  https://github.com/xinutec/volume/blob/3019ef9cbb5fb24a95b60afa04c58e093cc95444/docs/bose-read-surface.md
- Prepared DEBUG-only --inspect-power-preferences: five explicit GETs for
  [1.4], [1.14], [31.3], [31.4], [31.5], once per session; no writes, no recovery
  checkpoint, no audible verifier. Produces PowerPreferencesInspection.json.
  Not a new user-facing control.
- Next physical comparison: record original Bose timer/toggle, take baseline;
  change only Auto-Off and compare, restore; change only Remember My Mode and
  compare, restore. Only then consider a separately bounded write/read-back and
  physical behavior tests. Current mode must be tracked to detect mirrored data.

Physical baseline captured with signed build 20 at 21:25:16 UTC, 25 October:
model 884367-0100 / firmware 1.0.6-80+f5f219b; [1.4]=00, [1.14]=01,
[31.3]=00, [31.4]=00, [31.5]=01. Evidence: ignored
build/v20-power-baseline.json. Inspection build compiled/signature verified and
installed; launched once with the GET-only inspection flag, then relaunched
normally with no flags. Bose comparison pending: iPhone Mirroring requires
the user to enter their Mac password in its own window.

### Remember My Mode: official-app comparison completed

At 21:26–21:27 UTC on the physical standard QC, Bose showed Remember My Mode
ON. Switched it OFF through Bose once, took independent GET-only snapshot,
then restored ON through Bose and independently read again:

- ON baseline: [1.14]=01, [31.5]=01, [31.3]=00, [31.4]=00.
- OFF (21:27:07): [1.14]=00, [31.5]=00; current/default remain 00.
- ON restored (21:27:48): [1.14]=01, [31.5]=01; current/default remain 00.
- Auto-Off stayed [1.4]=00 throughout. No mode selection, EQ, voice prompt,
  multipoint or pairing settings changed by this comparison.

This maps Bose's toggle to both candidate boolean registers on prince; it
refutes treating [31.4] alone as this boolean. It does not prove which register
the Bose app writes, QuietControl's ability to write either, or power-on behavior.
Do not reuse the QC45 negative power-cycle finding as a prince conclusion.
Evidence: build/v20-power-baseline.json, build/v20-remember-off.json,
build/v20-remember-restored.json and build/power-settings-evidence/remember-*.png
(all ignored). Screenshots also confirm ON after returning to Bose.

### Auto-Off: official-app mapping

Bose visibly showed Never selected (retained screenshot auto-off-never.png).
Selected 20 Minutes through Bose; independent GET at 21:35:56 UTC returned
[1.4]=14 hex (20 decimal), with all four other probe fields unchanged.
Evidence: build/v20-auto-off-20.json. This confirms the minutes interpretation
for that selection on this prince firmware. Original Never was restored through Bose and visibly confirmed. A fresh
independent GET at 21:41:48 UTC confirms [1.4]=00. Remember My Mode fields
remain 01, with current mode unchanged at 00. Evidence: ignored
build/v20-power-restored.json and power-settings-evidence/auto-off-restored-never.png.

The in-app list observed: 5, 20, 40 minutes; 1 hour; 3 hours; Never. Only Never
and 20 minutes have been directly compared so far. No claim that the real idle
shutdown timer or QuietControl write support has been tested.

Investigation completed with both originals restored: Auto-Off Never, Remember
My Mode On. QuietControl build 20 relaunched normally without inspection flags.
Next implementation step is bounded write/read-back verification; real idle
shutdown and power-cycle persistence still need physical testing. No new
user-facing controls have been enabled.

## QuietControl write verification completed, builds 21/22

Physical standard QC, 25 October 2026, same firmware.

- Auto-Off [1.4] SETGET one byte: 00 -> 14 -> 00, each independently GET
  confirmed. Build-21 report: build/v21-power-proof.json; wire log
  build/v21-power-session.json.
- IMPORTANT distinction: [1.14] accepts and reads back 00 but leaves [31.5]=01.
  The build-21 cross-check correctly failed and restored [1.14]=01. Do not use
  [1.14] alone as the Remember My Mode writer.
- Correct writer: [31.5] SETGET 00 -> GET 00 also makes [1.14]=00. Restoring
  [31.5] SETGET 01 -> GET 01 restores both fields to 01. Build-22 report
  build/v22-power-proof.json passes; current mode remained 00.
- Final fresh inspection at 21:50:30 UTC: Auto-Off 00, [1.14]=01, [31.5]=01,
  current/default mode 00. Evidence: build/v22-power-restored.json. All evidence
  reports are ignored. QuietControl relaunched normally without flags afterward.
- Tests are explicit DEBUG launch checks, restricted to this model/firmware and
  specific setting addresses; once-per-session gate prevents reconnect replay.
  Original value journal saved before each write, exact original restored after
  candidate success or failure; incomplete journal blocks another test. No
  automatic startup writes or voice-prompt writes were added.

This establishes setting write/read-back support, not a timed idle shutdown or
physical power-on behavior. No user-facing controls added yet. UI implementation
should use [31.5] for Remember My Mode (replace the old unused [31.4] guess).

## User-facing power controls, build 23 (26 October 2026)

Headphone Settings → Power now offers Auto-Off ([1.4]) and Remember My Mode
([31.5]) through the confirmed preference write path, gated to this model and
firmware. No new hardware writes were performed when adding them. Values other
than Never/20 minutes, idle shutdown and power-on behavior remain untested.
