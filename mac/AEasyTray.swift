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
func cablePlugged() -> Bool {
    shell("export PATH=/opt/homebrew/bin:$PATH; [[ \"$(adb get-state 2>/dev/null)\" == device ]]") == 0
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
                    (plugged ? "🔌 Cable: connected" : "🔌 Cable: not connected")
                    + (running ? "  ·  🖥 running" : "  ·  🖥 stopped")
            }
        }
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
