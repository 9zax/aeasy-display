# Setup guide — first run, step by step

<p align="center"><b>English</b> · <a href="SETUP.th.md">ภาษาไทย</a></p>

Everything on the Mac side is the same for both platforms; the device side differs. Android is the fast path (~2 minutes). iOS works but costs more setup, because Apple requires a signed app — read its section before starting.

## Mac (once, both platforms)

```sh
brew install 9zax/tap/aeasy-display     # or: git clone && make install
```

Two permission prompts will appear on first run — both are needed once:

| Prompt | Why | Where |
|---|---|---|
| **Screen Recording** | capturing the virtual display | System Settings → Privacy & Security → Screen Recording → `aeasy-server` |
| **Accessibility** | turning phone touches into Mac clicks | System Settings → Privacy & Security → Accessibility → `aeasy-server` |

Video works with only the first; touch needs both. If you build from source, re-grant Accessibility after every rebuild (the binary's signature changes).

---

## Android (~2 minutes)

1. **Enable USB debugging** on the phone: Settings → About phone → tap **Build number** 7 times → back → System → Developer options → **USB debugging** on.
2. Plug in the cable. Accept the **"Allow USB debugging?"** prompt on the phone.
3. ```sh
   aeasy install-app     # pushes the bundled APK
   aeasy start
   ```
4. Done. The viewer app launches itself, rotates with the phone, and reconnects on its own. Unplug/replug freely.

Wireless later: `aeasy wifi` (cable plugged in once to enable), back with `aeasy usb`.

---

## iPhone / iPad (beta, ~15 minutes first time)

**Read first:** Apple requires every app on a device to be signed. With a free Apple ID that means: sign once in Xcode, and the certificate **expires every 7 days** — when the app stops launching, plug in and press Run in Xcode again. No paid developer program needed.

**iPad owners:** if you're willing to sign into an Apple ID on both devices, Apple's own [Sidecar](https://support.apple.com/en-us/102597) is better than this — free, native, Apple Pencil. AEasy's iOS support exists mainly for iPhone, which has no first-party option.

### 1. Mac prerequisites

```sh
brew install libusbmuxd libimobiledevice socat   # iOS equivalent of android-platform-tools
```

Xcode (full app, not just Command Line Tools) must be installed — and **its SDK must be at least as new as the device's iOS version**. An iOS 26 device needs Xcode 26; if Run fails with "device not supported", update Xcode from the App Store first.

### 2. Device prerequisites

- Plug in, unlock, and tap **Trust** on the "Trust This Computer?" prompt.
- iOS 16+: enable **Developer Mode** — Settings → Privacy & Security → Developer Mode → on (the device restarts).

### 3. Install the app

```sh
aeasy install-app        # opens the Xcode project
```

In Xcode (all one-time):

1. **Xcode → Settings… → Accounts → +** → sign in with any Apple ID.
2. Project → target **AEasyDisplay** → **Signing & Capabilities** → tick **Automatically manage signing** → pick your **Personal Team**.
   - If Xcode says your certificate is **revoked**: that's normal after certificates rotate — with automatic signing selected, Xcode mints a fresh one on the spot.
3. Select your device in the toolbar → press **▶ Run**.
4. If the device blocks the app: Settings → General → **VPN & Device Management** → tap your Apple ID → **Trust**.

### 4. Run

```sh
aeasy start
```

Open **AEasy Display** on the device (the Mac can't launch it remotely — a notification reminds you). The app shows "Waiting for Mac…", connects within seconds, and the display rebuilds once at the device's real size. Touch drives the Mac cursor.

Wireless: the app shows its IP on screen → `aeasy wifi <that-ip>` → unplug. iOS asks once for Local Network permission.

### iOS limitations (by platform design — not bugs)

- Locking the screen or backgrounding the app **stops the stream**; unlock and it reconnects.
- The free certificate expires every **7 days** → press Run in Xcode again.
- The app can't be launched from the Mac.
- The very edges of the screen occasionally trigger iOS gestures instead of clicks.

---

## Android and iOS on the same Mac

Auto-detection prefers Android when both are plugged in. Force a platform with one config line:

```sh
echo "PLATFORM=ios" >> ~/.local/share/aeasy/config && aeasy restart   # use the iPhone/iPad
# remove the line (or set PLATFORM=android) and restart to switch back
```

---

## Troubleshooting

| Symptom | Fix |
|---|---|
| Black screen, connection fine | Phone can't decode HEVC → set `CODEC=h264` in `aeasy config` |
| Video works, taps do nothing | Grant **Accessibility** to `aeasy-server`, then `aeasy restart` |
| "not trusted — unlock and tap Trust" in `aeasy status` | Unlock the device with the cable in; accept the prompt |
| iOS app suddenly won't launch | The 7-day certificate expired → plug in, press Run in Xcode |
| Xcode: "signing certificate is revoked" | Pick the team again with **Automatically manage signing** on — Xcode issues a new one |
| Xcode: device's iOS version not supported | Update Xcode from the App Store |
| Laggy / stuttering | It auto-tunes per stream already; for slow devices run `aeasy tune` |
| Wrong device picked (several attached) | Android: unplug the extra. iOS: set `UDID=<id>` in the config (`idevice_id -l` lists them) |
| iOS display is too dense / too small | Set `IOS_SCALE=0.8` (smaller desktop, bigger text) or up to `2.0` in the config |
| Wi-Fi mode can't connect (iOS) | Re-check the IP the app shows; both machines on the same network; `aeasy status` says reachable? |

Still stuck → `aeasy log` shows the server's last lines; issues welcome.
