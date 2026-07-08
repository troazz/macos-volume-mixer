# Volume Mixer

A macOS menu-bar app (no Dock icon) that gives you a Windows-style volume mixer:
an independent volume slider + mute for **each app currently playing audio**, plus
a **master volume** control and an **output-device picker**.

Built from scratch in Swift/SwiftUI for **macOS 14.4+** (developed on macOS 26 /
Xcode 26). Per-app control uses the modern **Core Audio process-tap API** — no kernel
extension, no installed audio driver.

## How it works

- **Master volume / mute / device picker** — plain Core Audio device properties
  (`kAudioHardwarePropertyDefaultOutputDevice`, `…VolumeScalar`, `…Mute`), with
  property listeners so the UI tracks media keys and device hot-plugs live.
- **Per-app volume** — for each app you adjust, a process tap
  (`AudioHardwareCreateProcessTap`, `.mutedWhenTapped`) removes the app's audio from
  its normal path and hands us a copy; a private aggregate device
  (`AudioHardwareCreateAggregateDevice`) fronts the real output device, and an IOProc
  multiplies the tapped samples by your chosen gain and plays them back. Apps left at
  100 % and unmuted are never tapped (zero added latency).
- **Permission** — process taps require the system audio-capture permission
  (`kTCCServiceAudioCapture`). The app requests it on first use.
- **Reset** — each adjusted app shows a reset button that clears its gain/mute and
  releases its tap, returning it to the untouched direct path.
- **Loudness compensation** — tapped audio is scaled by `max(1, channels/2)` to
  counteract the reported multichannel tap-attenuation quirk. This is a no-op for
  ordinary 2-channel devices and only boosts on multichannel hardware.

## Build & run

```bash
brew install xcodegen          # one-time
xcodegen generate              # regenerates VolumeMixer.xcodeproj from project.yml
open VolumeMixer.xcodeproj      # then Build & Run (⌘R) in Xcode
```

In Xcode, select your team under **Signing & Capabilities** (or "Sign to Run
Locally") — a stable signature keeps the audio-capture permission grant across
rebuilds. On first per-app adjustment macOS will prompt for audio-capture access;
grant it (or later enable it under **System Settings → Privacy & Security → System
Audio Recording**).

The `.xcodeproj` is generated and git-ignored — edit `project.yml` and re-run
`xcodegen generate` to change build settings or add files.

## Known limitations (v1)

- **Same-format assumption:** the mixing IOProc assumes the tap and output device
  share a stream format (the common stereo-float32 case). Genuinely mismatched
  sample rates/channel counts aren't resampled yet.
- **Tap persists until the app quits:** once an app is tapped, lowering it back to
  100 % keeps a (pass-through) tap alive to avoid audible create/destroy churn; it's
  released when the app stops playing, you switch output devices, or you hit reset.
- **Level accuracy:** the loudness-compensation heuristic (`max(1, channels/2)`) is
  a no-op on stereo devices; on multichannel hardware validate that levels match the
  plain system path, as the exact attenuation factor may differ.
- **Not for the App Store:** relies on the private TCC SPI for the permission
  request and unrestricted aggregate-device/tap creation (intended for personal /
  direct use).
