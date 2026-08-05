# Spec: iOS client (iPhone & iPad)

**Date:** 2026-08-05
**Status:** draft
**Goal:** Ship an iOS viewer app that turns an iPhone or iPad into a second display for the Mac, with the same feature set the Android client has today, without changing how the Android path behaves.

## Background

AEasy Display streams a macOS virtual display to an Android phone: `mac/aeasy-server` creates a `CGVirtualDisplay` sized to the phone panel, captures it with ScreenCaptureKit, hardware-encodes H.264/HEVC, and serves the Annex-B stream on TCP `:7355`. `adb reverse` tunnels the phone's `localhost:7355` to that listener over USB. The phone sends 5-byte touch packets back up the same socket, which the Mac injects as `CGEvent` mouse events.

Three facts drive the design.

**1. Every piece of device knowledge comes from `adb shell`.** `bin/aeasy` shells out to `adb` at 18 call sites — panel resolution (`wm size`), rotation (`dumpsys display`), foreground check (`dumpsys window`), liveness (`pidof`), app launch (`am start`), APK install, wireless setup (`tcpip`), and the transport itself. None has an iOS equivalent. `libimobiledevice`/lockdownd gives device attach/detach and a model name, but **not** screen resolution, scale, or orientation. So sizing and rotation must move into the wire protocol.

**2. The USB connection direction inverts.** `usbmuxd` only lets the Mac dial *into* a port on the device; there is no `adb reverse` primitive. On iOS the app listens and something on the Mac connects — the opposite of today. This is confirmed against `usbmuxd`'s `device_start_connect()`, which synthesizes a real TCP handshake terminating on the device's own `127.0.0.1:<port>`, and against shipping precedent: OpenDisplay's iOS entitlements file is an empty `<dict/>` and it listens on device port 9000 under a free Apple ID. No entitlement is needed.

**3. Because of #2, the Mac ends up with two listeners that cannot talk to each other** — `aeasy-server` on `:7355` and `iproxy` on `:7356`. Something must connect to both. Rather than rewrite `TCPServer` into an outbound client (which pulls in `NWConnection` re-dial bookkeeping, `.waiting`-state handling, and a nasty auto-tune failure mode — see the Open questions), a one-line `socat` relay bridges them and **`aeasy-server`'s listener is not touched at all**. That makes "no Android regression" true by construction instead of by review. (Routing type-3 does still change the upstream drain — see the multi-source interaction section.)

**On iPad:** Sidecar already does this natively, free, over the same cable, with Apple Pencil support; it only needs an Apple ID with 2FA. iPad support here is for users who will not sign in, and the README must say so rather than pretend we compete. iPhone is the real target — Sidecar excludes iPhone, Universal Control excludes iPhone, and iPhone cannot be an AirPlay receiver for a Mac.

## Interaction with the multi-source panes spec

`specs/2026-08-05-multi-source-panes.md` is not a parallel draft — **its step 1a Mac side is already implemented in the working tree, uncommitted.** `mac/AEasyServer.swift` is 1034 lines against HEAD's 400: `Source`, `LayoutStore`, the `AEZ1` handshake, loopback-only binding, per-source step-down, no `AUTO`, no `exit(0)` in the health check. `test/smoke.py` exists and `Makefile:35` already runs it as `make check`. What has *not* landed is the Android side, the `bin/aeasy` side (still writes `MODE`/`WINDOW_APP`/`AUTO`), and step 1b.

**This spec therefore rebases onto that code; it is not a symmetric merge.** Every requirement below is written against the working tree, not HEAD. No feature from either spec is dropped. The rules that make them coexist:

- **Framing.** The receive loop is now `minimumIncompleteLength: 1, maximumLength: 65536` (`:605`). The 5-byte grid is held by `drainTouch`'s fixed-stride slicing (`:702-707`), *not* by the reader — so a type-3 packet survives chunking, including a split across two TCP segments, and the invariant to protect is the remainder handling plus "exactly one outstanding receive per connection".
- **Type-3 is currently dropped on purpose.** `handleTouch:519` already carries `guard type < 3 else { return }  // type 3+ is reserved (see specs/2026-08-05-ios-client.md)`. This spec fills that hole.
- **Type-3 is process-global, not per-source.** It declares the phone panel, which drives `pxW`/`pxH`, the virtual display geometry, the `viewport` control message and `defaultPane`'s offsets. It is honoured on exactly one connection class and ignored everywhere else (FR-7).
- **The iOS client is a legacy viewer, by construction.** Its first upstream byte is `0x03`, and `ingest:636` classifies any non-`0x41` first byte as legacy → primary source. Since `parseSources` forces `display` to index 0, an iOS client gets the virtual display whenever one exists. It gets exactly **one fullscreen pane** in phase 1 — not by policy but because one `socat` process carries one connection and both ends are listeners, so neither side can originate a second.
- **The socat relay makes multi-source NFR-2 *stronger*, not weaker.** Both USB (`socat TCP:127.0.0.1:7356 …`) and Wi-Fi (`socat TCP:$IOS_ADDR:7355 …`) run on the Mac and dial Mac loopback, satisfying `requiredLocalEndpoint` unchanged. Multi-source's line 60 caveat describes this spec's *abandoned* `--connect` design and must be deleted.
- **Restart triggers do not intersect.** Multi-source deletes restart-on-lag; this spec keeps restart-on-resize. Multi-source's own edge-case table already accepts that rotation restarts the server.

Three consequences that need stating rather than fixing:

1. A rotation restart drops every video **and control** connection — including the step-1b settings canvas — and discards all in-memory `Source.step` degradation state. FR-25's reconnect-with-backoff covers the canvas; the step reset is accepted.
2. With `SOURCES=display,window:A,window:B` the server encodes three sources while an iOS client consumes one, and NFR-5's 60/20/20 split gives that pane 60 % of the budget. `SOURCES=display` is the recommended iOS default; `aeasy status` surfaces the count.
3. If `SOURCES` contains no `display` entry, no source satisfies `isDisplay`, so type-3 is honoured nowhere and rotation does not resize. That is the correct outcome — it is this spec's old "mirror mode" case, now expressed as source kind rather than `vdispID == 0`.

## Scope

### In scope

- New `ios/` UIKit app, deployment target **iOS 15.0** (so iPhone 7 is supported), universal iPhone + iPad.
- USB transport via `iproxy` + `socat`, with `aeasy-server` still a pure listener.
- Wi-Fi transport via the same `socat` relay against a user-supplied IP.
- One new control packet, device→Mac, carrying the display size. It doubles as the rotation signal.
- Platform dispatch in `bin/aeasy`, leaving every existing `adb` code path unchanged.
- Touch input, mapped over the safe area.
- `aeasy install-app` opens the Xcode project so the user signs with their own free Apple ID.
- A shared, unit-tested packet parser (`mac/Protocol.swift`) and `make check`.
- GitHub Actions CI.

### Out of scope

