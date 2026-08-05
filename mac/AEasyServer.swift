// AEasyServer — streams up to three Mac sources (a virtual display and/or app windows)
// to the Android viewer, one raw H.264/HEVC Annex-B stream per TCP connection on :7355.
// The listener is loopback-only; every real client arrives through `adb reverse`.
//
// Each video connection opens with `AEZ1 <source-id>\n` and then carries 5-byte touch
// packets back up. `AEZ1 control\n` opens a JSON control channel (length-prefixed) that
// carries the pane layout both ways, so the phone and the settings GUI stay in sync live.
//
// Usage: aeasy-server [W] [H]   (phone panel pixels; W>H landscape, W<H portrait)
// Config: ~/.local/share/aeasy/config  (FPS, BITRATE, SCALE, SOURCES, CODEC)
// Layout: ~/.local/share/aeasy/layout.json

import Foundation
import AppKit
import ScreenCaptureKit
import VideoToolbox
import CoreMedia
import CoreVideo
import Network
import ApplicationServices

// AEASY_DIR / AEASY_PORT let `make check` run against a scratch config on a spare port
// instead of clobbering the live session's state
let PORT = UInt16(ProcessInfo.processInfo.environment["AEASY_PORT"] ?? "") ?? 7355
let MAX_SOURCES = 3
let MIN_PANE = 0.15          // smallest pane edge, as a fraction of the viewport
let MAX_CONTROL = 65536      // an attacker-controlled u32 must not drive an allocation

// connect to WindowServer up front — SCContentFilter(desktopIndependentWindow:) asserts
// (CGS_REQUIRE_INIT) in a headless process without it; display mode only survived because
// CGVirtualDisplay happened to open the connection first
_ = NSApplication.shared

// MARK: - config

let shareDir = NSString(string: ProcessInfo.processInfo.environment["AEASY_DIR"] ?? "~/.local/share/aeasy")
    .expandingTildeInPath

func loadConf() -> [String: String] {
    var c: [String: String] = [:]
    if let txt = try? String(contentsOfFile: shareDir + "/config", encoding: .utf8) {
        for line in txt.split(separator: "\n") {
            let kv = line.split(separator: "=", maxSplits: 1)
            if kv.count == 2 { c[String(kv[0])] = String(kv[1]).trimmingCharacters(in: .whitespaces) }
        }
    }
    return c
}

let _conf = loadConf()
let FPS = Int32(_conf["FPS"] ?? "") ?? 20
let BITRATE = Int(_conf["BITRATE"] ?? "") ?? 2_000_000
let SCALE = min(100, max(40, Int(_conf["SCALE"] ?? "") ?? 80))  // encode size, % of panel
let CODEC = _conf["CODEC"] ?? "h264"                            // h264 | hevc (phone sniffs the stream)

