# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

AEasy Display turns Android phones and iPhones into touchscreen second displays for a Mac (up to 3 devices at once) over USB (`adb reverse`) or Wi-Fi. No web stack — the codebase is Swift (mac + iOS), Kotlin (Android), and zsh (CLI + tests).

## Commands

```sh
make build        # compile the three macOS binaries (aeasy-server, aeasy-config, aeasy-tray)
make check        # CI gate: pure protocol assertions (mac/check) + CLI registry tests (test/cli.sh)
make smoke        # end-to-end protocol smoke test against the real server — needs Screen Recording granted
make apk          # build the Android viewer (needs Android SDK; gradle or gradle@8)
make install      # build + install the `aeasy` CLI (alias `aez`) via install.sh
make run          # rebuild, reinstall, restart the stream
make clean
```

- Run a single test layer directly: `./mac/check`, `zsh test/cli.sh`, or `python3 test/smoke.py -v`.
- `make check` is pure (no device, no permissions, scratch config) — always run it after touching `mac/Protocol.swift`, `bin/aeasy`, or the registry logic. `make smoke` runs the real server on a spare port (7399) and needs Screen Recording; it briefly creates a real virtual display.
- Swift builds target macOS 13 explicitly (`-target ...-apple-macos13.0`) — don't use newer-than-13 APIs; they compile silently against the host SDK.
- `make build` invalidates the Accessibility grant on `aeasy-server`; touch input needs it re-toggled after rebuilds.
- Releases go through the `9zax` GitHub account, not `nakarin-w`.

## Architecture

Pipeline: Mac creates a virtual display (private `CGVirtualDisplay` API, `mac/virtual-display.h`) → ScreenCaptureKit capture → VideoToolbox hardware H.264/HEVC encode → raw Annex-B stream over loopback TCP → tunneled to the phone by `adb reverse` (or `iproxy`/`socat` for iOS, `adb connect` for Wi-Fi) → phone hardware-decodes and renders fullscreen.

One process per concern, all launched/supervised by the CLI:

- **`bin/aeasy`** (zsh, ~900 lines) — the CLI and the brain: device registry (`DEVICES=<slot>:<platform>:<serial>,…` in the global config), cable watcher with relaunch backoff, rotation handling, USB/Wi-Fi switching. Sourceable for tests; `AEASY_SHARE` points it at a scratch tree.
- **`mac/AEasyServer.swift`** — one server process *per device*. Serves up to 3 sources (display / app window / camera) as independent panes, each its own stream on the same port. Connections open with `AEZ1 <source-id>\n`; `AEZ1 control\n` is a length-prefixed JSON channel syncing pane layout live between phone and settings GUI. Adapts bitrate/fps per stream from the real frame-drop rate.
- **`mac/Protocol.swift`** — pure (no I/O) upstream packet parser, compiled into both the server and `mac/check`. Every upstream packet is exactly 5 bytes: touch down/move/up + type-3 resize (also the iOS rotation signal). Also holds the iOS display-sizing math. New protocol logic goes here so `make check` can assert it.
- **`mac/AEasyConfig.swift`** — per-device settings GUI; edits the config file (restart-applied) but drives the pane layout live over the same control channel the phone uses.
- **`mac/AEasyTray.swift`** — menu bar tray, shells out to `aeasy`.
- **`android/`** (Kotlin, `dev.ctz.usbdisplay`) and **`ios/AEasyDisplay/`** (Swift, beta) — thin viewers: connect, hardware-decode, render, send 5-byte touch packets back. iOS ships as source (free Apple ID signing); `install.sh` copies it plus `mac/Protocol.swift` to `$SHARE/ios-src` preserving the tree shape the xcodeproj expects.

Multi-device invariants (see `specs/2026-08-06-multi-device-targets.md`): slot fixes the port (`7355 + 10*slot`) and the port fixes the virtual display's serial — macOS keys saved resolution/arrangement to it, so slots must not shift when a device is removed. Per-device state lives in `~/.local/share/aeasy/dev/<slot>/` (config, layout, log); the registry is guarded by a `mkdir` lock. Adding/removing a device must never drop another device's stream.

Runtime state root: `~/.local/share/aeasy` (binaries, APK, global + per-device config). Env overrides `AEASY_DIR` / `AEASY_PORT` / `AEASY_SHARE` exist so tests never touch a live session — keep that property when adding features.

## Conventions

- `specs/` holds dated design docs with status; nontrivial features get one and cite it from tests (e.g. smoke.py assertions reference spec test IDs like T-16).
- Docs come in EN/TH pairs (`README.md`/`README.th.md`, etc.) — update both.
- Comments explain *why* (the failure mode that forced the code), not what; keep that style.
