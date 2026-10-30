# Quest Tuner

A macOS app that monitors and tunes a Meta Quest 3 over adb, by USB cable or Wi-Fi.

## Features

- **Dashboard**: live charts of frame rate, frame time, GPU clock, load and temperature, CPU clock, free RAM and swap. Charts turn grey while the headset is offline.
- **Tuning**: GPU and CPU levels, refresh rate, foveation and eye texture size (`debug.oculus.*` properties), with presets.
- **Connection**: switch between USB and Wi-Fi adb.
- **Live view**: stream the headset display (left eye, right eye or both) or a headset camera, such as the left and right passthrough cameras, with size, frame rate and bitrate controls.
- **Video capture**: size, bitrate and frame rate of the headset's own video recording.
- **Files**: browse the headset storage, upload by drag and drop, download, rename and delete.
- **Screenshot**: capture what the headset shows.

## Requirements

- macOS 14 or later, Swift 5.10 or later
- `adb` (`brew install android-platform-tools`)
- `scrcpy` 5 or later for Live view (`brew install scrcpy`)
- Developer mode enabled on the headset

## Build

```bash
./build.sh            # builds build/Quest Tuner.app
./build.sh --install  # also copies it to /Applications
```

`debug.oculus.*` properties reset when the headset restarts.