- Any change to `android/`, or to the `adb` code paths in `bin/aeasy`. (Decision: Q2.)
- Any change to `aeasy-server`'s **listener, encoder, capture or virtual-display** code. The socat relay is what buys this: the server stays a pure loopback listener. The upstream *drain* and `handleTouch` do change (FR-6, FR-7), because that is where type-3 has to be routed — an earlier draft of this spec claimed the whole file was untouched, which the landed multi-source code makes false.
- Audio, scrolling, multi-finger, keyboard, clipboard, stylus pressure — not on Android either, so not parity items.
- App Store or TestFlight distribution, and anything needing the $99/yr Apple Developer Program. (Decision: Q3.)
- Waking or unlocking the device from the Mac. No lockdown service exposes it.
- Running while locked or backgrounded — not achievable without a qualifying `UIBackgroundMode`. See NFR-4.
- Bonjour / zero-config Wi-Fi discovery. Wi-Fi uses a typed IP. See Open questions.
- Multiple phones at once (already a stated product limitation).

## Requirements

### Functional

**Transport — no Swift networking changes**

- **FR-1** — The iOS app listens on TCP **7355** on the device with `NWListener`, `newConnectionLimit = 1`, and `allowLocalEndpointReuse = true`. It serves the existing protocol unchanged: Annex-B NALs inbound, 5-byte packets outbound.
- **FR-2** — USB transport is two watcher-managed processes:
  ```
  iproxy 7356:7355 -u "$UDID"                          # Mac :7356 -> device :7355
  socat TCP:127.0.0.1:7356 TCP:127.0.0.1:7355          # relay into the unchanged aeasy-server listener
  ```
  `aeasy-server` keeps its `NWListener` on `:7355` and is launched exactly as it is today.
- **FR-3** — Wi-Fi transport is the same relay against a user-supplied address: `socat TCP:$IOS_ADDR:7355 TCP:127.0.0.1:7355`. `aeasy wifi <ip>` on iOS writes `IOS_ADDR=<ip>` to the config; the app displays its own IP on screen (FR-14) so the user can read it off. No Bonjour, no `NWBrowser`, no `NSBonjourServices`.
- **FR-4** — Both helpers are started `pgrep`-guarded once per watcher tick, matching the existing `pgrep -qf aeasy-server || server_start` idiom at `bin/aeasy:52`, and are killed by argv signature in `aeasy stop` and in the device-gone branch (`bin/aeasy:66`): `pkill -f "iproxy 7356:7355"`, `pkill -f "socat TCP:.*:7355"`. Without this they are disowned with `&!` and outlive the watcher, holding port 7356 forever.
- **FR-5** — iOS device reachability, the `plugged()` equivalent: USB is `[[ -n "$(idevice_id -l)" ]]`; Wi-Fi is `nc -z -w1 "$IOS_ADDR" 7355`. `nc` ships with macOS.

**Control channel**

- **FR-6** — New device→Mac packet, **type 3**: `[3][w u16 BE][h u16 BE]`, 5 bytes. It needs no framing change, but *not* for the reason an earlier draft of this spec gave: the reader is now `minimumIncompleteLength: 1, maximumLength: 65536` (`:605`), so nothing about the receive guarantees alignment. The 5-byte grid is held by `drainTouch` (`:702-707`), which slices fixed 5-byte units and leaves any 0–4 byte remainder in `conn.buf` for the next receive. Three invariants must be commented and preserved:
  - **Never consume a partial unit.** A 3-byte remainder stays buffered — not zero-padded, not discarded. Discarding desyncs every subsequent packet by 2 bytes permanently, and a misaligned type-3 reads as a plausible touch, so the symptom is a wandering cursor rather than a crash.
  - **Exactly one outstanding `receive` per connection**, re-armed only from its own completion (`:616`). Two loops would interleave appends into the same `conn.buf`.
  - **The 300 ms handshake timer must never post a receive** (`:620-628`) — it may only mutate state the pending completion reads. Its `guard case .handshaking` is a decision rather than a race *only* because the timer and the connection share one serial queue (`:595`, `:621`); moving connections to per-connection queues would silently turn it into a TOCTOU bug.
  Rewrite `drainTouch` as an index walk rather than the current `prefix(5)`/`dropFirst(5)` pair, which recopies the buffer per packet.
- **FR-7** — Type-3 is honoured **iff the connection's subscribed source is the primary source, is a `display` source, and is alive** — i.e. `src.isPrimary && src.isDisplay && src.displayID != 0`. On any `window:` connection it is dropped and logged; on a control connection it is structurally impossible (`.control` never enters the drain). Routing happens **in the drain, on `TCPServer.queue`, before the `touchQueue.async` hop at `:706`**, because that is where the connection's source index is known.
  This replaces the earlier draft's rule that `guard vdispID != 0` must stay first in `handleTouch`. That guard now lives *inside* `if src.isDisplay` (`:526`) because multi-source FR-20 makes window sources touchable, so the ordering argument is gone — but its intent survives exactly. `guard type < 3` (`:519`) is deleted in favour of the `Protocol` dispatch, which must still reject types 4…255 so they stay reserved.
  Two reasons a non-primary subscriber must not be honoured: a `window:` pane's dimensions are the Mac window's, not the phone's; and a secondary pane could otherwise restart the whole server, killing the other panes and every control connection, which violates multi-source FR-4.
- **FR-8** — `handleResize(conn, src, w, h)` runs on `TCPServer.queue`: validate per FR-7, drop out-of-range values, set the FR-26 latch, and if `Protocol.shouldRestart` says the size changed, write `"<w> <h>"` to `~/.local/share/aeasy/dims.ios` **atomically** and `exit(0)`. The watcher relaunches with the new size. Details:
  - The write-and-exit hops to a `.utility` queue, following `LayoutStore.persist`'s precedent (`:230`). It must **not** go through `touchQueue` (`:564`), which is a single serial queue shared by every source and blocks behind `raiseWindow`'s Accessibility calls (`AXUIElementSetMessagingTimeout` 0.5 s, `:488`) — one hung mirrored app would delay the rotation restart.
  - A `restarting` latch makes the write one-shot. FR-8 of multi-source permits several subscribers per source, and two reporting the same rotation would otherwise both write and both exit.
  - Atomicity matters because the watcher reads this file on a 2 s tick and a torn read launches the server with garbage.
  - The safety precedent for `exit(0)` from the net queue is no longer the health check, which no longer exits — it is `dropSource`'s `exit(1)` (`:809`), which runs on the same queue. There is still no `stopCapture()` anywhere; process death *is* the teardown, and `bin/aeasy:66` depends on that.
- **FR-9** — A separate `dims.ios` file, not the shared `dims`. `bin/aeasy:39` writes `dims` on every Android `server_start`, so a user who has ever run an Android session would otherwise start their iPhone at the Android panel size.

**Display sizing — the number that matters most**

