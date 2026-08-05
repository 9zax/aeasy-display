// AEasyConfig — settings window for AEasy Display (opened via `aeasy config`).
// Encode settings and the source list are written to the config file and need a restart.
// The pane layout is live: this app connects to the server's control channel on :7355
// exactly like the phone does, so dragging a pane here moves it on the phone immediately.
import AppKit
import AVFoundation
import Network

let shareDir = NSString(string: ProcessInfo.processInfo.environment["AEASY_DIR"] ?? "~/.local/share/aeasy")
    .expandingTildeInPath
let cfgPath = shareDir + "/config"
// matches the server's override so the settings window can be pointed at a test instance
let CTL_PORT = UInt16(ProcessInfo.processInfo.environment["AEASY_PORT"] ?? "") ?? 7355

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

// listing names needs no camera permission — only capture does (that prompt is the server's)
func cameraNames() -> [String] {
    AVCaptureDevice.DiscoverySession(deviceTypes: [.builtInWideAngleCamera, .externalUnknown],
                                     mediaType: .video, position: .unspecified)
        .devices.map(\.localizedName).sorted()
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

// MARK: - control link

/// ponytail: the 4-byte length framing is duplicated from the server rather than shared —
/// swiftc only allows top-level code in a single file, so a shared file would mean
/// restructuring both binaries around @main for 25 lines.
final class ControlLink {
    private var conn: NWConnection?
    private var buf = Data()
    private let queue = DispatchQueue(label: "ctl")
    private var backoff = 0.3
    private var stopped = false

    var onMessage: (([String: Any]) -> Void)?
    var onState: ((Bool) -> Void)?

    func start() { connect() }

    private func connect() {
        guard !stopped else { return }
        let c = NWConnection(host: .ipv4(.loopback), port: NWEndpoint.Port(rawValue: CTL_PORT)!, using: .tcp)
        conn = c
        c.stateUpdateHandler = { [weak self] st in
            guard let self else { return }
            switch st {
            case .ready:
                self.backoff = 0.3
                self.buf.removeAll()
                c.send(content: Data("AEZ1 control\n".utf8), completion: .contentProcessed { _ in })
                self.receive(c)
                DispatchQueue.main.async { self.onState?(true) }
            case .failed, .cancelled:
                DispatchQueue.main.async { self.onState?(false) }
                self.retry()
            default: break
            }
        }
        c.start(queue: queue)
    }

    // the server restarts on every phone rotation, so the canvas has to come back on its own
    private func retry() {
        guard !stopped else { return }
        conn = nil
        let delay = backoff
        backoff = min(backoff * 2, 3)
        queue.asyncAfter(deadline: .now() + delay) { [weak self] in self?.connect() }
    }

    private func receive(_ c: NWConnection) {
        c.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, complete, err in
            guard let self else { return }
            if let d = data, !d.isEmpty {
                self.buf.append(d)
                self.drain()
            }
            if complete || err != nil { self.retry(); return }
            self.receive(c)
        }
    }

    private func drain() {
        while buf.count >= 4 {
            let len = buf.withUnsafeBytes { raw -> Int in
                let b = raw.bindMemory(to: UInt8.self)
                return Int(b[0]) << 24 | Int(b[1]) << 16 | Int(b[2]) << 8 | Int(b[3])
            }
            guard len > 0, len <= 1 << 20 else { buf.removeAll(); return }
            guard buf.count >= 4 + len else { return }
            let body = Data(buf[buf.index(buf.startIndex, offsetBy: 4)..<buf.index(buf.startIndex, offsetBy: 4 + len)])
            buf = Data(buf.dropFirst(4 + len))
            if let obj = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] {
                DispatchQueue.main.async { self.onMessage?(obj) }
            }
        }
    }

    func send(_ obj: [String: Any]) {
        guard let c = conn, let body = try? JSONSerialization.data(withJSONObject: obj) else { return }
        var frame = Data([UInt8((body.count >> 24) & 0xff), UInt8((body.count >> 16) & 0xff),
                          UInt8((body.count >> 8) & 0xff), UInt8(body.count & 0xff)])
        frame.append(body)
        c.send(content: frame, completion: .contentProcessed { _ in })
    }
}

// MARK: - drag canvas

struct CanvasPane {
    var src: String
    var x: Double, y: Double, w: Double, h: Double
    var z: Int
}

