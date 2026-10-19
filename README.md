# Huawei Audio Control for Mac

An unofficial macOS menu bar app for **HUAWEI and HONOR audio devices** that use
the Huawei serial control protocol. It talks to the earbuds over their Bluetooth
Classic serial channel (RFCOMM/SPP), so it can change settings that macOS itself
does not expose.

The app does not scan for or pair devices; pair the earbuds with the Mac in
**System Settings → Bluetooth** first. Pairing and audio work as usual; this app
only adds the control channel.

The device tables, command definitions and protocol algorithms are ported from
[OpenFreebuds](https://github.com/melianmiko/OpenFreebuds), which supports every
device listed below. See [License](#license) for the resulting GPL-3.0 terms.

## Supported models

The app has a capability profile for every audio model in OpenFreebuds' device
map. The same profile can cover several marketing names:

| Device names | Profile highlights |
| --- | --- |
| HUAWEI FreeBuds 3 | Battery and in-ear state, double-tap actions. No ANC or EQ. |
| HUAWEI FreeBuds 4i, HONOR Earbuds 2 / 2 SE / 2 Lite | ANC on/off (no strength levels), auto-pause, double-tap, left long-press, noise-control cycle. |
| HUAWEI FreeBuds 5i | ANC with four strengths, EQ presets, double/triple/long-press/swipe gestures, noise cycle, auto-pause, low latency, sound preference, in-ear state. |
| HUAWEI FreeBuds 6i | Same as the 5i, plus custom EQ presets stored on the device. |
| HUAWEI FreeBuds Pro | ANC with four strengths and voice boost, long-press and swipe gestures, noise cycle, in-ear state. No EQ, auto-pause or low-latency control. |
| HUAWEI FreeBuds Pro 2 | ANC with three strengths, EQ (Default / Hard Bass / Treble), long-press and swipe gestures, auto-pause, sound preference. |
| HUAWEI FreeBuds Pro 3 / Pro 4, HUAWEI FreeClip | ANC with four strengths and voice boost, renumbered EQ presets plus custom presets, double-tap/long-press/swipe gestures, auto-pause, low latency, sound preference. |
| HUAWEI FreeBuds Pro 5 | Same profile as Pro 3/4 and FreeClip, including custom EQ. |
| HUAWEI FreeBuds SE | Battery, double-tap actions. No ANC, EQ, in-ear state or multi-tap gestures. |
| HUAWEI FreeBuds SE 2 | EQ, double/triple-tap, in-call long-press, low latency. No ANC or in-ear state. |
| HUAWEI FreeBuds SE 4 ANC | ANC with four strengths, EQ, double/triple-tap, long-press with assistant/volume actions, low latency. |
| HUAWEI FreeBuds Studio | Over-ear battery level, ANC with four strengths and voice boost, auto-pause, EQ presets. EQ writes are not read back by this firmware. |
| HUAWEI FreeClip 2 | Double/triple-tap, long-press with extra actions, swipe, EQ, auto-pause, low latency, sound preference, in-ear state. No ANC. |
| HUAWEI FreeLace Pro | Neckband battery level, ANC with three strengths, combined long-press noise cycle, power-button double-tap. |
| HUAWEI FreeLace Pro 2 | Neckband battery level, ANC with four strengths and voice boost, custom EQ, left long-press, noise cycle, low latency, sound preference. |

Controls that a profile does not support are hidden rather than shown as broken
switches. Some models expose the same data under different preset IDs or store
the long-press action differently; those differences live in
`DeviceProfile.swift`.

### Model detection

Automatic mode resolves the model in this order:

1. The Bluetooth name (for example `HUAWEI FreeBuds 6i`).
2. The hardware model code read from the earbuds, when the code is known. The
   code `BTFT0014` is shared by the FreeBuds 5i and SE 2, so it resolves to the
   5i profile.
3. The FreeBuds 6i profile as a compatibility fallback for renamed devices.

Because the Bluetooth name can be changed, **Settings → Device → Model** offers
an explicit override. Set it when the earbuds have a custom name and automatic
detection picks the wrong profile. Choose **Automatic** to return to detection.
The override takes effect immediately if the app is connected.

## Features

- **Noise control** — Off, Noise cancelling, and Awareness, with the strengths
  and voice-boost option the selected model actually supports.
- **Battery** — left bud, right bud, and charging case on true-wireless models;
  a single battery level on FreeBuds Studio and FreeLace headsets. Charging
  indicators are shown per component where the model reports them.
- **Equalizer** — the built-in presets reported for the model, plus custom
  presets stored on the device for models that support them. Custom presets can
  be selected but not created or edited.
- **Gestures** — double-tap and triple-tap per earbud, press-and-hold action,
  swipe action, power-button action, and the per-side noise-control cycle where
  the model supports them.
- **Device behaviour** — auto-pause (wear detection), low-latency mode, and
  sound preference (sound quality vs. connection stability), when available.
- **Device information** — Bluetooth name, hardware model code, firmware,
  hardware revision, serial number, and per-bud in-ear status.
- **Menu bar controls** — optional lowest-bud battery percentage next to the
  icon; the menu bar panel can connect, refresh, and disconnect.
- **Launch at login** and a configurable polling interval (10–120 seconds).

Writes are normally read back from the earbuds before the UI reports success. If
the earbuds reject or ignore a change, the previous value stays on screen and an
error banner explains what happened. Some firmware gates settings on wear; for
example, cancelling-strength changes on the FreeBuds 6i must be made while the
earbuds are in your ears. FreeBuds Studio is the one write-only exception: its
firmware accepts EQ preset writes but never reports the active preset.

## Requirements

- macOS 14 (Sonoma) or later
- Bluetooth enabled
- A supported HUAWEI/HONOR audio device already paired with the Mac

Only the FreeBuds 6i has been tested on physical hardware in this project. Its
current profile-driven build passed reads, writes, custom EQ, reconnect, in-ear
state and on-ear ANC strengths on firmware
`HarmonyOS 6.0.0.292(F001H003C90)`. The other profiles are ported from
OpenFreebuds' per-model handlers and pass static capability/protocol tests, but
they have not been verified against each model. Please report the model,
firmware, and any command that behaves differently. Wear-dependent controls such
as ANC strength and in-ear state should be checked with the earbuds in your
ears.

## Build and install

```bash
./build.sh
```

`build.sh` compiles a release build, generates the app bundle, copies the icon,
ad-hoc signs it with the sandbox and Bluetooth entitlements, and writes an
installer disk image to `releases/`. The GPL license and third-party notice are
copied into the app bundle alongside the icon.

```bash
open releases/HuaweiAudioControlMac-1.0.0.dmg
```

Drag **Huawei Audio Control** into **Applications** in the mounted image. The
disk image contains the app and an Applications shortcut. Because the build is
ad-hoc signed, Gatekeeper may require **right-click → Open** the first time.

To run it directly from the build tree instead:

```bash
open .build/release/HuaweiAudioControlMac.app
```

Launch at login uses `SMAppService`, which requires the app bundle to live in
`/Applications` **and** to be signed with a Developer ID identity. Ad-hoc
development builds produced by `build.sh` still run, but macOS rejects their
login-item registration (`Operation not permitted`), so the toggle stays off and
the app explains why. With a properly signed build, macOS may ask you to approve
the login item in **System Settings → General → Login Items**.

## Usage

1. Pair the earbuds with the Mac in **System Settings → Bluetooth** and make
   sure they are connected.
2. Launch the app. macOS asks for Bluetooth permission the first time; allow it.
3. Click the earbuds icon in the menu bar.
4. The app connects automatically. If it does not, open the **Device** tab and
   choose **Connect**.
5. Use the **Sound**, **Gestures**, and **Device** tabs. Controls are disabled
   while the earbuds are disconnected.
6. If automatic model detection picked the wrong profile, open **Settings** and
   choose the model under **Device**.
7. Choose **Quit** in the panel footer to release the control channel cleanly.

The earbuds allow only one control session at a time. If the Huawei phone app or
another copy of this app is connected, disconnect it there and try again.

## How it works

### Bluetooth transport

The app uses `IOBluetooth` and the classic Serial Port Profile:

1. Find the paired earbuds (remembered address first, then a name heuristic).
2. Bring up the ACL link if needed.
3. Resolve the SPP service (`0x1101`) and open its RFCOMM channel. Some models
   use RFCOMM port 1, others port 16. SDP is authoritative; the model's known
   port is only a fallback when the SDP record is incomplete. The earbuds also
   advertise a decoy "Private COM" service on some firmware.
4. Send one framed request at a time and wait for a matching response.

No BLE/CoreBluetooth control channel is used. macOS keeps the audio link up
while the app only opens and closes the RFCOMM control channel.

### Frame format

```
5A | length (2, big-endian) | 00 | command (2, big-endian) | TLV… | CRC16 (2, big-endian)
```

- `length` covers the command, the TLV payload, and one extra byte.
- Each parameter is `key (1) | size (1) | value (size)`.
- The checksum is CRC-16/XMODEM over every preceding byte.
- Frames can be fragmented or concatenated; `FrameDecoder` resynchronises on the
  header and validates every checksum.

Shared command definitions and enums live in `Protocol.swift`. The per-model
capability table, fallback ports, detection aliases and gesture code maps live
in `DeviceProfile.swift`. The command set follows OpenFreebuds' Huawei drivers,
including split vs. combined long-press storage, ANC level/mode byte order,
auto-pause command IDs, in-ear parameter keys, EQ preset numbering and
sound-preference response layout.

### Source layout

```
Sources/HuaweiAudioControlMac/
├── App.swift             MenuBarExtra scene and app lifecycle
├── Protocol.swift        Frame codec, command IDs, enums and presets
├── DeviceProfile.swift   Per-model capabilities, detection and gesture maps
├── BluetoothLink.swift   Paired-device lookup, RFCOMM session, request gate
├── DeviceState.swift     Snapshot parsing, polling, setters and read-back
├── Panels.swift          Sound, Gestures and Device panels
├── MenuBar.swift         Menu panel, settings, preferences
├── Artwork.swift         Earbud glyphs and menu bar image
├── Glass.swift           Shared cards, chips, meters and buttons
└── LoginItem.swift       SMAppService login-item handling
```

### App icon

The icon is drawn with Core Graphics rather than composed from SF Symbols:

```bash
swift Tools/make-icon.swift
```

This regenerates `Resources/AppIcon.iconset`, `Resources/AppIcon.icns`, and the
1024 px preview at `Resources/AppIcon-1024.png`. `build.sh` copies the `.icns`
into the app bundle.

## Settings

- **Model** — automatic detection, or a manual profile for renamed devices.
- **Launch at login** — registers the app with `SMAppService`.
- **Show battery in the menu bar** — shows the lower of the two bud levels, or
  the single level on non-TWS models.
- **Refresh interval** — how often battery, noise state, EQ and gesture settings
  are polled. The earbuds answer one request at a time, so very short intervals
  can make changes feel sluggish.

Preferences are stored in the app's standard `UserDefaults` domain. The paired
device address is remembered after a successful connection so a renamed pair
continues to work.

## Troubleshooting

### "Pair your earbuds in System Settings › Bluetooth first"

The app could not find a paired device. Pair the earbuds in System Settings,
make sure they are connected, then reopen the panel.

### Connection times out or the earbuds do not answer

Another phone, tablet, or app may own the control channel. Disconnect the
earbuds there, or disable Bluetooth on that device temporarily, then choose
**Connect** again. Huawei earbuds allow only one control session at a time.

### The first connection times out

A previous process may still hold the RFCOMM channel. Quit any older copy of the
app (`pgrep -fl HuaweiAudioControlMac`), toggle Bluetooth off and on, and retry.

### The app connects but the controls are wrong for my model

The Bluetooth name may have been changed, or the hardware code may be ambiguous.
Open **Settings → Device → Model** and select the correct profile.

### Controls are greyed out

The panel disables controls until the control channel is open. Check the status
line in the header and the **Device** tab.

### The menu bar icon is missing

The icon may be hidden by a notch or by menu bar overflow. Quit other menu bar
apps or use a menu bar manager to reveal it. The process can be checked with:

```bash
pgrep -fl HuaweiAudioControlMac
```

### Launch at login does not stay enabled

Move the app to `/Applications`, enable the item again, and approve it in
**System Settings → General → Login Items**. If registration is rejected with
`Operation not permitted`, the bundle is ad-hoc signed: `SMAppService` only
accepts Developer ID-signed apps for the main-app login item.

## Privacy

- The app is sandboxed and requests only the Bluetooth device entitlement.
- It has no network entitlement and makes no network requests.
- No analytics, telemetry, accounts, or cloud services are used.
- Settings and the remembered device address stay in local `UserDefaults`.

## Limitations

- Only the FreeBuds 6i has been hardware-tested. Other models rely on the
  OpenFreebuds protocol definitions and need confirmation on real devices.
- No device scanning, pairing, or multi-device switching UI.
- Dual-connection management and voice-language selection are available in
  OpenFreebuds but are not exposed by this app yet.
- No firmware update support.
- Custom EQ curves are read from the earbuds but cannot be created or edited.
- OpenFreebuds' synthetic "fake" built-in EQ presets for the 6i are not added;
  the app only shows presets the device or profile reports.
- "Find my buds" is not implemented.
- Protocol behaviour can change between firmware versions. The UI only reports
  values the earbuds actually return.
- Only one process can hold the earbuds' control channel at a time.

## Contributing

Bug reports and hardware test results are welcome. A useful report includes the
model and marketing name, the Bluetooth name, the hardware model code, the
firmware version, the macOS version, the app build, and which control failed or
read back incorrectly. Please do not include your device serial number.

When a control is hidden, check **Settings → Device → Model** before reporting
it: an automatic profile may have resolved a renamed device incorrectly.

## Credits

The protocol work builds on the publicly documented reverse engineering in the
[OpenFreebuds](https://github.com/melianmiko/OpenFreebuds) project and the
community work around Huawei audio devices. The per-model handlers there are
the reference for this app's profiles, commands and gesture tables. Apple's
`IOBluetooth` and SwiftUI provide the macOS integration.

This is an unofficial project and is not affiliated with or endorsed by Huawei
Technologies Co., Ltd. or HONOR.

## License

GNU General Public License, version 3 (GPL-3.0). See [LICENSE](LICENSE) and
[NOTICE](NOTICE).

This project contains protocol data, command definitions and device-handling
algorithms derived from OpenFreebuds, which is licensed under GPL-3.0. The
combined work is therefore distributed under GPL-3.0. If you redistribute a
binary, you must also make the corresponding source code available under the
same license. There is no warranty, to the extent permitted by law.