- **FR-10** — The app reports **half the safe area's native pixels**, rounded down to a multiple of 4:
  ```
  reported = (safeAreaLayoutGuide.layoutFrame.size * nativeScale / 2 * IOS_SCALE) & ~3
  ```
  Rationale: `AEasyServer.swift:295-315` sets `hiDPI = 1` with `maxPixelsWide = pxW * 2`, and the mode-pinning code at `:376-382` picks the largest backing for the pinned logical size — so the desktop's **point** count equals the reported number and its backing is 2× that in pixels. Reporting half the native pixels therefore makes the HiDPI backing land almost exactly on the physical panel:

  | Device | safe area (pt) | nativeScale | native px | reported | backing (2×) | panel px |
  |---|---|---|---|---|---|---|
  | iPhone 7 portrait | 375×667 | 2.0 | 750×1334 | 372×664 | 744×1328 | 750×1334 |
  | iPhone 15 Pro portrait | 393×759 | 3.0 | 1179×2277 | 588×1136 | 1176×2272 | 1179×2277 |
  | iPhone 15 Pro landscape | 734×372 | 3.0 | 2202×1116 | 1100×556 | 2200×1112 | 2202×1116 |

  Reporting **raw** native pixels — the obvious choice, and what the draft of this spec said — produces a 1179-point-wide macOS desktop on a 2.56" panel: 461 pt/in, roughly 4× a Mac's density, with a 24 pt menu bar rendering **1.3 mm tall**. Unusable. Half-pixels gives 230 pt/in, sharp and legible.
  **Hard dependency on multi-source FR-2:** `encodeBox(index)` caps every non-zero source index at 960×540 (multi-source NFR-4). This sizing math holds only because `parseSources` forces `display` to index 0. If FR-2 is ever relaxed, an iPhone-sized virtual display gets encoded at 960×540 and M-6 fails.
- **FR-11** — `IOS_SCALE` (config, default `1.0`, clamped 0.5–2.0) multiplies the reported size. This is the calibration knob: lower means a smaller desktop with bigger text, at some sharpness cost; higher means more desktop area and smaller text. Panel density is a physical-world variable a fixed formula cannot get right for every device.
- **FR-12** — Use `nativeScale`, never `scale`. They differ on iPhone Plus models (8 Plus: `scale` 3.0 vs `nativeScale` 2.6087) and in Display Zoom (iPhone 7 zoomed: 2.0 vs 2.34375). The product is non-integral, so round (`(w * nativeScale).rounded()`) before the integer conversion or the 8 Plus reports 1078 instead of 1080. Never use `UIScreen.main.nativeBounds` — it does not rotate.

**App behaviour**

- **FR-13** — The app sets `prefersStatusBarHidden = true` (the `SYSTEM_UI_FLAG_FULLSCREEN` equivalent at `MainActivity.kt:45`). Without it, iPhone 7's safe area excludes a 20 pt status bar and every in-call/recording double-height status bar change triggers a spurious resize and server restart.
- **FR-14** — One `UILabel` over the video showing connection state: "Waiting for Mac…" plus the device's own Wi-Fi IP, then hidden once streaming. Without it, "waiting", "crashed", and "certificate expired" (NFR-6) are three identical black screens, and FR-3 has no way to tell the user the IP.
- **FR-15** — The app renders into its **safe area** and reports that same rectangle (FR-10). Video area, touch area, and virtual display are one rectangle, preserving the Android invariant that view-relative touch coordinates need no un-letterboxing (`MainActivity.kt:58`). On home-button devices the safe area is the full screen once the status bar is hidden; on Face ID devices it excludes the notch/Dynamic Island and home indicator, which is also what keeps the video's bottom edge clear of the home-indicator gesture zone. (Decision: Q8.)
- **FR-16** — `videoGravity = .resizeAspect`, not `.resize`. FR-15 makes source and destination aspect ratios identical in steady state, but during the ~2–5 s between a rotation and the server restart the incoming video still has the old aspect ratio, and `.resize` visibly stretches it. Mirror mode (`aeasy mirror`) streams the *Mac window's* aspect ratio, so it letterboxes permanently — in that mode touch is ignored anyway (`AEasyServer.swift:279`), so the coordinate mismatch is moot.
- **FR-17** — `prefersHomeIndicatorAutoHidden = true` and `preferredScreenEdgesDeferringSystemGestures = .all`, each followed by its `setNeedsUpdateOf…` invalidation call — both properties are read once at first layout and a later change is otherwise ignored. This defers only the *first* edge swipe; the second always reaches the system. It is a second line of defence behind FR-15, not the primary mechanism.
- **FR-18** — `UIApplication.shared.isIdleTimerDisabled = true` while connected (the `FLAG_KEEP_SCREEN_ON` equivalent, `MainActivity.kt:43`).
- **FR-19** — Size reporting is **one function on one hook**:
  ```swift
  override func viewDidLayoutSubviews() {          // rotation, Split View, Slide Over, status-bar changes
      super.viewDidLayoutSubviews()
      reportSizeDebounced()
  }
  // plus one observer on didBecomeActive, for the re-check after the foreground layout pass

  func reportSizeDebounced() {
      guard UIApplication.shared.applicationState != .background else { return }
      let s = view.safeAreaLayoutGuide.layoutFrame.size
      guard s.width > 0 else { return }
      // compare to lastSent; if changed, schedule a 500 ms debounced send
  }
  ```
  `viewDidLayoutSubviews` is the only place where both `bounds` and `safeAreaInsets` are correct — reading them in `viewWillTransition` returns the *pre*-rotation safe area and builds the wrong virtual display. The `applicationState` guard is the whole of the foreground gating: it stops iOS's background App-Switcher-snapshot layout pass from flipping the Mac display, which is the real threat the Android `dumpsys window` check (`bin/aeasy:55`) defends against. `willResignActive` is deliberately **not** used — Control Center, Notification Center, incoming calls, Siri, and screenshots all fire it with no backgrounding and no resize. (Decision: Q6.)
- **FR-20** — Cancel the `NWListener` in `didEnterBackground` and recreate it in `willEnterForeground`. Apple TN2277: the system can reclaim a suspended app's listening socket, leaving it not listening even after resume. `allowLocalEndpointReuse` (FR-1) is what makes the rebind survive `TIME_WAIT`.
- **FR-21** — Touch: `touchesBegan`/`Moved`/`Ended`/`Cancelled` on the render view, no gesture recognizer (recognizers have a delay-and-fail phase and can cancel touches already reported). Emit the existing packets — 0 down, 1 move, 2 up, with `cancelled` also mapped to 2 so the Mac button never sticks (`MainActivity.kt:63`). Requirements:
  - Leave `isMultipleTouchEnabled` at its default `false`. A second finger is then never delivered, which *is* the Android single-finger limitation, for free — and cleaner than Android, where lifting the first of two fingers silently teleports the cursor to the second.
  - Track the active `UITouch` explicitly and check `touches.contains(t)`; never `touches.first!` in `touchesMoved`, as `Set<UITouch>` ordering is undefined.
  - **Clamp to 0…1 before the `UInt16` conversion.** Android's `.coerceIn(0f, 1f)` (`MainActivity.kt:66-67`) is cosmetic; on iOS a drag leaving the view yields a negative value and `UInt16(negativeDouble)` **traps and crashes**.