// re-read before merging: `aeasy sources` or the settings GUI may have edited the file
// since launch, and rebuilding it from a startup snapshot would silently revert them
func writeConf(_ updates: [String: String]) {
    var c = loadConf()
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

// SOURCES=display,window:Code — falls back to the legacy MODE/WINDOW_APP pair so an
// existing install keeps working. `display`, when present, is always primary.
func parseSources(_ c: [String: String]) -> [String] {
    var ids = (c["SOURCES"] ?? "").split(separator: ",")
        .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    if ids.isEmpty {
        let app = c["WINDOW_APP"] ?? ""
        ids = (c["MODE"] ?? "display") == "window" && !app.isEmpty ? ["window:\(app)"] : ["display"]
    }
    var seen = Set<String>()
    ids = ids.filter { seen.insert($0).inserted }
    if ids.count > MAX_SOURCES {
        NSLog("more than \(MAX_SOURCES) sources configured — ignoring \(ids.dropFirst(MAX_SOURCES).joined(separator: ", "))")
        ids = Array(ids.prefix(MAX_SOURCES))
    }
    if let i = ids.firstIndex(of: "display"), i != 0 { ids.remove(at: i); ids.insert("display", at: 0) }
    return ids
}

let SOURCE_IDS = parseSources(_conf)

// BITRATE alone is not a valid budget: the settings slider bottoms out at 0.5 Mbps,
// below the 3-source floor. 60% to the primary, the rest split evenly.
func bitrateBudget(_ n: Int) -> [Int] {
    let total = max(BITRATE, 300_000 * n)
    if n <= 1 { return [total] }
    let primary = total * 6 / 10
    return [primary] + Array(repeating: (total - primary) / (n - 1), count: n - 1)
}

var pxW: UInt32 = 1650, pxH: UInt32 = 720
if CommandLine.arguments.count >= 3,
   let a = UInt32(CommandLine.arguments[1]), let b = UInt32(CommandLine.arguments[2]) {
    pxW = a  // passed as-is: W>H = landscape, W<H = portrait
    pxH = b
}

func fitEven(_ w: Double, _ h: Double, into maxW: Double, _ maxH: Double) -> (Int, Int) {
    let s = min(maxW / w, maxH / h)
    return (Int(w * s) & ~3, Int(h * s) & ~3)
}

// secondary panes are small on screen; capping them keeps three concurrent decoders
// inside a mid-range phone's pixel-throughput budget, which bitrate alone does not bound
func encodeBox(_ index: Int) -> (Double, Double) {
    let full = (Double(pxW) * Double(SCALE) / 100.0, Double(pxH) * Double(SCALE) / 100.0)
    return index == 0 ? full : (min(full.0, 960), min(full.1, 540))
}

// MARK: - layout

struct Pane {
    var src: String
    var x = 0.0, y = 0.0, w = 1.0, h = 1.0
    var z = 0

    var dict: [String: Any] { ["src": src, "x": x, "y": y, "w": w, "h": h, "z": z] }

    init(src: String, x: Double, y: Double, w: Double, h: Double, z: Int) {
        self.src = src; self.x = x; self.y = y; self.w = w; self.h = h; self.z = z
    }

    init?(_ d: [String: Any]) {
        guard let s = d["src"] as? String else { return nil }
        func num(_ k: String, _ fallback: Double) -> Double { (d[k] as? NSNumber)?.doubleValue ?? fallback }
        src = s
        x = num("x", 0); y = num("y", 0); w = num("w", 1); h = num("h", 1)
        z = (d["z"] as? NSNumber)?.intValue ?? 0
    }
}

func defaultPane(_ src: String, _ index: Int) -> Pane {
    if index == 0 { return Pane(src: src, x: 0, y: 0, w: 1, h: 1, z: 0) }
    let k = Double(index - 1)                       // stack each extra pane 24px further in
    let ox = 24.0 / Double(pxW), oy = 24.0 / Double(pxH)
    return Pane(src: src, x: max(0, 0.58 - ox * k), y: max(0, 0.68 - oy * k), w: 0.4, h: 0.3, z: index)
}

// Canonical layout, owned by the server. Clients propose; the server serialises,
// bumps `rev` and broadcasts, so two simultaneous drags converge.
final class LayoutStore {
    private(set) var rev = 0
    private(set) var panes: [Pane] = []
    private let path = shareDir + "/layout.json"
    private var saveWork: DispatchWorkItem?

    func load(_ sources: [String]) {
        if let d = FileManager.default.contents(atPath: path),
           let o = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] {
            rev = (o["rev"] as? NSNumber)?.intValue ?? 0
            panes = ((o["panes"] as? [[String: Any]]) ?? []).compactMap(Pane.init)
        }
        let reconciled = reconcile(panes, sources)
        if reconciled.map(\.src) != panes.map(\.src) {
            panes = reconciled
            rev += 1
            persist(now: true)
        } else {
            panes = reconciled
        }
    }

    // drop panes for sources that are gone, add defaults for sources with none
    private func reconcile(_ input: [Pane], _ sources: [String]) -> [Pane] {
        var seen = Set<String>()
        var kept = input.filter { sources.contains($0.src) && seen.insert($0.src).inserted }
        for (i, s) in sources.enumerated() where !kept.contains(where: { $0.src == s }) {
            kept.append(defaultPane(s, i))
        }
        return kept.sorted { $0.z < $1.z }
    }

    /// nil = reject wholesale; the caller re-broadcasts the canonical layout so the proposer snaps back
    func validate(_ proposed: [Pane], _ sources: [String]) -> [Pane]? {
        var seen = Set<String>()
        for p in proposed {
            guard sources.contains(p.src), seen.insert(p.src).inserted else { return nil }
        }
        guard seen.count == sources.count else { return nil }   // every active source needs a pane
        return proposed.map { p in
            var q = p
            q.w = min(1, max(MIN_PANE, q.w))
            q.h = min(1, max(MIN_PANE, q.h))
            q.x = min(1 - q.w, max(0, q.x))
            q.y = min(1 - q.h, max(0, q.y))
            return q
        }.sorted { $0.z < $1.z }
    }

    func apply(_ newPanes: [Pane]) {
        panes = newPanes
        rev += 1
        persist(now: false)
    }

    func drop(_ src: String) {
        guard panes.contains(where: { $0.src == src }) else { return }
        panes.removeAll { $0.src == src }
        rev += 1
        persist(now: false)
    }

    var message: [String: Any] { ["t": "layout", "rev": rev, "panes": panes.map(\.dict)] }

    // a drag proposes at up to 20Hz; writing layout.json on each one would put an fsync
    // on the same serial queue that carries three video streams
    private func persist(now: Bool) {
        saveWork?.cancel()
        let snapshot: [String: Any] = ["rev": rev, "panes": panes.map(\.dict)]
        let write = {
            guard let d = try? JSONSerialization.data(withJSONObject: snapshot, options: [.prettyPrinted]) else { return }
            try? FileManager.default.createDirectory(atPath: shareDir, withIntermediateDirectories: true)
            try? d.write(to: URL(fileURLWithPath: self.path), options: .atomic)
        }
        if now { write(); return }
        let w = DispatchWorkItem(block: write)
        saveWork = w
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.5, execute: w)
    }
}

let layout = LayoutStore()

// MARK: - encoder

final class Encoder {
    private var session: VTCompressionSession?
    private(set) var usingHEVC = false
    private var frames: Int64 = 0
    private var bitrate: Int
    private var fps: Int32

    var onEncoded: ((Data, Bool) -> Void)?
    var onHeader: ((Data) -> Void)?