final class PaneCanvasView: NSView {
    var panes: [CanvasPane] = [] { didSet { needsDisplay = true } }
    var viewport = CGSize(width: 720, height: 1650) { didSet { needsDisplay = true } }
    var connected = false { didSet { needsDisplay = true } }
    var onEdit: (([CanvasPane]) -> Void)?

    private var dragIndex: Int?
    private var resizing = false
    private var grabDX = 0.0, grabDY = 0.0
    private var lastSent = Date.distantPast

    override var isFlipped: Bool { true }   // match the phone's top-left origin

    /// the phone's screen, letterboxed inside this view
    private var screenRect: CGRect {
        let inset = bounds.insetBy(dx: 8, dy: 8)
        let s = min(inset.width / viewport.width, inset.height / viewport.height)
        let w = viewport.width * s, h = viewport.height * s
        return CGRect(x: inset.midX - w / 2, y: inset.midY - h / 2, width: w, height: h)
    }

    private func rect(_ p: CanvasPane) -> CGRect {
        let s = screenRect
        return CGRect(x: s.minX + p.x * s.width, y: s.minY + p.y * s.height,
                      width: p.w * s.width, height: p.h * s.height)
    }

    override func draw(_ dirty: CGRect) {
        NSColor.underPageBackgroundColor.setFill()
        bounds.fill()
        let s = screenRect
        NSColor.black.setFill()
        NSBezierPath(roundedRect: s, xRadius: 6, yRadius: 6).fill()

        for p in panes.sorted(by: { $0.z < $1.z }) {
            let r = rect(p)
            NSColor.controlAccentColor.withAlphaComponent(0.28).setFill()
            r.fill()
            NSColor.controlAccentColor.setStroke()
            let path = NSBezierPath(rect: r)
            path.lineWidth = 2
            path.stroke()
            NSColor.controlAccentColor.setFill()
            CGRect(x: r.maxX - 12, y: r.maxY - 12, width: 12, height: 12).fill()
            let label = p.src.replacingOccurrences(of: "window:", with: "")
                             .replacingOccurrences(of: "camera:", with: "📷 ")
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 10),
                .foregroundColor: NSColor.white,
            ]
            (label as NSString).draw(at: CGPoint(x: r.minX + 5, y: r.minY + 4), withAttributes: attrs)
        }

        if !connected {
            let msg = "Not connected — start the display first (aeasy start)"
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 11),
                .foregroundColor: NSColor.secondaryLabelColor,
            ]
            let size = (msg as NSString).size(withAttributes: attrs)
            (msg as NSString).draw(at: CGPoint(x: bounds.midX - size.width / 2, y: bounds.maxY - 18),
                                   withAttributes: attrs)
        }
    }

    override func mouseDown(with event: NSEvent) {
        let pt = convert(event.locationInWindow, from: nil)
        for (i, p) in panes.enumerated().sorted(by: { $0.element.z > $1.element.z }) {
            let r = rect(p)
            guard r.contains(pt) else { continue }
            dragIndex = i
            resizing = pt.x > r.maxX - 16 && pt.y > r.maxY - 16
            grabDX = Double((pt.x - r.minX) / screenRect.width)
            grabDY = Double((pt.y - r.minY) / screenRect.height)
            return
        }
        dragIndex = nil
    }

    override func mouseDragged(with event: NSEvent) {
        guard let i = dragIndex else { return }
        let pt = convert(event.locationInWindow, from: nil)
        let s = screenRect
        let nx = Double((pt.x - s.minX) / s.width), ny = Double((pt.y - s.minY) / s.height)
        var p = panes[i]
        if resizing {
            p.w = min(1 - p.x, max(0.15, nx - p.x))
            p.h = min(1 - p.y, max(0.15, ny - p.y))
        } else {
            p.x = min(1 - p.w, max(0, nx - grabDX))
            p.y = min(1 - p.h, max(0, ny - grabDY))
        }
        panes[i] = p
        if Date().timeIntervalSince(lastSent) > 0.05 {   // 20Hz, same as the phone
            lastSent = Date()
            onEdit?(panes)
        }
    }

    override func mouseUp(with event: NSEvent) {
        guard dragIndex != nil else { return }
        dragIndex = nil
        resizing = false
        onEdit?(panes)
    }
}

