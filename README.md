# QuietControl

A small, open-source iPhone remote for **Bose QuietComfort Headphones** (standard
model / prince), built with SwiftUI for iOS 17+. It controls the headphones
directly through public CoreBluetooth APIs. No account, server, or Mac bridge.

## Everyday controls

Home prioritizes the things used most often:

- Compact battery and control-connection status. The battery has proportional
  fill: green at 50–100%, yellow at 20–49%, and red below 20%.
- Matching Focus/Aware cards above a full-width Quiet card. Actual configured
  mode names come from the headphones; additional modes appear below. Tap to
  switch, or hold any mode to open its editor directly.
- The QC's paired audio devices, with their names, connection switches and
  confirmed active-audio state. A pending switch stays on its last confirmed
  value until the headphones answer an independent read.
- An occupied-slot chooser before replacing a connected device.
- Devices menu: Refresh, multipoint on/off, and confirmed **Disconnect all audio
  devices**. The last action disconnects audio while retaining the BLE remote.
- A separate Equalizer page: drag the three points on the Bezier curve to adjust
  bass/mid/treble from −10 to +10. Values update while dragging and writes happen
  on release. Reset and locally saved personal presets live on this page.
- A direct custom-mode editor with a Bose-style filled ANC bar, Wind Block and
  explicit Save/Cancel. Fixed Quiet/Aware settings remain read-only. Wind Block
  forces maximum cancellation on this firmware.
- Grouped Headphone Settings for Self Voice, the button shortcut, voice prompts,
  Auto-Off, Remember My Mode, auto-connect and multipoint. About and diagnostics sit deeper in Settings.
  Dark appearance uses charcoal surfaces and a mint accent; light appearance
  remains supported. The Home row summarizes current EQ.

EQ is stored on the headphones and shared with the Bose app. Opening QuietControl
preserves the settings. Curve writes occur on release; failed changes return to
the last confirmed value. The curve is a visual summary, not a frequency-response
measurement.

The BLE control link is retained when the app backgrounds. When the QC disappears,
one CoreBluetooth connection request waits for its return. After eight seconds,
Home shows **Waiting for QC** without a spinner. The menu's **Pause auto-connect**
preference survives relaunches. A disconnect alone cannot prove the power switch
was used, so the app does not claim the headphones are powered off.

Home keeps a fixed status area and four compact device rows. Extra devices open
in **View all**. Larger accessibility text and shorter screens can scroll.
Confirmed modes, paired names, EQ, identity and last-seen details are saved locally
in Application Support using a versioned, atomic file excluded from backup.
Offline values remain visible and read-only; connection indicators and battery
are not presented as live. Corrupt or incompatible data falls back to setup.
Background reads keep the dashboard usable; a tap during a read waits its turn on
the Bluetooth connection. Action results use small bottom toasts with action-specific text and icons,
a short fade/slide animation, and a fade-only Reduce Motion alternative. The
compact Home EQ row shows a miniature curve with values at its three points.

iOS controls background execution and relaunch eligibility; force-quitting is
different from switching apps. No account, network service or notification
permission is needed.

This firmware rejects the separate direct source-routing function. Choose which
hosts are connected here, then start playback on the connected host you want to
hear. QuietControl does not show an unsupported “Use audio” action.

Auto-Off ([1.4], minutes; 0 = Never) and Remember My Mode ([31.5]) are under
Headphone Settings → Power, enabled only for model 884367-0100 firmware
1.0.6-80+f5f219b, where write/read-back was verified. Every change is confirmed
by an independent read. Only Never/20 minutes and On/Off were written on the
hardware; the timed shutdown and power-on mode behavior are not yet tested. True ANC off, adding/removing modes or pairings, firmware updates,
widgets and other headphone models remain outside this update. The button
shortcut supports battery level, Spotify and off; Spotify needs its app.
The shortcut command was read back on this QC; physical long-press behavior
for every choice still needs listening/button testing.

## Hardware verification

Direct iPhone control was proven on 23 October 2026 using an iPhone 15 Plus and
Bose QuietComfort model **884367-0100**, firmware **1.0.6-80+f5f219b**.

The actual phone check read battery, current mode, all EQ bands and configured
modes; switched Quiet/Aware; changed bass by one step; and confirmed restoration
of the original mode and EQ. See [the acceptance record](docs/HARDWARE_CHECK.md)
for measured results and checks that still need manual listening/device testing.
Device packet formats and the audio/control distinction are documented in
[device management](docs/DEVICE_MANAGEMENT.md).

This supports the observed standard QuietComfort 884367 model family. The app
checks manufacturer, model, firmware and the prince mode layout. It does not
claim QC45, Ultra or earbud support.

