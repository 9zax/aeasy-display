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

// bracket pattern so pgrep doesn't match our own `zsh -c` wrapper
func serverRunning() -> Bool { shell("pgrep -qf 'aeasy-serve[r]'") == 0 }
func cablePlugged() -> Bool {  // any online device counts: adb (USB/wireless) or a tethered iOS device
    shell("export PATH=/opt/homebrew/bin:$PATH; adb devices 2>/dev/null | grep -q 'device$' || idevice_id -l 2>/dev/null | grep -q .") == 0
}

final class Tray: NSObject, NSApplicationDelegate, NSMenuDelegate {
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    let statusLine = NSMenuItem(title: "…", action: nil, keyEquivalent: "")

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
            let running = serverRunning()
            DispatchQueue.main.async { self.item.button?.appearsDisabled = !running }
        }
    }

    func menuWillOpen(_ menu: NSMenu) {
        statusLine.title = "checking…"
        DispatchQueue.global().async {
            let running = serverRunning(), plugged = cablePlugged()
            DispatchQueue.main.async {
                self.statusLine.title =
                    (plugged ? "📱 Phone: connected" : "📱 Phone: not connected")
                    + (running ? "  ·  🖥 running" : "  ·  🖥 stopped")
            }
        }
    }

    // ponytail: hardcoded copy of FEATURES.md / FEATURES.th.md — update both when features change
    static let featuresText = """
    • Second display over USB-C or Wi-Fi (aeasy wifi)
    • Real macOS extended display — not just mirroring
    • Touchscreen: tap to click, drag windows
    • Auto-rotation — portrait/landscape follows the device
    • Up to 3 sources as arrangeable, resizable panes
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
    • Touchscreen: แตะ = คลิก ลากหน้าต่างด้วยนิ้ว
    • หมุนจออัตโนมัติ — แนวตั้ง/แนวนอนตามการถือเครื่อง
    • แสดงได้สูงสุด 3 แหล่งภาพ เป็น pane ลากย้าย-ปรับขนาดได้
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