// MARK: - app

final class App: NSObject, NSApplicationDelegate {
    let fps = NSSlider(value: 20, minValue: 10, maxValue: 30, target: nil, action: nil)
    let bitrate = NSSlider(value: 2, minValue: 0.5, maxValue: 6, target: nil, action: nil)
    let scale = NSSlider(value: 80, minValue: 40, maxValue: 100, target: nil, action: nil)
    let fpsLabel = NSTextField(labelWithString: "")
    let bitrateLabel = NSTextField(labelWithString: "")
    let scaleLabel = NSTextField(labelWithString: "")
    let codec = NSPopUpButton(frame: .zero, pullsDown: false)
    var sourcePicks: [NSPopUpButton] = []
    let canvas = PaneCanvasView()
    let status = NSTextField(labelWithString: " ")
    var window: NSWindow!

    let link = ControlLink()
    var rev = -1
    let token = String(UUID().uuidString.prefix(8))

    private let NONE = "— none —"
    private let DISPLAY = "Extended display"
    private let CAM = "Camera: "   // visible prefix, doubles as the title↔id discriminator

    func applicationDidFinishLaunching(_ n: Notification) {
        let c = loadConf()
        fps.doubleValue = Double(c["FPS"] ?? "") ?? 20
        bitrate.doubleValue = (Double(c["BITRATE"] ?? "") ?? 2_000_000) / 1_000_000
        scale.doubleValue = Double(c["SCALE"] ?? "") ?? 80
        codec.addItems(withTitles: ["H.264 (compatible)", "HEVC (better quality)"])
        codec.selectItem(at: c["CODEC"] == "hevc" ? 1 : 0)

        // MODE/WINDOW_APP are gone: SOURCES is the only thing the server reads now, so a
        // leftover Mode dropdown would silently do nothing
        let apps = runningAppNames()
        let cams = cameraNames().map { CAM + $0 }
        let current = configuredSources(c)
        for i in 0..<3 {
            let p = NSPopUpButton(frame: .zero, pullsDown: false)
            p.addItems(withTitles: [NONE, DISPLAY] + cams + apps)
            if i < current.count {
                let id = current[i]
                if id == "display" { p.selectItem(withTitle: DISPLAY) }
                else {
                    let title = id.hasPrefix("camera:") ? CAM + id.dropFirst("camera:".count)
                                                        : String(id.dropFirst("window:".count))
                    if p.itemTitles.contains(title) { p.selectItem(withTitle: title) }
                    else { p.addItem(withTitle: title); p.selectItem(withTitle: title) }
                }
            }
            p.target = self
            p.action = #selector(changed)
            sourcePicks.append(p)
        }

        for s in [fps, bitrate, scale] { s.target = self; s.action = #selector(changed) }

        let save = NSButton(title: "Save & Restart", target: self, action: #selector(saveTapped))
        save.keyEquivalent = "\r"

        canvas.translatesAutoresizingMaskIntoConstraints = false
        canvas.heightAnchor.constraint(equalToConstant: 230).isActive = true
        canvas.widthAnchor.constraint(equalToConstant: 460).isActive = true
        canvas.onEdit = { [weak self] panes in self?.propose(panes) }

        func row(_ label: String, _ v: NSView) -> NSStackView {
            let l = NSTextField(labelWithString: label)
            l.widthAnchor.constraint(equalToConstant: 130).isActive = true
            let r = NSStackView(views: [l, v])
            r.orientation = .horizontal
            return r
        }

        let hint = NSTextField(labelWithString: "Drag a pane to move it, drag its corner to resize — the phone follows live.")
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = .secondaryLabelColor

        let restartNote = NSTextField(labelWithString: "Save & Restart applies quality and sources — it restarts the stream.")
        restartNote.font = .systemFont(ofSize: 11)
        restartNote.textColor = .secondaryLabelColor

        let stack = NSStackView(views: [
            row("Frame rate", fps), row("", fpsLabel),
            row("Bitrate", bitrate), row("", bitrateLabel),
            row("Resolution", scale), row("", scaleLabel),
            row("Codec", codec),
            row("Source 1", sourcePicks[0]),
            row("Source 2", sourcePicks[1]),
            row("Source 3", sourcePicks[2]),
            hint, canvas,
            save, restartNote, status,
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)

        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 700),
                          styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "AEasy Display — Settings"
        window.contentView = stack
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        changed()

        link.onState = { [weak self] up in
            self?.canvas.connected = up
            if !up { self?.rev = -1 }
        }
        link.onMessage = { [weak self] msg in self?.handle(msg) }
        link.start()
    }

    private func configuredSources(_ c: [String: String]) -> [String] {
        let ids = (c["SOURCES"] ?? "").split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        if !ids.isEmpty { return ids }
        let app = c["WINDOW_APP"] ?? ""
        return (c["MODE"] ?? "display") == "window" && !app.isEmpty ? ["window:\(app)"] : ["display"]
    }

    private func pickedSources() -> [String] {
        var ids: [String] = []
        for p in sourcePicks {
            guard let t = p.titleOfSelectedItem, t != NONE else { continue }
            let id = t == DISPLAY ? "display"
                   : t.hasPrefix(CAM) ? "camera:\(t.dropFirst(CAM.count))"
                   : "window:\(t)"
            if !ids.contains(id) { ids.append(id) }
        }
        if ids.isEmpty { ids = ["display"] }
        if let i = ids.firstIndex(of: "display"), i != 0 { ids.remove(at: i); ids.insert("display", at: 0) }
        return ids
    }

    private func handle(_ msg: [String: Any]) {
        switch msg["t"] as? String {
        case "viewport":
            if let w = (msg["w"] as? NSNumber)?.doubleValue, let h = (msg["h"] as? NSNumber)?.doubleValue {
                canvas.viewport = CGSize(width: w, height: h)
            }
        case "layout":
            let newRev = (msg["rev"] as? NSNumber)?.intValue ?? -1
            let mine = (msg["ack"] as? String) == token
            guard newRev > rev || mine else { return }
            rev = newRev
            canvas.panes = ((msg["panes"] as? [[String: Any]]) ?? []).compactMap { d in
                guard let src = d["src"] as? String else { return nil }
                func num(_ k: String, _ f: Double) -> Double { (d[k] as? NSNumber)?.doubleValue ?? f }
                return CanvasPane(src: src, x: num("x", 0), y: num("y", 0),
                                  w: num("w", 1), h: num("h", 1),
                                  z: (d["z"] as? NSNumber)?.intValue ?? 0)
            }
        case "error":
            status.stringValue = "⚠️ " + ((msg["msg"] as? String) ?? "")
        default:
            break
        }
    }

    private func propose(_ panes: [CanvasPane]) {
        let arr = panes.map { ["src": $0.src, "x": $0.x, "y": $0.y, "w": $0.w, "h": $0.h, "z": $0.z] as [String: Any] }
        link.send(["t": "layout", "panes": arr, "tok": token])
    }

    @objc func changed() {
        fpsLabel.stringValue = "\(Int(fps.doubleValue)) fps"
        bitrateLabel.stringValue = String(format: "%.1f Mbps", bitrate.doubleValue)
        scaleLabel.stringValue = "\(Int(scale.doubleValue))% of phone panel"
    }

    @objc func saveTapped() {
        var c = loadConf()  // preserve keys the GUI doesn't know about (WIFI_ADDR, …)
        c["FPS"] = "\(Int(fps.doubleValue))"
        c["BITRATE"] = "\(Int(bitrate.doubleValue * 1_000_000))"
        c["SCALE"] = "\(Int(scale.doubleValue))"
        c["CODEC"] = codec.indexOfSelectedItem == 1 ? "hevc" : "h264"
        c["SOURCES"] = pickedSources().joined(separator: ",")
        c["MODE"] = nil          // superseded by SOURCES
        c["WINDOW_APP"] = nil
        c["AUTO"] = nil          // quality is stepped down live now, no restart ladder
        let conf = c.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: "\n")
        try? FileManager.default.createDirectory(atPath: (cfgPath as NSString).deletingLastPathComponent,
                                                 withIntermediateDirectories: true)
        try? conf.write(toFile: cfgPath, atomically: true, encoding: .utf8)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        p.arguments = ["-c", "\(NSHomeDirectory())/.local/bin/aeasy restart"]
        try? p.run()
        status.stringValue = "✅ Saved — restarting the stream..."
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ app: NSApplication) -> Bool { true }
}

let app = NSApplication.shared
let delegate = App()
app.delegate = delegate
app.run()
