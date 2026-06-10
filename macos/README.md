# NanoKVM USB — Native macOS Client

Native macOS application for NanoKVM-USB, based on upstream PR [sipeed/NanoKVM-USB#125](https://github.com/sipeed/NanoKVM-USB/pull/125). It provides a standalone `.app` bundle for Apple Silicon Macs, built from one Swift source file with no Xcode project and no third-party dependencies.

This is a parallel client, not a replacement for the existing clients:

- `browser/`: static web client, useful through GitHub Pages or a local web server.
- `desktop/`: Electron desktop client, currently has the fork's FPS/debug panel and display color controls.
- `macos/`: native Swift client, focused on lower macOS overhead and direct AppKit/AVFoundation/CoreAudio integration.

The native client includes the fork's key observability and display-tuning features: FPS selection, a compact Debug panel, diagnostics JSON copy, and display color controls.

## Why

The Chrome-based solution (WebSerial + getUserMedia) works but uses significant CPU and RAM on macOS due to JavaScript video processing. This native app uses `AVCaptureVideoPreviewLayer` which renders USB capture card frames directly on the GPU, using a fraction of the CPU and RAM compared to Chrome.

## Features

- **GPU-accelerated video** — zero-copy rendering via AVCaptureVideoPreviewLayer, with device/resolution/FPS switching and fullscreen (`Cmd+F`)
- **Display color controls** — brightness, contrast, and saturation controls with the recommended `101 / 112 / 109` preset, plus neutral and range-expand presets
- **Debug panel** — active video mode/FourCC/FPS, color metadata, serial GET_INFO, mouse event/report rates, serial write latency, and copyable diagnostics JSON
- **Full HID forwarding** — keyboard and absolute/relative mouse over CH552 serial protocol
- **Toolbar UI** — Video (device/resolution/FPS switching), Display (color controls), Audio (device selection, mute), Serial (port selection), Keyboard (paste, key combos, shortcuts), one-click Ctrl+Alt+Del, Mouse (cursor, mode, wheel, jiggler), Debug, Record (screenshots, recording)
- **Audio pass-through** — opt-in USB audio capture, CoreAudio HAL playback with lock-free ring buffer, mute and device selection controls. Audio is not started by default to avoid unnecessary microphone privacy indicators.
- **Screen recording** — H.264 or H.265 (HEVC) codec selectable from the Record toolbar menu, saved as .mov. Default is H.265 for smaller files. Selection persists across launches.
- **Screenshots** — PNG, JPEG, or HEIC format with quality control (50–100%) for lossy formats. Format and quality persist across launches.
- **Resolution persistence** — remembers manually selected resolution between launches; first-run defaults prefer 1080p instead of the capture dongle's highest advertised mode
- **Paste to remote** — types clipboard contents as HID keystrokes with correct shift handling
- **Mouse jiggler** — prevents remote machine from sleeping (30-second micro-movements)
- **Background monitoring** — uses an adaptive low-CPU retained frame by default: after losing focus it refreshes every 5 seconds for 15 minutes, every 30 seconds until 60 minutes, then every 60 seconds. Optional Live while visible mode keeps an unfocused window on a second display continuously current; Paused and fixed snapshot intervals remain available.
- **Session watchdog** — if the capture session fails to produce a frame within 3 seconds of refocusing (e.g. after long idle), it is automatically force-restarted
- **Scoped cursor hiding** — the local cursor is hidden by default only while it is inside the rendered video area, with a fullscreen top-edge escape zone for macOS menu/toolbar access
- **Minimal footprint** — single file, builds in seconds

## Display and Debug Notes

Display color controls are implemented as a Core Image display filter on the preview layer. They tune what you see on the Mac; they do not change NanoKVM firmware, the UVC stream, HDMI EDID, or the source machine's output.

The Neutral `100 / 100 / 100` preset removes the Core Image filter entirely for lower GPU use. The recommended and range-expand presets retain the filter because they intentionally alter the displayed image.

The Debug panel keeps video sample-buffer output enabled while it is open so it can estimate actual FPS and dropped frames. Closing the panel returns the app to the lower-overhead preview-only path.

## Privacy Indicators

macOS shows the green camera indicator whenever the USB capture device video stream is active. The app cannot suppress that system indicator while it is displaying a current KVM video feed. The default **adaptive snapshot** inactive-window mode refreshes frequently just after focus loss, then backs off to reduce energy use. Remote audio no longer wakes video capture between scheduled snapshots. Optional **Live while visible** keeps an unfocused visible window current with the indicator steadily active; **Paused** releases capture completely.

The yellow microphone indicator appears only when audio capture is running. This client does not start audio automatically; use the **Audio** toolbar menu to enable matching USB audio when needed, and **Stop Audio Capture** to release it.

## Build

```sh
cd macos
bash build.command
open NanoKVM.app
```

Requires macOS 12+ and Xcode command line tools (`xcode-select --install`).

`build.command` defaults to an arm64 app:

```sh
ARCH=arm64 bash build.command
```

It also ad-hoc signs the app bundle when `codesign` is available. This is not the same as Apple Developer ID signing or notarization, so the first launch may still require right-clicking the app and choosing Open.

To create a zip for local sharing:

```sh
ditto -c -k --keepParent NanoKVM.app NanoKVM-native-macos-arm64.zip
```

## Files

| File | Description |
|------|-------------|
| `NanoKVM.swift` | All application code |
| `Info.plist` | Bundle metadata + camera/microphone permissions |
| `build.command` | Compile + create .app bundle |
| `AppIcon.icns` | App icon |

## CI / Releases

GitHub Actions builds this client on macOS and uploads a native Apple Silicon artifact named:

```text
nanokvm-usb-native-macos-arm64-<tag>.zip
```

The release artifact is intentionally separate from the Electron macOS package so both desktop clients can be tested side by side.

## Permissions

On first launch macOS will prompt for Camera to access the USB HDMI capture device video feed. macOS will prompt for Microphone only if you enable USB audio capture from the **Audio** toolbar menu. The app filters for external USB capture devices and does not access your Mac's built-in camera or microphone intentionally.

## Protocol Compatibility

Uses the same CH552 serial protocol (57600 baud, `[0x57][0xAB]` framing) with commands:
- `0x01` GET_INFO
- `0x02` SEND_KB_GENERAL (8-byte HID keyboard reports)
- `0x04` SEND_MS_ABS (7-byte absolute mouse, 12-bit coordinates)
- `0x05` SEND_MS_REL (5-byte relative mouse)

## Keyboard Shortcuts

| Action | Shortcut |
|--------|----------|
| Fullscreen | `Cmd+F` |
| Quit | `Cmd+Q` |

Additional key combos available from the **Keyboard** toolbar menu: Ctrl+Alt+Del, Win+Tab, Alt+F4, Ctrl+Esc, Paste, Release All Keys.
