# Changelog

All notable changes to this project are documented here. The format is based on
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the project adheres to
[Semantic Versioning](https://semver.org/).

## [0.3.0] - 2026-07-08

### Added
- In-app **auto-update** via Sparkle — EdDSA-signed, so it needs no Apple Developer ID.
  Automatic daily checks plus a **Check for Updates…** menu item; Sparkle shows its own
  download/verify/install-and-relaunch UI. Each release is signed in CI and published
  with an `appcast.xml` feed.

## [0.2.0] - 2026-07-08

### Added
- Custom app icon — three mixer faders on a blue→indigo squircle, generated
  programmatically (`scripts/make_icon.sh`).
- Media transport controls (play / pause / next / previous) for the current
  now-playing source, via the bundled BSD-licensed
  [`ungive/mediaremote-adapter`](https://github.com/ungive/mediaremote-adapter).
  Meeting apps (Teams, Google Meet) publish no Now Playing session and so correctly
  show no transport controls.

### Changed
- Media controls sit inline beside the app name, wrapped in a rounded highlight box.
- The app name truncates and yields space so it never overflows the controls.
- Popover widened from 320 to 360 pt for more breathing room.
- README screenshot is loaded via an absolute raw URL so it renders reliably.

## [0.1.0] - 2026-07-08

### Added
- Menu-bar app (no Dock icon) with an independent volume slider, mute, and boost to
  200 % for every app producing audio.
- Master volume + mute and an output-device picker, synced with the hardware/media keys.
- Live detection of audio-producing apps, resolving browser/Electron helper processes
  to the real app name and icon.
- Magnetic snap to 100 % on per-app sliders and a per-app reset button.
- Multichannel loudness compensation.
- Per-app settings persistence (by bundle ID) and launch-at-login.
- Audio-capture permission flow (TCC).
- Universal (Apple Silicon + Intel) release published by GitHub Actions on `v*` tags.

### Fixed
- Robotic/garbled audio caused by a channel-layout mismatch when adjusting per-app volume.
- Internal per-app tap aggregate devices leaking into the output-device picker.

[0.3.0]: https://github.com/troazz/macos-volume-mixer/releases/tag/v0.3.0
[0.2.0]: https://github.com/troazz/macos-volume-mixer/releases/tag/v0.2.0
[0.1.0]: https://github.com/troazz/macos-volume-mixer/releases/tag/v0.1.0