    init(bitrate: Int, fps: Int32) {
        self.bitrate = bitrate
        self.fps = fps
    }

    private func makeSession(width: Int32, height: Int32) {
        var s: VTCompressionSession?
        if CODEC == "hevc" {
            VTCompressionSessionCreate(
                allocator: nil, width: width, height: height,
                codecType: kCMVideoCodecType_HEVC,
                encoderSpecification: nil, imageBufferAttributes: nil,
                compressedDataAllocator: nil, outputCallback: nil, refcon: nil,
                compressionSessionOut: &s)
            if s != nil { usingHEVC = true } else { NSLog("HEVC encoder unavailable — falling back to H.264") }
        }
        if s == nil {
            VTCompressionSessionCreate(
                allocator: nil, width: width, height: height,
                codecType: kCMVideoCodecType_H264,
                encoderSpecification: nil, imageBufferAttributes: nil,
                compressedDataAllocator: nil, outputCallback: nil, refcon: nil,
                compressionSessionOut: &s)
        }
        guard let s else { fatalError("VTCompressionSessionCreate failed") }
        VTSessionSetProperty(s, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        VTSessionSetProperty(s, key: kVTCompressionPropertyKey_ProfileLevel,
                             value: usingHEVC ? kVTProfileLevel_HEVC_Main_AutoLevel : kVTProfileLevel_H264_Main_AutoLevel)
        VTSessionSetProperty(s, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)
        VTSessionSetProperty(s, key: kVTCompressionPropertyKey_MaxKeyFrameInterval, value: NSNumber(value: fps))
        VTSessionSetProperty(s, key: kVTCompressionPropertyKey_AverageBitRate, value: NSNumber(value: bitrate))
        VTSessionSetProperty(s, key: kVTCompressionPropertyKey_ExpectedFrameRate, value: NSNumber(value: fps))
        VTCompressionSessionPrepareToEncodeFrames(s)
        session = s
    }

    /// AverageBitRate is the only knob that actually throttles a live session;
    /// ExpectedFrameRate is read before compression begins and is a hint afterwards.
    func setBitrate(_ b: Int) {
        bitrate = b
        guard let session else { return }
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AverageBitRate, value: NSNumber(value: b))
    }

    func encode(_ pb: CVPixelBuffer, force: Bool) {
        if session == nil {
            makeSession(width: Int32(CVPixelBufferGetWidth(pb)), height: Int32(CVPixelBufferGetHeight(pb)))
            NSLog("encoding \(CVPixelBufferGetWidth(pb))x\(CVPixelBufferGetHeight(pb)) @\(fps)fps \(bitrate)bps")
        }
        guard let session else { return }
        // synthesize the timeline instead of forwarding capture timestamps: forced keyframes
        // re-encode an older buffer, and VideoToolbox requires the PTS to keep increasing
        frames += 1
        let pts = CMTime(value: frames * Int64(600 / max(1, fps)), timescale: 600)
        let props = force ? [kVTEncodeFrameOptionKey_ForceKeyFrame: kCFBooleanTrue] as CFDictionary : nil
        VTCompressionSessionEncodeFrame(session, imageBuffer: pb, presentationTimeStamp: pts,
                                        duration: .invalid, frameProperties: props,
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
            // identical signatures; HEVC yields 3 sets (VPS/SPS/PPS), H.264 yields 2 (SPS/PPS)
            let getPS = usingHEVC ? CMVideoFormatDescriptionGetHEVCParameterSetAtIndex
                                  : CMVideoFormatDescriptionGetH264ParameterSetAtIndex
            var psCount = 0
            _ = getPS(fmt, 0, nil, nil, &psCount, nil)
            var header = Data()
            for i in 0..<psCount {
                var ptr: UnsafePointer<UInt8>?
                var size = 0
                _ = getPS(fmt, i, &ptr, &size, nil, nil)
                if let ptr {
                    header.append(contentsOf: startCode)
                    header.append(ptr, count: size)
                }
            }
            onHeader?(header)
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
        onEncoded?(out, isKey)
    }

    func retune(fps: Int32) { self.fps = fps }
}

// MARK: - source

final class Source {
    let id: String
    let index: Int
    let cfg = SCStreamConfiguration()
    let sampleQueue: DispatchQueue
    let encoder: Encoder
    let budget: Int

    var stream: SCStream?
    var output: StreamOutput?
    var encW = 0, encH = 0
    var fps: Int32
    var bitrate: Int
    var step = 0            // 0 = configured quality, 2 = floor
    var alive = true

    var displayID: CGDirectDisplayID = 0
    var windowID: CGWindowID = 0
    var windowPID: pid_t = 0

    var isDisplay: Bool { id == "display" }
    var isPrimary: Bool { index == 0 }
    var atFloor: Bool { step >= 2 }

    /// last encoded frame, re-encoded as a keyframe when a client subscribes.
    /// ScreenCaptureKit is change-driven: an idle window emits one frame and then
    /// nothing, so without this a pane on a static window would stay black forever.
    var lastPB: CVPixelBuffer?

    init(id: String, index: Int, budget: Int) {
        self.id = id
        self.index = index
        self.budget = budget
        self.bitrate = budget
        self.fps = FPS
        self.sampleQueue = DispatchQueue(label: "capture.\(index)")
        self.encoder = Encoder(bitrate: budget, fps: FPS)
    }

