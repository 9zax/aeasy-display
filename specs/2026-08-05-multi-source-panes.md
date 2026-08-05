# Spec: Multi-source panes on the phone (share mode, phase 1)

**Date:** 2026-08-05
**Status:** implemented (step 1a and 1b)
**Goal:** Show up to three Mac sources at once as draggable panes inside the AEasy Android app, arrangeable in real time from either side, with touch still driving the real Mac window behind each pane.

## Background

Today AEasy streams exactly one source to exactly one fullscreen `SurfaceView`:

- `mac/AEasyServer.swift` creates its own virtual display (`makeVirtualDisplay()`, :293), captures it with one `SCStream`, encodes with one `VTCompressionSession` (`Encoder`, :156) and pushes a raw Annex-B elementary stream over TCP `:7355` (`TCPServer`, :61).
- `MODE=display|window` (:34) picks *either* the virtual display *or* the largest window of `WINDOW_APP` — never both.
- `android/.../MainActivity.kt` opens one socket, sniffs the codec from the first NAL, creates one `MediaCodec` and decodes straight into one `SurfaceView` (:106-176).
- The same socket carries 5-byte touch packets back (`recvTouch`, :96; `handleTouch`, :278) which are mapped onto `CGDisplayBounds(vdispID)` and are ignored entirely in window mode (`guard vdispID != 0`, :279).
- Nothing is live: the server reads config once into `let` constants (:31-37) and the settings GUI's only apply path is "Save & Restart" (`AEasyConfig.swift:110-113`). Lag handling is `exit(0)` plus a watcher relaunch (`startHealthCheck`, :125-153).

