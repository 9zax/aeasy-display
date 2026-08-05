// AEasyConfig — tiny settings window for AEasy Display (opened via `aeasy config`)
import AppKit

let cfgPath = NSString(string: "~/.local/share/aeasy/config").expandingTildeInPath

func loadConf() -> [String: String] {
    var c: [String: String] = [:]
    if let txt = try? String(contentsOfFile: cfgPath, encoding: .utf8) {
        for line in txt.split(separator: "\n") {
            let kv = line.split(separator: "=", maxSplits: 1)
            if kv.count == 2 { c[String(kv[0])] = String(kv[1]).trimmingCharacters(in: .whitespaces) }
        }
    }
    return c
}

func runningAppNames() -> [String] {
    let opts = CGWindowListOption([.optionOnScreenOnly, .excludeDesktopElements])
    let list = CGWindowListCopyWindowInfo(opts, kCGNullWindowID) as? [[String: Any]] ?? []
    var names = Set<String>()
    for w in list where (w[kCGWindowLayer as String] as? Int) == 0 {
        if let n = w[kCGWindowOwnerName as String] as? String { names.insert(n) }
    }
    return names.sorted()
}

final class App: NSObject, NSApplicationDelegate {
    let fps = NSSlider(value: 20, minValue: 10, maxValue: 30, target: nil, action: nil)
    let bitrate = NSSlider(value: 2, minValue: 0.5, maxValue: 6, target: nil, action: nil)
    let scale = NSSlider(value: 80, minValue: 40, maxValue: 100, target: nil, action: nil)
    let fpsLabel = NSTextField(labelWithString: "")
    let bitrateLabel = NSTextField(labelWithString: "")
    let scaleLabel = NSTextField(labelWithString: "")
    let mode = NSPopUpButton(frame: .zero, pullsDown: false)
    let appPick = NSPopUpButton(frame: .zero, pullsDown: false)
    let status = NSTextField(labelWithString: " ")
    var window: NSWindow!

    func applicationDidFinishLaunching(_ n: Notification) {
        let c = loadConf()
        fps.doubleValue = Double(c["FPS"] ?? "") ?? 20
        bitrate.doubleValue = (Double(c["BITRATE"] ?? "") ?? 2_000_000) / 1_000_000
        scale.doubleValue = Double(c["SCALE"] ?? "") ?? 80
        mode.addItems(withTitles: ["Extended display", "Mirror one app window"])
        mode.selectItem(at: c["MODE"] == "window" ? 1 : 0)
        appPick.addItems(withTitles: runningAppNames())
        if let sel = c["WINDOW_APP"], appPick.itemTitles.contains(sel) { appPick.selectItem(withTitle: sel) }

        for s in [fps, bitrate, scale] { s.target = self; s.action = #selector(changed) }
        mode.target = self; mode.action = #selector(changed)

        let save = NSButton(title: "Save & Restart", target: self, action: #selector(saveTapped))
        save.keyEquivalent = "\r"

        func row(_ label: String, _ v: NSView) -> NSStackView {
            let l = NSTextField(labelWithString: label)
            l.widthAnchor.constraint(equalToConstant: 130).isActive = true
            let r = NSStackView(views: [l, v])
            r.orientation = .horizontal
            return r
        }

        let stack = NSStackView(views: [
            row("Frame rate", fps), row("", fpsLabel),
            row("Bitrate", bitrate), row("", bitrateLabel),
            row("Resolution", scale), row("", scaleLabel),
            row("Mode", mode),
            row("App to mirror", appPick),
            save, status,
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)

        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 340),
                          styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "AEasy Display — Settings"
        window.contentView = stack
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        changed()
    }

    @objc func changed() {
        fpsLabel.stringValue = "\(Int(fps.doubleValue)) fps"
        bitrateLabel.stringValue = String(format: "%.1f Mbps", bitrate.doubleValue)
        scaleLabel.stringValue = "\(Int(scale.doubleValue))% of phone panel"
        appPick.isEnabled = mode.indexOfSelectedItem == 1
    }

    @objc func saveTapped() {
        let conf = """
        FPS=\(Int(fps.doubleValue))
        BITRATE=\(Int(bitrate.doubleValue * 1_000_000))
        SCALE=\(Int(scale.doubleValue))
        MODE=\(mode.indexOfSelectedItem == 1 ? "window" : "display")
        WINDOW_APP=\(appPick.titleOfSelectedItem ?? "")
        AUTO=0
        """
        try? FileManager.default.createDirectory(atPath: (cfgPath as NSString).deletingLastPathComponent,
                                                 withIntermediateDirectories: true)
        try? conf.write(toFile: cfgPath, atomically: true, encoding: .utf8)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        p.arguments = ["-c", "\(NSHomeDirectory())/.local/bin/aeasy restart"]
        try? p.run()
        status.stringValue = "✅ Saved — restarting..."
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ app: NSApplication) -> Bool { true }
}

let app = NSApplication.shared
let delegate = App()
app.delegate = delegate
app.run()
