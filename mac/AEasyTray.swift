// AEasyTray — menu bar status item for AEasy Display (launched by `aeasy start`)
import AppKit

let aeasy = "\(NSHomeDirectory())/.local/bin/aeasy"

@discardableResult
func shell(_ cmd: String) -> Int32 {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/bin/zsh")
    p.arguments = ["-c", cmd]
    p.standardOutput = FileHandle.nullDevice
    p.standardError = FileHandle.nullDevice
    try? p.run()
    p.waitUntilExit()
    return p.terminationStatus
}

// shell() throws stdout away, so it cannot read a device list
func shellOut(_ cmd: String) -> String {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/bin/zsh")
    p.arguments = ["-c", cmd]
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = FileHandle.nullDevice
    do { try p.run() } catch { return "" }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return String(data: data, encoding: .utf8) ?? ""
}

struct Dev {
    let slot: String, serial: String, platform: String
    let conn: String, app: String, state: String, name: String
    var added: Bool { slot != "-" }
    var installed: Bool { app != "no" }          // n/a (iOS) and unknown are not "missing"
    var ready: Bool { state == "device" }
}

func deviceList() -> [Dev] {
    shellOut("'\(aeasy)' device list --raw").split(separator: "\n").compactMap { line in
        let f = line.components(separatedBy: "\t")
        guard f.count >= 7 else { return nil }
        return Dev(slot: f[0], serial: f[1], platform: f[2],
                   conn: f[3], app: f[4], state: f[5], name: f[6])
    }
}

// per-slot, not one bracket pattern over them all: a single `pgrep -qf 'aeasy-serve[r]'`
// reports healthy while two of three devices are dead
func runningSlots() -> Set<String> {
    var out = Set<String>()
    for s in 0..<3 where shell("pgrep -qf 'aeasy-serve[r] .*--slot \(s)'") == 0 {
        out.insert(String(s))
    }
    return out
}

func inputHolder() -> String {
    shellOut("'\(aeasy)' device input").split(separator: " ").first.map(String.init) ?? ""
}

func stateNote(_ d: Dev) -> String? {
    switch d.state {
    case "device":       return d.installed ? nil : "app not installed / ยังไม่ได้ติดตั้งแอพ"
    case "unauthorized": return "allow USB debugging / กดอนุญาต USB debugging"
    case "untrusted":    return "unlock and tap Trust / ปลดล็อกแล้วกด Trust"
    case "offline":      return "offline / ออฟไลน์"
    default:             return d.state
    }
}

final class Tray: NSObject, NSApplicationDelegate, NSMenuDelegate {
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    let statusLine = NSMenuItem(title: "…", action: nil, keyEquivalent: "")
    let devicesItem = NSMenuItem(title: "Devices", action: nil, keyEquivalent: "")
    let inputItem = NSMenuItem(title: "Input control", action: nil, keyEquivalent: "")

