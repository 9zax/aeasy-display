# Spec: Android tablet support

**Date:** 2026-08-05
**Status:** done — no code change required
**Goal:** Document that Android tablets are supported today, and what the actual compatibility boundary is.

## Statement

AEasy Display works on any Android device that `adb` can see — phone or tablet. Nothing in the stack is phone-specific:

- **Client requirement is only Android 8+ (API 26)** — `minSdk = 26` in `android/app/build.gradle`, and the only permission is `INTERNET`.
- **Transport is `adb reverse`**, so device class is irrelevant; if USB debugging is on and `adb devices` lists it, the tunnel works. Wireless mode (`aeasy wifi`) likewise.
- **Geometry is discovered, not assumed.** `bin/aeasy` reads the panel via `adb shell wm size` and rotation via `dumpsys display`, and the Mac sizes the `CGVirtualDisplay` to whatever comes back. A 2560×1600 tablet panel is handled the same way as a phone panel.
- **Touch** uses normalized coordinates in the 5-byte packet, so panel size doesn't affect input mapping.

## Boundary / caveats

- Low-end tablets may have weak HEVC decoders; H.264 is the fallback and works everywhere MediaCodec does.
- Very large panels mean more pixels to encode — the existing per-source step-down in `mac/AEasyServer.swift` already covers this.

## Doc changes

- `README.md` / `README.th.md` Requirements: "phone" → "phone or tablet".