- **FR-22** — Decode with `AVSampleBufferDisplayLayer` **alone**. `VTDecompressionSession` emits `CVPixelBuffer`s that the layer cannot accept — pairing them means decoding and then re-wrapping for nothing. The layer decodes `CMSampleBuffer`s internally, which is the direct analogue of Android's `codec.configure(fmt, holder.surface, …)`. Codec is sniffed from the first NAL exactly as Android does — HEVC VPS type 32 vs H.264 SPS type 7, no handshake (Decision: Q9). Required details, each of which is a silent-failure mode:
  - Parameter sets go into `CMVideoFormatDescriptionCreateFrom{H264,HEVC}ParameterSets` **without** start codes — the opposite of Android's `csd-0` construction at `MainActivity.kt:141-144`. HEVC needs VPS, SPS, PPS in that order.
  - `nalUnitHeaderLength: 4`, and every enqueued NAL carries a 4-byte big-endian length (excluding the length field itself) in place of the start code. A width mismatch produces garbage, not an error.
  - **Gate the first enqueue on an IDR.** `AEasyServer.swift:73-78` sends the cached parameter sets the instant a client connects, and the next broadcast may be a droppable P-frame. `MediaCodec` tolerates that and glitches for ≤1 s; `AVSampleBufferDisplayLayer` does not — the SDK states the next frame after a format change "should be an IDR frame", and feeding it otherwise raises `…FailedToDecodeNotification` and can drive `status` to `.failed`. Gate on H.264 `nal_type == 5`, HEVC `nal_type` in 16…21.
  - Set `kCMSampleAttachmentKey_DisplayImmediately = true` on each sample buffer. Without it the layer waits on a `controlTimebase` that is never set and displays nothing, forever. Safe here because the server sets `AllowFrameReordering = false` (`AEasyServer.swift:187`), so there are no B-frames.
  - Create the `CMBlockBuffer` with `memoryBlock: nil` + `CMBlockBufferReplaceDataBytes`. Passing a Swift `Data`'s pointer directly is a use-after-free.
  - Rebuild the format description whenever the parameter-set bytes change — they change on every server restart, i.e. every rotation.
  - Observe `AVSampleBufferDisplayLayerRequiresFlushToResumeDecodingDidChangeNotification`, call `flush()`, and re-arm the IDR gate. Without it, M-13 (lock, unlock, resume) fails.
  - Keep `VTIsHardwareDecodeSupported(kCMVideoCodecType_HEVC)` as a startup check; since there is no handshake, the only useful response to `false` is showing "set CODEC=h264 in the config" instead of a black screen.
- **FR-23** — The Annex-B splitter is a **rewrite**, not a port. `NalReader` (`MainActivity.kt:195-216`) reads one byte at a time from a blocking `BufferedInputStream`; `NWConnection` delivers `Data` chunks asynchronously, and a per-byte receive would be catastrophic. Accumulate from `receive(minimumIncompleteLength: 1, maximumLength: 1 << 16)` and scan the buffer, carrying the zero-run counter **across chunk boundaries** so a start code split across two receives still parses. Preserve the `contentLen = size - min(zeros, 3)` trailing-zero trim and the VCL filter at `MainActivity.kt:152`.
- **FR-24** — Reconnect: on connection loss, return to accepting. Matches the Android 1-second retry loop (`MainActivity.kt:89-104`).

**Mac-side changes — the complete list**

- **FR-25** — Extract `mac/Protocol.swift`: a pure `parse(_ d: Data) -> Packet` returning `.touch(type, x, y)` / `.resize(w, h)` / `.invalid`, plus `shouldRestart(current:reported:) -> Bool`. Compiled into both `aeasy-server` and a new `mac/check` binary; the drain and `handleTouch` call it instead of decoding inline. It now has two callers rather than one, since the drain must classify the type byte before choosing a queue (FR-7). **`.invalid` must reject only types ≥ 4** — inheriting the `type < 3` literal from `:519` would classify every type-3 packet as invalid and this feature would fail silently, with `make check`'s round-trip assertion as the only thing that catches it.
- **FR-26** — New `--ios` flag on `aeasy-server`, arming a single 5-second timer; if no type-3 packet has arrived by then it posts "Open AEasy Display on your iPhone" through the existing `notify()` helper and never fires again. (Decision: Q4.)
  The trigger must be *no type-3 packet*, not *no TCP connection*: `iproxy` `accept()`s the local connection **before** attempting the usbmux dial (`iproxy.c:165-171`), so with the app closed the relay connects, subscribes, receives video and drops. A connection-based trigger would never fire. Use a latch, not `conns.isEmpty`, since connect-then-drop leaves `conns` empty at t=5.
  **The flag must be appended after `W H`** — `aeasy-server 372 664 --ios`. Argument parsing at `:104-105` is `guard count >= 3, let a = UInt32(arguments[1]), let b = UInt32(arguments[2])`, so `aeasy-server --ios 372 664` silently falls back to the `1650×720` defaults and produces a landscape virtual display on a portrait iPhone — a failure that looks like a sizing bug, not an argv bug.
  It is also what gates the Android path out of this behaviour, since Android sends no type-3 packets.
- **FR-27** — Move `sent` and `dropped` from the server's per-source dictionaries (`:566`) onto `Conn` (`:557`), alongside `pending`. `broadcast` (`:826-827`) increments the connection's counters; `startHealthCheck` (`:843-851`) sums the live connections per source index and zeroes them in the same pass.
  This is a lifetime change, not a reset call: `conns[k] = nil` at `:610`, `:695` and `:798` already destroys them, so the invariant becomes structural. It is also the *correct* granularity under multi-source FR-8 — zeroing a per-source counter when one subscriber leaves would erase a genuine lag signal from the other subscribers of that same source.
  Why it is still needed after multi-source deleted `AUTO`: with the app closed, `socat` connects and drops every ~2 s, inflating source 0's `dropped` while `sent` stays low. The health check no longer writes config, but it calls `sources[0].stepDown()` — and `stepDown` has no inverse (`step` only increments, `:416-434`), so **the primary pane is pinned at the quality floor for the life of the process.** Different blast radius, same user-visible outcome.
  The other half of the original bug is already fixed: `pending` moved onto `Conn` and the send completion guards on `if self.conns[k] != nil` (`:830`), so the dead-key resurrection cannot occur.
- **FR-28** — Rate-limit `Source.forceKeyframe()` to ~1 Hz per source. `subscribe` (`:686`) forces an IDR unconditionally, and re-encoding `lastPB` broadcasts to **every** subscriber of that source (`:822`). With the iOS app closed, the 2 s relay churn therefore pumps a forced keyframe into an unrelated Android viewer on `display` indefinitely — a visible bitrate spike and quality dip caused by a phone that is not even running the app. A second forced keyframe within a second is redundant anyway, since `MaxKeyFrameInterval` is one second's worth of frames (`:277`).
- **FR-29** — `mac/AEasyTray.swift:20-22` reports "not plugged in" for any iOS session, because `cablePlugged()` only greps `adb devices`. Add `|| idevice_id -l` to the same shell one-liner. Additive; Android behaviour unchanged.
- **FR-30** — When `--ios` is set and `AXIsProcessTrusted()` is false, `notify()` once at startup. Multi-source FR-21 sends `{"t":"error","code":"no_accessibility"}` so the phone can explain why taps do nothing, but that message goes only to **control** connections and an iOS client is a legacy video client that never opens one. Without this an iOS user gets a silently dead touch surface — exactly what FR-21 exists to prevent. Reuses the FR-26 mechanism; no new plumbing.
- **FR-31** — When `--ios` is set and no `display` source came up, log once at startup: "iOS client with no display source — rotation will not resize". Do **not** auto-force a `display` source; that would silently override `aeasy sources`.

