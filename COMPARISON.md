# AEasy Display vs other open source projects

<p align="center"><b>English</b> · <a href="COMPARISON.th.md">ภาษาไทย</a></p>

Compared against the closest open source projects: [scrcpy](https://github.com/Genymobile/scrcpy), [Deskreen](https://github.com/pavlobu/deskreen), [Weylus](https://github.com/H-M-H/Weylus), [VirtScreen](https://github.com/kbumsik/VirtScreen), [Sunshine](https://github.com/LizardByte/Sunshine)+[Moonlight](https://moonlight-stream.org/)
(Closed-source options like Duet Display and superDisplay are excluded. spacedesk is closed source too, but people ask about it so often that it's in the table anyway.)

## Overview — the "use another device as a second display" problem

| | ⭐ AEasy Display | spacedesk | Deskreen | Weylus | VirtScreen | Sunshine + Moonlight |
|---|---|---|---|---|---|---|
| Computer side | macOS only | Windows 10/11 only | Win / macOS / Linux | Win / macOS / Linux | Linux (X11) only | Win / macOS / Linux |
| Display side | Android / iOS beta (viewer apps) | Android / iOS / browser / Windows viewer | anything with a browser | anything with a browser | anything with a VNC client | Android / iOS / more (Moonlight app) |
| Open source | ✅ MIT | ❌ closed source, freeware | ✅ | ✅ | ✅ | ✅ |
| Creates the virtual display for you | ✅ (`CGVirtualDisplay`) | ✅ (Windows display driver) | ❌ needs a dummy plug or DIY virtual display | ⚠️ Linux only (macOS = mirror only) | ✅ (xrandr) | ❌ needs a dummy plug or BetterDisplay |
| Transport | USB (zero network) or Wi-Fi (`aeasy wifi`) | Wi-Fi / LAN / USB (via Android USB tethering) | Wi-Fi (WebRTC) | Wi-Fi (WebRTC/WebSocket) | Wi-Fi (VNC) | Wi-Fi / LAN (hw encode) |
| Latency | low (hw encode/decode end to end) | medium (depends on network; low over USB/LAN) | medium–high (software encode via browser) | medium (hw encode on some platforms) | high (VNC isn't built for video) | very low (built for game streaming) |
| Input back (touch/stylus) | ✅ tap + drag (no stylus pressure/scroll) | ✅ touch, pressure stylus, keyboard/mouse | ❌ | ✅ its main selling point (pressure stylus — Linux only) | ✅ via VNC | ✅ (mouse/keyboard/gamepad) |
| Audio | ❌ | ✅ | ❌ | ❌ | ❌ | ✅ |
| Auto-rotation | ✅ | ✅ | ❌ | ❌ | ❌ | ❌ |
| Several devices at once | ✅ up to 3, each its own extended display, added and removed live | ⚠️ one desktop across many devices (video wall) | ❌ | ❌ | ❌ | ❌ |
| Several sources at once | ✅ up to 3 panes (display, app windows, cameras), arrangeable live from either side | ⚠️ one desktop across many devices (video wall) | ❌ | ❌ | ❌ | ⚠️ one stream per session |
| Single-app window mirror | ✅ `aeasy mirror <App>` | ❌ whole desktop only | ✅ pick an app window to share | ⚠️ Linux only | ❌ | ❌ whole display only |
| Adaptive quality under load | ✅ live, per stream — bitrate/fps step down, secondary panes first | ⚠️ manual quality settings | ⚠️ whatever WebRTC negotiates | ❌ | ❌ | ✅ adaptive bitrate |
| Auto start on plug-in | ✅ cable watcher: plug in and it streams, reconnects itself | ❌ open the viewer and connect | ❌ | ❌ | ❌ | ❌ |
| Project status | new | mature, actively maintained | active, but virtual display has been "on the roadmap" for years | active | ⚠️ abandoned (last commit 2018) | very active, large community |

## Project by project

### Deskreen — second screen in a browser, over Wi-Fi
- **Strengths**: nothing to install on the receiving side — just open a browser; works with an iPad, a phone, or another laptop; cross-platform.
- **Weaknesses**: doesn't create a virtual display — to truly *extend* you need a dummy plug yourself, otherwise it's mirror-only; software encoding via Electron+WebRTC costs CPU and latency; both devices must share a Wi-Fi network.

### Weylus — a mouse/pen first, a second screen second
- **Strengths**: full input back to the computer — use a tablet as a graphics tablet with pressure/tilt (Linux); very light (a single Rust binary); the receiving side is just a browser.
- **Weaknesses**: the killer features (pressure stylus, virtual monitor, window capture) are Linux-only — on macOS you're left with basic mirroring and control; Wi-Fi only.

### VirtScreen — same idea as AEasy, but for Linux
- **Strengths**: creates a real virtual display via xrandr and shares it over VNC — same all-in-one approach.
- **Weaknesses**: Linux/X11 only (no Wayland); VNC is a poor fit for moving pictures, so latency is high; **abandoned since 2018**.

### Sunshine + Moonlight — the fastest video pipe, but you assemble it yourself
- **Strengths**: lowest latency of the group (built for game streaming; hw encode H.264/HEVC/AV1); clients on every platform including Android; big, active community.
- **Weaknesses**: it's game streaming, not a second-display tool — on macOS you must supply the virtual display yourself with a dummy plug or [BetterDisplay](https://github.com/waydabber/BetterDisplay) (freemium) and point Sunshine at it; multiple moving parts; runs over the network.

### Where AEasy Display fits
The only one that does **"macOS → Android second display over a USB cable, in one command"** — creates its own virtual display, hardware encode/decode end to end, zero network, the display rotates with the phone, and up to **three sources stream at once** as draggable panes (the extended display, app windows, or a camera), each an independent stream. Around that core: a settings GUI (`aeasy config` — fps/bitrate/resolution/codec plus a live pane-layout editor), a one-shot low-latency preset (`aeasy tune`), a menu bar tray with status and start/stop, and a phone app that needs only the `INTERNET` permission. Free, MIT, no accounts. The trade-off: macOS+Android only, no audio, no scroll/multi-finger gestures.

### spacedesk — the same idea, but for Windows
- **Strengths**: mature and polished; audio streaming; touch, pressure stylus, and keyboard/mouse input back; video wall across many devices; viewer runs in any browser; free.
- **Weaknesses**: **Windows only — there is no macOS version**, so it can't even be compared head-to-head with AEasy on the same machine; closed source; its "USB" mode is network-over-USB via Android USB tethering, not a direct pipe.
- People compare AEasy to spacedesk a lot, and fair enough — same "phone as a USB second display" idea. But spacedesk answers it for Windows users, AEasy for Mac users. They never compete.

---

# Appendix: AEasy Display vs scrcpy in depth

> Key point: these two solve **opposite problems, in opposite directions**
>
> - **AEasy Display** — streams **Mac → Android**: turns the phone into a *second display* for the Mac
> - **scrcpy** — streams **Android → PC**: *mirrors and controls* the phone from a computer
>
> So they're not direct competitors — you can even run both at once. This table shows which tool fits which job.

## At a glance

| | ⭐ AEasy Display | scrcpy |
|---|---|---|
| Video direction | Mac → Android (second display) | Android → PC (phone mirroring) |
| Core job | more screen space for the Mac | view/control the phone from a computer |
| Computer side | macOS 13+ only | Windows / macOS / Linux |
| Phone side | viewer app required (APK) | no app needed (server pushed via adb automatically) |
| Transport | USB (`adb reverse`) or Wi-Fi (`aeasy wifi`) | USB or Wi-Fi (TCP/IP) |
| Audio | none | yes (Android 11+, forwarded to the computer) |
| Control the other side? | touch: tap + drag drive the Mac cursor | full control (mouse, keyboard, clipboard, drag-and-drop files) |
| Video | H.264 / HEVC hardware encode/decode | H.264 / H.265 / AV1 |
| Maturity | new, small project | battle-tested, huge community (100k+ stars) |

## AEasy Display strengths

- **Does what scrcpy can't on macOS** — creates a real virtual display (`CGVirtualDisplay`) so you can drag windows onto the phone like a genuine second monitor
- **Zero network** — everything runs over the USB cable (`adb reverse`); never fights your Wi-Fi, works on the go
- **Multi-source panes** — `aeasy sources display,window:Safari` shows up to three Mac sources as overlapping panes, draggable and resizable live from the phone or from `aeasy config`; touch on a pane drives the real window behind it
- **Load-aware quality** — measures the real per-stream frame-drop rate and steps bitrate/fps down on the fly, secondary panes before the main one, with no restart
- **Auto-rotation** — rotate the phone and the Mac-side virtual display follows (portrait ↔ landscape), always using the full panel
- **Per-app mirroring** — `aeasy mirror Safari` streams a single app window to the phone
- **Hardware all the way** — ScreenCaptureKit + VideoToolbox on the Mac, MediaCodec on Android; low CPU use

## AEasy Display weaknesses (vs scrcpy)

- macOS only — no Windows/Linux
- requires building/installing an APK on the phone first
- no audio (rarely needed for a second display, but scrcpy has it)
- 30fps ceiling
- young project — ecosystem/docs/testing can't compare to scrcpy yet

## scrcpy strengths

- **Full phone control** — type, click, drag files, two-way clipboard
- **No app on the phone** — pushes its server binary via adb every time
- **Feature-complete** — audio, video recording, camera-as-webcam, OTG/UHID keyboard, H.265/AV1
- **Cross-platform + Wi-Fi** — every major OS, wired or wireless
- **High confidence** — years of active development, huge user base, most bugs long since shaken out

## scrcpy weaknesses (for the "second display" job)

- **Can't turn the phone into a second display for the Mac** — its video direction is the reverse of AEasy's
  (scrcpy 3.x has `--new-display`, but that creates a virtual display *on the Android side* to run Android apps on your computer — still Android → PC)
- CLI-only with a lot of flags; expect to read the docs

## Which one, in short

| You want to… | Use |
|---|---|
| use the phone as a second monitor for the Mac | **AEasy Display** |
| view/play/control the phone from the computer, demo apps, answer phone chats on the desktop | **scrcpy** |
| both | run both — opposite directions, they don't conflict |
