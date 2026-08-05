// AEasyServer — streams a virtual display OR one app window to an Android phone over USB.
// H.264 Annex-B over TCP :7355; the Android app connects through `adb reverse`.
// Usage: aeasy-server [W] [H]   (phone panel pixels; W>H landscape, W<H portrait)
// Config: ~/.local/share/aeasy/config  (FPS, BITRATE, SCALE, MODE=display|window, WINDOW_APP)

import Foundation
import AppKit
import ScreenCaptureKit
import VideoToolbox
import CoreMedia
import CoreVideo
import Network

let PORT: UInt16 = 7355

// connect to WindowServer up front — SCContentFilter(desktopIndependentWindow:) asserts
// (CGS_REQUIRE_INIT) in a headless process without it; display mode only survived because
// CGVirtualDisplay happened to open the connection first
_ = NSApplication.shared

// tunables live in ~/.local/share/aeasy/config (key=value), edited by the config GUI
let shareDir = NSString(string: "~/.local/share/aeasy").expandingTildeInPath
var _conf: [String: String] = [:]
if let txt = try? String(contentsOfFile: shareDir + "/config", encoding: .utf8) {
    for line in txt.split(separator: "\n") {
        let kv = line.split(separator: "=", maxSplits: 1)
        if kv.count == 2 { _conf[String(kv[0])] = String(kv[1]).trimmingCharacters(in: .whitespaces) }
    }
}
let FPS = Int32(_conf["FPS"] ?? "") ?? 20
let BITRATE = Int(_conf["BITRATE"] ?? "") ?? 2_000_000
let SCALE = min(100, max(40, Int(_conf["SCALE"] ?? "") ?? 80))  // encode size, % of panel
let MODE = _conf["MODE"] ?? "display"                            // display | window
let WINDOW_APP = _conf["WINDOW_APP"] ?? ""
let AUTO = (_conf["AUTO"] ?? "1") == "1"  // first connection = auto-tune until the user picks settings

func writeConf(_ updates: [String: String]) {
    var c = _conf
    for (k, v) in updates { c[k] = v }
    let txt = c.map { "\($0.key)=\($0.value)" }.sorted().joined(separator: "\n")
    try? FileManager.default.createDirectory(atPath: shareDir, withIntermediateDirectories: true)
    try? txt.write(toFile: shareDir + "/config", atomically: true, encoding: .utf8)
}

func notify(_ msg: String) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
    p.arguments = ["-e", "display notification \"\(msg)\" with title \"AEasy Display\" sound name \"Funk\""]
    try? p.run()
}

var pxW: UInt32 = 1650, pxH: UInt32 = 720
if CommandLine.arguments.count >= 3,
   let a = UInt32(CommandLine.arguments[1]), let b = UInt32(CommandLine.arguments[2]) {
    pxW = a  // passed as-is: W>H = landscape, W<H = portrait
    pxH = b
}

final class TCPServer {
    private var conns: [ObjectIdentifier: NWConnection] = [:]
    private let queue = DispatchQueue(label: "net")
    var header = Data() // cached Annex-B SPS+PPS for late joiners

    init() throws {
        let l = try NWListener(using: .tcp, on: NWEndpoint.Port(rawValue: PORT)!)
        l.newConnectionHandler = { c in
            c.stateUpdateHandler = { [weak self, weak c] st in
                guard let self, let c else { return }
                switch st {
                case .ready:
                    NSLog("client connected")
                    self.queue.async {
                        self.conns[ObjectIdentifier(c)] = c
                        if !self.header.isEmpty {
                            c.send(content: self.header, completion: .contentProcessed { _ in })
                        }
                    }
                case .failed, .cancelled:
                    self.queue.async {
                        self.conns[ObjectIdentifier(c)] = nil
                        self.pending[ObjectIdentifier(c)] = nil
                    }
                default: break
                }
            }
            c.start(queue: self.queue)
        }
        l.start(queue: queue)
        NSLog("listening on \(PORT)")
    }

    private var pending: [ObjectIdentifier: Int] = [:]
    private var sent = 0, dropped = 0
    private var lastAlert = Date.distantPast
    private var healthTimer: DispatchSourceTimer?