**CLI & tooling**

- **FR-32** — `bin/aeasy` gains `platform()`, evaluated **once per watcher tick** and cached in a variable (not per process — a long-lived watcher must survive a device swap). It calls `command adb get-state` first (never the `adb()` wrapper at `:14-17`, which would inject `-s`), and only if that reports no device does it try `idevice_id -l`. A missing `idevice_id` is not an error on the Android path. A `PLATFORM=android|ios` config key overrides detection.
- **FR-33** — `watch_loop`'s body splits into `watch_android` (today's body, verbatim) and `watch_ios`. It cannot be a branch-at-the-top: the `dumpsys window` block is inline and FR-19 moves that responsibility into the app, and the `command adb connect "$w"` line fires every 2 s whenever `WIFI_ADDR` is set.
- **FR-34** — Introduce one `session_restart()` that dispatches on the cached `platform()`, and convert **all five** call sites of `server_start; sleep 1; app_open` to it in a single pass: `restart`, `mirror`, `screen`, `tune`, and the `watch_loop` body. Multi-source FR-28 adds a sixth (`aeasy sources`). Branching inside each one is a larger diff than one dispatcher and lets the next new subcommand silently reintroduce the bug — `server_start` clobbers `$SHARE/dims` and `app_open` shells `adb`, neither of which is right on iOS.
- **FR-35** — On iOS, `session_restart` reads `$SHARE/dims.ios`, defaulting to `372 664` (iPhone 7) when absent, and does **not** write it — the server owns that file (FR-8). First run on any other device therefore builds one wrong-sized display, then rebuilds; once ever per device, since the file persists.
- **FR-36** — `aeasy status` on iOS prints the resolved `SOURCES`. `parseSources` falls back to `MODE`/`WINDOW_APP` when `SOURCES` is absent, and `aeasy mirror` still writes exactly those keys — so a user who once ran `aeasy mirror Safari` and never set `SOURCES` gets no virtual display at all, and rotation silently stops working (see FR-31's startup log). Surfacing the resolved source list is what makes that diagnosable.
- **FR-37** — `aeasy install-app` on iOS refreshes `$SHARE/ios` from the installed source **on every invocation** (not "if absent" — a Homebrew upgrade would otherwise leave a stale app running silently), opens `$SHARE/ios/AEasyDisplay.xcodeproj`, and prints the signing instructions. `$SHARE` is used because Xcode must write the signing team and Homebrew's Cellar is read-only. It is not gated on a device being attached. `install.sh` copies `ios/` to `$SHARE/ios`, mirroring the APK copy at `install.sh:17`; the external Homebrew formula must do the same. (Decision: Q3.)
- **FR-38** — Per-command iOS behaviour: `stop` also kills the relay helpers (FR-4); `app` prints "Open AEasy Display on your iPhone — it cannot be launched remotely" instead of `am start`; `status` reports the device name from `ideviceinfo -k DeviceName`, relay state from `pgrep`, and "not trusted — unlock the phone and tap Trust" when `idevice_id -l` lists a device but `ideviceinfo` fails; `wifi <ip>` / `usb` set and clear `IOS_ADDR`; `restart` routes through `session_restart` (FR-34). `status`'s "Phone app: open/closed" line has no iOS equivalent and is omitted.
- **FR-39** — `UDID` config key selects the device when `idevice_id -l` lists more than one (iPads and Apple Watches appear too). Without it, the first entry wins and the choice is logged.
- **FR-40** — Missing `iproxy`, `idevice_id`, or `socat` produces "brew install libusbmuxd libimobiledevice socat", not a raw command-not-found.
- **FR-41** — User-facing text: `bin/aeasy`'s English and Thai help gains the iOS commands, in the same pass that multi-source FR-28 adds `aeasy sources` to both languages — they edit the same two heredocs. `README.md` and `README.th.md` document the iOS client, NFR-4, NFR-5 and NFR-6, and the stale limitation "No touch input back to the Mac" at `README.md:191` / `README.th.md:191` is corrected at the same time (touch shipped in `cc0b8da`). Multi-source's copy table has no Thai strings for the iOS commands; filling that gap belongs here.
- **FR-42** — **Split the `check` target.** `Makefile:35` already defines `check:` as `python3 test/smoke.py` (multi-source's 19-case harness), which needs Screen Recording and Accessibility granted to the binary and a real GUI session. This spec's assertions are pure and permissionless. Merge as:
  - `make check` → build and run `mac/check` (FR-25). CI-safe.
  - `make smoke` → `mac/aeasy-server` + `python3 test/smoke.py`. Local only, permission-gated. Multi-source's test plan and `smoke.py`'s docstring are updated to say `make smoke`.
- **FR-43** — `.github/workflows/ci.yml` on a macOS runner runs `make build`, `make check`, and `xcodebuild -project ios/AEasyDisplay.xcodeproj -scheme AEasyDisplay -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO build`. No signing identity is needed because real installs go through the user's own Xcode (FR-37). Neither `make smoke` nor `make apk` is in CI — the former needs granted permissions, the latter needs an Android SDK the runners do not ship. Note that `Makefile:7` builds a single arch (`$(shell uname -m)`), so an arm64 runner will not catch a broken x86_64 slice; that remains a multi-source P-1 item. (Decision: Q10.)

### Non-functional

- **NFR-1** — Deployment target iOS 15.0. iPhone 7 (A10) tops out at iOS 15.8 and has hardware HEVC decode of Main profile 8-bit 4:2:0, which is exactly what the Mac encodes (`kVTProfileLevel_HEVC_Main_AutoLevel` from a BGRA source), so FR-22 holds on it. Every API in this spec is verified available on iOS 15; nothing may use `UIWindowScene.requestGeometryUpdate` (16.0), `AVSampleBufferVideoRenderer` (17.4), or `isReadyForDisplay` (17.4). `AVSampleBufferDisplayLayer.enqueue` is deprecated in iOS 18 in favour of `.sampleBufferRenderer` (17.4+), so build warnings on that call are expected and correct. (Decision: Q1.)
- **NFR-2** — Android behaviour is preserved. Stated as observable invariants rather than code identity, since the multi-source rewrite already changed the file wholesale:
  1. The Annex-B byte stream and 5-byte touch framing an unmodified Android APK sees are unchanged — this is multi-source NFR-10, referenced rather than restated.
  2. No iOS-specific work runs when no iOS device is attached: no new process per watcher tick, `idevice_id` invoked at most once per tick and only after `command adb get-state` reports no device, and a missing `libimobiledevice` is not an error on the Android path.
  3. `$SHARE/dims` semantics are unchanged; iOS writes only `$SHARE/dims.ios`.
  4. The listener stays loopback-only and multi-client. This work adds no bind address, no port, and no `adb reverse` rule — so this NFR *depends on* multi-source NFR-2 rather than competing with it.
  5. `make check` and `make smoke` both pass with the iOS work landed, plus M-32…M-34.
  **`libusbmuxd`, `libimobiledevice`, and `socat` are optional dependencies**, needed only for iOS; Android-only users install nothing new. (Decision: Q2.)
- **NFR-3** — First USB connection requires unlocking the device once and accepting "Trust This Computer?" — the equivalent of Android's USB-debugging prompt. Pairing then persists in `/var/db/lockdown`.
- **NFR-4** — Locking the screen or backgrounding the app ends the session, with no workaround: no `UIBackgroundMode` covers usbmux socket traffic (`external-accessory` is MFi-only). `isIdleTimerDisabled` prevents auto-lock only, not a deliberate side-button press. Documented as a limitation in both READMEs. (Decision: Q7.)
- **NFR-5** — Wi-Fi mode triggers iOS's Local Network permission prompt; USB mode does not, because usbmuxd terminates on device loopback, which is outside that prompt's scope. `NSLocalNetworkUsageDescription` is required in `Info.plist`. The Android app's "no permissions except INTERNET" claim must not be restated for iOS without this caveat.
- **NFR-6** — Free-provisioning limits, all of which belong in the README **before** a user installs: certificates expire after **7 days** (the app stops launching until re-run from Xcode), **3 sideloaded apps** per free Apple ID at a time, and **10 App IDs per 7-day period**. This is the cost of "no accounts, no paid apps" on Apple's platform.
- **NFR-7** — Rotation latency budget: 500 ms debounce + packet + `exit(0)` + up to 2 s watcher poll + `server_start` + virtual-display appearance (up to 10 retries at 500 ms, `AEasyServer.swift:368-373`) + app reconnect. **Typical ≤5 s, worst case ~10 s.** Slower than Android's, and not fixable without shortening the watcher poll.
- **NFR-8** — Latency and quality behaviour is inherited, but from the *multi-source* mechanism, not the old one: degradation is now per-source `stepDown()` held in memory, never a config write and never a process restart. Two iOS-specific consequences: the backpressure signal differs, because `broadcast` counts outstanding sends into a localhost socket to `socat` rather than into an `adb reverse` tunnel and `socat` has its own buffering; and every rotation restart (FR-8) discards all accumulated step-down state, so an iOS user who rotates resets degradation each time. Verified by M-18 rather than assumed.

## Data model

**Config** (`~/.local/share/aeasy/config`) gains four optional keys, all iOS-only:

| Key | Values | Meaning |
|---|---|---|
| `PLATFORM` | `android` \| `ios` | Overrides auto-detection. Absent = auto-detect, Android first. |
| `IOS_ADDR` | `<ip>` | Wi-Fi mode target. Absent = USB via `iproxy`. |
| `IOS_SCALE` | `0.5`–`2.0`, default `1.0` | Display-size multiplier (FR-11). |
| `UDID` | device UDID | Disambiguates multiple attached iOS devices. |

**`$SHARE/dims.ios`** — `"<w> <h>"`, same format as `dims`, written by `aeasy-server` (FR-8) rather than by the watcher. Separate file per FR-9.

## API / Interface changes

**Wire protocol** — additive and backward compatible. The Mac already rejects `type >= 3` at `AEasyServer.swift:281`, so an Android client is unaffected and a Mac running today's build ignores a type-3 packet rather than misparsing it.

| Type | Direction | Bytes | Meaning |
|---|---|---|---|
| 0 / 1 / 2 | device → Mac | `[t][x u16][y u16]` | Touch down / move / up-or-cancel (existing) |
| 3 | device → Mac | `[3][w u16][h u16]` | **New.** Display size; also the rotation signal |
| — | Mac → device | Annex-B NALs | Video (existing, unchanged) |

**`mac/`**

| File | Change |
|---|---|
| `Protocol.swift` | **New.** Pure parser + `shouldRestart`, compiled into `aeasy-server` and `check` (FR-25) |
| `check.swift` | **New.** `assert`-based self-check, run by `make check` and CI |
| `AEasyServer.swift` | `drainTouch` → routing drain (FR-6, FR-7); `handleTouch` split into `postTouch` + `handleResize` (FR-7, FR-8); `sent`/`dropped` moved onto `Conn` (FR-27); `forceKeyframe` rate limit (FR-28); `--ios` flag, notify timer, Accessibility and no-display warnings (FR-26, FR-30, FR-31); argv parse tolerates the trailing flag. **No listener, encoder, capture or virtual-display changes.** |
| `AEasyTray.swift` | One-line `idevice_id` fallback in `cablePlugged()` (FR-29) |
| `AEasyConfig.swift` | Unchanged — the new keys are edited by hand |

**`bin/aeasy`** — `platform()`, `watch_ios`, `ios_server_start`, and iOS branches in `plugged`, `start`, `stop`, `restart`, `app`, `status`, `wifi`, `usb`, `install-app`, plus help text. `watch_android` is today's `watch_loop` body verbatim.

**`ios/`** (new)

| File | Purpose |
|---|---|
| `AEasyDisplay.xcodeproj` | iOS 15 target, universal, non-scene lifecycle (no `UIApplicationSceneManifest`) |
| `AppDelegate.swift` | Lifecycle, `isIdleTimerDisabled` |
| `ViewController.swift` | Render layer, safe-area sizing, touch capture, status label, gesture deferral |
| `StreamListener.swift` | `NWListener` on 7355, background teardown/rebuild, IP display |
| `NalScanner.swift` | Incremental Annex-B scanner (FR-23) |
| `Decoder.swift` | Codec sniff, format description, `AVSampleBufferDisplayLayer` enqueue |
| `Info.plist` | `NSLocalNetworkUsageDescription`, all four orientations in `UISupportedInterfaceOrientations`, **no** `UIRequiresFullScreen` (it would kill the iPad Split View support FR-19 handles) |

## Edge cases & error handling

| Case | Behaviour |
|---|---|
| Device attached but locked / not trusted | `idevice_id -l` lists it; `ideviceinfo` fails with lockdownd -19. `aeasy status` says "not trusted — unlock the phone and tap Trust". Watcher retries every 2 s. |
| `iproxy` / `idevice_id` / `socat` missing | `aeasy start` exits with the `brew install` line (FR-36). |
| Device attached, app not running | `iproxy` accepts, then drops. `socat` exits; the watcher restarts it next tick. FR-26 notifies after 5 s. FR-27 stops the churn from corrupting the config. |
| Cable unplugged mid-session | **`iproxy` does not exit** — it is a persistent local listener and keeps accepting, failing the usbmux dial after the local handshake. Device liveness therefore comes from `idevice_id -l` (FR-5), never from the relay's state. Once it reports nothing, the server and both helpers are killed and the virtual display torn down. |
| Type-3 reports unchanged dimensions | Ignored, no restart. Terminates the resize loop after exactly one extra restart: server writes `dims.ios` → exits → watcher relaunches at the new size → app reconnects and re-reports → equal → stop. |
| Type-3 dimensions out of range | **Dropped and logged.** Not clamped — clamping turns a garbage packet into a restart into a wrong-sized display. Valid range 320…8192 per axis. |
| Type-3 in mirror mode | Ignored — `vdispID == 0`, no virtual display to resize (FR-7). |
| iPad Split View / Slide Over / iPadOS window resize | Handled by the same debounced `viewDidLayoutSubviews` path as rotation (FR-19). Slide Over appearing *over* the app does not resize it and correctly produces no event. |
| Android phone and iPhone attached together | `PLATFORM` decides; without it Android wins (checked first), preserving today's behaviour. |
| Two iOS devices attached | `UDID` decides; otherwise first wins, logged (FR-35). |
| Second relay connects while a session is live | Refused by the device-side `newConnectionLimit = 1` (FR-1), so the orphaned `socat` simply fails. The Mac listener stays multi-client for Android's sake. |
| Two subscribers on the primary both report a rotation | `restarting` latch (FR-8) makes the write-and-exit one-shot; the second is a no-op. |
| Type-3 reports 0 or an absurd size | Dropped, never clamped — and this is load-bearing, not cosmetic: `defaultPane` computes `24.0 / Double(pxW)`, so a zero would be a divide-by-zero in `LayoutStore`. |
| `SOURCES` has no `display` entry | No source satisfies `isDisplay`, so type-3 is honoured nowhere and rotation does not resize. Logged once at startup (FR-31) and surfaced by `aeasy status` (FR-36). |
| Free-provisioning cert expired | The app will not launch — invisible to the Mac. Covered by the FR-26 notification and the FR-14 label being absent; documented in NFR-6. |
| Wi-Fi mode, wrong or stale IP | `nc -z -w1` fails, `plugged` is false, watcher tears down and retries. `aeasy status` reports "Wireless: unreachable ($IOS_ADDR)". |
| Screen locked mid-session | Connection drops, app suspends, video stops. On unlock the app foregrounds, rebuilds its listener (FR-20), flushes the layer (FR-22), and re-accepts. Documented, not fixed (NFR-4). |
| Reconnect mid-GOP | The cached parameter sets arrive without an IDR; FR-22's gate discards frames until the next keyframe, ≤1 s (`MaxKeyFrameInterval = FPS`, a frame count). Brief black rather than a decoder fault. |

## Test plan

**Automated — `make check`, also run in CI (FR-43).** `make smoke` (multi-source's 19-case harness) stays local and permission-gated per FR-41.

`mac/check.swift` asserts against `mac/Protocol.swift` (FR-25), which exists precisely so this logic is reachable outside the single-file `swiftc` script.

| Covers | Assertion |
|---|---|
| FR-6 | Type-3 round-trips across the u16 range, including 372×664, 588×1136, 1100×556 |
| FR-6, FR-25 | Types 0–2 parse identically to the pre-change inline decode — the Android regression guard for NFR-2 |
| Edge cases | 0, 1, 65535, and 319×319 are rejected as `.invalid`; nothing is clamped |
| FR-8 | `shouldRestart` is false for equal dimensions, true for differing — the loop-termination proof |
| FR-10, FR-12 | Half-native-pixel sizing with rounding: 414 pt × 2.6087 → 1080, not 1078; results are multiples of 4 |

**Manual — USB, iPhone 7 (iOS 15, Lightning)**

| # | Steps | Expected |
|---|---|---|
| M-1 | `aeasy install-app`, sign in Xcode, Run | Installs and launches; FR-37's instructions are accurate |
| M-2 | `aeasy start` with the app closed | "Open AEasy Display on your iPhone" after ~5 s (FR-26) |
| M-3 | Leave it closed 60 s, then open it | **No `LAGGY` line, `Source.step` still 0, and per-source `bitrate` in the next `sources` message unchanged** (FR-27) — then the stream appears. The old failure was a corrupted config file; post-merge it is a primary pane permanently pinned at the quality floor. |
| M-4 | Observe first-ever connect | May build one placeholder-sized display, then rebuild at the panel size (FR-32); subsequent starts do not |
| M-5 | Rotate to landscape | Rebuilds landscape within the NFR-7 budget (≤5 s typical); full panel used |
| M-6 | Read the menu bar and finder text | **Legible** — this is the FR-10 acceptance test; a ~1 mm menu bar is a fail |
| M-7 | Background the app, rotate, foreground | No flip while backgrounded; correct size on return (FR-19) |
| M-8 | Pull down Control Center, dismiss | No resize, no server restart (FR-19's rejection of `willResignActive`) |
| M-9 | Drag a Mac window by touching the phone | Cursor tracks; drag works; no stuck button on a cancelled touch (FR-21) |
| M-10 | Drag a finger off the edge of the screen mid-drag | **No crash** (FR-21's clamp) |
| M-11 | Leave idle past the auto-lock interval | Screen stays on (FR-18) |
| M-12 | Unplug mid-stream, replug | Display torn down then restored; `ps` shows no orphan `iproxy` or `socat` (FR-4) |
| M-13 | Lock the screen, unlock | Stream stops, then resumes — the flush path (FR-22) |
| M-14 | `CODEC=hevc`, restart | Decodes on the iPhone 7 (NFR-1) |
| M-15 | `aeasy mirror Safari` | Window mirrors letterboxed; touch ignored; no restart on rotation (FR-7, FR-16) |
| M-16 | Kill `aeasy-server` by hand | App shows "Waiting for Mac…", then re-accepts when the watcher relaunches it (FR-14, FR-24) |
| M-17 | `IOS_SCALE=0.7`, restart | Desktop is smaller with larger text (FR-11) |
| M-18 | `FPS=30 SCALE=100`, force lag | `LAGGY` in `aeasy log` and one auto-tune step — auto-tune still works over the relay (NFR-8) |

**Manual — Face ID device**

| # | Steps | Expected |
|---|---|---|
| M-19 | Connect an iPhone with a Dynamic Island | Video sits inside the safe area; virtual display matches it; text legible (FR-10, FR-15) |
| M-20 | **Swipe up** from the bottom edge of the video | The first swipe reaches the app as a touch, not the system (FR-17). A tap would pass trivially and proves nothing |

**Manual — iPad & Wi-Fi**

| # | Steps | Expected |
|---|---|---|
| M-21 | Connect an iPad over USB | Works; README points iPad users to Sidecar first |
| M-22 | Enter Split View, drag the divider | Resizes once after the debounce; `aeasy log` gains **exactly one** new `virtual display … id=` line (FR-19) |
| M-23 | Read the IP from the app, `aeasy wifi <ip>`, unplug | Local Network prompt once; stream resumes over Wi-Fi (FR-3, NFR-5) |
| M-24 | Wi-Fi mode, put the phone in airplane mode | "Wireless: unreachable"; no restart loop; recovers when it returns |

**Manual — CLI, tray & docs**

| # | Steps | Expected |
|---|---|---|
| M-25 | During an iOS session, open the menu-bar tray | Reports connected, not "not plugged in" (FR-29) |
| M-26 | `aeasy status` with an iPhone attached | Device name, relay state, config; no "Phone app: open/closed" line (FR-34) |
| M-27 | Temporarily rename `socat` out of `PATH`, `aeasy start` | Prints the `brew install` line, not `command not found` (FR-36) |
| M-28 | `aeasy --help` and `aeasy --help --th` | Both list the iOS commands; Thai copy present (FR-41) |
| M-29 | Read `README.md` limitations | iOS section documents the 7-day expiry, screen-lock, and Local Network prompt; the stale "No touch input back to the Mac" line is gone (FR-41, NFR-4/5/6) |
| M-30 | Take a screenshot on the phone mid-session (double-height status bar on iPhone 7) | No resize, no server restart (FR-13) |
| M-31 | Attach an iPhone and an iPad together | First wins and is logged; `UDID` selects the other (FR-35) |

**Manual — Android regression (NFR-2)**

| # | Steps | Expected |
|---|---|---|
| M-32 | Full Android session: start, rotate, touch, `aeasy wifi`, `aeasy install-app` | Works as before. Specifically: `aeasy status` output byte-identical, `$SHARE/dims` contents unchanged after rotation, rotation latency unchanged, and no new processes in `ps` during a watcher tick |
| M-33 | Uninstall `libimobiledevice`, run an Android session | No errors, no `command not found` in the log (NFR-2) |
| M-34 | Android phone and iPhone attached together | Android chosen; `PLATFORM=ios` switches it |

## Open questions

All resolved.

- Which devices — iPhone only, or iPad too? → Both, reaching back to **iPhone 7**, which pins the target to iOS 15. iPad is supported, but the README points iPad users to Sidecar first.
- Does the Android path change? → No. `aeasy-server`'s transport, encoder, capture, and display code are untouched; the only shared edits are a behaviour-preserving parser extraction and two bug fixes that help Android too (NFR-2, M-32…M-34).
- How does the user install the iOS app, given "no accounts, no paid apps"? → `aeasy install-app` opens the Xcode project and the user signs with their own free Apple ID. No $99/yr program. Cost: 7-day certificate expiry and the other free-provisioning limits, documented up front (NFR-6).
- What replaces `adb`'s auto-launch of the viewer? → Nothing can launch it, so the Mac notifies — but only when no type-3 packet has arrived within 5 s, because `iproxy` accepts the TCP connection even with the app closed and a connection-based trigger would never fire (FR-26).
- Rotation — restart, or resize in place? → Restart, reusing the auto-tune `exit(0)` + watcher-relaunch mechanism. Costs ≤5 s typically (NFR-7).
- What replaces the `dumpsys window` foreground check? → The app gates on `applicationState != .background` inside its single size-reporting function. `willResignActive` was rejected: Control Center and friends fire it with no backgrounding (FR-19).
- Is the screen-lock limitation accepted? → Yes, documented rather than worked around (NFR-4).
- iOS reserving the screen edges? → The video, the touch area, and the virtual display are all the safe-area rectangle, so every point of the Mac display stays reachable — which a touch-only inset would have broken (FR-15).
- Codec negotiation, or keep sniffing? → Keep sniffing from the first NAL, unchanged (FR-22).
- Add CI? → Yes, GitHub Actions on macOS: `make build`, `make check`, unsigned `xcodebuild`. `make apk` is excluded because the runners have no Android SDK (FR-43).
- *(Drafting)* Write a usbmux client in Swift, or shell out? → Shell out to `iproxy`, already a Homebrew package, mirroring how `adb` is used today.
- *(Review)* Rewrite `TCPServer` as an outbound client, or relay with `socat`? → **Relay.** The outbound path needs `.waiting`-state handling (a refused connect never reaches `.failed`), fresh-connection-per-dial to avoid leaks and duplicate receive loops, and a counter reset — and getting any of it wrong lets the health check permanently degrade the user's config. `socat` is two lines of shell, and it makes "no Android regression" true by construction. Cost: a third optional Homebrew dependency.
- *(Review)* Report native pixels as the display size? → **No — half of them.** Raw pixels give a 1179-point desktop on a 2.56" panel (461 pt/in, a 1.3 mm menu bar). Half-native-pixels lands the HiDPI 2× backing on the physical panel: sharp and legible (FR-10), with `IOS_SCALE` as the calibration knob (FR-11).
- *(Review)* Is Wi-Fi mode in scope? → Yes, since full Android parity was the ask — but **without Bonjour**. `adb connect` is what makes Android's `plugged()` work over the network, and Bonjour does not replace it; a `nc -z` reachability check against a user-typed IP does, and it deletes `NWBrowser`, the Bonjour plist keys, and the multiple-device discovery case (FR-3, FR-5).
- *(Review)* Separate rotation and resolution messages? → No. One type-3 message carries the size, and a changed size *is* the rotation event. It is exactly 5 bytes, so the existing fixed-width reader needs no framing change (FR-6).
- *(Review)* `VTDecompressionSession` feeding `AVSampleBufferDisplayLayer`? → Not a valid pipeline; the layer decodes internally and cannot accept `CVPixelBuffer`s. Use the layer alone, which deletes most of the decoder (FR-22).
- *(Rebase)* Does the multi-source rewrite break the 5-byte framing this spec depends on? → No, but it moves the guarantee. Alignment now comes from `drainTouch`'s fixed-stride slicing and its 0–4 byte remainder handling, not from `maximumLength`, which is already 65536 on disk (FR-6).
- *(Rebase)* Where is type-3 honoured once three sources can be active? → On exactly one connection class: a video connection whose source is primary, is a `display` source, and is alive. Elsewhere it is dropped and logged, because a `window:` pane's dimensions are the Mac window's and because a secondary pane must not be able to restart the whole server (FR-7).
- *(Rebase)* Multi-source deletes the `exit(0)` restart path — does resize-on-rotation survive? → Yes; the triggers are disjoint. Multi-source removes restart-*on-lag*; this spec keeps restart-*on-resize*, which multi-source's own edge-case table already accepts. The cost is that each rotation also resets in-memory degradation state and drops control connections (NFR-8).
- *(Rebase)* Is the drop-counter fix still needed once `AUTO` is gone? → Yes, with a different blast radius. The health check now calls `stepDown()`, which has no inverse, so relay churn would pin the primary pane at the quality floor for the life of the process. The fix becomes a lifetime change — counters move onto `Conn` — rather than a reset call (FR-27).
- *(Rebase)* Both specs define `make check`. → Split: `make check` runs the pure protocol assertions and goes in CI; `make smoke` runs multi-source's harness, which needs Screen Recording and Accessibility and stays local (FR-41, FR-43).