## Install and run

Before installing an updated app build, run `./scripts/verify.sh preinstall`.
Routine tests run on the Mac's simulator, leaving your real phone available.
iPhone Mirroring is reserved for specific device-only investigations or requested
hardware acceptance. After the gate passes and installation is authorized, use
the app normally and report anything wrong; a separate Mirroring QA session is
not required. See [the testing policy and commands](docs/testing/README.md).

1. Open `QuietControl.xcodeproj` in Xcode and sign in under **Settings → Accounts**.
2. Copy `Configuration/Local.xcconfig.example` to `Configuration/Local.xcconfig`
   and enter your Developer team ID, or select a team in Signing & Capabilities.
3. Select your iPhone and Run the **QuietControl** scheme.
4. For a first setup, turn on your QC and connect it in iPhone **Settings →
   Bluetooth**. Tap **Find my QuietComfort**, allow Bluetooth, select the QC in
   Connection inspection, then tap **Done**.
5. Run **Verify controls** once for a newly selected headphone/firmware combination.
   This briefly switches modes and changes one bass step, restores the starting
   values, and checks them. Mode/EQ controls unlock after the check succeeds.
6. For a new QC/firmware, **Check device controls** verifies connect/disconnect and
   multipoint, restoring the starting connections. Audio briefly stops during
   this explicit check; playback may need resuming afterward. Only confirmed
   device capabilities are enabled.

The app identifier is `uk.co.mzbali.quietcontrol`. Existing installations retain
their selected QC and verification when updated. If the verification is
interrupted, a local checkpoint restores the original bass and mode on the next
connection to that same QC.

## Build and IPA

```sh
./scripts/test.sh                # Focused BMAP and BLE framing tests
./scripts/build.sh simulator    # Simulator build; hardware Bluetooth needs iPhone
./scripts/build.sh device       # Development-signed iPhone app
./scripts/build.sh archive      # Signed IPA: build/Export/QuietControl.ipa
./scripts/build.sh unsigned     # Unsigned IPA for a separate signing workflow
```

Scripts select `/Applications/Xcode.app/Contents/Developer` by default; override
`DEVELOPER_DIR` to use another Xcode. Device/archive commands allow Xcode to update
development provisioning. A signed development IPA works only on devices covered
by its embedded profile, and needs re-signing before that profile expires. No
personal team ID, certificate or provisioning profile is committed.

## Connection and protocol

The successful route is the Bose **FEBE BLE service**, using its documented
secure read/write/notify characteristic. The documented plain characteristic is
a fallback if the secure endpoint cannot establish a BMAP session. Notifications
are reassembled using Bose's BLE envelope, then decoded as BMAP. This uses no
private iOS APIs.

- `App/QuietComfortSession.swift`: serial commands, bounded timeouts, identity
  checks, device state, read-back verification and interrupted-check recovery.
- `App/QuietControlView.swift`: everyday modes, battery and EQ.
- `Packages/QuietComfortCore/`: shared BMAP/prince codec and BLE segmentation,
  with independent SwiftPM tests. Xcode compiles the same source files directly.

The original RFCOMM transport in bosectl is not used on iPhone. Prince's
device-specific settings come from bosectl; the public BLE service, characteristic
IDs and envelope come from bozo. Upstream versions are pinned and both MIT
licenses are preserved in [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md), the app
resources, and **Device & about → Open-source licenses**.

## Local reports

Reports stay in **Files → On My iPhone → QuietControl**; nothing uploads them:

- `LatestProbe.json`: connection inspection and standard device metadata.
- `SessionDiagnostics.json`: latest BLE session, replies and timing.
- `ControlProof.json`: latest explicit mode/EQ verification, including restoration.
- `DeviceControlProof.json`: device-action checks, restoration and any limitations.
- `DeviceRecovery.json`: temporary checkpoint for interrupted connection checks.
- `ModeEditingProof.json`: custom-mode strength/Wind Block and restoration check.
- `ModeEditRecovery.json`: checkpoint for an interrupted mode editing check.
- `HeadphonePreferences.json`: latest preference read report.
- `PreferenceProof.json`: Self Voice/shortcut write and restoration check.
- `PreferenceRecovery.json`: checkpoint for an interrupted preference check.
- `PendingRestoration.json`: temporary recovery checkpoint, removed after restoration.

Connection inspection is under the More menu. Unknown services are inventoried
without arbitrary reads or writes. Serial-number reads are omitted. Generated
reports, build products and local signing settings are ignored by Git.

MIT licensed. Independent project, not affiliated with Bose.
