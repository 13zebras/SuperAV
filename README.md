# SuperAV

A macOS app combining SoundSource controls, audio balance, and per-display brightness:

- **SoundSource** — Kill, reStart, or Toggle the SoundSource app. Kill and reStart ramp the system output volume down first and restore it afterward. Toggle changes the app’s running state without touching volume.
- **Audio Balance** — Set the default macOS output device’s stereo balance on a `0–100` scale (`0` is left, `50` is a center detent, and `100` is right).
- **Display Brightness** — Show a separate `0–100` slider for each active display, track brightness changes made outside SuperAV, and set the built-in display to `0%`, `5%`, `50%`, or `100%` with dedicated buttons. Connected-display changes are detected while the app is open.

## Build and run

```sh
./build-app.sh
open SuperAV.app
```

The build script generates the app icon from `icon-film-audio.png` and ad-hoc signs the app.

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

SuperAV uses macOS’s private DisplayServices framework at runtime because macOS does not provide a public API for independently controlling arbitrary displays. This is intended for local use rather than Mac App Store distribution. A display that does not support this interface remains visible with its slider disabled and an error message.