    // droppable frames are skipped for clients that fall behind — bounded latency
    // ponytail: dropped P-frames glitch until the next keyframe (≤1s); fine for a monitor
    func broadcast(_ d: Data, droppable: Bool) {
        queue.async {
            for (k, c) in self.conns {
                if droppable && (self.pending[k] ?? 0) > 2 { self.dropped += 1; continue }
                self.sent += 1
                self.pending[k, default: 0] += 1
                c.send(content: d, completion: .contentProcessed { _ in
                    self.queue.async { self.pending[k] = max(0, (self.pending[k] ?? 1) - 1) }
                })
            }
        }
    }

    // if the phone keeps falling behind, tell the user what settings will fix it
    func startHealthCheck() {
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 15, repeating: 15)
        t.setEventHandler { [weak self] in
            guard let self else { return }
            let total = self.sent + self.dropped
            defer { self.sent = 0; self.dropped = 0 }
            guard total > 100 else { return }
            let rate = Double(self.dropped) / Double(total)
            if rate > 0.25, Date().timeIntervalSince(self.lastAlert) > 60 {
                self.lastAlert = Date()
                if AUTO {
                    // first-connection auto mode: step the quality down and restart (watcher relaunches us)
                    let next: [String: String] = FPS > 15
                        ? ["FPS": "15", "BITRATE": "1500000", "SCALE": "60"]
                        : ["FPS": "12", "BITRATE": "1000000", "SCALE": "50", "AUTO": "0"]  // floor — stop stepping
                    writeConf(next)
                    NSLog("LAGGY: \(Int(rate * 100))%% dropped — AUTO applying FPS=\(next["FPS"]!) SCALE=\(next["SCALE"]!), restarting")
                    notify("Lag detected — auto-tuned to \(next["FPS"]!)fps / \(next["SCALE"]!)% resolution")
                    exit(0)
                } else {
                    NSLog("LAGGY: \(Int(rate * 100))%% of frames dropped — phone decoder can't keep up; run `aeasy tune`")
                    notify("Phone decoder cannot keep up (laggy) — run aeasy tune for the recommended settings (15fps / 60%)")
                }
            }
        }
        t.resume()
        healthTimer = t
    }
}

final class Encoder {
    private var session: VTCompressionSession?
    private let server: TCPServer

    init(server: TCPServer) { self.server = server }

    private func makeSession(width: Int32, height: Int32) {
        var s: VTCompressionSession?
        VTCompressionSessionCreate(
            allocator: nil, width: width, height: height,
            codecType: kCMVideoCodecType_H264,
            encoderSpecification: nil, imageBufferAttributes: nil,
            compressedDataAllocator: nil, outputCallback: nil, refcon: nil,
            compressionSessionOut: &s)
        guard let s else { fatalError("VTCompressionSessionCreate failed") }
        VTSessionSetProperty(s, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        VTSessionSetProperty(s, key: kVTCompressionPropertyKey_ProfileLevel, value: kVTProfileLevel_H264_Main_AutoLevel)
        VTSessionSetProperty(s, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)
        VTSessionSetProperty(s, key: kVTCompressionPropertyKey_MaxKeyFrameInterval, value: NSNumber(value: FPS))
        VTSessionSetProperty(s, key: kVTCompressionPropertyKey_AverageBitRate, value: NSNumber(value: BITRATE))
        VTSessionSetProperty(s, key: kVTCompressionPropertyKey_ExpectedFrameRate, value: NSNumber(value: FPS))
        VTCompressionSessionPrepareToEncodeFrames(s)
        session = s
    }

    func encode(_ pb: CVPixelBuffer, pts: CMTime) {
        if session == nil {
            makeSession(width: Int32(CVPixelBufferGetWidth(pb)), height: Int32(CVPixelBufferGetHeight(pb)))
            NSLog("encoding \(CVPixelBufferGetWidth(pb))x\(CVPixelBufferGetHeight(pb)) @\(FPS)fps \(BITRATE)bps")
        }
        guard let session else { return }
        VTCompressionSessionEncodeFrame(session, imageBuffer: pb, presentationTimeStamp: pts,
                                        duration: .invalid, frameProperties: nil,
                                        infoFlagsOut: nil) { [weak self] status, _, sbuf in
            guard status == noErr, let sbuf, let self else { return }
            self.emit(sbuf)
        }
    }

    private func emit(_ sbuf: CMSampleBuffer) {
        guard let fmt = CMSampleBufferGetFormatDescription(sbuf),
              let db = CMSampleBufferGetDataBuffer(sbuf) else { return }

        let attachments = CMSampleBufferGetSampleAttachmentsArray(sbuf, createIfNecessary: false) as? [[CFString: Any]]
        let isKey = !(attachments?.first?[kCMSampleAttachmentKey_NotSync] as? Bool ?? false)

        var out = Data()
        let startCode: [UInt8] = [0, 0, 0, 1]

        if isKey {
            var psCount = 0
            CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                fmt, parameterSetIndex: 0, parameterSetPointerOut: nil, parameterSetSizeOut: nil,
                parameterSetCountOut: &psCount, nalUnitHeaderLengthOut: nil)
            var header = Data()
            for i in 0..<psCount {
                var ptr: UnsafePointer<UInt8>?
                var size = 0
                CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                    fmt, parameterSetIndex: i, parameterSetPointerOut: &ptr, parameterSetSizeOut: &size,
                    parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil)
                if let ptr {
                    header.append(contentsOf: startCode)
                    header.append(ptr, count: size)
                }
            }
            server.header = header
            out.append(header)
        }

