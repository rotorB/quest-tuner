# Quest Tuner

A native macOS app that monitors and tunes a Meta Quest 3 over adb, by USB cable or Wi-Fi.
It shows live performance charts, changes the headset's performance settings, streams the
headset display and cameras to a window on the Mac, and manages files on the headset.

Built with SwiftUI and Swift Charts. No Xcode project: a Swift package plus a build script.

## Features

### Dashboard

Live charts of the last few minutes, updated every 1–2 seconds:

| Chart | Source on the headset |
| --- | --- |
| Frames per second, with stale frames | `VrApi` compositor stats in logcat |
| Frame time, against the frame budget | `VrApi` |
| CPU clock and level | `VrApi` |
| GPU clock, load and temperature | GPU driver (`/sys/class/kgsl/kgsl-3d0`) |
| RAM free, swap used | `/proc/meminfo` |

Each chart is coloured green, yellow or red by threshold. Battery level is in the header.
When the connection drops, the charts keep the last values and turn grey with an
**OFFLINE** badge, so a frozen picture is never mistaken for live data.

A small sampler loop runs on the headset itself (shell builtins only), so monitoring costs
next to nothing while a game runs.

### Connection

- Finds a headset on USB automatically.
- Switches it to Wi-Fi adb in one click and remembers the address. The USB-C port is then free,
  for example for a USB camera. Wi-Fi adb stays on until the headset reboots.
- Reconnects by itself while the headset sleeps and wakes.

### Tuning and presets

Writes `debug.oculus.*` system properties:

- **GPU level** 0–7 (285–690 MHz). Level 7 is undocumented but reaches the top GPU clock.
- **CPU level** 0–6 (0.69–2.21 GHz).
- **Refresh rate** 72, 80, 90 or 120 Hz.
- **Foveation** Off, Low, Medium, High or High top.
- **Eye texture size** 1536 to 3072 px wide at the 10:11 aspect, shown as a percentage of the panel.

Two presets apply a full set at once: **High Quality** (2560×2816 eye texture) and
**High Performance** (2048×2256). The app reads back what the headset has applied and marks
unapplied changes. The properties reset when the headset restarts.

### Game control

- Pick any installed app from the list.
- **Restart** it.
- **Free resources & launch game**: stops every other app, non-essential Meta apps and cached
  processes, applies the tuning, then starts the game. Core VR services are left alone.
  Optionally reboots the headset first (USB only).

### Live view

A separate window that streams the headset to the Mac over USB or Wi-Fi, using the scrcpy server:

- **Headset display**: the picture as it goes to the lenses. Show the left eye, the right eye or
  both. Quality presets set resolution and bitrate, from 1920 px at 4 Mbit/s up to the full
  4128 px at 16 Mbit/s. Frame rate 30, 60 or 90 fps.
- **Headset cameras**: every camera the headset reports, including the left and right
  passthrough cameras (1280×1280, up to 60 fps). Pick capture size, frame rate and bitrate.
  One camera at a time: the headset allows only one open camera.
- Hardware H.264 decoding with low latency. Resolution, frame rate and bitrate are shown in the
  window subtitle. The chosen source and settings are remembered.

The display stream sends frames only while the headset is worn; the window says so.

### Screenshots

- **Eye view**: a 1440×1440 JPG of one eye, as you see it.
- **Full display**: a 4128×2208 PNG of both eyes at panel resolution, with lens distortion.

Screenshots are saved to `~/Pictures/Quest Tuner` and previewed in the app.

### Video capture

Settings for the headset's own **Record video**: size (720p up to 2560×1440), bitrate
(5–60 Mbit/s, with megabytes per minute) and full or half frame rate.
**Defaults** restores the system values (1024×1024, 5 Mbit/s, half rate).

### File manager

A Finder-like window for the headset storage:

- Shortcuts to Download, Screenshots, VideoShots, Movies, `Android/data`, `Android/obb` and `/data/local/tmp`.
- Sortable table, back and up navigation, a path field, hidden files on demand.
- Download to the Mac, upload by drag and drop from Finder, open a file on the Mac, new folder,
  rename, delete (with confirmation).
- Transfer progress with Cancel, and free space on the headset.
- Existing files are never overwritten: a name clash gets a numbered name.

## Requirements

- macOS 14 or later, Swift 5.10 or later (Xcode or the Command Line Tools)
- `adb`: `brew install android-platform-tools`
- `scrcpy` 5 or later, for Live view: `brew install scrcpy`
- Developer mode enabled on the headset, and USB debugging allowed for this Mac

## Build and run

```bash
./build.sh            # builds build/Quest Tuner.app
./build.sh --install  # also copies it to /Applications
```

The app is ad-hoc signed for local use.

## Project layout

| File | Purpose |
| --- | --- |
| `QuestTunerApp.swift` | App entry and windows |
| `QuestModel.swift` | Connection, monitoring, tuning, game control, screenshots |
| `ADB.swift` | Running adb commands |
| `ContentView.swift`, `Gauges.swift` | Dashboard and charts |
| `ControlPanel.swift`, `StepSelector.swift` | Side panel cards and controls |
| `Tuning.swift`, `VideoCapture.swift` | Settings and presets |
| `LiveStream.swift`, `LiveView.swift` | scrcpy stream, decoding, Live view window |
| `FileBrowser.swift`, `FileBrowserView.swift` | File manager |

## Notes

- The tuning values are debug properties. They do not survive a reboot and Meta does not
  support them for everyday use.
- The undistorted "cast to TV" view is not available over adb, so Live view shows the
  lens-distorted display or the cameras.
