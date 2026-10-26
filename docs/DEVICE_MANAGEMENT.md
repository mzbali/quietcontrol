# Standard QC device management

Observed on model 884367-0100, firmware 1.0.6-80+f5f219b, through FEBE BLE.
Addresses below are placeholders; local phone reports contain the original values
and are Git ignored. No pairing entries are removed or cleared.

## Read formats

- `[4.4] GET`: one connection-mask byte, followed by six bytes per paired address.
  The leading byte is not the number of devices. Four addresses were returned.
- `[4.5] GET <six-byte address>`: address, status, two classification bytes, UTF-8
  name. Status bit 0 is audio connected; bit 1 identifies this controller.
  All four states matter: 0 disconnected, 1 connected, 2 this controller with
  audio disconnected, 3 this controller with audio connected. State 2 was
  observed after disconnecting iPhone audio while BLE control stayed available.
- `[5.1] GET`: two supported-source bytes, source type, then six address bytes for
  Bluetooth type 1. Types 0/2 have no Bluetooth address. A cached source does not
  make a disconnected device connected.
- `[1.10] GET`: state is **bit 0**. The actual unit returned 07 on, 06 off.
  Treating bit 1 as the switch is incorrect for this firmware.

## Actions and confirmation

- Connect: `[4.1] START 00 <address>`.
- Disconnect: `[4.2] START <address>`.
- Multipoint: `[1.10] SETGET <00 or 01>`, followed by an independent GET.
- Preserve address wire order exactly; do not reverse a display-form MAC.
- Processing/Result packets acknowledge a transaction, not its final state.
  Read `[4.5]` until the requested audio connection is independently confirmed.
- Disconnecting this controller's audio can apply without a matching action
  reply. Only connection actions have a short optional acknowledgement window;
  a missing reply is never accepted as proof that the action worked.
- Multipoint enable can initiate a late remembered-host connection. Recovery
  removes extra connections and requires two snapshots matching the baseline.
- `[4.12]` direct routing returned `ERROR 04` (function not supported). It is not
  offered as a working control. Start playback on the preferred connected host.

- While the QC pages an unreachable host after `[4.1]`, other connect requests are
  rejected with `ERROR 08` for roughly 15–20 s (observed 26 October 2026, build 26).
  A failed replacement therefore sends `[4.2]` for the unreachable target, then retries
  restoring the previous host every 3 s, at most 8 times. Observed: restored after ~17 s.

`DeviceRecovery.json` checkpoints a hardware check before any write. Recovery
restores the starting connected set and multipoint, not media playback. Resuming
playback may require the user. Normal user connection changes are not rolled back
as temporary tests. A failed replacement attempts to restore the old connection.

## References

Wire descriptions were cross-checked against actual phone replies:

- [bosectl DeviceManagement notes](https://github.com/aaronsb/bosectl/blob/70570b29c1d3c9ba775b08a29eaea72385de27b5/NOTES.md)
- [BoseConnect Linux packet definitions](https://github.com/bosefirmware/BoseConnect-Linux_based-connect/blob/master/based.c)
- [Independent Bose protocol investigation](https://github.com/xinutec/volume/blob/3019ef9cbb5fb24a95b60afa04c58e093cc95444/docs/bose-read-surface.md)

The Swift implementation is independent. These references establish wire facts;
the codecs and capability gates are validated on this specific standard QC.