        // AVCC (4-byte length prefix) -> Annex-B
        var totalLen = 0
        var dataPtr: UnsafeMutablePointer<Int8>?
        CMBlockBufferGetDataPointer(db, atOffset: 0, lengthAtOffsetOut: nil,
                                    totalLengthOut: &totalLen, dataPointerOut: &dataPtr)
        guard let dataPtr else { return }
        var off = 0
        dataPtr.withMemoryRebound(to: UInt8.self, capacity: totalLen) { p in
            while off + 4 <= totalLen {
                let len = Int(p[off]) << 24 | Int(p[off+1]) << 16 | Int(p[off+2]) << 8 | Int(p[off+3])
                guard len > 0, off + 4 + len <= totalLen else { break }
                out.append(contentsOf: startCode)
                out.append(UnsafeBufferPointer(start: p + off + 4, count: len))
                off += 4 + len
            }
        }
        server.broadcast(out, droppable: !isKey)
    }
}

final class StreamOutput: NSObject, SCStreamOutput, SCStreamDelegate {
    let encoder: Encoder
    init(encoder: Encoder) { self.encoder = encoder }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sampleBuffer.isValid,
              let pb = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        encoder.encode(pb, pts: CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        NSLog("stream stopped: \(error.localizedDescription)")
        exit(1)
    }
}

// --- virtual display (display mode only) ---
var vdispRef: AnyObject?
func makeVirtualDisplay() -> CGDirectDisplayID? {
    let desc = CGVirtualDisplayDescriptor()
    desc.queue = DispatchQueue.main
    desc.name = "AEasy Display"
    desc.maxPixelsWide = pxW * 2
    desc.maxPixelsHigh = pxH * 2
    desc.sizeInMillimeters = CGSize(width: 152, height: 152.0 * Double(pxH) / Double(pxW))
    desc.serialNum = 1
    desc.productID = 0x5544
    desc.vendorID = 0x1209
    guard let vdisp = CGVirtualDisplay(descriptor: desc) else { return nil }
    let settings = CGVirtualDisplaySettings()
    settings.hiDPI = 1
    // native mode is the crisp default; smaller ones are selectable in System Settings > Displays for bigger text
    settings.modes = [
        CGVirtualDisplayMode(width: pxW, height: pxH, refreshRate: 60),
        CGVirtualDisplayMode(width: (pxW * 5 / 6) & ~3, height: (pxH * 5 / 6) & ~3, refreshRate: 60),
        CGVirtualDisplayMode(width: (pxW * 2 / 3) & ~3, height: (pxH * 2 / 3) & ~3, refreshRate: 60),
    ]
    guard vdisp.apply(settings) else { return nil }
    vdispRef = vdisp
    return vdisp.displayID
}

