# SuperAV

A tiny always-on-top macOS menu utility for controlling audio and display brightness without digging through System Settings or juggling separate apps.

## Why

Day-to-day desktop audio/video setups on macOS often need a few small, repetitive adjustments: nudging stereo balance, restarting [SoundSource](https://rogueamoeba.com/soundsource/) when it gets into a bad state, and setting brightness per-display since macOS doesn't expose that as a single system-wide control. SuperAV bundles those into one small floating window with keyboard shortcuts, so they're a keypress away instead of a few menu clicks each.

It's a personal utility built for a single-machine, local workflow — not intended for the Mac App Store (see [Brightness compatibility](#brightness-compatibility) below).

## Features

- **SoundSource** — Kill, reStart, or Toggle the SoundSource app. Kill and reStart ramp the system output volume down first and restore it afterward. Toggle changes the app's running state without touching volume.
- **Audio Balance** — Set the default macOS output device's stereo balance on a `0–100` scale (`0` is left, `50` is a center detent, and `100` is right).
- **System Volume** — A slider for the default output device's volume, kept in sync with the volume keys and other apps.
- **Display Brightness** — A separate `0–100` slider for each active display, tracking brightness changes made outside SuperAV, with preset buttons per display (the built-in display gets `0/5/50/75/100`, external displays get `0/40/60/80/100`). Connected-display changes are detected while the app is open.

## Requirements

- macOS 26 (Tahoe) or later
- Xcode (for building — see [Build and run](#build-and-run))
- [SoundSource](https://rogueamoeba.com/soundsource/) installed, for the SoundSource controls specifically (the audio balance, volume, and brightness controls work without it)

## Build and run

```sh
./build-app.sh
open SuperAV.app
```

The build script generates the app icon from `icon-film-audio.png` and ad-hoc signs the app. It compiles with `swiftc` directly rather than `swift build`, since the Command Line Tools toolchain lacks the SwiftUI macro plugin the UI relies on — it uses Xcode's toolchain instead when Xcode is installed.

`Package.swift` is provided for editing in Xcode/SourceKit (autocomplete, jump-to-definition); it isn't used to produce the shipped app.

## Hotkeys

| Action | Key |
| --- | --- |
| Kill SoundSource | **K** |
| reStart SoundSource | **S** |
| Toggle SoundSource | **T** |
| Balance Left | **L** |
| Balance Center | **C** |
| Balance Right | **R** |
| Top display dimmer | **F1** |
| Top display brighter | **F2** |
| Quit | **Q** or **esc** |

The Left, Center, and Right actions take effect immediately. The Custom Balance slider applies changes as it moves. F1 and F2 adjust the first display row in 5-point steps while SuperAV is the active app.

The app stays open after every action. Quit explicitly with the Quit button, **Q** or **esc**, or by closing the window. The first SoundSource action triggers the macOS Apple Events permission prompt used for volume control.

## Brightness compatibility

SuperAV uses macOS's private DisplayServices framework at runtime because macOS does not provide a public API for independently controlling arbitrary displays. This is intended for local use rather than Mac App Store distribution. A display that does not support this interface remains visible with its slider disabled and an error message.

## License

MIT — see [LICENSE](LICENSE).