    var descriptor: [String: Any] {
        ["id": id, "w": encW, "h": encH, "fps": Int(fps), "bitrate": bitrate]
    }

    func forceKeyframe() {
        sampleQueue.async { [weak self] in
            guard let self, let pb = self.lastPB else { return }
            self.encoder.encode(pb, force: true)
        }
    }

    /// live quality step-down — no process restart, no encoder teardown
    func stepDown() {
        guard step < 2, alive else { return }
        step += 1
        fps = step == 1 ? max(12, FPS - 5) : 12
        bitrate = step == 1 ? max(300_000, budget * 6 / 10) : max(300_000, budget * 4 / 10)
        NSLog("LAGGY: \(id) stepping down to \(fps)fps \(bitrate)bps")
        let b = bitrate, f = fps
        sampleQueue.async { [weak self] in            // the encoder session belongs to this queue
            guard let self else { return }
            self.encoder.setBitrate(b)
            self.encoder.retune(fps: f)
            // updateConfiguration replaces the whole configuration, so mutate the retained
            // object — a fresh one would reset pixelFormat/queueDepth/width/height
            self.cfg.minimumFrameInterval = CMTime(value: 1, timescale: f)
            self.stream?.updateConfiguration(self.cfg) { err in
                if let err { NSLog("updateConfiguration failed for \(self.id): \(err.localizedDescription)") }
            }
        }
    }

    func teardown() {
        guard alive else { return }
        alive = false
        stream?.stopCapture { _ in }
        stream = nil
        sampleQueue.async { [weak self] in self?.lastPB = nil }
    }
}

var sources: [Source] = []

final class StreamOutput: NSObject, SCStreamOutput, SCStreamDelegate {
    let source: Source
    init(source: Source) { self.source = source }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sampleBuffer.isValid,
              let pb = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        source.lastPB = pb            // sampleQueue-confined, same queue this callback runs on
        source.encoder.encode(pb, force: false)
    }

    // one source dying must not take the other panes with it
    func stream(_ stream: SCStream, didStopWithError error: Error) {
        NSLog("source \(source.id) stopped: \(error.localizedDescription)")
        server?.dropSource(source.index)
    }
}

// MARK: - touch

let axGetWindow: (@convention(c) (AXUIElement, UnsafeMutablePointer<CGWindowID>) -> AXError)? = {
    guard let h = dlopen("/System/Library/Frameworks/ApplicationServices.framework/ApplicationServices", RTLD_LAZY),
          let sym = dlsym(h, "_AXUIElementGetWindow") else {
        NSLog("_AXUIElementGetWindow unavailable — window raising will fall back to frame matching")
        return nil
    }
    return unsafeBitCast(sym, to: (@convention(c) (AXUIElement, UnsafeMutablePointer<CGWindowID>) -> AXError).self)
}()

func currentWindowFrame(_ wid: CGWindowID) -> CGRect? {
    guard let list = CGWindowListCopyWindowInfo([.optionIncludingWindow], wid) as? [[String: Any]],
          let bounds = list.first?[kCGWindowBounds as String] as? [String: Any],
          let r = CGRect(dictionaryRepresentation: bounds as CFDictionary) else { return nil }
    return r
}

/// NSRunningApplication.activate is denied to an unbundled process on macOS 14+ (it returns
/// true and nothing moves), so raise through Accessibility instead. A .cghidEventTap click
/// then lands by z-order at the point, which is exactly what the raise just arranged.
func raiseWindow(pid: pid_t, wid: CGWindowID, frame: CGRect) {
    let app = AXUIElementCreateApplication(pid)
    AXUIElementSetMessagingTimeout(app, 0.5)   // never block on an unresponsive app
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value) == .success,
          let windows = value as? [AXUIElement] else { return }
    for w in windows {
        var id: CGWindowID = 0
        if let get = axGetWindow, get(w, &id) == .success {
            if id == wid { AXUIElementPerformAction(w, kAXRaiseAction as CFString); return }
            continue
        }
        // fallback without the private symbol: match on geometry. Ambiguous for
        // identically-placed windows, which is why the dlsym path is preferred.
        var pv: CFTypeRef?, sv: CFTypeRef?
        var origin = CGPoint.zero, size = CGSize.zero
        guard AXUIElementCopyAttributeValue(w, kAXPositionAttribute as CFString, &pv) == .success,
              AXUIElementCopyAttributeValue(w, kAXSizeAttribute as CFString, &sv) == .success,
              let pav = pv, CFGetTypeID(pav) == AXValueGetTypeID(),
              let sav = sv, CFGetTypeID(sav) == AXValueGetTypeID(),
              AXValueGetValue(pav as! AXValue, .cgPoint, &origin),
              AXValueGetValue(sav as! AXValue, .cgSize, &size) else { continue }
        if abs(origin.x - frame.origin.x) < 2, abs(size.width - frame.width) < 2 {
            AXUIElementPerformAction(w, kAXRaiseAction as CFString)
            return
        }
    }
}