let server = try TCPServer()
server.startHealthCheck()
let encoder = Encoder(server: server)
let output = StreamOutput(encoder: encoder)
var streamRef: SCStream?

func fitEven(_ w: Double, _ h: Double, into maxW: Double, _ maxH: Double) -> (Int, Int) {
    let s = min(maxW / w, maxH / h)
    return (Int(w * s) & ~3, Int(h * s) & ~3)
}

Task {
    do {
        let cfg = SCStreamConfiguration()
        cfg.pixelFormat = kCVPixelFormatType_32BGRA
        cfg.minimumFrameInterval = CMTime(value: 1, timescale: FPS)
        cfg.queueDepth = 5
        cfg.showsCursor = true
        let filter: SCContentFilter

        var wantWindow: SCWindow?
        if MODE == "window", !WINDOW_APP.isEmpty {
            let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
            wantWindow = content.windows
                .filter { $0.owningApplication?.applicationName.localizedCaseInsensitiveContains(WINDOW_APP) == true }
                .max(by: { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height })
            if wantWindow == nil {
                let apps = Set(content.windows.compactMap { $0.owningApplication?.applicationName }).sorted()
                NSLog("window of '\(WINDOW_APP)' not found; running apps: \(apps.joined(separator: ", "))")
                NSLog("falling back to display mode")
            }
        }

        if let win = wantWindow {
            filter = SCContentFilter(desktopIndependentWindow: win)
            let (w, h) = fitEven(win.frame.width * 2, win.frame.height * 2,  // 2x for retina sharpness
                                 into: Double(pxW) * Double(SCALE) / 100.0,
                                 Double(pxH) * Double(SCALE) / 100.0)
            cfg.width = w
            cfg.height = h
            cfg.scalesToFit = true
            NSLog("mirroring window '\(win.title ?? "?")' of \(win.owningApplication?.applicationName ?? "?")")
        } else {
            guard let vdispID = makeVirtualDisplay() else { NSLog("virtual display creation failed"); exit(1) }
            NSLog("virtual display 'AEasy Display' id=\(vdispID) for phone \(pxW)x\(pxH)")
            var display: SCDisplay?
            for _ in 0..<10 {  // virtual display can take a moment to appear
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
                display = content.displays.first { $0.displayID == vdispID }
                if display != nil { break }
                try await Task.sleep(nanoseconds: 500_000_000)
            }
            guard let display else { NSLog("virtual display not found in capture list"); exit(1) }
            // WindowServer sometimes defaults to 800x600 — pin the mode that matches the panel
            if let all = CGDisplayCopyAllDisplayModes(vdispID,
                    [kCGDisplayShowDuplicateLowResolutionModes: kCFBooleanTrue] as CFDictionary) as? [CGDisplayMode],
               let m = all.filter({ $0.width == Int(pxW) && $0.height == Int(pxH) })
                          .max(by: { $0.pixelWidth < $1.pixelWidth }) {
                CGDisplaySetDisplayMode(vdispID, m, nil)
                NSLog("mode pinned \(m.width)x\(m.height) (backing \(m.pixelWidth)x\(m.pixelHeight))")
            }
            filter = SCContentFilter(display: display, excludingWindows: [])
            cfg.width = Int(pxW * UInt32(SCALE) / 100) & ~3
            cfg.height = Int(pxH * UInt32(SCALE) / 100) & ~3
            NSLog("capturing display id=\(display.displayID)")
        }

        let stream = SCStream(filter: filter, configuration: cfg, delegate: output)
        try stream.addStreamOutput(output, type: .screen, sampleHandlerQueue: DispatchQueue(label: "capture"))
        try await stream.startCapture()
        streamRef = stream
        NSLog("capture started")
    } catch {
        NSLog("failed: \(error.localizedDescription) — check Screen Recording permission in System Settings")
        exit(1)
    }
}

RunLoop.main.run()