The request ("mode share จอที่ 2 ไปยัง android ได้ด้วย 1 camera, app window อื่นๆ และ หน้า setting ลากตำแหน่งจัดการไปยัง android ได้ realtime") was analysed on 2026-08-05; twelve decisions were resolved with the requester and are recorded under [Open questions](#open-questions). This spec covers **phase 1 only**.

Three findings from the design review shaped the requirements below and are worth stating up front, because each one invalidates the obvious implementation:

1. **Overlapping `SurfaceView`s cannot be z-ordered on API 26-28.** A SurfaceView is composited by SurfaceFlinger in one of three fixed tiers, set before window attach; relative order within a tier is device-dependent. Multi-pane therefore uses `TextureView` (FR-14).
2. **`NSRunningApplication.activate` no longer raises anything.** `aeasy-server` is an unbundled binary with activation policy `.prohibited`, and macOS 14+ cooperative activation silently denies the request — verified: `activate` returns `true` and the frontmost app does not change. Raising uses the Accessibility `kAXRaiseAction` path instead (FR-20).
3. **ScreenCaptureKit is change-driven, not clock-driven.** An idle window emits one frame and then nothing, and `MaxKeyFrameInterval` is counted in *frames* (`AEasyServer.swift:188`). A pane subscribing to a static window would stay black forever. Each source must retain its last frame and force a keyframe on subscribe (FR-22).

## Scope

### In scope

- Multiple concurrent sources streamed to one phone, capped at **3**.
- Source kinds for phase 1: the AEasy **virtual display**, and **app windows** (`window:<AppName>`), any mix.
- Android renders each source as its own pane inside the AEasy activity, overlapping PiP-style.
- Panes are dragged and resized on the phone **and** on a new Mac settings canvas, kept in sync live with no restart.
- Touch on any pane drives the real Mac window/display behind it, raising the target window first.
- Under lag, secondary panes lose quality before the primary pane does — no process restart.

### Out of scope

- **Camera, both directions** — deferred to phase 2, including `AVCaptureSession` on the Mac, the Android `CAMERA` permission, `VTDecompressionSession`, and the Mac preview window. The protocol and layout model here take a `camera:*` source id without a wire change.
- Floating over *other* Android apps (`SYSTEM_ALERT_WINDOW`) and Android system PiP (`PictureInPictureParams`) — panes live inside the AEasy activity only.
- Adding or removing sources at runtime. Changing `SOURCES` restarts the server (FR-28). The `sources` control message reports source *loss*, not source *addition*.
- Changing a pane's encode resolution when it is dragged or resized (NFR-4).
- Audio, multi-finger gestures, scrolling — unchanged limitations.
- More than one phone. `bin/aeasy` still targets a single adb device.

### Delivery order

The protocol is designed so the two clients land independently. Ship in this order; each step is releasable.

| Step | Contents |
|---|---|
| **1a** | Prerequisites, per-source server refactor, wire protocol, Android multi-pane + arrange mode, per-source degradation |
| **1b** | Mac settings drag canvas (FR-25, FR-26) — a second control client, purely additive |

## Interaction with the iOS client spec

`specs/2026-08-05-ios-client.md` edits the same upstream byte channel and the same `handleTouch`. **This spec's step 1a landed first**, so the iOS spec rebases onto it; that rebase is written up in full under "Interaction with the multi-source panes spec" there. The rules that must not drift:

- That spec adds a **type-3** upstream packet `[3][w u16][h u16]` for panel size. It is 5 bytes, so it drains cleanly through `drainTouch`'s fixed-stride slicing (FR-5). The `guard type < 3` at `handleTouch` is a *placeholder* that drops it — the iOS spec replaces it with a dispatch. What must not drift is that types 4…255 stay reserved and are dropped without disturbing the 5-byte grid.
- Type-3 is **process-global, not per-source**: it declares the phone panel, which drives `pxW`/`pxH`, the virtual display geometry, the `viewport` message and `defaultPane`'s offsets. It is honoured only on a connection whose source is primary, `display`, and alive. A secondary pane must never be able to trigger a resize, because that restarts the server and kills every other pane — which would violate FR-4.
- An iOS client's first byte is `0x03`, not `A`, so FR-5 classifies it as a legacy viewer on the primary source. That is the correct outcome for phase 1: **iOS gets a single fullscreen pane.** Note this is enforced by transport, not policy — that spec relays one connection through one `socat` process, and both ends are listeners, so panes would need N relays *and* a raised `newConnectionLimit`, not just the `AEZ1` handshake.
- That spec relays through `socat` into this listener rather than replacing it, so **NFR-2's loopback binding holds unconditionally** — both its USB and Wi-Fi relays run on the Mac and dial Mac loopback. (An earlier iOS draft proposed a `--connect` mode that would have replaced the `NWListener`; it was dropped during review.) One residual: iOS Wi-Fi mode re-opens the touch and window-raise surface to the configured peer. USB mode does not.
- FR-2's "`display` is forced to index 0" is load-bearing for iOS, not just for legacy clients: `encodeBox` caps every non-zero index at 960×540 (NFR-4), so a demoted virtual display would break the iOS client's display-sizing math.

## Prerequisites

- **P-1** — `Makefile:19-27` invokes bare `swiftc -O` with no deployment target. The shipped binary reports `LC_BUILD_VERSION minos 16.0`, so the documented "macOS 13+" support (`README.md:44`) is currently fiction and the compiler will not flag a macOS 14/15-only API. Add an explicit `-target …-apple-macos13.0` (and the x86_64 slice) **before** any new API is written. Every API this spec needs is macOS 12.3-or-older, so this is a build-config fix, not an API constraint.

## Requirements

### Functional

#### Sources

- **FR-1** — The server exposes a set of *sources*, each an independent capture + encode + broadcast unit owning its own `SCStream`, `SCStreamConfiguration`, `StreamOutput`, `sampleHandlerQueue`, `Encoder` and cached parameter sets. Source ids are strings: `display`, `window:<AppName>`. The active set comes from the new config key `SOURCES` (comma-separated, max 3). When `SOURCES` is absent it is derived from the legacy `MODE`/`WINDOW_APP` keys, so existing installs keep working.
- **FR-2** — The **primary** source is `SOURCES[0]`. There is no `primary` field in the layout and no way to promote a pane from either UI; reordering `SOURCES` is the only way to change it. When `display` is present it is written first, so an extended display is always primary. This one rule fixes what is otherwise primary, which source a legacy client gets (FR-5), and which source is protected under lag (FR-20).
- **FR-3** — A source whose window cannot be found at startup is skipped with a log line; the remaining sources start normally. Today's silent fallback from window mode to display mode is removed.
- **FR-4** — A capture error on one source tears down **that source only**: its stream stops, its subscribers are closed, and a `sources` message goes out. `StreamOutput.stream(_:didStopWithError:)` must stop calling `exit(1)` (`AEasyServer.swift:269-272`), which today would kill all three panes when one mirrored app quits.

#### Wire protocol

- **FR-5** — A client subscribes to one source per TCP connection by sending `AEZ1 <source-id>\n` as its first bytes. The server then streams only that source's Annex-B bytes on that connection. Handshake parsing rules, which exist because the same socket also carries fixed 5-byte touch packets:
  - If the first byte is not `A` (0x41), the connection is a legacy viewer — subscribe it to the primary source immediately and treat every byte received as touch data.
  - Otherwise read to `\n` with a 300 ms deadline and a 64-byte cap. Cap exceeded, or deadline hit mid-line → close.
  - Bytes after the `\n` in the same segment are the first bytes of the touch/control stream and must be carried over, not dropped.
- **FR-6** — A connection whose handshake names an unknown or inactive source id receives `AEZ1 ERR <reason>\n` and is then closed, with the close issued from the send-completion handler so the reply is not lost to the FIN.
- **FR-7** — `AEZ1 control\n` opens a **control connection**: no video, and length-prefixed JSON both ways (`u32` big-endian byte length, then UTF-8 JSON). Both the Android app and the Mac settings GUI connect as control clients. A control connection never starts the touch reader.
- **FR-8** — Multiple connections may subscribe to the same source id; each gets its own header, forced keyframe and backpressure counter. Touch from any of them is accepted.

#### Layout

- **FR-9** — The server owns the canonical layout, persists it to `~/.local/share/aeasy/layout.json`, and pushes `{"t":"layout","rev":N,"panes":[…]}` to every control client on connect and on every change.
- **FR-10** — A pane is `{"src":"<source-id>","x":0..1,"y":0..1,"w":0..1,"h":0..1,"z":int}`, in fractions of the phone's viewport. Exactly one pane per active source; the load path reconciles this (see edge cases).
- **FR-11** — Either side proposes a change by sending `{"t":"layout","panes":[…],"tok":"<client token>"}`. The server validates, bumps `rev`, persists and broadcasts `{"t":"layout","rev":N,"panes":[…],"ack":"<tok>"}` to all control clients. A client discards its pending proposal only when it receives a newer `rev` whose `ack` is **not** its own token — without the token a client cannot tell its own echo from an overwrite, and every drag snaps back.
- **FR-12** — Additionally, a client ignores incoming layout for a pane it is *actively dragging* until the gesture ends, so two simultaneous drags do not fight frame by frame.
- **FR-13** — On connect and on change the server also sends `{"t":"sources","sources":[{"id":…,"w":…,"h":…,"fps":…,"bitrate":…}]}` and `{"t":"viewport","w":…,"h":…}` (the phone panel pixels the server was launched with, `AEasyServer.swift:54-59`). The settings canvas needs the viewport to draw the right aspect ratio; the smoke test needs the per-source bitrate to assert FR-20.

#### Android rendering and input

- **FR-14** — With one source and one pane, Android keeps today's fullscreen `SurfaceView` path unchanged. With more than one pane every pane is a `TextureView`, which is an ordinary View: real integer z, no surface-lifecycle churn on drag, and overlays composite above it. `setZOrderOnTop` must never be called — that tier sits above the whole app window and would hide the arrange toggle and the error text.
- **FR-15** — Pane stacking order is applied by **child order in the root `FrameLayout`**, not by `setZ`/`setTranslationZ` alone, because `ViewGroup` dispatches touches by child index. The topmost pane under the finger consumes the touch.
- **FR-16** — A pane's video view is aspect-fitted and centred inside the pane rect, as `applyFit()` does today (`MainActivity.kt:184-191`). The touch listener stays on the **video view**, never on the pane container, so `e.x / v.width` remains an identity mapping onto the encoded frame and needs no un-fitting — the precondition already documented at `MainActivity.kt:58`.
- **FR-17** — The app has two input modes:
  - **View mode** (default): a touch on a pane is forwarded as today's 5-byte packet on *that pane's own socket*. The socket identifies the source, so the touch format is unchanged and carries no source id.
  - **Arrange mode**: the root layout intercepts touches (`onInterceptTouchEvent` returning true everywhere except the toggle's rect), so no pane listener is reached and nothing is forwarded. Drag anywhere in a pane to move it; drag a bottom-right corner handle (drawn 32 dp, hit 48 dp) to resize; minimum pane size 0.15 of the viewport; coordinates clamped to 0..1. Proposals are sent at ≤20 Hz during a drag and once on release.
  - Switching modes with a finger down sends a type-2 (up) packet first, for the same reason `ACTION_CANCEL` is handled at `MainActivity.kt:63` — otherwise the Mac button sticks down.
- **FR-18** — The toggle is a `TextView` with a code-built `GradientDrawable` background (no AndroidX, no XML), ≥48 dp, in the bottom-right corner inset by `WindowInsets`, added to the root `FrameLayout` **last** so reverse-order touch dispatch gives it priority inside its own box and nowhere else. Its label and `contentDescription` both change with mode; mode is never signalled by colour alone.

#### Touch on the Mac

- **FR-19** — For a `display` source, behaviour is unchanged: map into `CGDisplayBounds(vdispID)` and post to `.cghidEventTap`.
- **FR-20** — For a `window:<App>` source, on `mouseDown` the server raises that window and then posts the click:
  - Raise via Accessibility: `SCWindow.owningApplication.processID` → `AXUIElementCreateApplication` → match the `AXUIElement` whose `CGWindowID` equals `SCWindow.windowID` → `AXUIElementPerformAction(kAXRaiseAction)`. Matching needs the `_AXUIElementGetWindow` symbol resolved via `dlsym` from ApplicationServices; the public fallback is comparing `kAXPositionAttribute`/`kAXSizeAttribute` against `kCGWindowBounds`, which is ambiguous for identically-placed windows. `NSRunningApplication.activate` does not work here (see Background).
  - Post by z-order, not by frontmost app: a `.cghidEventTap` event lands on whatever is topmost at that point, which is what the raise just arranged.
  - Map coordinates by inverting the same fit the phone applies. The encode size is frozen at subscribe (NFR-4) with `cfg.scalesToFit = true` (`AEasyServer.swift:352-357`), so a window resized after subscribe is letterboxed inside the encoded frame; a naive map onto the current frame lands the click off-target. Read the current frame per `mouseDown` with `CGWindowListCopyWindowInfo([.optionIncludingWindow], windowID)` → `kCGWindowBounds` (same top-left CG global space as `CGEvent.mouseCursorPosition`, measured at 0.16 ms/call), then undo the letterbox.
- **FR-21** — The Accessibility prompt at `AEasyServer.swift:363-366` moves out of the virtual-display branch and runs whenever any source is active. If trust is absent, the server sends an `error` control message so the phone can explain why taps do nothing — `CGEvent.post` fails silently otherwise.

#### Quality under load

- **FR-22** — Each source retains its most recent `CVPixelBuffer` and, on every new subscriber, re-encodes it with `kVTEncodeFrameOptionKey_ForceKeyFrame` (today `frameProperties` is `nil`, `AEasyServer.swift:202`). Without this a pane on a static window never receives a decodable frame.
- **FR-23** — Degradation is per source and never restarts the process. When a source's drop rate exceeds 25 % over a health-check window, that source steps down:
  - Bitrate via `VTSessionSetProperty(kVTCompressionPropertyKey_AverageBitRate)` on the live session — verified to work mid-encode.
  - Frame rate via `SCStream.updateConfiguration`, mutating and resubmitting the source's **stored** `SCStreamConfiguration`. The call replaces the whole configuration, so a fresh object would silently reset `pixelFormat`, `queueDepth`, `showsCursor`, `width`/`height` and `scalesToFit`, changing the encode size out from under the running encoder.
  - `kVTCompressionPropertyKey_ExpectedFrameRate` is a hint the encoder reads before compression begins; setting it mid-session succeeds but throttles nothing. It is not the frame-rate knob.
  - The primary source steps down only after every secondary source has reached the floor.
  - The `exit(0)` path and the `AUTO` config key are deleted, along with the `writeConf` call at `:141`. Step-down state is in-memory only. `aeasy status`'s `LAGGY` grep (`bin/aeasy:117-119`) is scoped to the current process's log lines, or it will recommend `aeasy tune` forever.
- **FR-24** — Decoder failures on Android are classified, not swallowed by the blanket `catch` at `MainActivity.kt:172`:
  - `ERROR_INSUFFICIENT_RESOURCE` or an unsupported profile → stop retrying after 3 consecutive failures, show a persistent error in that pane with a manual retry affordance. Retrying at 1 Hz forever thrashes the media resource manager and can reclaim a *working* pane's codec.
  - `ERROR_RECLAIMED` → transient, retry with backoff.
  - Decoder creation across panes is serialised behind one lock in primary-first order, so which pane loses is deterministic rather than a race.
  - Other panes keep running in every case.

#### Mac settings (step 1b)

- **FR-25** — `aeasy config` gains a drag canvas: a `PaneCanvasView: NSView` drawing the phone viewport (aspect from the `viewport` message) with one draggable, resizable rectangle per pane. Edits are pushed over a control connection immediately — no "Save & Restart" for layout. The connection reconnects with backoff and shows a disconnected state, because `bin/aeasy:52-59` restarts the server on every phone rotation.
- **FR-26** — The existing "Mode" and "App to mirror" controls (`AEasyConfig.swift:45-50, 102-104`) are replaced by a source-list editor writing `SOURCES`. Left as they are, they would write `MODE`/`WINDOW_APP` keys that FR-1 ignores, so the user would pick a mode, hit Save, and see nothing change. "Save & Restart" keeps its meaning for encode settings and is labelled as restarting the session; it drops every pane and control connection while the server relaunches.
- **FR-27** — `writeConf` (`AEasyServer.swift:39-45`) re-reads the config file before merging instead of rebuilding it from the launch-time `_conf` snapshot (`:25-30`). Otherwise any server-side write silently reverts a `SOURCES` change made by the CLI or the GUI since launch.

#### CLI

- **FR-28** — `bin/aeasy` gains `aeasy sources [<spec,…>]` to print or set `SOURCES`, working with no phone attached (like `aeasy screen`, `:103-107`), and rejecting a 4th entry with a non-zero exit rather than a log line. `aeasy mirror <App>` keeps its current *exclusive* meaning — it replaces `SOURCES` with `window:<App>` — and `aeasy screen` replaces it with `display`. Additive edits belong to `aeasy sources`. Help text is updated in both languages (`:166-202`).

### Non-functional

- **NFR-1** — All connections use `:7355`; no new port, no new `adb reverse` rule.
- **NFR-2** — `NWListener` binds **loopback only** (`AEasyServer.swift:67` currently binds every interface). Every real client arrives through `adb reverse`, which connects to `127.0.0.1` on the Mac in both USB and Wi-Fi mode, so this costs nothing. Today an unauthenticated peer on the LAN can already synthesise `.cghidEventTap` clicks; this spec would otherwise add a JSON control channel and arbitrary window raising to that surface.
- **NFR-3** — Control messages are capped at 64 KiB; a larger declared length is rejected and the connection closed. The `u32` prefix is otherwise an attacker-controlled allocation.
- **NFR-4** — Encode size per source is fixed at subscribe time and does not change when a pane is dragged or resized; Android scales the decoded frame into the pane. Secondary sources are capped at 960×540 by default. Concurrent decoding is limited by pixel throughput, not bitrate, and the handshake carries no device capability, so this cap is what keeps a three-pane layout inside a mid-range phone's budget.
- **NFR-5** — Total configured bitrate across sources is `max(BITRATE, 300_000 × source count)`, split 60 % to the primary and the remainder evenly among secondaries, recomputed **only when the source set changes** — never during a drag. `BITRATE` alone is not a valid budget: the settings slider bottoms out at 500 kbps (`AEasyConfig.swift:29`), below the 3-source floor.
- **NFR-6** — Layout proposals are coalesced to ≤20 Hz on the client, broadcasts to ≤10 Hz on the server, and `layout.json` is written debounced after 500 ms of idle. A 60 Hz drag would otherwise put a validate-persist-broadcast cycle, including an fsync, on the same serial queue that carries three video streams.
- **NFR-7** — No blocking work runs on `TCPServer.queue`. Accessibility calls block on the target app's run loop up to the messaging timeout (default 6 s); one unresponsive app would freeze every stream. FR-20's raise and post run off that queue, with `AXUIElementSetMessagingTimeout` lowered.
- **NFR-8** — Mutable state is confined to a single queue per domain: per-source `header`, the source table and the drop counters live on `TCPServer.queue`; `Encoder.session` and step-down calls live on that source's `sampleHandlerQueue`. Today `header` is already written from the VideoToolbox callback thread (`:235`) and read on the net queue (`:76`) — an existing race that multiplies by source count.
- **NFR-9** — Layout latency: from the server receiving a proposal to a second control client observing the broadcast, ≤200 ms on USB under a 3-stream load. The rendering leg is not covered by this bound.
- **NFR-10** — The Annex-B byte stream a legacy client receives is unchanged. First-frame latency may increase by up to 300 ms when the client sends no handshake (FR-5).
- **NFR-11** — Android: minSdk stays 26, no AndroidX or any other dependency in `android/app/build.gradle.kts`. JSON uses the platform `org.json.JSONObject`/`JSONArray`.
- **NFR-12** — Android permissions stay `INTERNET` only.
- **NFR-13** — Android threading: one UI thread (sole owner of the layout model and `rev`), one worker per pane (connect + blocking read + decode, never split), one control reader, and one shared outbound executor for touch packets and proposals. `running`, `out`, the socket, the codec and `videoW`/`videoH` become per-pane; today they are shared fields (`MainActivity.kt:33-38`).
- **NFR-14** — Pane teardown closes the socket. `worker?.interrupt()` (`MainActivity.kt:85`) does not unblock a thread parked in `BufferedInputStream.read()` on a `java.net.Socket`; only `Socket.close()` does. Today the socket is owned by a `use { }` block inside the blocked frame (`:92`), so the thread and socket leak and a second worker starts on the next `surfaceCreated`, whose `finally { out = null }` (`:100`) then kills the live worker's touch channel.

### Accessibility

- **A11Y-1** — Panes are `focusable` with a `contentDescription`; without it TalkBack has nothing to announce in a fullscreen video app.
- **A11Y-2** — The arrange toggle carries its state in the `contentDescription` and label (there is no state-description API before API 30) and fires `announceForAccessibility` on change.
- **A11Y-3** — Arrange-mode dragging is unusable with TalkBack, since explore-by-touch consumes touch. A "reset layout" accessibility action on the toggle's long-press is the non-drag fallback, and the limitation is documented.
- **A11Y-4** — Error strings wrap rather than ellipsize inside small panes, and the toggle label is sized in `sp`.
- **A11Y-5** — `android:label` (`AndroidManifest.xml:4`) moves to `@string/app_name` so the Thai locale gets a launcher label.

## Data model

`~/.local/share/aeasy/config` gains one flat key, keeping the existing `KEY=value` parser in all three readers (`AEasyServer.swift:25-30`, `AEasyConfig.swift:6-15`, `bin/aeasy` greps). `AUTO` is removed (FR-23):

```
SOURCES=display,window:Code
```

Layout is nested and lives in its own file, `~/.local/share/aeasy/layout.json`:

```json
{
  "rev": 7,
  "panes": [
    {"src": "display",     "x": 0,    "y": 0,    "w": 1,    "h": 1,    "z": 0},
    {"src": "window:Code", "x": 0.58, "y": 0.62, "w": 0.4,  "h": 0.34, "z": 1}
  ]
}
```

## API / Interface changes

### Wire protocol on `:7355` (loopback)

| Direction | When | Bytes |
|---|---|---|
| client → server | first bytes, if they start with `A` | `AEZ1 <source-id>\n` or `AEZ1 control\n` |
| client → server | first bytes, if they do not start with `A` | treated as touch data; connection subscribed to the primary source |
| server → client | rejected handshake | `AEZ1 ERR <reason>\n`, then close |
| server → client | video connection | raw Annex-B, unchanged |
| client → server | video connection, after handshake | 5-byte touch `[type u8][x u16 BE][y u16 BE]`, unchanged |
| both | control connection only | `[len u32 BE][JSON UTF-8]`, len ≤ 64 KiB |

Control messages:

| `t` | Direction | Payload |
|---|---|---|
| `layout` | server → client | `rev`, `panes`, `ack` — canonical; on connect and on change |
| `layout` | client → server | `panes`, `tok` — a proposal |
| `sources` | server → client | `sources[]` of `{id, w, h, fps, bitrate}`; on connect and on source loss |
| `viewport` | server → client | `w`, `h` — phone panel pixels; on connect |
| `error` | server → client | `code`, `msg` — `code` is a stable token the client localises, `msg` is English fallback |

### Swift — `mac/AEasyServer.swift`

- New `final class Source`: `id`, `SCStream`, retained `SCStreamConfiguration`, own `StreamOutput`, own `sampleHandlerQueue`, own `Encoder`, cached `header`, retained last `CVPixelBuffer`, live `fps`/`bitrate`, `stepDown()`, `forceKeyframe()`, `teardown()`.
- `Encoder` (:156) drops its direct `server.header` write (:235) and `server.broadcast` call (:255) in favour of an `onEncoded: (Data, Bool) -> Void` callback, and gains a `frameProperties` path for forced keyframes (:202).
- `TCPServer.conns` (:62) becomes `[ObjectIdentifier: Conn]`, where `Conn` holds the connection, its state (`.handshaking(Data)` / `.video(sourceID)` / `.control`), its 5-byte touch drain buffer and its `pending` counter. `broadcast(_:droppable:)` (:111) becomes `broadcast(_:to:droppable:)`.
- `recvTouch` (:96) is replaced by one receive loop with `minimumIncompleteLength: 1, maximumLength: 64` driving that state machine. Two constraints: an outstanding `NWConnection.receive` cannot be cancelled, so the 300 ms timer must only mutate state that the pending completion handler reads (guarded by `guard case .handshaking`), never post its own receive; and once the read is no longer exactly 5 bytes, touch packets must be buffered and drained in 5-byte units or they silently vanish.
- `handleTouch` (:278) takes a source, and for window sources runs raise-then-post off the net queue (NFR-7).
- `startHealthCheck` (:125) counts per source and calls `Source.stepDown()`; `exit(0)` and the `AUTO` branch (:136-144) are deleted.
- New `LayoutStore`: load, reconcile against `SOURCES`, validate proposals, bump `rev`, debounced persist, broadcast.

### Swift — `mac/AEasyConfig.swift`

- New `PaneCanvasView: NSView` with mouse-drag hit-testing over pane rectangles.
- The settings app opens its own control connection to `127.0.0.1:7355` and speaks the same protocol as the phone — no new IPC mechanism, and one fewer moving part than a config-file watcher.
- Mode/app controls replaced per FR-26.

### Kotlin — `android/.../MainActivity.kt`

- New `Pane`: one `TextureView` (or the legacy `SurfaceView` when single), one socket held in a field, one worker, one `MediaCodec`, own `running`/`out`/`videoW`/`videoH`. The existing `decode()`/`NalReader` bodies move in nearly unchanged.
- New `ControlClient` thread; all View work posted via `runOnUiThread` behind a `@Volatile destroyed` guard, since a runnable posted after `onDestroy` would touch a released Surface — a hole that already exists at `:181`.
- New root `FrameLayout` subclass overriding `onInterceptTouchEvent` for arrange mode, plus a non-clickable overlay view drawing pane borders and resize handles.
- `res/values/strings.xml` and `res/values-th/strings.xml` — the project has no `res/values/` at all today; every string is a literal.

### CLI — `bin/aeasy`

- New `sources` subcommand; `mirror`/`screen` rewritten to set `SOURCES`; `LAGGY` grep scoped (FR-23); bilingual help updated.

## Copy

| key | English | ไทย |
|---|---|---|
| `arrange_toggle` | Arrange | จัดวาง |
| `arrange_toggle_done` | Done | เสร็จ |
| `arrange_toggle_desc` | Toggle arrange mode | สลับโหมดจัดวาง |
| `arrange_on` | Arrange mode on — drag to move, drag a corner to resize | เปิดโหมดจัดวาง — ลากเพื่อย้าย ลากมุมเพื่อปรับขนาด |
| `arrange_off` | Arrange mode off — tap to control the Mac | ปิดโหมดจัดวาง — แตะเพื่อควบคุม Mac |
| `pane_window_closed` | "%1$s" window closed | ปิดหน้าต่าง "%1$s" แล้ว |
| `pane_decoder_unavailable` | Decoder unavailable | ตัวถอดรหัสวิดีโอไม่พอ |
| `pane_decoder_detail` | This device can't decode this many streams | เครื่องนี้ถอดรหัสหลายภาพพร้อมกันไม่ไหว |
| `pane_retry` | Retry | ลองใหม่ |
| `pane_connecting` | Connecting… | กำลังเชื่อมต่อ… |
| `pane_connection_lost` | Connection lost — reconnecting… | การเชื่อมต่อหลุด กำลังเชื่อมต่อใหม่… |
| `pane_source_unavailable` | Source not available | ไม่พบแหล่งภาพนี้ |
| `err_no_accessibility` | Taps do nothing until Accessibility is granted on the Mac | แตะแล้วไม่มีผล จนกว่าจะอนุญาต Accessibility บน Mac |
| `err_too_many_sources` | Maximum 3 sources | ใช้ได้สูงสุด 3 แหล่งภาพ |
| `err_mac` | Mac error: %1$s | ข้อผิดพลาดจาก Mac: %1$s |
| `pane_desc` | Source %1$s | แหล่งภาพ %1$s |
| `reset_layout` | Reset layout | รีเซ็ตการจัดวาง |

The server's `error` messages carry a stable `code`; the client maps known codes to these strings and falls back to the English `msg`.

## Edge cases & error handling

| Case | Behaviour |
|---|---|
| Handshake for a source not in `SOURCES` | `AEZ1 ERR unknown source`, close after the send completes. Pane shows `pane_source_unavailable`. |
| First byte is not `A` | Legacy viewer: subscribed to the primary source immediately, all bytes treated as touch. |
| `AEZ1 dis` arrives, `play\n` arrives 60 ms after the deadline | Deadline hit mid-line → close. The client reconnects and retries; it is never silently demoted to legacy, which would feed 13 handshake bytes into the 5-byte touch reader and desynchronise it permanently. |
| Handshake line and first touch packet arrive in one TCP segment | Leftover bytes after `\n` seed the touch buffer. |
| Declared control length > 64 KiB | Reject, close. |
| Touch packet on a control connection | Impossible — the touch reader is never started for `.control`. |
| Source's window disappears (app quit) | That source only tears down (FR-4); `sources` re-broadcast without it; pane shows `pane_window_closed` and is removed on the next layout push. |
| `window:<App>` not found at startup | Skipped with a log line; other sources start. |
| Proposal names an unknown source, or omits a pane for an active source | Rejected wholesale; the canonical layout is re-broadcast so the proposer snaps back. |
| Proposal with a pane outside `0..1` or below the 0.15 minimum | Clamped, then accepted; `rev` bumps and the clamped result is broadcast. |
| Both sides drag at once | Server serialises. Each client ignores incoming layout for the pane under its own finger (FR-12) and reconciles on release, so neither gesture is yanked mid-drag. |
| `layout.json` references a source no longer in `SOURCES` | On load: drop orphan panes, add default panes for sources with none, bump `rev`, persist. |
| `layout.json` missing or corrupt | Default layout: primary fullscreen, secondaries at 40 % width in the bottom-right, stacked by 24 px. |
| More than 3 entries in `SOURCES` | Extra entries ignored, log line plus an `error` control message. `aeasy sources` refuses a 4th entry with a non-zero exit instead. |
| `BITRATE` below `300_000 × source count` | Budget floor wins (NFR-5); the configured value is logged as overridden. |
| Phone rotates | `watch_loop` restarts the server (`bin/aeasy:55-59`); all clients reconnect, re-handshake, and receive the persisted layout and a new `viewport`. Fractions survive, but pane *shapes* change with the new aspect and encode sizes are re-derived — aspect distortion after rotation is accepted for phase 1. |
| Settings canvas open when the server restarts | Control connection reconnects with backoff; the canvas shows disconnected and any in-flight proposal is dropped. |
| Phone locks / app backgrounded | Every pane closes its socket and releases its codec on `onStop`; `onStart` reconnects. Reconnect backoff for surface loss is 200 ms, not the 1 s at `MainActivity.kt:102`. |
| Decoder creation fails on the third pane | Classified per FR-24: 3 strikes on `ERROR_INSUFFICIENT_RESOURCE` → persistent `pane_decoder_unavailable` with a retry affordance; panes 1-2 unaffected. |
| Codec reclaimed mid-stream by another app | `ERROR_RECLAIMED` → backoff retry, pane shows `pane_connection_lost` meanwhile. |
| Accessibility not granted | Prompt on startup (FR-21); `error` with code `no_accessibility` so the phone shows `err_no_accessibility` instead of taps silently doing nothing. |
| All secondaries at the quality floor and drops continue | Primary steps down; on reaching its own floor, notify once per 60 s as today. |
| Server restarted while the phone app is open | Per-pane retry loop reconnects each socket. |

## Test plan

Automated smoke test at `test/smoke.py` (python3 from the already-required Command Line Tools), run by **`make smoke`**. The split the iOS spec's FR-41 called for is in place: `make check` is the pure protocol assertions that run anywhere, and `make smoke` is this harness, which needs Screen Recording and Accessibility granted to the binary and so cannot run in CI. It launches its own server directly (never via `bin/aeasy`, whose `restart` requires a plugged phone, `bin/aeasy:88`) against a scratch config on port 7399 using the `AEASY_DIR`/`AEASY_PORT` overrides, so a live session's config, layout and port are untouched. The virtual display's serial number is derived from the port for the same reason — two displays sharing vendor/product/serial cannot coexist, so without it the harness fails whenever a real session is running.

**As-built coverage.** T-1 to T-10 and T-13 to T-19 are automated and green (17 checks; T-3 and T-15 each split into two). Three rows are not automated and fall to the manual matrix: **T-11**, because a real step-down needs sustained backpressure over a 15 s health window — M-5 covers it; **T-12**, covered by M-3's territory; and **T-15a**, refusing a non-loopback peer, which needs a second host — the loopback-only bind is verified by inspection (`lsof -nP -iTCP:7355 -sTCP:LISTEN` shows `127.0.0.1:7355`, not `*:7355`). T-18 is verified by a CLI transcript rather than by the Python harness.

| # | Covers | Assertion |
|---|---|---|
| T-1 | FR-5, FR-22 | `AEZ1 display` yields a decodable keyframe (parameter sets followed by an IDR) within 1 s, with no frame activity on the Mac. |
| T-2 | FR-6 | `AEZ1 bogus` yields `AEZ1 ERR` in full and then a closed socket. |
| T-3 | FR-5, NFR-10 | A socket whose first bytes are a 5-byte touch packet receives video and moves the cursor; a socket that sends nothing receives video within 300 ms + 1 s. |
| T-4 | FR-5 | `AEZ1 dis` then a 400 ms pause then `play\n` results in a closed connection, and a subsequent clean handshake succeeds. |
| T-5 | FR-7, FR-9, FR-13 | `AEZ1 control` receives `layout`, `sources` (with `fps`/`bitrate` per source) and `viewport` on connect, all length-prefixed and parseable. |
| T-6 | FR-11, NFR-9 | Two control clients: a proposal from A is broadcast to both with `rev` +1 and `ack` equal to A's token; elapsed time from send to B's receipt is ≤200 ms. |
| T-7 | FR-10, FR-11 | A proposal omitting a pane for an active source is rejected and the canonical layout re-broadcast unchanged. |
| T-8 | FR-11, edge case | A pane at `x: 1.4`, `w: 0.05` comes back clamped to the viewport and to the 0.15 minimum, with `rev` bumped. |
| T-9 | FR-1, FR-8 | With `SOURCES=display,window:<harness window>`, four sockets — two on `display`, one on the window, one control — all receive independently. |
| T-10 | FR-2 | With `SOURCES=window:X,display`, the config writer reorders to put `display` first, and a legacy client receives `display`. |
| T-11 | FR-23 | Forcing a step-down changes only that source's `bitrate` in the next `sources` message, the process does not exit, and the primary is untouched while a secondary is above the floor. |
| T-12 | FR-4 | Killing one mirrored app leaves the process alive, re-broadcasts `sources` without it, and keeps the other sources streaming. |
| T-13 | FR-9, FR-27 | `layout.json` holds the new `rev` after T-6 and is reloaded on restart; a `writeConf` call after an external `SOURCES` edit does not revert it. |
| T-14 | Edge case | A `layout.json` naming a dead source loads with orphans dropped, defaults added and `rev` bumped. |
| T-15 | NFR-2, NFR-3 | Connecting from a non-loopback address is refused; a control frame declaring 100 MiB is rejected and the socket closed. |
| T-16 | FR-19 | Subscribe to `display`, send a touch, assert the cursor moved via `CGEventGetLocation`. |
| T-17 | NFR-5 | With 3 sources and `BITRATE=500000`, the sum of configured per-source bitrates is 900 kbps, split 60/20/20. |
| T-18 | FR-28 | `aeasy sources` prints and sets `SOURCES` with no phone attached; a 4th entry exits non-zero; `aeasy mirror X` replaces rather than appends. |
| T-19 | FR-3 | With `SOURCES=display,window:NotRunningApp`, the server starts, logs the skip, and `sources` lists `display` alone — no fallback to window mode, no exit. |

Manual matrix, recorded in the PR:

| # | Covers | Steps |
|---|---|---|
| M-1 | FR-25, NFR-6 | Drag a pane on the Mac canvas; it moves on the phone with no restart and no snap-back. |
| M-2 | FR-11, FR-12, FR-17 | Drag a pane on the phone in arrange mode; the Mac canvas follows. Drag both at once; neither gesture is yanked. Switch to view mode; the same drag moves a Mac window instead. |
| M-3 | FR-20, FR-21 | Put a `window:` pane's real window behind another app; tap it on the phone; it comes to front and receives the click at the right point. Resize the Mac window first and confirm the click still lands correctly. |
| M-4 | FR-24 | Force three HEVC panes on a phone with a two-decoder limit; the third shows a persistent error after 3 tries, the others keep playing, and the retry affordance works. |
| M-5 | FR-23 | Over **USB**, raise `BITRATE` past the phone's decode capability; assert from the logged per-source bitrate that a secondary degrades first and the primary is untouched until the secondaries floor. |
| M-6 | NFR-10 | Run the new server against the previously released APK; confirm a normal fullscreen mirror. |
| M-7 | FR-14, FR-15 | Overlap three panes; confirm stacking is stable across a rotation and that taps hit the visually topmost pane. |
| M-8 | A11Y-1, A11Y-2, A11Y-3, A11Y-4, A11Y-5 | TalkBack: panes are focusable and announced (A11Y-1), the toggle announces its state on change (A11Y-2), long-press reset-layout works with explore-by-touch on (A11Y-3), error text wraps rather than ellipsizes at the largest font scale (A11Y-4), and the launcher label is Thai under a Thai locale (A11Y-5). |
| M-9 | FR-16, FR-18 | In a pane whose video letterboxes inside its rect, tap the four corners of the *video* and confirm the Mac cursor lands at the matching corners — not offset by the bars. Then tap a pane positioned under the arrange toggle and confirm the touch reaches the pane everywhere except inside the toggle's own box. |
| M-10 | FR-26 | In `aeasy config`, the Mode and "App to mirror" controls are gone; the source-list editor writes `SOURCES`, and saving encode settings warns that the session restarts. |

NFR-1, NFR-4, NFR-7, NFR-8, NFR-11, NFR-12, NFR-13, NFR-14 and P-1 are verified by code review at PR time, not by an automated test: they are structural properties (build flags, queue confinement, dependency set, per-pane ownership) rather than observable behaviours.

## Open questions

All resolved during analysis and drafting; recorded as question → answer pairs.


- Which screen is "จอที่ 2"? → The same Android device: extra panes overlaid PiP-style, not a second physical Mac monitor.
- How far does the overlay go? → Inside the AEasy app only; no `SYSTEM_ALERT_WINDOW`, no Android system PiP.
- One composited video or several streams? → Several separate streams; Android arranges them.
- How are streams multiplexed? → One TCP socket per source on the existing port 7355, so each stream stays raw Annex-B and `NalReader` is untouched.
- How many concurrent sources? → 3.
- What about the camera? → Both directions, with the phone camera shown in a preview window on the Mac — deferred to phase 2.
- Who owns the layout? → Both sides can drag; the server serialises and both converge.
- What happens on touch? → Every pane is touchable, mapped to the real window, which is raised before the click.
- What happens under lag? → Secondary panes degrade first; the primary is protected.
- How is the work delivered? → Phased; this spec is phase 1 only, itself split into 1a (server + Android) and 1b (Mac canvas).
- How does the settings GUI push changes live, given it is a separate process from the server? → It connects to `:7355` as an ordinary control client, reusing the phone's protocol rather than adding IPC.
- How does the phone tell "arrange the pane" apart from "click the Mac"? → An explicit arrange-mode toggle; view mode forwards every touch, arrange mode forwards none.
- What does "primary" mean, and who sets it? → It is `SOURCES[0]`, with `display` forced first when present. No separate field, no UI to promote a pane — reordering `SOURCES` is the only control.
- How do overlapping panes get z-ordered given SurfaceView's three fixed tiers? → Multi-pane uses `TextureView`; the single-pane path keeps `SurfaceView` and its lower latency.
- How is a window raised, now that `NSRunningApplication.activate` is denied to unbundled processes? → Accessibility `kAXRaiseAction`, matching the `AXUIElement` to `SCWindow.windowID` via `_AXUIElementGetWindow`.