    func applicationDidFinishLaunching(_ n: Notification) {
        let logo = "\(NSHomeDirectory())/.local/share/aeasy/logo.svg"
        if let img = NSImage(contentsOfFile: logo) {
            img.size = NSSize(width: 18, height: 18)
            item.button?.image = img
        } else {
            item.button?.title = "📱"  // ponytail: fallback if logo.svg missing from share dir
        }
        let menu = NSMenu()
        menu.delegate = self
        menu.addItem(statusLine)
        menu.addItem(.separator())
        menu.addItem(devicesItem)
        menu.addItem(inputItem)
        menu.addItem(.separator())
        menu.addItem(withTitle: "Start / Restart", action: #selector(start), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Stop", action: #selector(stop), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Settings…", action: #selector(settings), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Features…", action: #selector(features), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit AEasy", action: #selector(quit), keyEquivalent: "").target = self
        item.menu = menu
        refreshIcon()
        Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { _ in self.refreshIcon() }
    }

    func refreshIcon() {
        DispatchQueue.global().async {
            let up = !runningSlots().isEmpty
            DispatchQueue.main.async { self.item.button?.appearsDisabled = !up }
        }
    }

    // enumeration shells out to adb/idevice_id, which can block for seconds on an
    // unresponsive device, so it never runs on the main queue
    func menuWillOpen(_ menu: NSMenu) {
        statusLine.title = "checking…"
        DispatchQueue.global().async {
            let devs = deviceList(), running = runningSlots(), holder = inputHolder()
            DispatchQueue.main.async { self.rebuild(devs, running, holder) }
        }
    }

    private func rebuild(_ devs: [Dev], _ running: Set<String>, _ holder: String) {
        let added = devs.filter { $0.added }
        let holderName = added.first { $0.slot == holder }?.name ?? "nobody"
        statusLine.title = "📱 \(added.count) of 3 devices  ·  🖱 \(holderName)"

        let dm = NSMenu()
        if devs.isEmpty {
            let none = NSMenuItem(title: "No devices found — plug one in", action: nil, keyEquivalent: "")
            none.isEnabled = false
            dm.addItem(none)
        }
        for d in devs {
            var title = d.name
            if let note = stateNote(d) { title += " — \(note)" }
            else if d.added { title += "  ·  \(d.conn)\(running.contains(d.slot) ? "" : " (stopped)")" }
            let mi = NSMenuItem(title: title,
                                action: #selector(toggleDevice(_:)), keyEquivalent: "")
            mi.target = self
            mi.state = d.added ? .on : .off           // a checkmark, never colour alone
            mi.representedObject = d
            if d.ready && !d.installed {
                // not addable, but the row stays visible and says why — and its action
                // explains how to install rather than installing anything
                mi.action = #selector(installHelp(_:))
            } else if !d.ready {
                mi.action = #selector(installHelp(_:))
            }
            dm.addItem(mi)
        }
        devicesItem.submenu = dm

        let im = NSMenu()
        if added.isEmpty {
            let none = NSMenuItem(title: "No devices added", action: nil, keyEquivalent: "")
            none.isEnabled = false
            im.addItem(none)
        }
        for d in added {
            // NSMenu has no radio grouping; the action clears every sibling and sets the sender
            let mi = NSMenuItem(title: d.name, action: #selector(setInput(_:)), keyEquivalent: "")
            mi.target = self
            mi.state = d.slot == holder ? .on : .off
            mi.representedObject = d
            im.addItem(mi)
        }
        inputItem.submenu = im
    }

    @objc func toggleDevice(_ sender: NSMenuItem) {
        guard let d = sender.representedObject as? Dev else { return }
        let cmd = d.added ? "device rm \(d.slot)" : "device add \(d.serial)"
        DispatchQueue.global().async { shell("'\(aeasy)' \(cmd)") }
    }

    @objc func setInput(_ sender: NSMenuItem) {
        guard let d = sender.representedObject as? Dev else { return }
        DispatchQueue.global().async { shell("'\(aeasy)' device input \(d.slot)") }
    }

    // shows instructions and installs nothing: there is no unauthenticated remote-install
    // path on either platform, and pretending otherwise would fail silently
    @objc func installHelp(_ sender: NSMenuItem) {
        guard let d = sender.representedObject as? Dev else { return }
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "\(d.name) — \(stateNote(d) ?? d.state)"
        let body: String
        switch d.state {
        case "unauthorized":
            body = """
            Unlock the device and accept the "Allow USB debugging?" prompt, then open this menu again.

            ปลดล็อกเครื่องแล้วกดอนุญาตหน้าต่าง "Allow USB debugging?" จากนั้นเปิดเมนูนี้ใหม่
            """
        case "untrusted":
            body = """
            Unlock the device and tap Trust on the "Trust This Computer?" prompt, then open this menu again.

            ปลดล็อกเครื่องแล้วกด Trust ที่หน้าต่าง "Trust This Computer?" จากนั้นเปิดเมนูนี้ใหม่
            """
        case "device" where d.platform == "ios":
            body = """
            iOS needs Xcode to sign the app. Open ios/AEasyDisplay.xcodeproj, pick this device, and press Run:

                aeasy install-app \(d.serial)

            iOS ต้องใช้ Xcode เซ็นแอพ เปิด ios/AEasyDisplay.xcodeproj เลือกเครื่องนี้ แล้วกด Run
            """
        default:
            body = """
            Plug the device in over USB with USB debugging on, then run:

                aeasy install-app \(d.serial)

            เสียบสาย USB โดยเปิด USB debugging ไว้ แล้วรัน:

                aeasy install-app \(d.serial)
            """
        }
        let scroll = NSTextView.scrollableTextView()
        scroll.frame = NSRect(x: 0, y: 0, width: 440, height: 190)
        let tv = scroll.documentView as! NSTextView
        tv.string = body
        tv.isEditable = false
        tv.isSelectable = true        // the commands are meant to be copied
        tv.font = .systemFont(ofSize: 13)
        tv.textContainerInset = NSSize(width: 6, height: 8)
        alert.accessoryView = scroll
        alert.runModal()
    }

    // ponytail: hardcoded copy of FEATURES.md / FEATURES.th.md — update both when features change
    static let featuresText = """
    • Second display over USB-C or Wi-Fi (aeasy wifi)
    • Real macOS extended display — not just mirroring
    • Up to 3 devices at once, each its own display
    • Touchscreen: tap to click, drag windows
    • Auto-rotation — portrait/landscape follows the device
    • Up to 3 sources per device as arrangeable, resizable panes
    • Single-app window mirroring (aeasy mirror <App>)
    • Hardware H.264 / HEVC, Retina-crisp
    • Adaptive quality when the decoder lags
    • Low-latency preset for slow devices (aeasy tune)
    • Settings GUI: fps, bitrate, resolution, pane layout
    • Plug-and-play: auto-start and auto-reconnect
    • Android 8+ phones and tablets
    • iPhone & iPad viewer (beta)
    • Free, open source (MIT), no accounts

    • จอที่สองผ่านสาย USB-C หรือ Wi-Fi (aeasy wifi)
    • เป็นจอ macOS จริง ลากหน้าต่างไปวางได้ ไม่ใช่แค่ mirror
    • ต่อได้พร้อมกันสูงสุด 3 เครื่อง แต่ละเครื่องเป็นจอของตัวเอง
    • Touchscreen: แตะ = คลิก ลากหน้าต่างด้วยนิ้ว
    • หมุนจออัตโนมัติ — แนวตั้ง/แนวนอนตามการถือเครื่อง
    • แสดงได้สูงสุด 3 แหล่งภาพต่อเครื่อง เป็น pane ลากย้าย-ปรับขนาดได้
    • Mirror หน้าต่างแอปเดียว (aeasy mirror <App>)
    • เข้ารหัสฮาร์ดแวร์ H.264 / HEVC คมระดับ Retina
    • ปรับคุณภาพอัตโนมัติเมื่อเครื่องถอดรหัสไม่ทัน
    • พรีเซ็ตหน่วงต่ำสำหรับเครื่องช้า (aeasy tune)
    • GUI ตั้งค่า: เฟรมเรต บิตเรต ความละเอียด ผัง pane
    • เสียบปุ๊บติดปั๊บ: เริ่มและต่อใหม่ให้เองอัตโนมัติ
    • รองรับมือถือ/แท็บเล็ต Android 8+
    • แอปดูบน iPhone & iPad (beta)
    • ฟรี โอเพนซอร์ส (MIT) ไม่ต้องสมัครสมาชิก
    """

    @objc func features() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "AEasy Display — Features / ฟีเจอร์"
        let scroll = NSTextView.scrollableTextView()
        scroll.frame = NSRect(x: 0, y: 0, width: 440, height: 360)
        let tv = scroll.documentView as! NSTextView
        tv.string = Tray.featuresText
        tv.isEditable = false
        tv.font = .systemFont(ofSize: 13)
        tv.textContainerInset = NSSize(width: 6, height: 8)
        alert.accessoryView = scroll
        alert.runModal()
    }

    // Start/Restart and Stop stay global: `aeasy restart` loops the registry and `aeasy
    // stop` is meant to stop everything. Per-device control is the Devices submenu, where
    // removing a device stops exactly that one.
    @objc func start() { DispatchQueue.global().async { shell("'\(aeasy)' restart || '\(aeasy)' start") } }
    @objc func stop() { DispatchQueue.global().async { shell("'\(aeasy)' stop") } }
    @objc func settings() { DispatchQueue.global().async { shell("'\(aeasy)' config") } }
    @objc func quit() { NSApp.terminate(nil) }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = Tray()
app.delegate = delegate
app.run()