/// Runs off the net queue: Accessibility calls block on the target app's run loop, and
/// one unresponsive app would otherwise freeze every video stream behind it.
func handleTouch(_ d: Data, _ src: Source) {
    let type = Int(d[d.startIndex])
    guard type < 3 else { return }   // type 3+ is reserved (see specs/2026-08-05-ios-client.md)
    let nx = Double(UInt16(d[d.startIndex + 1]) << 8 | UInt16(d[d.startIndex + 2])) / 65535.0
    let ny = Double(UInt16(d[d.startIndex + 3]) << 8 | UInt16(d[d.startIndex + 4])) / 65535.0
    let mouseType: [CGEventType] = [.leftMouseDown, .leftMouseDragged, .leftMouseUp]

    let pt: CGPoint
    if src.isDisplay {
        guard src.displayID != 0 else { return }
        let b = CGDisplayBounds(src.displayID)  // per event: tracks display rearrangement
        pt = CGPoint(x: b.origin.x + nx * b.width, y: b.origin.y + ny * b.height)
    } else {
        guard let f = currentWindowFrame(src.windowID), f.width > 0, f.height > 0 else { return }
        // the encode size is frozen at subscribe, so a window resized afterwards is
        // letterboxed inside it — undo that fit before mapping onto the real window
        let s = min(Double(src.encW) / f.width, Double(src.encH) / f.height)
        let ox = (Double(src.encW) - f.width * s) / 2, oy = (Double(src.encH) - f.height * s) / 2
        let wx = min(f.width, max(0, (nx * Double(src.encW) - ox) / s))
        let wy = min(f.height, max(0, (ny * Double(src.encH) - oy) / s))
        pt = CGPoint(x: f.origin.x + wx, y: f.origin.y + wy)
        if type == 0 { raiseWindow(pid: src.windowPID, wid: src.windowID, frame: f) }
    }
    CGEvent(mouseEventSource: nil, mouseType: mouseType[type],
            mouseCursorPosition: pt, mouseButton: .left)?.post(tap: .cghidEventTap)
}

// MARK: - server

enum ConnState {
    case handshaking
    case video(Int)
    case control
    case dead
}

final class Conn {
    let c: NWConnection
    var state: ConnState = .handshaking
    var buf = Data()
    var pending = 0
    init(_ c: NWConnection) { self.c = c }
}

final class TCPServer {
    private var conns: [ObjectIdentifier: Conn] = [:]
    let queue = DispatchQueue(label: "net")
    private let touchQueue = DispatchQueue(label: "touch")
    private var headers: [Int: Data] = [:]        // per-source Annex-B parameter sets, for late joiners
    private var sent: [Int: Int] = [:], dropped: [Int: Int] = [:]
    private var lastAlert = Date.distantPast
    private var healthTimer: DispatchSourceTimer?
    private var lastBroadcast = Date.distantPast
    private var pendingBroadcast: DispatchWorkItem?

    init() throws {
        // loopback only: every client arrives through `adb reverse`, and this socket can
        // synthesize clicks and raise windows — it has no business being on the LAN
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = NWEndpoint.hostPort(host: .ipv4(.loopback),
                                                           port: NWEndpoint.Port(rawValue: PORT)!)
        let l = try NWListener(using: params)
        l.newConnectionHandler = { [weak self] c in
            guard let self else { return }
            let conn = Conn(c)
            let key = ObjectIdentifier(c)
            // conns is the strong owner from here on; the handler must not capture `c`
            // itself or the connection would retain its own handler and never be freed
            self.conns[key] = conn
            c.stateUpdateHandler = { [weak self, weak conn] st in
                guard let self, let conn else { return }
                switch st {
                case .ready:
                    self.armHandshakeTimeout(conn)
                    self.recv(conn)
                case .failed, .cancelled:
                    self.conns[key] = nil
                    conn.state = .dead
                default: break
                }
            }
            c.start(queue: self.queue)
        }
        l.start(queue: queue)
        NSLog("listening on 127.0.0.1:\(PORT) — sources: \(sources.map(\.id).joined(separator: ", "))")
    }

    // MARK: reading

