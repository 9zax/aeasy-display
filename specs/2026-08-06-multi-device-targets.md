# Spec: Multi-device targets (up to 3 phones/tablets at once)

**Date:** 2026-08-06
**Status:** draft
**Goal:** Drive up to three Android/iOS devices at the same time, each its own extended display with its own panes, added and removed live from the tray or the settings window, without changing the Android or iOS apps and without dropping the stream of a device that is already running.

## Background

Today AEasy targets exactly one device, and `README.md:217` says so out loud — "One phone at a time (the stream itself supports multiple viewers)". Both prior specs defer to that line (`specs/2026-08-05-multi-source-panes.md:43`, `specs/2026-08-05-ios-client.md:63`). The request analysed on 2026-08-06 asks for the opposite: pick several installed displays, add them from a button, and see the ones that do not have the app in a settings list. Twelve decisions were resolved with the requester and are recorded as **D-1…D-12** under [Open questions](#open-questions); every scope statement below cites them.

Four findings from the design review shaped everything that follows, because each one invalidates the obvious implementation:

1. **`aeasy-server` is already a multi-instance binary.** `AEASY_PORT` (`AEasyServer.swift:24`) and `AEASY_DIR` (`AEasyServer.swift:36`) were added so `make check` could run a server beside a real session. Every piece of per-device state this feature needs — the virtual display, `SOURCES`, `layout.json`, `dims`, `dims.ios`, `IOS_ADDR` — already hangs off one of those two variables, and a grep of `mac/*.swift` finds no path that bypasses `shareDir`. Critically, `desc.serialNum = PORT == 7355 ? 1 : UInt32(PORT)` (`:960`) already derives a **distinct virtual-display identity** from the port, which is the one thing macOS needs to keep several displays' resolutions and arrangements apart; the reasoning is written out at `:957-959`, and `desc.vendorID`/`desc.productID` (`:961-962`) stay constant, so the serial is what makes the triple unique. **Multi-device is therefore N server processes, not one process managing N devices.** The single-process alternative — a `DeviceSession` class holding what are today file-scope globals (`pxW`/`pxH` `:106`, `SOURCE_IDS` `:95`, `vdispRef` `:949`, `layout` `:240`, `TCPServer.headers` `:585`, `pendingBroadcast` `:591`) — was costed during review at a near-total rewrite of `AEasyServer.swift` plus a `@device` handshake extension, per-device control-message routing, a per-device `rev` counter in the GUI, and new `addDevice`/`dropDevice`/`teardown` paths. It buys nothing the environment variables do not already provide, and it *loses* fault isolation: one exhausted `VTCompressionSession` (`fatalError`, `:278`) would take down all three devices instead of one.

2. **`adb reverse` rules live on the device, so the device-side port never has to change.** `adb help` describes `reverse` as listing and removing "reverse socket connections **from device**" — the table is in the phone's `adbd`. So `adb -s S2 reverse tcp:7355 tcp:7365` lets device 2 keep dialling `127.0.0.1:7355` while landing on the Mac's 7365. The Android app hardcodes the host at `Pane.kt:197` / `ControlClient.kt:57` and the port at `MainActivity.kt:27`, and needs to know nothing. `iproxy` takes an arbitrary local port with `-u UDID` (verified against the installed build), and the iOS app is the *listener* on its own 7355 (`StreamListener.swift:24`) and never sends a handshake at all — `grep AEZ1 ios/` is empty, so it lands on the server's 300 ms legacy path (`AEasyServer.swift:644-653`) exactly as it does today. **No wire-protocol change and no client change of any kind** — no APK rebuild, no Xcode round trip — and `newConnectionLimit = 1` (`StreamListener.swift:28`) stops being a limitation because each iOS device gets its own relay.

3. **What blocks hot-add is nine unscoped process patterns, not the architecture.** Five kills: `server_start` (`bin/aeasy:89`), `ios_server_start` (`:100`), the watcher's teardown (`:150`), and `relay_kill`'s two (`:65`, one of which is `pkill -f "socat TCP:"` and takes out unrelated socat processes on the machine). Four liveness *guards* that are just as fatal and easier to miss: `pgrep -qf aeasy-server` at `:128`, `:141`, `:239`, and `AEasyTray.swift:19`. With slot 0 running, `pgrep -qf aeasy-server` succeeds for slots 1 and 2, so the watcher would never launch them — scoping only the kills produces a feature that silently never starts a second device. Both sets are addressed by FR-7.

4. **D-2's motivation dissolves under one-process-per-device.** The requester chose "let the user lock the resolution in Settings" to settle a fight between two devices of different panel sizes over the process-global `pxW`/`pxH`. With a process each, every device sizes its own virtual display from its own panel and there is no fight. Auto-sizing stays the default (FR-21); the lock ships anyway because it was asked for and is independently useful for pinning a tablet to a non-native desktop size, but it is an override, not the mechanism.

One thing the architecture does **not** give for free, and the spec must pay for explicitly: there is exactly one system cursor. Three servers each posting `CGEvent(...).post(tap: .cghidEventTap)` (`AEasyServer.swift:554-555`) and each raising windows (`:552`) would fight over it, so D-10's input arbitration is not a nicety — it is what makes step 1 releasable (FR-23).

## Interaction with the prior specs

- **`specs/2026-08-05-multi-source-panes.md`** — its "More than one phone" out-of-scope line (`:43`) is what this spec lifts. Everything else in it holds unchanged *per device*: `MAX_SOURCES = 3` (`AEasyServer.swift:25`), the `AEZ1 <source-id>\n` handshake (its FR-5), the layout `rev`/`ack` protocol (its FR-11) and the per-source degradation ladder (its FR-23) are all process-scoped and therefore already per-device. The `viewport` control message (`AEasyServer.swift:809`) carries `pxW`/`pxH` from that process's own argv, so it is per-device for free; the Android app never reads it (`MainActivity.onControl` handles only `sources`, `layout`, `error`) and its only consumer is the Mac canvas (`AEasyConfig.swift:366-369`).
  Its Background finding 3 — ScreenCaptureKit is change-driven, so "an idle window emits one frame and then nothing" — is why no test in this spec may assert "no gap in the byte stream" (see Test plan).
- **`specs/2026-08-05-ios-client.md`** — its "Multiple phones at once" out-of-scope line (`:63`) is likewise lifted, and its FR-39 `UDID` key is superseded: the UDID becomes a registry entry rather than a global tiebreak. Its NFR-2.3 finding — that `dims.ios` had to be split from `dims` because one shared file cross-contaminated sizes — generalises here: per-device `AEASY_DIR` is not polish, it is the correctness requirement that lets two iPhones coexist. Its no-Bonjour decision (`:62`, `:369`) is what bounds FR-18. Its `sawTypeThree` latch (`AEasyServer.swift:586`, set at `:754`, read at `:1104`) constrains where FR-22's early return may go, and its NFR-7 rotation budget ("typical ≤5 s") is what forbids a naive crash-backoff (FR-17).
- Both specs' "loopback only" NFR holds for every slot: three `NWListener`s, three `127.0.0.1` binds.

## Prerequisites

- **P-1** — `bin/aeasy`'s `adb()` wrapper must carry a device serial before anything else lands (FR-6). Until then every `adb` call with two devices attached fails with *"more than one device/emulator"* into `>/dev/null 2>&1`, and the failure is invisible.
- **P-2** — Every config writer in `bin/aeasy` shares one fixed temp path, `"$CFG.tmp"` (`:85`, `:259`, `:268`, `:286`, `:293`). Two concurrent writers interleave into that single file and `mv` then atomically installs the torn result, so the existing tmp+rename gives no concurrency safety at all. This is a pre-existing bug, but the registry makes concurrent writes routine (tray and settings window both add devices), so it must be fixed first: `mktemp` per writer, plus an `mkdir`-based lock around any registry read-modify-write.
- **P-3** — `test/smoke.py`'s `Server` class cannot start a second instance: `PORT = 7399` (`:28`) and `PANEL` (`:29`) are module constants and `__init__` (`:50`) takes neither, so two `Server()` objects would both bind 7399. It must take `port`, `panel` and `slot`. Ten of this spec's automated rows depend on running two or three servers at once.

## Scope

### In scope

- Up to **3** devices streaming at once (D-3), each with its own virtual display (D-1), its own `SOURCES`, pane layout and encode settings (D-12).
- Android and iOS simultaneously, in any mix (D-4).
- Add and remove a device live, from the tray menu or the settings window (D-5), without dropping the other devices' streams (D-6).
- A device picker listing what `adb devices` / `idevice_id -l` can see (D-9), with per-device app-installed status on Android (D-7).
- Devices without the app appear with install instructions (D-8).
- Exactly one device holds mouse/touch control of the Mac at a time, user-selectable (D-10).
- Optional per-device resolution lock (D-2).
- Registry persisted in the flat config (D-11).

### Out of scope

- **Any change to the Android app or the iOS app.** Both keep their shipped binaries (finding 2). This is a hard constraint, not a preference — it is what makes the feature shippable without an APK or TestFlight round trip.
- **Any wire-protocol change.** No handshake field, no packet type, no control message added or altered.
- Network discovery beyond `adb devices` / `idevice_id -l` — no mDNS, no ARP scan, no QR pairing (D-9, and the iOS spec's `:62` non-goal).
- Pushing an install to a device (D-8). `aeasy install-app` keeps its existing USB-tethered `adb install` (`bin/aeasy:313`) and is only *suggested* by the UI.
- App-installed detection on iOS (D-7) — there is no way to ask a tethered iPhone whether a side-loaded app is present.
- A cross-device bitrate or pixel governor (NFR-5).
- Per-device `FPS`/`CODEC` divergence in the UI. The data model allows it; no control ships.
- Mirroring the *same* virtual display to two devices. Each device gets its own; that is D-1.
- Preventing macOS from reflowing windows when a display appears or disappears (NFR-10).

### Delivery order

| Step | Contents |
|---|---|
| **1** | P-1, P-2, P-3, registry, slot-scoped process/relay lifecycle, `aeasy device` subcommands, **and the `INPUT` gate (FR-23)**. The gate is in step 1 and not step 2 because without it three devices fight over one cursor, which is not a releasable state. |
| **2** | `PANEL` lock, crash backoff, per-device notifications and display names. |
| **3** | Tray devices submenu and settings device selector + add-device sheet. |
| **4** | Docs, in both languages. |

## Requirements

### Functional

#### Device registry

- **FR-1** — A device occupies a **slot**, 0–2. The slot fixes the Mac-side port (`7355 + 10 × slot`) and therefore the virtual display's `serialNum` (`AEasyServer.swift:960`). A slot is allocated on add and **persisted**, never derived from list position: macOS keys a display's saved resolution and arrangement to vendor/product/serial (`:957-959`), so a device whose slot shifted when another was removed would lose its arrangement. Slot 0 is 7355, so an existing single-device install keeps display serial `1` and its current desktop arrangement across the upgrade.
- **FR-2** — The registry is one flat key in the global config, keeping the `KEY=value` parser in all three readers: `DEVICES=<slot>:<platform>:<serial>,…`. Slot and platform come first so the serial takes the remainder of the field — an Android device added over Wi-Fi has an `ip:port` serial, which any other field order would split. Parsing is `slot=${e%%:*}`, `rest=${e#*:}`, `plat=${rest%%:*}`, `serial=${rest#*:}`.
- **FR-3** — Each device owns `~/.local/share/aeasy/dev/<slot>/`, holding its `config`, `layout.json`, `dims`, `dims.ios`, `server.log` and `backoff` (FR-17). The path is keyed by **slot, not serial**: serials contain `:` and are untrusted input, and a numeric slot needs no sanitising to be a safe path component. `DEVICES=` in the global config is the single source of truth for slot↔serial; the `SERIAL=` key inside a slot config is a cross-check only, and on mismatch the slot's directory is treated as stale — its `layout.json` and `dims` are discarded and reseeded (this is the slot-reuse path, FR-10).
- **FR-4** — Encode-quality keys (`FPS`, `BITRATE`, `SCALE`, `CODEC`) live in each slot's own config, because the server reads its whole config from `$AEASY_DIR`. `aeasy tune` (`bin/aeasy:257-263`) writes to every occupied slot and restarts every occupied slot, preserving its current global meaning. This is a deliberate exception to FR-15, which scopes only *add and remove*; a global quality change restarting every device is the existing behaviour and is what the user asks for by typing a global command.

#### CLI — device context

- **FR-5** — `bin/aeasy` gains one context setter, replacing what would otherwise be a serial parameter on fifteen functions:
  ```sh
  with_dev() {                       # with_dev <slot> <cmd...>
    local -x AEASY_SLOT=$1
    local -x AEASY_SERIAL=$(dev_serial $1)
    local -x AEASY_PORT=$((7355 + 10 * $1))
    local -x AEASY_DIR="$SHARE/dev/$1"
    local CFG="$AEASY_DIR/config"
    shift; "$@"
  }
  ```
  `local -x` in zsh both exports to child processes and unwinds on return, so `aeasy-server` and `aeasy-config` inherit their device context from the environment and existing function bodies keep working unchanged. `conf()` (`bin/aeasy:13`) needs no edit — it already reads `$CFG`. **`with_dev` must not nest**, and the registry readers (`dev_serial`, `dev_slot`, the `DEVICES=` parser) must read `"$SHARE/config"` by explicit path rather than `$CFG`, or inside a `with_dev` frame they would resolve against a per-device config that has no `DEVICES=` and silently return an empty serial.
- **FR-6** *(P-1)* — `adb()` (`bin/aeasy:16-19`) requires a device context:
  ```sh
  adb() {
    if [[ -z "$AEASY_SERIAL" ]]; then
      print -u2 "adb() called with no device context — wrap the call in with_dev"; return 2
    fi
    command adb -s "$AEASY_SERIAL" "$@"
  }
  ```
  A `${AEASY_SERIAL:?…}` expansion was rejected during drafting: in a non-interactive zsh it terminates the **shell**, not the function, so one stray bare call inside `watch_loop` would kill the watcher and with it every slot's supervision — the opposite of the fault isolation this spec is built on. `WIFI_ADDR` disappears from this function: a wireless device's serial *is* `ip:port`, so it is just another `AEASY_SERIAL`.
- **FR-7** — Every server launch appends a `--slot <n>` argv marker after `W H`, and **every process pattern** is scoped to it. The marker is inert on the server, which reads only `arguments[1]`/`arguments[2]` (`AEasyServer.swift:107-111`) and scans for `--ios` by `contains` (`:114`), so this gives a per-process handle with no PID files. All nine sites:
  | Site | Today | Becomes |
  |---|---|---|
  | `server_start` `bin/aeasy:89` | `pkill -f aeasy-server` | `pkill -f "aeasy-serve[r] .*--slot $AEASY_SLOT"` |
  | `ios_server_start` `:100` | same | same |
  | watcher teardown `:150` | `pgrep … && pkill …` | both slot-scoped |
  | watcher liveness `:128`, `:141` | `pgrep -qf aeasy-server` | `pgrep -qf "aeasy-serve[r] .*--slot $AEASY_SLOT"` |
  | `status` `:239` | same | per slot, one line each |
  | `AEasyTray.swift:19` `serverRunning()` | `pgrep -qf 'aeasy-serve[r]'` | per-slot count (FR-33) |
  | `stop` `:173` | `pkill -f aeasy-server` | unchanged — killing everything is correct here |
  | `relay_kill` `:65` | two patterns | FR-8 |
  Scoping the kills without the liveness guards produces a feature that never starts a second device (finding 3), so the two halves ship together.
- **FR-8** — Relays are per-device on **both** legs. `relay_ensure` (`bin/aeasy:55-63`) currently hardcodes 7356 and, in both its USB and Wi-Fi branches, terminates at `TCP:127.0.0.1:7355` — slot 0's listener. Left unscoped, every iOS device would stream slot 0's display. It becomes, under `with_dev`:
  ```sh
  local l=$((AEASY_PORT + 1))
  # Wi-Fi:  socat "TCP:$a:7355" TCP:127.0.0.1:$AEASY_PORT
  # USB:    iproxy $l:7355 -u "$AEASY_SERIAL"
  #         socat TCP:127.0.0.1:$l TCP:127.0.0.1:$AEASY_PORT
  ```
  with every `pgrep`/`pkill` pattern carrying `$l` or `$AEASY_PORT`. Argv order must keep ports before `-u` as written now (`:61`), or the patterns miss. Slot 0 resolves to `iproxy 7356:7355` → `127.0.0.1:7355`, byte-identical to today. A separate `relay_kill_all` loops the registry and is used by `stop` (`:174`) and `usb` (`:290`), which today rely on `relay_kill` being global.
- **FR-9** — `app_open` (`bin/aeasy:107-110`) installs `adb reverse tcp:7355 tcp:$AEASY_PORT`. The device side stays 7355 for every device (finding 2). The existing ordering invariant holds: the reverse rule goes in **before** `am start`, or the app dials a dead loopback and backs off from 200 ms to a 3 s ceiling (`Pane.kt:217-218`) while the user watches `pane_connection_lost`.

#### CLI — surface

- **FR-10** — New subcommands, all driven by the registry:
  - `aeasy device list` — every device the Mac can see, added or not, with slot, name, platform, connection type and app status.
  - `aeasy device add <serial>` — **slot choice is reclaim-first**: if some `dev/<n>/config` records this `SERIAL` and slot `n` is free, reuse `n` so the device keeps its display arrangement (FR-1); otherwise take the lowest free slot and reseed that directory (FR-3). Seeds a new slot config from **slot 0's** config, falling back to built-in defaults when slot 0 does not exist — not from the global config, which after migration holds only `DEVICES=`.
  - `aeasy device rm <serial|slot>` — stops that slot only, frees it, keeps the directory for reclaim, and reassigns `INPUT` if it held it (FR-23).
  - `aeasy device input <serial|slot>` — clears `INPUT` from every slot, then sets it on one.
  - An `add` whose serial is already in `DEVICES=` is rejected. A 4th `add` exits non-zero with `dev_slots_full`. An `add` of a device in a non-`device` adb state is refused with the state's message (FR-20).
- **FR-11** — `restart`, `config`, `log`, `status`, `install-app` and `uninstall` take an optional `<serial|slot>`. Three of these are silently broken today for a slot argument: `restart)` (`bin/aeasy:177-179`) ignores `$2`, `config|--config)` (`:250-256`) both ignores `$2` and runs `pkill -f "$CONFIGAPP"` before launching, and `LOG="$SHARE/server.log"` (`:9`) is global while FR-3 moves `server.log` into the slot directory, so `aeasy log` (`:330`) would tail a file nothing writes. With no argument, `status` and `log` cover every occupied slot; `restart` loops the registry; `install-app`/`uninstall` default to the single registered device and refuse when several are registered.
- **FR-12** — `aeasy wifi` (`:264-289`) takes a device. It uses `command adb -d` at `:273`, `:276`, `:279` and `:281`, which means "the single USB device" and errors with two attached — and the guard at `:273-275` would report "plug in the USB cable first", which is not what failed.
- **FR-13** — Migration from a pre-upgrade install runs once, when `DEVICES=` is absent: `$SHARE/config` is copied to `$SHARE/dev/0/config`, and `layout.json`, `dims` and `dims.ios` move with it. The serial for slot 0 is recovered in order: `WIFI_ADDR`, then `UDID`, then — the common case, because **`bin/aeasy` never records a serial for a cable-connected Android phone** — the single online entry from `adb devices` / `idevice_id -l`. If that enumeration returns more than one device, migration writes no registry and prints which devices it found and the `aeasy device add` command to run; it must not guess, because guessing wrong silently streams to the wrong phone. Until a serial exists, FR-6 makes every `adb` call a loud no-op rather than a wrong-device stream.
- **FR-14** — Both help heredocs are updated — Thai at `bin/aeasy:338-360` and English at `:362-386` — covering the `device` subcommands and the new `<serial|slot>` arguments. Both prior specs made this an explicit requirement; it is the house standard for a new subcommand.

#### Watcher and hot-add

- **FR-15** — Adding or removing a device leaves every other device's **stream, control connection, layout and encode session** untouched: no reconnect, no re-handshake, no `rev` bump, no restart. Deliberately *not* claimed: window arrangement. Creating or destroying a `CGVirtualDisplay` is a global WindowServer reconfiguration that reflows windows across every display and can blank them all briefly (NFR-10).
- **FR-16** — `watch_loop` (`bin/aeasy:124-157`) keeps its 2 s tick. Each tick enumerates online devices **once**, then runs the existing per-platform tick body under `with_dev` for each registry entry. A device that has gone offline has only its own slot's server and relay killed; today the `*)` branch at `:149-152` kills the server whenever `platform()` returns none. The loop holds no in-memory device state — the registry and `pgrep` are re-derived every tick — with exactly one exception, FR-17's backoff, which lives in `$SHARE/dev/<slot>/backoff` so it survives a watcher restart. A `--slot` process whose slot is no longer in `DEVICES=` is killed on the next tick; this is what cleans up after a lost concurrent registry write (NFR-7).
- **FR-17** — A slot whose server exits with a **non-zero status or on a signal** is relaunched with backoff (2 s, 8 s, 30 s, then a 60 s ceiling), the reason logged once per transition; the counter resets after 60 s of survival. The trigger is exit *status*, never time-since-launch: `handleResize` calls `exit(0)` as the **normal** rotation and first-connect mechanism (`AEasyServer.swift:766-771`), typically within seconds of launch, and penalising that would break the iOS spec's NFR-7 rotation budget. Conversely `VTCompressionSessionCreate`'s `fatalError` (`:278`) only fires once a frame reaches the encoder, which on a loaded machine is well past any short window. Without this, an exhausted ninth encoder becomes a 2 s relaunch loop; process isolation contains the blast radius to one device, and the backoff is what stops it spinning.

#### Enumeration and install status

- **FR-18** — Discovery uses no source beyond `adb devices -l` and `idevice_id -l` (D-9). `adb devices -l` supplies the serial and a `model:` field (underscored — good enough for a menu label, and it saves a `getprop` round trip per device, today's `bin/aeasy:232`, `:234`); iOS names come from `ideviceinfo -k DeviceName`. Connection type comes from the serial's shape: `adb connect` devices are `ip:port`, USB serials never contain `:`. One menu-open costs up to seven subprocesses with three devices (FR-19 adds one `adb shell` each), which is what NFR-8 bounds.
- **FR-19** — App-installed status is Android-only (D-7) and uses `adb shell pm list packages dev.ctz.usbdisplay`, matched as `tr -d '\r' | grep -qx "package:$APP"`. Both filters are load-bearing: `adb shell` output is CRLF-terminated, and `pm list packages` does a *substring* match, so an unanchored grep would count `dev.ctz.usbdisplay.debug` as a hit. Exit status is useless — `pm` exits 0 and prints nothing when the package is absent. iOS rows report `n/a`, never a guess.
- **FR-20** — Devices in a non-`device` adb state (`unauthorized`, `offline`) appear in the list with that state shown rather than being filtered out. A phone displaying the USB-debugging dialog is the single most likely thing a first-time user is looking at, and today it is invisible. A listed-but-untrusted iOS device — `idevice_id -l` lists it while `ideviceinfo` returns empty — shows the existing "unlock the device and tap Trust" wording from `bin/aeasy:223-224`. Neither state has a `model:` field, so rows fall back to the serial for their name.

#### Server

- **FR-21** — A per-slot config key `PANEL=<W> <H>` locks that device's virtual display size. When absent — the default, and the state of every existing install — sizing is unchanged: `phone_dims` for Android, the type-3 report for iOS. With `PANEL` set, the Android watcher also skips its `phone_dims` vs `dims` comparison (`bin/aeasy:131-136`); otherwise rotating a locked tablet would still drop the stream and rebuild a display at the same size, for nothing.
- **FR-22** — `handleResize` (`AEasyServer.swift:753-772`) returns early when `PANEL` is set, without writing `dims.ios` and without `exit(0)`. The early return must go **after** `sawTypeThree = true` (`:754`) and before the guard at `:755`: that latch is the iOS spec's FR-26 mechanism, read at `:1104`, and skipping it would leave a `PANEL`-locked iOS device receiving "Open AEasy Display on your iPhone" forever while it streams. Unlocked behaviour is unchanged and stays correct, because that `exit(0)` now ends only its own device's process and FR-17 relaunches only that slot.
- **FR-23** — Mac input control is gated by a per-slot config key `INPUT=1`, enforced by one guard at the top of `handleTouch` (`AEasyServer.swift:531`) — the only site in the repo that synthesises `.cghidEventTap` events (`:554-555`), so one guard covers every caller and window raising (`:552`) is gated with it. Placement is deliberate: the guard must not go in `drainTouch`'s slicing loop (`:729-748`), whose comment at `:725-728` explains that skipping a 5-byte unit desyncs every later packet and a misaligned type-3 reads as a plausible touch. Type-3 continues to be honoured from every device, input holder or not — it is a viewport report, not input, and dropping it would break rotation on a device the user is merely watching. The key is re-read from disk when its file's `mtime` has changed and at most once per second, so a change from any UI takes effect within a second with no restart and no new control message; the cost is one `stat` per second on a queue that already does a `CGDisplayBounds` per event. Exactly one slot carries `INPUT=1`; the clear-then-set pair is written by `aeasy device input` and by both UIs, and `aeasy device rm` reassigns it to the lowest occupied slot when it removes the holder. A device merely going offline does **not** move it — the registry entry is still there, and a cable jiggle silently handing control to another phone with no way back is worse than a dead pointer.
- **FR-24** — The Accessibility prompt (`AEasyServer.swift:1018-1020`) fires only on the slot holding `INPUT`. It is unconditional today, and the comment at `:1019` notes the grant must be redone after every rebuild, so three processes starting together would raise three identical prompts. The grant itself is per-binary, so one is enough (NFR-9). Separately, `notify()` (`:69-74`) is given the device's name, because its two call sites — "Open AEasy Display on your iPhone" (`:1104`) and the decoder-lag warning (`:937`) — would otherwise fire up to three times with identical text and no way to tell which device is complaining.
- **FR-25** — `desc.name` (`AEasyServer.swift:953`) includes the slot, e.g. `AEasy Display 2`. All instances are named `"AEasy Display"` today, so System Settings > Displays would show three identical entries and the user could not tell which one to drag where.

#### Settings window

- **FR-26** — `aeasy config [<serial|slot>]` opens the settings window **for one device** by exporting that slot's `AEASY_DIR` and `AEASY_PORT`. `AEasyConfig.swift` already reads both (`:8`, `:12`), so the existing sources pickers, pane canvas and control link become per-device with no change to the UI builder (`applicationDidFinishLaunching`, `:256-342`). This is the whole of D-12. The blanket `pkill -f "$CONFIGAPP"` (`bin/aeasy:253`) is scoped to the requested slot so two devices' settings windows can be open at once.
- **FR-27** — The window gains a device `NSPopUpButton` as the first row of the existing stack (`:311-321`). `shareDir` and `CTL_PORT` are file-scope `let`s, so switching device relaunches: the app spawns a new instance with the new environment via `Process`, then calls `NSApp.terminate` — in that order, and the new instance must not `pkill` the old one or the two race. The relaunch flicker is accepted; the alternative is threading a device parameter through every path touching those two constants.
- **FR-28** — An **Add Device…** entry in that popup opens a sheet listing FR-18's enumeration. Rows for devices with the app are selectable. Android rows without the app are disabled with an **Install…** button showing instructions (D-8) — it never installs. iOS rows show `n/a` for app status and the same instructions path, since a side-loaded iOS build always needs Xcode.
- **FR-29** — The window gains a per-device **resolution lock** writing `PANEL` (FR-21) and an **input control** radio writing `INPUT` (FR-23). `NSButton(radioButtonWithTitle:)` instances sharing a superview and action get mutual exclusion from AppKit, so the radio costs no state code.
- **FR-30** — `saveTapped` (`AEasyConfig.swift:400-419`) writes into that slot's config and shells `aeasy restart <slot>` (`:414-417`). Left as-is it restarts every device to apply one device's bitrate change.

#### Tray

- **FR-31** — `AEasyTray.swift` gains a **Devices** submenu, rebuilt in the existing `menuWillOpen` (`:58-68`), which already dispatches off the main queue at `:60`. One row per enumerated device: added devices carry `NSMenuItem.state = .on`; toggling adds or removes; devices without the app are disabled and their action raises the install alert, reusing the `NSAlert` + scrollable `NSTextView` shape at `features()` (`:103-116`).
- **FR-32** — A nested **Input control** submenu selects the FR-23 holder. `NSMenu` has no radio grouping, so the action clears every sibling's state and sets the sender's.
- **FR-33** — Three tray-side corrections: a new `shellOut(_:) -> String` helper, because `shell()` sends stdout to `FileHandle.nullDevice` (`:11`) and so cannot read a device list; `serverRunning()` (`:19`) becomes a per-slot count, since one `pgrep -qf 'aeasy-serve[r]'` reports healthy while two of three devices are dead; and `start()`/`stop()` (`:118-119`), which shell the global `aeasy restart` / `aeasy stop` and today would kill all three devices, take the selected slot. `cablePlugged()` (`:20-22`) is replaced by the enumeration.
- **FR-34** — `Tray.featuresText` (`:71-101`) is a hardcoded bilingual copy of `FEATURES.md`, flagged as such by the `ponytail:` comment above it, and it contains the "up to 3 sources" line FR-36 rewords. It is updated in the same commit.

#### Test harness

- **FR-35** *(P-3)* — `test/smoke.py`'s `Server.__init__` (`:50`) takes `port`, `panel` and `slot`, replacing the module constants `PORT` (`:28`) and `PANEL` (`:29`) as its defaults, and appends `--slot` to the argv it launches (`:57`). A new `test/cli.sh` holds the shell-level assertions and is added to the `check` target (`Makefile:40-41`), which must stay permission-free and device-free — it is the CI gate.

#### Documentation

- **FR-36** — `README.md:217` / `README.th.md:217` ("One phone at a time" / "ต่อมือถือได้ทีละเครื่อง") are rewritten, and `SETUP.md:112`'s "Wrong device picked (several attached) — unplug the extra" row becomes a pointer to `aeasy device add`. `FEATURES.md`, `FEATURES.th.md`, `COMPARISON.md`, `COMPARISON.th.md`, `SETUP.md` and `SETUP.th.md` gain a multi-device line, worded so it does not collide with the existing "up to 3 sources" line, which is about Mac-side sources and is routinely misread as multi-device.

### Non-functional

- **NFR-1** — Zero client changes. The shipped APK and iOS app must work unmodified against all three slots; `git diff --stat android/ ios/` is empty at PR time.
- **NFR-2** — Zero wire-protocol changes. `git diff mac/Protocol.swift` is empty. Device identity comes from the socket's port, not from the bytes.
- **NFR-3** — Every slot's `NWListener` stays loopback-only. Verified per slot with `lsof -nP -iTCP:<port> -sTCP:LISTEN`.
- **NFR-4** — Slot 0 is byte-for-byte today's behaviour: port 7355, iproxy 7356, display serial 1, `$SHARE/dev/0/config` seeded from the existing `$SHARE/config`. An existing install must upgrade without losing its arrangement, layout or sources.
- **NFR-5** — There is **no** cross-device bitrate or pixel governor, deliberately. Each process keeps `bitrateBudget` (`AEasyServer.swift:99-104`) over its own source count, so three devices at three sources each is 3× today's aggregate — up to 9 concurrent `SCStream`s and `VTCompressionSession`s. The enforceable guarantee is the 3×3 cap plus FR-17's backoff, not a scheduler. macOS documents no concurrent-`SCStream` limit and nothing in the repo has tested one; encoder-session exhaustion at `:278` is the real ceiling and is now contained to one device.
- **NFR-6** — A serial is accepted only if it matches `^[A-Za-z0-9._:-]+$`, anchored at both ends. Unanchored, the pattern matches `R5CT;rm -rf ~`. Serials arrive from `adb devices` output, and `$SHARE/dev/<slot>` is keyed by slot precisely so no serial ever becomes a path component (FR-3).
- **NFR-7** — Registry read-modify-write is serialised by an `mkdir`-based lock and writes through a `mktemp` file (P-2). Two UIs can add a device concurrently; the loser's entry may be lost, but the file is never torn, and FR-16 kills any `--slot` process whose slot is absent from the registry.
- **NFR-8** — Enumeration never runs on the main queue and its result is cached for the life of one menu-open. `adb`/`idevice_id` can block for seconds on an unresponsive device, and one menu-open costs up to seven subprocesses (FR-18). The tray already dispatches at `AEasyTray.swift:60`; `AEasyConfig.swift` has **no** existing off-main shell-out — its only `Process` (`:414-417`) runs on the main queue — so the add-device sheet adds a new background dispatch rather than inheriting one.
- **NFR-9** — One Accessibility grant covers all three processes: TCC keys on the binary's identity, and all slots run the same `$SHARE/aeasy-server` (`bin/aeasy:5`). FR-24 is what keeps the *prompt* from firing three times.
- **NFR-10** — Display reconfiguration is global and is **not** isolated. Creating or destroying a `CGVirtualDisplay`, and `CGDisplaySetDisplayMode` (`AEasyServer.swift:1075`), each trigger a WindowServer reconfiguration that reflows windows across every display and may blank all of them for a moment. Adding or removing a device therefore disturbs the *desktop* even though it does not disturb the other devices' *streams* (FR-15). This is the same behaviour as plugging in a real monitor; it is documented in `SETUP.md`, not engineered around.

### Accessibility

- **A11Y-1** — Device state in the tray is carried by `NSMenuItem.state` and by the item's title, never by colour alone.
- **A11Y-2** — Disabled "app not installed" rows say why in their title, so VoiceOver announces the reason rather than an unexplained disabled item.
- **A11Y-3** — The install-instructions alert uses selectable text so commands can be copied, matching `features()`' scrollable `NSTextView`.
- **A11Y-4** — The settings window's content stack is wrapped in an `NSScrollView`. It is 520×700 with a fixed `[.titled, .closable]` style mask (`AEasyConfig.swift:326-327`) and a 230 pt canvas; the new rows overflow that on a 13" laptop, and `.resizable` alone would let the window grow but not shrink to fit.

## Data model

`~/.local/share/aeasy/config` — global. After migration it holds the registry and nothing device-specific:

```
DEVICES=0:android:R5CT12ABCDE,1:ios:00008030-001A2B3C4D5E,2:android:192.168.1.42:5555
```

`~/.local/share/aeasy/dev/<slot>/config` — one per device, the full config its server reads:

```
SERIAL=R5CT12ABCDE       # cross-check against DEVICES=; mismatch means a stale slot (FR-3)
PLATFORM=android
SOURCES=display,window:Code
PANEL=1080 2400          # optional; absent = auto-size (FR-21)
INPUT=1                  # at most one slot carries this (FR-23)
FPS=20
BITRATE=2000000
SCALE=60
CODEC=h264
```

Siblings in the same directory, all already written relative to `shareDir`: `layout.json` (`AEasyServer.swift:162`), `dims` (`bin/aeasy:91`), `dims.ios` (`AEasyServer.swift:768`), `server.log`, `backoff` (FR-17).

Ports and identity, derived from the slot and never stored twice:

| Slot | Server port | iproxy local | socat → | Display serial | Display name | Device-side port |
|---|---|---|---|---|---|---|
| 0 | 7355 | 7356 | 7355 | 1 | AEasy Display | 7355 |
| 1 | 7365 | 7366 | 7365 | 7365 | AEasy Display 2 | 7355 |
| 2 | 7375 | 7376 | 7375 | 7375 | AEasy Display 3 | 7355 |

## API / Interface changes

### Wire protocol

**Unchanged.** No row of the multi-source spec's protocol table is edited. Stated explicitly because it is this spec's main claim.

### Environment contract (already exists, now load-bearing)

| Variable | Read by | Effect |
|---|---|---|
| `AEASY_PORT` | `AEasyServer.swift:24`, `AEasyConfig.swift:12` | listener port; also the display's `serialNum` (`:960`) |
| `AEASY_DIR` | `AEasyServer.swift:36`, `AEasyConfig.swift:8` | config, `layout.json`, `dims`, `dims.ios`, `server.log` |
| `AEASY_SERIAL` | `bin/aeasy` `adb()` | the `-s` target for every adb call |
| `AEASY_SLOT` | `bin/aeasy` | `--slot` marker and every `pgrep`/`pkill` scope |

### Shell — `bin/aeasy`

| Site | Change |
|---|---|
| `adb()` `:16-19` | `-s "$AEASY_SERIAL"`, explicit guard, `WIFI_ADDR` removed (FR-6) |
| `plugged()` `:21` | takes a serial |
| `platform()` `:29-37` | probing becomes add-time only; the registry stores the answer |
| `ios_udid()` `:39-43` | deleted — the UDID is the device key |
| `relay_ensure()`/`relay_kill()` `:55-65` | per-slot ports on both legs, `relay_kill_all` added (FR-8) |
| `set_sources` `:85`, `tune` `:259`, `wifi` `:268`, `:286`, `usb` `:293` | `mktemp` instead of the shared `"$CFG.tmp"` (P-2) |
| `server_start` `:88-94`, `ios_server_start` `:99-105` | slot-scoped kill, `--slot` marker, `$AEASY_DIR/dims` |
| `app_open` `:107-110` | `adb reverse tcp:7355 tcp:$AEASY_PORT` |
| `session_restart` `:115-122` | optional slot; no arg loops the registry |
| `watch_loop` `:124-157` | per-slot tick under `with_dev`, scoped `pgrep` at `:128`/`:141`/`:150` (FR-16, FR-17) |
| `stop` `:171-174` | keeps the global server kill; gains `relay_kill_all` |
| `restart` `:177-179` | forwards `$2` as a slot (FR-11) |
| `status` `:214-249` | per-slot blocks; scoped `pgrep` at `:226`, `:227`, `:239` |
| `config` `:250-256` | passes `AEASY_DIR`/`AEASY_PORT`; scoped `pkill` at `:253` (FR-26) |
| `wifi` `:264-289` | takes a device; `adb -d` at `:273`, `:276`, `:279`, `:281` (FR-12) |
| `install-app` `:297-315`, `uninstall` `:316` | take a device |
| `log` `:330` | per-slot `server.log`; `LOG` at `:9` is no longer a single path |
| help `:338-386` | both heredocs (FR-14) |
| new | `with_dev`, `dev_serial`, `dev_slot`, `devices_list`, `migrate`, `device` subcommand |

### Swift — `mac/AEasyServer.swift`

Four guards and two strings; no structural change:

- `handleTouch` `:531` — `INPUT` gate, mtime-checked re-read (FR-23).
- `handleResize` `:753` — early return when `PANEL` is set, placed after `:754` (FR-22).
- Startup — prefer `PANEL` over argv `W H` (FR-21); prompt for Accessibility only on the input slot `:1018-1020` (FR-24).
- `notify()` `:69-74` — takes the device name (FR-24). `desc.name` `:953` — includes the slot (FR-25).

### Swift — `mac/AEasyConfig.swift`

Device popup and relaunch (FR-27), Add Device sheet (FR-28), `PANEL`/`INPUT` controls (FR-29), per-slot save (FR-30), `NSScrollView` (A11Y-4).

### Swift — `mac/AEasyTray.swift`

`shellOut()`, per-slot `serverRunning()`, scoped `start`/`stop` (FR-33), Devices and Input submenus (FR-31, FR-32), `featuresText` (FR-34).

### Test — `test/smoke.py`, `test/cli.sh`, `Makefile`

`Server` takes `port`/`panel`/`slot` (FR-35); new `test/cli.sh` wired into the `check` target.

## Copy

`%1$s` is the device's name, falling back to its serial when no name is available — which is exactly the `unauthorized`, `offline` and untrusted-iOS cases these strings exist for (FR-20).

| key | English | ไทย |
|---|---|---|
| `menu_devices` | Devices | อุปกรณ์ |
| `menu_add_device` | Add Device… | เพิ่มอุปกรณ์… |
| `menu_input_control` | Input control | สิทธิ์ควบคุมเมาส์ |
| `dev_status_count` | %1$d of 3 devices · input: %2$s | %1$d จาก 3 เครื่อง · ควบคุม: %2$s |
| `dev_no_app` | %1$s — app not installed | %1$s — ยังไม่ได้ติดตั้งแอพ |
| `dev_unauthorized` | %1$s — allow USB debugging on the device | %1$s — กดอนุญาต USB debugging บนเครื่อง |
| `dev_untrusted` | %1$s — unlock the device and tap Trust | %1$s — ปลดล็อกเครื่องแล้วกด Trust |
| `dev_offline` | %1$s — offline | %1$s — ออฟไลน์ |
| `dev_already_added` | %1$s is already added | เพิ่ม %1$s ไว้แล้ว |
| `dev_slots_full` | Maximum 3 devices | ใช้ได้สูงสุด 3 เครื่อง |
| `dev_migrate_ambiguous` | Several devices are connected — add the one you want with: aeasy device add <id> | มีหลายเครื่องเชื่อมต่ออยู่ — เลือกเครื่องที่ต้องการด้วย: aeasy device add <id> |
| `btn_install` | Install… | ติดตั้ง… |
| `install_title` | Install AEasy on this device | ติดตั้ง AEasy บนเครื่องนี้ |
| `install_android` | Plug the device in over USB, then run:\n\n  aeasy install-app %1$s\n\nUSB debugging must be on. | เสียบสาย USB แล้วรัน:\n\n  aeasy install-app %1$s\n\nต้องเปิด USB debugging ไว้ก่อน |
| `install_ios` | iOS needs Xcode to sign the app. Open ios/AEasyDisplay.xcodeproj, pick this device, and press Run. | iOS ต้องใช้ Xcode เซ็นแอพ เปิด ios/AEasyDisplay.xcodeproj เลือกเครื่องนี้ แล้วกด Run |
| `lbl_device` | Device | อุปกรณ์ |
| `lbl_panel_lock` | Lock resolution | ล็อกความละเอียด |
| `lbl_panel_auto` | Auto (device panel) | อัตโนมัติ (ตามจอเครื่อง) |
| `lbl_takes_input` | This device controls the Mac | ให้เครื่องนี้ควบคุม Mac |
| `err_bad_serial` | Unrecognised device id | รหัสอุปกรณ์ไม่ถูกต้อง |
| `notify_open_app` | Open AEasy Display on %1$s | เปิดแอพ AEasy Display บน %1$s |
| `notify_decoder_lag` | %1$s can't keep up — lower the bitrate | %1$s ตามไม่ทัน ลองลด bitrate |

## Edge cases & error handling

| Case | Behaviour |
|---|---|
| Two Android devices attached, any bare `adb` call | The wrapper prints to stderr and returns 2 (FR-6); the caller's slot fails its tick and the watcher moves on. Never the swallowed "more than one device", never a shell exit. |
| Device added over Wi-Fi, serial is `192.168.1.42:5555` | Parsed correctly: FR-2 puts the serial last, so its colons stay in the serial field. |
| Existing USB-only install upgrades, config has no `WIFI_ADDR`/`UDID` | The single online enumerated device becomes slot 0's `SERIAL` (FR-13). This is the common upgrade path — `bin/aeasy` never records a serial for a cabled phone. |
| Upgrade with two devices already attached | No registry is written; `dev_migrate_ambiguous` names them and the user picks. Guessing would silently stream to the wrong phone. |
| A 4th device is added | `dev_slots_full`, non-zero exit; the tray row is disabled. |
| The same serial is added twice | Rejected with `dev_already_added`. |
| Slot freed, then the same device re-added | Reclaims its old slot (FR-10), so its port, display serial, arrangement, layout and sources all come back. |
| Slot freed, then a *different* device takes it | The `SERIAL=` cross-check fails, so `layout.json` and `dims` are discarded and the slot reseeds from slot 0 (FR-3). |
| One physical Android added twice, once by USB serial and once by `ip:port` | Both slots issue `adb reverse tcp:7355 …` to the same device; the second **replaces** the first, because the reverse table is keyed by device-side port, and slot 0 goes dark. `aeasy device add` refuses when `ro.serialno` matches an existing entry's. |
| Device unplugged while streaming | Only that slot's server and relay are killed (FR-16). Its virtual display disappears and macOS reflows windows across the remaining displays (NFR-10). It keeps its registry entry and its `INPUT` flag. |
| The input holder is removed with `aeasy device rm` | `INPUT=1` moves to the lowest occupied slot; if none remain, nothing holds it. Merely going offline does not move it (FR-23). |
| Two slots somehow both carry `INPUT=1` | Both accept touches — the config is the only arbiter and there is no cross-process lock. Every writer does clear-then-set, so this is a hand-edited config; the tray shows two checkmarks so it is visible rather than mysterious. |
| Ninth encoder fails (`VTCompressionSessionCreate`, `:278`) | That device's process dies with a non-zero status; the other two are untouched. FR-17 backs off to a 60 s retry and logs the reason once. |
| iOS device rotates | Its own `handleResize` writes its own `dims.ios` and calls `exit(0)`; FR-17 does not penalise a zero exit, so the watcher relaunches it on the next tick. With `PANEL` set, no restart at all (FR-22). |
| Android device rotates with `PANEL` set | The watcher skips the `dims` comparison (FR-21); no restart, no reconnect. |
| `PANEL` set to a size the device cannot display | Honoured; the app scales to fit. A `PANEL` with a zero or non-numeric field is ignored with a log line and auto-sizing is used. |
| Settings window open when its device is removed | Its control link fails and shows disconnected, as it already does across a restart. The device popup no longer lists it. |
| Two settings windows open for two devices | Supported — FR-26 scopes the `pkill` to the requested slot. Each writes only its own slot's config. |
| Two UIs add a device at the same instant | The `mkdir` lock serialises them (NFR-7); the loser retries and sees the winner's entry. A server left running for a slot that lost is killed on the next watcher tick (FR-16). |
| `adb devices` hangs on a dead device | Enumeration runs off the main queue with a per-menu-open cache (NFR-8); the previous list is shown rather than beach-balling. |
| Serial containing a shell metacharacter | Rejected by NFR-6's anchored pattern with `err_bad_serial`. |
| `pm list packages` returns only `package:dev.ctz.usbdisplay.debug` | Counted as not installed — `grep -qx` anchors the match (FR-19). |
| Slot 0 still running without `--slot` after an upgrade | The first `aeasy restart` relaunches it with the marker. Until then a scoped `pkill` would miss it, so `session_restart` falls back to the unscoped kill exactly once, when `DEVICES=` is absent. |
| `aeasy stop` with three devices | The unscoped server `pkill` (`:173`) is still correct; `relay_kill_all` (FR-8) is what stops the other slots' iproxy processes from being orphaned on 7366/7376. |
| Accessibility not yet granted, three devices starting | Only the input slot prompts (FR-24). The other two log the `no_accessibility` control message as today. |

## Test plan

`make check` stays the CI gate: pure, no permissions, no attached device (`Makefile:40-41`). Shell-level rows run there via a new `test/cli.sh` with `adb`/`idevice_id` stubbed on `PATH`. `make smoke` (`:43-44`) runs the rows that need real servers, a real virtual display and — for T-11 and T-12 — Accessibility; it depends on FR-35's parameterised `Server`.

| # | Covers | Harness | Assertion |
|---|---|---|---|
| T-1 | FR-2 | cli.sh | Three registry entries, one with an `ip:port` serial, round-trip to the same slot/platform/serial triples. |
| T-2 | FR-1, FR-10 | cli.sh | Add allocates the lowest free slot; removing and re-adding the same serial reclaims its original slot; a 4th add and a duplicate serial each exit non-zero. |
| T-3 | FR-5, FR-6 | cli.sh | Inside `with_dev`, `adb` runs with `-s $AEASY_SERIAL`; outside it, the call returns 2, prints to stderr, and **the shell survives** — asserted by a following command in the same script still running. |
| T-4 | FR-5 | cli.sh | `dev_serial` called inside a `with_dev` frame still reads `DEVICES=` from the global config, not from the per-device one. |
| T-5 | FR-7 | cli.sh | Every `pgrep`/`pkill` pattern in `bin/aeasy` that names `aeasy-server` carries `--slot`, except the one in `stop)`. A grep-based structural assertion, because the failure mode is an easily-missed site rather than a behaviour. |
| T-6 | FR-8 | cli.sh | The generated relay commands for slot 1 are `iproxy 7366:7355 -u <udid>` and a socat terminating at `127.0.0.1:7365`, with matching `pgrep` patterns; slot 0's are byte-identical to today's. |
| T-7 | FR-9 | cli.sh | The reverse rule is `tcp:7355 tcp:<slot port>`, in that order, and `app_open` issues it before `am start`. |
| T-8 | FR-13 | cli.sh | A synthetic pre-upgrade `$SHARE` (config, `layout.json`, `dims`, no `DEVICES=`) with one stubbed online device migrates to slot 0 with layout, sources and serial intact; with two online devices it writes no registry and exits non-zero. |
| T-9 | NFR-6, NFR-7 | cli.sh | A serial containing `;` or `$(` is rejected; twenty concurrent `device add` runs leave a parseable `DEVICES=` with no duplicate slots. |
| T-10 | FR-17 | cli.sh | A stub server exiting non-zero is retried at 2/8/30/60/60 s and logged once per transition; a stub exiting **0** is retried on the next 2 s tick with no backoff; the counter resets after 60 s of survival; backoff state survives killing and restarting the watcher. |
| T-11 | FR-23 | smoke | Two servers, `INPUT=1` on slot 1 only, with disjoint `CGDisplayBounds` asserted as a precondition: a touch on slot 1 moves the cursor, an identical touch on slot 0 leaves it unmoved after a 500 ms settle. |
| T-12 | FR-23 | smoke | After flipping `INPUT` on disk, a touch on the new holder within 1 s moves the cursor and a touch on the old holder does not — neither server restarts and neither client reconnects. The transfer is triggered by the touch, so the test must send one. |
| T-13 | FR-23 | smoke | A type-3 packet from the non-input slot is still honoured, and the 5-byte grid stays aligned: a touch packet sent immediately after it lands at the expected coordinate on the input slot. |
| T-14 | FR-15 | smoke | Two servers streaming; starting a third leaves the first two's sockets open, produces no new `client subscribed` line in their logs, no `rev` bump in their `layout.json`, and no gap in their `sent` counters across the event. "No frame gap" is deliberately not asserted — ScreenCaptureKit is change-driven and an idle desktop emits nothing (multi-source spec, Background 3). |
| T-15 | FR-7, FR-15 | smoke | `pkill -f "aeasy-serve[r] .*--slot 1"` leaves slots 0 and 2 alive and serving, by the same observables as T-14. |
| T-16 | FR-3, FR-21 | smoke | Each slot reads its own `SOURCES` and writes its own `layout.json`; a layout change on slot 1 does not touch slot 0's file. With `PANEL=800 600`, the display is 800×600 regardless of argv `W H`. |
| T-17 | FR-22 | smoke | With `PANEL` set, a type-3 reporting a different size neither writes `dims.ios` nor exits, **and** the `--ios` "open the app" notification does not fire, proving `sawTypeThree` was still latched. Without `PANEL`, both the write and the exit happen. |
| T-18 | FR-1, FR-25 | smoke | Slots 0/1/2 bind 7355/7365/7375 and their displays report serials 1/7365/7375 and names `AEasy Display`/`AEasy Display 2`/`AEasy Display 3`. Requires the startup log at `AEasyServer.swift:1015` to include the serial and name — it logs only the display id today, so this is a one-line change carried by FR-25. |
| T-19 | NFR-3 | smoke | All three listeners bind `127.0.0.1`, asserted per port with `lsof`. |
| T-20 | FR-16 | cli.sh | A registry entry whose device is offline has only its own slot killed; a running `--slot` process whose slot is absent from `DEVICES=` is killed on the next tick. |
| T-21 | FR-18, FR-19, FR-20 | cli.sh | Against stubbed `adb`/`idevice_id`: the installed check matches `package:dev.ctz.usbdisplay` with a trailing `\r` and rejects `…usbdisplay.debug`; `ip:port` serials are typed `wifi` and others `usb`; `unauthorized` and `offline` rows appear with the serial as their name; iOS rows report `n/a`. |
| T-22 | FR-11, FR-12 | cli.sh | `restart 1`, `config 1`, `log 1` and `status` each act on the named slot; `aeasy wifi <serial>` passes `-s <serial>` and never `-d`. |
| T-23 | NFR-1, NFR-2 | check | `git diff --stat` against the merge base is empty for `android/`, `ios/` and `mac/Protocol.swift`. |
| T-24 | FR-4, FR-14 | cli.sh | `aeasy tune` writes the quality keys into every occupied slot's config and restarts every occupied slot. Both help heredocs mention every `device` subcommand — a grep-based assertion, since the Thai and English texts drift apart otherwise. |

Manual matrix, recorded in the PR:

| # | Covers | Steps |
|---|---|---|
| M-1 | D-1, FR-25 | Two Android phones plus an iPad: three virtual displays appear in System Settings > Displays, distinguishable by name, arrangeable independently, each showing different Mac content. |
| M-2 | FR-15, NFR-10 | Add the third device from the tray while two stream. Neither existing stream reconnects (their phones show no "connecting" state). Windows reflowing across displays at the moment the new display appears is expected and is recorded, not filed as a bug. |
| M-3 | FR-8, D-4 | One Android and one iPhone streaming at once; unplug the iPhone and confirm the Android stream and its `adb reverse` rule survive, and that no orphan `iproxy`/`socat` is left (`pgrep -f iproxy`). |
| M-4 | FR-23, FR-32 | Grant input to device 2 from the tray; taps on device 2 move the cursor, taps on 1 and 3 do nothing. Grant it back; the switch takes effect with no restart. Then start a drag on the holder and tap another device mid-drag — the drag must not be hijacked. |
| M-5 | FR-28, FR-31 | A phone without the app appears in both the tray and the add sheet, is not addable, and its Install… button shows copyable instructions and installs nothing. |
| M-6 | FR-20 | A phone showing the USB-debugging dialog appears as `unauthorized` named by its serial; accepting the dialog makes it addable on the next menu open. |
| M-7 | FR-26, FR-27, FR-30 | Open settings for device 2, change its sources and bitrate, save: device 2 restarts, devices 1 and 3 keep streaming. Switch the popup to device 3 and confirm exactly one settings window remains, pointed at device 3. Open a second window for device 1 alongside it. |
| M-8 | FR-21, FR-29 | Lock a tablet to a non-native resolution; rotate it and reconnect it — the size holds and `aeasy log <slot>` shows no restart. |
| M-9 | NFR-4, FR-13 | Upgrade a live single-device USB install: the display keeps its arrangement, layout and sources, and nothing needs re-adding. |
| M-10 | FR-24 | With Accessibility revoked, start three devices: exactly one prompt appears. Trigger the iOS "open the app" and the decoder-lag notifications and confirm each names its device. |
| M-11 | A11Y-1..4 | VoiceOver: device rows announce state and the not-installed reason; the install alert's text is selectable; the settings window scrolls to reach every control at 1280×800. |
| M-12 | NFR-5 | Three devices × three sources: record the combination at which encoder exhaustion first appears. **Pass condition:** whichever device fails, the other two keep streaming and the failing slot backs off rather than looping. The measured ceiling goes into `SETUP.md` as the documented practical limit. |

Verified by code review at PR time rather than by an assertion: **NFR-8, NFR-9, NFR-10** (structural or environmental properties, with M-2 and M-10 as their behavioural evidence); **FR-33** and **FR-34** (the tray's three corrections and its hardcoded `featuresText`, all reviewable as a diff and all exercised by M-2/M-5); **FR-35** (the harness change is proven by every `smoke` row above running at all); and **FR-36** (documentation, checked against the six-file bilingual list — the pairs `README`/`README.th`, `FEATURES`/`FEATURES.th`, `COMPARISON`/`COMPARISON.th` and `SETUP`/`SETUP.th` must land in the same commit, which is the house standard both prior specs set).

## Open questions

All resolved during analysis and drafting; recorded as question → answer pairs. **D-1…D-12** are the requester's decisions and are cited throughout; the remainder were resolved while drafting.

- **D-1** — Do several devices mirror one screen, or does each get its own? → Its own virtual display; an extended desktop per device, not a mirror. *(Analysis)*
- **D-2** — What happens when devices have different panel sizes? → Nothing — each process sizes its own display. The resolution lock the question called for ships as an optional override (FR-21), but the conflict it was meant to settle does not exist under one process per device. *(Analysis; motivation revised during drafting)*
- **D-3** — How many devices? → 3. *(Analysis)*
- **D-4** — Android and iOS at the same time? → Yes, any mix. Free under per-device relays; `newConnectionLimit = 1` stops mattering because each iOS device has its own. *(Analysis)*
- **D-5** — Where does the add button live? → Both the settings window and the tray menu. *(Analysis)*
- **D-6** — Does adding a device restart the others? → No. Their streams, control connections and layouts are untouched; the desktop's window arrangement is not protected and cannot be (NFR-10). *(Analysis; scope narrowed during drafting)*
- **D-7** — How is "app installed" detected? → `pm list packages`, Android only, anchored and CR-stripped. iOS reports `n/a`. *(Analysis)*
- **D-8** — What does the button on a device without the app do? → Shows install instructions; it never installs. *(Analysis)*
- **D-9** — Which devices can the list show? → Only what `adb devices` and `idevice_id -l` already see. No network scan; the iOS spec's no-Bonjour decision stands. *(Analysis)*
- **D-10** — Can several devices control the Mac at once? → No. Exactly one holds input, user-selectable. *(Analysis)*
- **D-11** — How is the device set persisted? → `DEVICES=<slot>:<platform>:<serial>` in the flat config, plus a per-slot directory. Slot-first ordering so Wi-Fi serials containing colons survive parsing. *(Drafting)*
- **D-12** — Does each device get its own panes? → Yes, and it costs nothing: per-device `AEASY_DIR` already gives each process its own `SOURCES` and `layout.json`. *(Analysis)*
- One process with N device sessions, or N processes? → N processes. The env-var parameterisation already exists; the single-process variant was costed at a near-total rewrite of `AEasyServer.swift` plus protocol and GUI changes, and it would lose fault isolation. *(Drafting)*
- Does the wire protocol need a device id? → No. One listener per device means the socket *is* the identity, which is also what keeps the shipped Android and iOS binaries working unmodified. *(Drafting)*
- Do the client apps need any change? → None. `adb reverse` is per-device so the device-side port stays 7355, and `iproxy -u <UDID>` gives each iOS device its own relay. *(Drafting)*
- How does input control switch without a restart or a new control message? → The server re-reads its own `INPUT` key on the touch path, gated by the file's mtime and to at most once per second. *(Drafting)*
- What stops a failing device relaunching every 2 seconds? → Per-slot backoff keyed on **exit status**, not on time-since-launch, because `exit(0)` is the normal rotation mechanism. State lives in the slot directory so it survives a watcher restart. *(Review)*
- Is scoping the `pkill`s enough for hot-add? → No. The four `pgrep -qf aeasy-server` liveness guards are just as fatal: with slot 0 alive they report every other slot as running, so the watcher would never start a second device. Both sets ship together (FR-7). *(Review)*
- Does the tmp+rename in `bin/aeasy` make config writes safe? → No. Every writer shares one `"$CFG.tmp"` path, so concurrent writers interleave and `mv` installs the torn result atomically. A lock and `mktemp` are a prerequisite, not a refinement (P-2). *(Review)*
- Can the existing smoke harness run three servers? → Not today — its port and panel are module constants and `Server.__init__` takes neither. Parameterising it is a prerequisite (P-3), not an afterthought. *(Review)*
- What is *not* isolated between devices? → The cursor (solved by FR-23), the Accessibility prompt and notifications (FR-24), the display name (FR-25), and window reflow on display add/remove — which is inherent to macOS and is documented rather than engineered around (NFR-10). *(Review)*
