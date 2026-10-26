# QuietControl: next controls and layout proposal

Draft for discussion, 25 October 2026. No app implementation changes are approved
by this document. Agree on the layout and interactions before changing SwiftUI.

## Intent

Add useful headphone controls while preserving the compact Home. More supported
features should not mean more dashboard tiles, duplicated controls or technical
options in everyday use. Keep the existing muted green accent, native typography,
readable controls, accessible scrolling and clear connection state.

## Bose app inspection

Inspected the actual Bose app through iPhone Mirroring on the paired iPhone 15
Plus. These observations establish the official UI, not working commands in
QuietControl.

- Home: volume, Modes, Source, EQ, Shortcut, Tips and Product Support.
- Modes: Quiet, Aware and Focus; custom-mode creation; editable noise-control
  strength and Wind Block. Quiet's noise strength is locked.
- Mode names include Commute, Focus, Home, Music, Outdoor, Relax, Run and Walk.
  This was not an exhaustive enumeration of the scrolled name list.
- Remember My Mode: enabled; described as using the last mode at power-on.
- Self Voice: High, Medium, Low, Off. Medium selected.
- Auto-Off: 5, 20, 40 minutes; 1 hour; 3 hours; Never. No selected timer was
  reliably established during inspection.
- Voice Prompts: disabled; displayed language English.
- Shortcut: enabled, Hear Battery Level selected; Spotify also offered.
- EQ: bass -1, mid +4, treble +2; Bass Boost/Reducer and Treble Boost/Reducer
  presets. Preset values were not measured or applied.
- Sources: multipoint on, four saved devices, active-stream indication,
  Add New and Edit. No pairings or audio connections were changed.
- Settings also includes product name, product update, tips and technical info.

Capture caveat: devicectl captured Home before Mirroring, but returned black
images while Mirroring was active. Those unusable files were removed. Visible
screenshots were inspected in the conversation; retained local reference images
are in ignored build/bose-app-reference (Home, Settings top, Shortcut, Remember
My Mode, original/restored Modes, EQ and Sources). The lower preference pages and
custom-mode editor were visually inspected but their direct-capture files were
black, so they are not claimed as retained screenshots.

Inspection side effect: choosing Commute in the new-mode name picker immediately
created and selected it, before Done. It was removed during cleanup; the original
Quiet/Aware/Focus list and selected Quiet were visually verified afterward. EQ
was then observed unchanged at -1/+4/+2. Future inspection must treat mode-name
selection as an immediate write, and any new editor should use explicit Save.

## Proposed structure

### Home: everyday actions

Preserve the status header, live battery, Focus/Aware and full-width Quiet,
compact device rows and Equalizer summary. Preserve the existing per-device
connection switches and occupied-slot flow. Do not add a headphone hero image,
playback card or another block of settings tiles.

User-reviewed direction: tap a Home mode to switch; long-press it to open its
editor directly. No separate mode-management page or Manage button. Long press
must not also trigger the normal tap action. Provide a VoiceOver Edit action,
and a subtle initial Hold to edit hint. Quiet/Aware open fixed-mode details.

Use one navigation-bar settings entry. Connection details remain available from
the status header. Auto-connect, technical information and diagnostics move into
the settings hierarchy instead of growing the current More menu.

### Mode editor: direct from Home

Long-press any actual Home mode to open its own editor. Quiet/Aware explain their
fixed behavior and do not offer unsupported edits. Editable custom modes show
strength and Wind Block. Creation/deletion remain deferred; their future entry
point needs review without adding a mode-management page.

The custom-mode editor contains the name and a Bose-style noise-control bar:
a wide rounded rectangle, gray fill indicating strength, subtle top/bottom ticks
and centered Noise Cancellation label. Drag across the whole bar; no thin track
or visible slider thumb. Fixed Quiet/Aware details show a lock. Include Wind
Block for editable modes with a short explanation. Match
the headphone's actual Wind Block behavior after verification; do not assume
that its interaction with ANC strength is independent. No spatial audio or ANC
off control is included for this hardware.

Changes stay in a draft until Save. Cancel discards the draft. Read back the
entire mode after a write, preserve unrelated configuration bytes, show failures
inline, and never save an edited mode merely by navigating back. Do not promise
live listening previews in this first version.

Remember My Mode belongs in Headphone Settings so the editor remains focused.

### Equalizer: keep its own page

Use the Bezier curve itself as the three-band control: drag each point vertically
in integer steps from -10 to +10, with large invisible touch targets and live
numeric labels. No duplicate band sliders or adjustment buttons. Provide native
VoiceOver adjustable actions and commit on release. Keep the dedicated EQ page
reachable from Home. Add a compact Presets entry
on that page, opening a short list. Start with saving and naming the user's own
confirmed EQ. Replicate Bose's four factory presets only after their actual band
values are known. Selecting a preset must use the existing serialized writes,
confirm all three bands, and retain a way back to the previous confirmed values.

### Headphone Settings: occasional preferences

Use a native grouped list, without marketing artwork or a grid:

- Listening: Remember My Mode, Self Voice.
- Headphones: Auto-Off, Button Shortcut, Voice Prompts.
- Connection: multipoint and auto-connect behavior.
- About: identity, firmware and notices; Diagnostics one level deeper.

Each row shows a confirmed value or an explicit loading/unavailable state.
Longer choices open a dedicated detail page. Keep explanatory text on those
pages, not repeated under every settings row. Product rename can be considered
later; firmware updates remain in the official Bose app.

## Behavior across states

- Offline: preserve confirmed values as saved/read-only, indicate they are not
  live; never invent current preferences from defaults.
- Reconnecting: keep layout stable and preserve the existing quiet waiting flow.
- Background read: controls remain available; user actions queue serially.
- Save pending: show progress only for the action being confirmed; avoid dimming
  the whole dashboard.
- Larger text: allow content to expand and scroll; do not shrink text or targets.
- Unsupported: omit the everyday control; explain relevant limitations in About.

## Delivery order and evidence

1. Review the visual proposal and navigation together. No UI implementation yet.
2. Investigate read commands for the settings already seen in the Bose app.
   Show current values in a development report before introducing writes.
3. Verify reversible editing of the existing Focus mode: strength and Wind Block,
   independent read-back and restoration. Then implement the approved editor.
4. Verify and add Remember My Mode, Self Voice, Auto-Off, voice prompts and button
   shortcut individually. Do not make the presence of an official UI a capability
   gate for our implementation.
5. Add saved EQ presets; defer custom-mode creation/deletion until their full
   protocol and recovery semantics are verified.

The design preview is illustrative. Its settings rows are proposed destinations,
not claims of currently implemented or hardware-verified controls. Device names
in it are generic placeholders. Maintain the existing direct-routing limitation;
connect hosts and start playback there. Widgets, firmware update implementation,
true ANC off and other headphone models are outside this proposal.

## Review criteria

At normal iPhone 15 Plus text size, Home still fits comfortably with three modes,
four devices and an EQ summary. Use consistent native outline device icons
(iphone, laptopcomputer, desktopcomputer), with a generic device fallback when
the class is unknown. Names remain the primary identification. Additional
features add no new Home sections.
Everyday actions remain one tap. Editing opens directly on long press and retains explicit
Save/Cancel. Review Home, editor, Settings, EQ and offline/larger-text
states before implementation; the initial interactive HTML is a layout sketch,
not pixel-perfect native or accessibility acceptance.