    // One loop, one state machine. An outstanding NWConnection.receive cannot be cancelled,
    // so the handshake deadline only mutates state that this handler reads.
    private func recv(_ conn: Conn) {
        conn.c.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self, weak conn] data, _, complete, err in
            guard let self, let conn else { return }
            if let d = data, !d.isEmpty { self.ingest(conn, d) }
            if complete || err != nil {
                self.conns[ObjectIdentifier(conn.c)] = nil
                conn.state = .dead
                conn.c.cancel()
                return
            }
            if case .dead = conn.state { return }
            self.recv(conn)
        }
    }

    private func armHandshakeTimeout(_ conn: Conn) {
        queue.asyncAfter(deadline: .now() + .milliseconds(300)) { [weak self, weak conn] in
            guard let self, let conn, case .handshaking = conn.state else { return }
            if conn.buf.isEmpty {
                self.subscribe(conn, 0)   // legacy viewer: never speaks first, gets the primary source
            } else {
                self.reject(conn, "handshake timeout")
            }
        }
    }

    private func ingest(_ conn: Conn, _ d: Data) {
        switch conn.state {
        case .handshaking:
            // 'A' is the only byte a handshake can start with, so anything else is a
            // legacy client whose first bytes are already a touch packet
            if conn.buf.isEmpty, let first = d.first, first != 0x41 {
                subscribe(conn, 0)
                conn.buf = d
                drainTouch(conn, 0)
                return
            }
            conn.buf.append(d)
            if let nl = conn.buf.firstIndex(of: 0x0A) {
                let line = String(decoding: conn.buf[conn.buf.startIndex..<nl], as: UTF8.self)
                conn.buf = Data(conn.buf[conn.buf.index(after: nl)...])   // keep whatever followed the newline
                handshake(conn, line.trimmingCharacters(in: .whitespaces))
            } else if conn.buf.count > 64 {
                reject(conn, "handshake too long")
            }
        case .video(let i):
            conn.buf.append(d)
            drainTouch(conn, i)
        case .control:
            conn.buf.append(d)
            drainControl(conn)
        case .dead:
            break
        }
    }

    private func handshake(_ conn: Conn, _ line: String) {
        let parts = line.split(separator: " ", maxSplits: 1)
        guard parts.count == 2, parts[0] == "AEZ1" else { reject(conn, "bad handshake"); return }
        let spec = String(parts[1]).trimmingCharacters(in: .whitespaces)
        if spec == "control" {
            conn.state = .control
            NSLog("control client connected")
            sendControlHello(conn)
            drainControl(conn)
            return
        }
        guard let i = sources.firstIndex(where: { $0.id == spec && $0.alive }) else {
            reject(conn, "unknown source")
            return
        }
        subscribe(conn, i)
        drainTouch(conn, i)
    }

    private func subscribe(_ conn: Conn, _ index: Int) {
        guard index < sources.count, sources[index].alive else { reject(conn, "unknown source"); return }
        conn.state = .video(index)
        NSLog("client subscribed to \(sources[index].id)")
        if let h = headers[index], !h.isEmpty {
            conn.c.send(content: h, completion: .contentProcessed { _ in })
        }
        sources[index].forceKeyframe()
    }

    private func reject(_ conn: Conn, _ reason: String) {
        conn.state = .dead
        let msg = Data("AEZ1 ERR \(reason)\n".utf8)
        // cancel from the completion handler, or the reply races the FIN and is lost
        conn.c.send(content: msg, completion: .contentProcessed { [weak self, weak conn] _ in
            guard let conn else { return }
            self?.conns[ObjectIdentifier(conn.c)] = nil
            conn.c.cancel()
        })
    }

    private func drainTouch(_ conn: Conn, _ index: Int) {
        guard index < sources.count else { return }
        let src = sources[index]
        while conn.buf.count >= 5 {
            let pkt = Data(conn.buf.prefix(5))
            conn.buf = Data(conn.buf.dropFirst(5))
            touchQueue.async { handleTouch(pkt, src) }
        }
    }

    // MARK: control channel

    private func drainControl(_ conn: Conn) {
        while conn.buf.count >= 4 {
            let len = conn.buf.withUnsafeBytes { raw -> Int in
                let b = raw.bindMemory(to: UInt8.self)
                return Int(b[0]) << 24 | Int(b[1]) << 16 | Int(b[2]) << 8 | Int(b[3])
            }
            if len <= 0 || len > MAX_CONTROL { reject(conn, "control frame too large"); return }
            guard conn.buf.count >= 4 + len else { return }
            let payload = Data(conn.buf[conn.buf.index(conn.buf.startIndex, offsetBy: 4)..<conn.buf.index(conn.buf.startIndex, offsetBy: 4 + len)])
            conn.buf = Data(conn.buf.dropFirst(4 + len))
            handleControl(conn, payload)
        }
    }

    private func handleControl(_ conn: Conn, _ payload: Data) {
        guard let obj = (try? JSONSerialization.jsonObject(with: payload)) as? [String: Any],
              let t = obj["t"] as? String else { return }
        switch t {
        case "layout":
            let proposed = ((obj["panes"] as? [[String: Any]]) ?? []).compactMap(Pane.init)
            let ids = sources.filter(\.alive).map(\.id)
            guard let valid = layout.validate(proposed, ids) else {
                broadcastLayout(ack: nil)   // rejected: snap the proposer back
                return
            }
            layout.apply(valid)
            broadcastLayout(ack: obj["tok"] as? String)
        default:
            break
        }
    }

    private func sendControlHello(_ conn: Conn) {
        send(conn, ["t": "viewport", "w": Int(pxW), "h": Int(pxH)])
        send(conn, sourcesMessage)
        send(conn, layout.message)
        if !AXIsProcessTrusted() {
            send(conn, ["t": "error", "code": "no_accessibility",
                        "msg": "Accessibility is not granted on the Mac — taps will not register"])
        }
    }

    private var sourcesMessage: [String: Any] {
        ["t": "sources", "sources": sources.filter(\.alive).map(\.descriptor)]
    }

    private func send(_ conn: Conn, _ obj: [String: Any]) {
        guard case .control = conn.state, let body = try? JSONSerialization.data(withJSONObject: obj) else { return }
        var frame = Data([UInt8((body.count >> 24) & 0xff), UInt8((body.count >> 16) & 0xff),
                          UInt8((body.count >> 8) & 0xff), UInt8(body.count & 0xff)])
        frame.append(body)
        conn.c.send(content: frame, completion: .contentProcessed { _ in })
    }

    private func broadcastControl(_ obj: [String: Any]) {
        for (_, conn) in conns { if case .control = conn.state { send(conn, obj) } }
    }

    /// coalesced to 10Hz: a drag proposes far faster than that, and every broadcast
    /// competes with three video streams on this queue
    func broadcastLayout(ack: String?) {
        pendingBroadcast?.cancel()
        let emit = { [weak self] in
            guard let self else { return }
            self.lastBroadcast = Date()
            var m = layout.message
            if let ack { m["ack"] = ack }
            self.broadcastControl(m)
        }
        let since = Date().timeIntervalSince(lastBroadcast)
        if since >= 0.1 { emit(); return }
        let w = DispatchWorkItem(block: emit)
        pendingBroadcast = w
        queue.asyncAfter(deadline: .now() + (0.1 - since), execute: w)
    }

    func broadcastSources() { broadcastControl(sourcesMessage) }

    func dropSource(_ index: Int) {
        queue.async {
            guard index < sources.count, sources[index].alive else { return }
            let src = sources[index]
            src.teardown()
            NSLog("source \(src.id) removed")
            for (k, conn) in self.conns {
                if case .video(let i) = conn.state, i == index {
                    conn.state = .dead
                    self.conns[k] = nil
                    conn.c.cancel()
                }
            }
            self.broadcastControl(["t": "error", "code": "source_lost", "msg": "\(src.id) is gone"])
            self.broadcastSources()
            layout.drop(src.id)
            self.broadcastLayout(ack: nil)
            if sources.allSatisfy({ !$0.alive }) {
                NSLog("no sources left — exiting")
                exit(1)
            }
        }
    }

    // MARK: video out

    func setHeader(_ h: Data, _ index: Int) {
        queue.async { self.headers[index] = h }
    }

    // droppable frames are skipped for clients that fall behind — bounded latency
    // ponytail: dropped P-frames glitch until the next keyframe (≤1s); fine for a monitor
    func broadcast(_ d: Data, from index: Int, droppable: Bool) {
        queue.async {
            for (k, conn) in self.conns {
                guard case .video(let i) = conn.state, i == index else { continue }
                if droppable && conn.pending > 2 { self.dropped[index, default: 0] += 1; continue }
                self.sent[index, default: 0] += 1
                conn.pending += 1
                conn.c.send(content: d, completion: .contentProcessed { _ in
                    self.queue.async { if self.conns[k] != nil { conn.pending = max(0, conn.pending - 1) } }
                })
            }
        }
    }

    // MARK: health

    func startHealthCheck() {
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 15, repeating: 15)
        t.setEventHandler { [weak self] in
            guard let self else { return }
            var laggy: [Int] = []
            for src in sources where src.alive {
                let total = (self.sent[src.index] ?? 0) + (self.dropped[src.index] ?? 0)
                let drops = self.dropped[src.index] ?? 0
                self.sent[src.index] = 0
                self.dropped[src.index] = 0
                guard total > 100, Double(drops) / Double(total) > 0.25 else { continue }
                laggy.append(src.index)
            }
            guard !laggy.isEmpty else { return }
            var stepped = false
            for i in laggy where i != 0 && !sources[i].atFloor {
                sources[i].stepDown()
                stepped = true
            }
            // the primary is protected until every secondary has bottomed out
            if laggy.contains(0), sources.dropFirst().allSatisfy({ !$0.alive || $0.atFloor }) {
                sources[0].stepDown()
                stepped = true
            }
            if stepped { self.broadcastSources() }
            if !stepped, Date().timeIntervalSince(self.lastAlert) > 60 {
                self.lastAlert = Date()
                notify("Phone decoder cannot keep up — run aeasy tune for the recommended settings")
            }
        }
        t.resume()
        healthTimer = t
    }
}

var server: TCPServer?

// MARK: - virtual display

var vdispRef: AnyObject?
func makeVirtualDisplay() -> CGDirectDisplayID? {
    let desc = CGVirtualDisplayDescriptor()
    desc.queue = DispatchQueue.main
    desc.name = "AEasy Display"
    desc.maxPixelsWide = pxW * 2
    desc.maxPixelsHigh = pxH * 2
    desc.sizeInMillimeters = CGSize(width: 152, height: 152.0 * Double(pxH) / Double(pxW))
    // macOS remembers a display's resolution and arrangement by vendor/product/serial, so the
    // real instance must keep serial 1 or the phone-display would jump home on every restart.
    // A test instance runs on a spare port and needs its own serial to coexist with a live one.
    desc.serialNum = PORT == 7355 ? 1 : UInt32(PORT)
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

// MARK: - startup

func makeStream(for src: Source, filter: SCContentFilter, width: Int, height: Int, scalesToFit: Bool) throws -> SCStream {
    src.cfg.pixelFormat = kCVPixelFormatType_32BGRA
    src.cfg.minimumFrameInterval = CMTime(value: 1, timescale: src.fps)
    src.cfg.queueDepth = 5
    src.cfg.showsCursor = true
    src.cfg.width = width
    src.cfg.height = height
    src.cfg.scalesToFit = scalesToFit
    src.encW = width
    src.encH = height

    let output = StreamOutput(source: src)
    src.output = output
    src.encoder.onHeader = { [weak src] h in
        guard let src else { return }
        server?.setHeader(h, src.index)
    }
    src.encoder.onEncoded = { [weak src] data, isKey in
        guard let src else { return }
        server?.broadcast(data, from: src.index, droppable: !isKey)
    }

    let stream = SCStream(filter: filter, configuration: src.cfg, delegate: output)
    // one handler queue per source, or three encoders serialise behind each other
    try stream.addStreamOutput(output, type: .screen, sampleHandlerQueue: src.sampleQueue)
    src.stream = stream
    return stream
}

Task {
    do {
        // the virtual display has to exist before SCShareableContent can see it
        var vdispID: CGDirectDisplayID = 0
        if SOURCE_IDS.contains("display") {
            guard let newID = makeVirtualDisplay() else { NSLog("virtual display creation failed"); exit(1) }
            vdispID = newID
            NSLog("virtual display 'AEasy Display' id=\(vdispID) for phone \(pxW)x\(pxH)")
        }

        if !AXIsProcessTrusted() {
            NSLog("touch input needs Accessibility: System Settings > Privacy & Security > Accessibility > add aeasy-server (re-grant after every rebuild)")
            AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary)
        }

        var displays: SCShareableContent?
        for _ in 0..<10 {  // virtual display can take a moment to appear
            let c = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
            if vdispID == 0 || c.displays.contains(where: { $0.displayID == vdispID }) { displays = c; break }
            try await Task.sleep(nanoseconds: 500_000_000)
        }
        guard let displays else { NSLog("virtual display not found in capture list"); exit(1) }
        let windows = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)

        // resolve first, build second: a source that cannot be found is dropped, and
        // indices have to stay contiguous or the budget split and the primary would shift
        var resolved: [(id: String, display: SCDisplay?, window: SCWindow?)] = []
        for id in SOURCE_IDS {
            if id == "display" {
                guard let d = displays.displays.first(where: { $0.displayID == vdispID }) else {
                    NSLog("virtual display missing from the capture list — skipping"); continue
                }
                resolved.append((id, d, nil))
            } else if id.hasPrefix("window:") {
                let app = String(id.dropFirst("window:".count))
                guard let win = windows.windows
                        .filter({ $0.owningApplication?.applicationName.localizedCaseInsensitiveContains(app) == true })
                        .max(by: { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }) else {
                    let names = Set(windows.windows.compactMap { $0.owningApplication?.applicationName }).sorted()
                    NSLog("window of '\(app)' not found — skipping. running apps: \(names.joined(separator: ", "))")
                    continue
                }
                resolved.append((id, nil, win))
            } else {
                NSLog("unknown source '\(id)' — skipping")
            }
        }
        guard !resolved.isEmpty else { NSLog("no usable sources — check SOURCES in the config"); exit(1) }

        let budgets = bitrateBudget(resolved.count)
        var built: [Source] = []
        for (i, entry) in resolved.enumerated() {
            let src = Source(id: entry.id, index: i, budget: budgets[i])
            let box = encodeBox(i)
            if let display = entry.display {
                src.displayID = vdispID
                // WindowServer sometimes defaults to 800x600 — pin the mode that matches the panel
                if let all = CGDisplayCopyAllDisplayModes(vdispID,
                        [kCGDisplayShowDuplicateLowResolutionModes: kCFBooleanTrue] as CFDictionary) as? [CGDisplayMode],
                   let m = all.filter({ $0.width == Int(pxW) && $0.height == Int(pxH) })
                              .max(by: { $0.pixelWidth < $1.pixelWidth }) {
                    CGDisplaySetDisplayMode(vdispID, m, nil)
                    NSLog("mode pinned \(m.width)x\(m.height) (backing \(m.pixelWidth)x\(m.pixelHeight))")
                }
                let (w, h) = fitEven(Double(pxW), Double(pxH), into: box.0, box.1)
                _ = try makeStream(for: src, filter: SCContentFilter(display: display, excludingWindows: []),
                                   width: w, height: h, scalesToFit: false)
            } else if let win = entry.window {
                src.windowID = win.windowID
                src.windowPID = win.owningApplication?.processID ?? 0
                let (w, h) = fitEven(win.frame.width * 2, win.frame.height * 2, into: box.0, box.1)  // 2x for retina sharpness
                _ = try makeStream(for: src, filter: SCContentFilter(desktopIndependentWindow: win),
                                   width: w, height: h, scalesToFit: true)
                NSLog("capturing window '\(win.title ?? "?")' of \(win.owningApplication?.applicationName ?? "?")")
            }
            built.append(src)
        }
        sources = built
        layout.load(sources.map(\.id))

        let s = try TCPServer()
        server = s
        s.startHealthCheck()

        for src in sources {
            try await src.stream?.startCapture()
        }
        NSLog("capture started for \(sources.count) source(s)")
    } catch {
        NSLog("failed: \(error.localizedDescription) — check Screen Recording permission in System Settings")
        exit(1)
    }
}

RunLoop.main.run()
