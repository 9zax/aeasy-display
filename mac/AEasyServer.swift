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
import AVFoundation
import ScreenCaptureKit
import VideoToolbox
import CoreMedia
import CoreImage
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
// iOS display-size multiplier. Applied HERE, not in the app — the app can't read this
// config, so it always reports pure half-native pixels and the Mac calibrates.
let IOS_SCALE = min(2.0, max(0.5, Double(_conf["IOS_SCALE"] ?? "") ?? 1.0))

// re-read before merging: `aeasy sources` or the settings GUI may have edited the file
// since launch, and rebuilding it from a startup snapshot would silently revert them
func writeConf(_ updates: [String: String]) {
    var c = loadConf()
    for (k, v) in updates { c[k] = v }
    let txt = c.map { "\($0.key)=\($0.value)" }.sorted().joined(separator: "\n")
    try? FileManager.default.createDirectory(atPath: shareDir, withIntermediateDirectories: true)
    try? txt.write(toFile: shareDir + "/config", atomically: true, encoding: .utf8)
}

// titled with this server's device label: with three servers running, two identically
// worded notifications give the user no way to tell which device is complaining
func notify(_ msg: String) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
    p.arguments = ["-e", "display notification \"\(msg)\" with title \"\(DEVICE_LABEL)\" sound name \"Funk\""]
    try? p.run()
}

// MARK: - input arbitration
// There is one system cursor, and every server posts into it. Exactly one device may
// drive it. Re-read on the touch path rather than pushed over the control channel: the
// tray, the settings window and the CLI all just edit a config file, so one mtime check
// covers all three with no new protocol. Touched only from touchQueue, which is serial.
private var _inputAllowed = true
private var _inputCheckedAt: TimeInterval = 0
private var _inputMTime: TimeInterval = -1
func inputAllowed() -> Bool {
    let now = Date().timeIntervalSince1970
    if now - _inputCheckedAt < 1 { return _inputAllowed }
    _inputCheckedAt = now
    let m = ((try? FileManager.default.attributesOfItem(atPath: shareDir + "/config")[.modificationDate])
        as? Date)?.timeIntervalSince1970 ?? 0
    if m == _inputMTime { return _inputAllowed }
    _inputMTime = m
    // absent means yes: a single-device install and the smoke harness never write the key
    _inputAllowed = (loadConf()["INPUT"] ?? "1") == "1"
    return _inputAllowed
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
// appended AFTER W H — `aeasy-server --ios 372 664` would silently fall back to the
// 1650x720 defaults above, which looks like a sizing bug rather than an argv bug
let IOS_MODE = CommandLine.arguments.contains("--ios")

// --slot <n> is how bin/aeasy addresses one of up to three concurrent servers: it is the
// pkill/pgrep handle, and it names the virtual display, which is otherwise identical
// across instances and unpickable in System Settings > Displays.
let SLOT: Int = {
    let a = CommandLine.arguments
    guard let i = a.firstIndex(of: "--slot"), i + 1 < a.count, let n = Int(a[i + 1]) else { return 0 }
    return n
}()
let DEVICE_LABEL = SLOT == 0 ? "AEasy Display" : "AEasy Display \(SLOT + 1)"

// PANEL=<W> <H> pins this device's display size. Without it the size still comes from
// argv — `wm size` on Android, the type-3 report on iOS — so every existing install is
// unaffected. Locked also means type-3 must not restart the process (see handleResize).
let PANEL_LOCK: (UInt32, UInt32)? = {
    let p = (_conf["PANEL"] ?? "").split(separator: " ").compactMap { UInt32($0) }
    guard p.count == 2, p[0] > 0, p[1] > 0 else { return nil }
    return (p[0], p[1])
}()
if let lock = PANEL_LOCK { pxW = lock.0; pxH = lock.1 }

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
    var camSession: AVCaptureSession?
    var camOutput: CameraOutput?

    var isDisplay: Bool { id == "display" }
    var isPrimary: Bool { index == 0 }
    var atFloor: Bool { step >= 2 }

    /// last encoded frame, re-encoded as a keyframe when a client subscribes.
    /// ScreenCaptureKit is change-driven: an idle window emits one frame and then
    /// nothing, so without this a pane on a static window would stay black forever.
    var lastPB: CVPixelBuffer?

    // ≥1 Hz cap: an iOS relay with the app closed connects and drops every ~2 s, and each
    // connect subscribes — without this, an unrelated viewer on the same source eats a
    // forced IDR per cycle, indefinitely. A second forced keyframe within a second is
    // redundant anyway (MaxKeyFrameInterval is one second's worth of frames).
    private var lastForcedKey = Date.distantPast

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
            guard Date().timeIntervalSince(self.lastForcedKey) >= 1 else { return }
            self.lastForcedKey = Date()
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
        camSession?.stopRunning()
        camSession = nil
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

// camera frames enter the same per-source pipeline as ScreenCaptureKit frames:
// lastPB + encode on sampleQueue (the delegate callback runs on that queue)
final class CameraOutput: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    let source: Source
    init(source: Source) { self.source = source }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        guard sampleBuffer.isValid, let pb = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        source.lastPB = pb
        source.encoder.encode(pb, force: false)
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
    // the one place in the repo that synthesises .cghidEventTap events, so gating here
    // covers window raising too. NOT in drainTouch: dropping a 5-byte unit there desyncs
    // every later packet, and a misaligned type-3 reads as a plausible touch.
    guard inputAllowed() else { return }
    let type = Int(d[d.startIndex])
    guard type < 3 else { return }   // defensive: drainTouch routes type 3 to handleResize and drops 4+
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

// MARK: - composite stream (legacy/iOS viewers)

// The iOS app is a single-connection legacy viewer: it never handshakes, so it can only
// receive one stream. With more than one source active, legacy viewers get this instead
// of the bare primary: every pane drawn into one frame per the shared layout, so the
// iPad shows the same arrangement as the settings canvas — no client change needed.
let COMPOSITE = 1_000   // ConnState.video index for composite subscribers; never a sources[] index

final class Compositor {
    private let queue = DispatchQueue(label: "composite")
    private let encoder = Encoder(bitrate: BITRATE, fps: FPS)
    private let ctx = CIContext(options: [.cacheIntermediates: false])
    private var pool: CVPixelBufferPool?
    private var timer: DispatchSourceTimer?
    private var forceKey = false
    private var lastForcedKey = Date.distantPast   // same ≥1 Hz cap as Source.forceKeyframe
    private let W: Int, H: Int

    init(width: Int, height: Int) {
        W = width; H = height
        encoder.onHeader = { h in server?.setHeader(h, COMPOSITE) }
        encoder.onEncoded = { data, isKey in server?.broadcast(data, from: COMPOSITE, droppable: !isKey) }
        // timer-driven, not capture-driven: ScreenCaptureKit sources go silent when idle,
        // but lastPB always holds their newest frame — a fixed tick composites the union
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 1, repeating: 1.0 / Double(FPS))
        t.setEventHandler { [weak self] in self?.tick() }
        t.resume()
        timer = t
    }

    func forceKeyframe() {
        queue.async { [weak self] in
            guard let self, Date().timeIntervalSince(self.lastForcedKey) >= 1 else { return }
            self.lastForcedKey = Date()
            self.forceKey = true
        }
    }

    private func tick() {
        guard let s = server else { return }
        // one hop to the net queue for its confined state; sources' lastPB on their queues.
        // Safe order: net and sample queues only ever dispatch *async* toward this queue.
        let (hasViewer, panes) = s.queue.sync { (s.hasCompositeViewer, layout.panes) }
        guard hasViewer else { return }
        var out = CIImage(color: .black).cropped(to: CGRect(x: 0, y: 0, width: W, height: H))
        for p in panes.sorted(by: { $0.z < $1.z }) {
            guard let src = sources.first(where: { $0.id == p.src && $0.alive }),
                  let pb = src.sampleQueue.sync(execute: { src.lastPB }) else { continue }
            let img = CIImage(cvPixelBuffer: pb)
            // ponytail: stretch to the pane box, matching the phone's pane view
            let sx = p.w * Double(W) / img.extent.width
            let sy = p.h * Double(H) / img.extent.height
            let ty = Double(H) - (p.y + p.h) * Double(H)   // layout is top-left origin, CI bottom-left
            out = img.transformed(by: CGAffineTransform(translationX: p.x * Double(W), y: ty)
                                        .scaledBy(x: sx, y: sy))
                     .composited(over: out)
        }
        guard let buf = makeBuffer() else { return }
        ctx.render(out, to: buf, bounds: CGRect(x: 0, y: 0, width: W, height: H),
                   colorSpace: CGColorSpaceCreateDeviceRGB())
        encoder.encode(buf, force: forceKey)
        forceKey = false
    }

    private func makeBuffer() -> CVPixelBuffer? {
        if pool == nil {
            let attrs: [CFString: Any] = [
                kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey: W, kCVPixelBufferHeightKey: H,
                kCVPixelBufferIOSurfacePropertiesKey: [:] as [CFString: Any],
            ]
            CVPixelBufferPoolCreate(nil, nil, attrs as CFDictionary, &pool)
        }
        guard let pool else { return nil }
        var pb: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pb)
        return pb
    }
}

var compositor: Compositor?

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
    // drop accounting lives on the connection, not the server: `conns[k] = nil` then
    // destroys it structurally, so a churning relay (iOS app closed: connect + drop
    // every ~2 s) cannot accumulate phantom drops against the source and step the
    // primary down to the floor — stepDown has no inverse for the life of the process
    var sent = 0
    var dropped = 0
    init(_ c: NWConnection) { self.c = c }
}

final class TCPServer {
    private var conns: [ObjectIdentifier: Conn] = [:]
    let queue = DispatchQueue(label: "net")
    private let touchQueue = DispatchQueue(label: "touch")
    private var headers: [Int: Data] = [:]        // per-source Annex-B parameter sets, for late joiners
    var sawTypeThree = false      // FR-26 latch: set on first resize packet, read by the --ios timer
    private var restarting = false // resize restart is one-shot even with several subscribers
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
                self.subscribe(conn, self.legacyTarget())   // legacy viewer: never speaks first
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
                let target = legacyTarget()
                subscribe(conn, target)
                conn.buf = d
                drainTouch(conn, target)
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

    // legacy viewers can't pick a source; when panes exist they get the composite
    private func legacyTarget() -> Int { compositor != nil ? COMPOSITE : 0 }

    // a composite subscriber counts viewers for the render loop — computed here because
    // conns is net-queue-confined; the compositor reads it via queue.sync
    var hasCompositeViewer: Bool {
        conns.values.contains { if case .video(let i) = $0.state { return i == COMPOSITE }; return false }
    }

    private func subscribe(_ conn: Conn, _ index: Int) {
        if index == COMPOSITE {
            guard let compositor else { reject(conn, "unknown source"); return }
            conn.state = .video(COMPOSITE)
            NSLog("client subscribed to composite (\(sources.filter(\.alive).count) panes)")
            if let h = headers[COMPOSITE], !h.isEmpty {
                conn.c.send(content: h, completion: .contentProcessed { _ in })
            }
            compositor.forceKeyframe()
            return
        }
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

    // The 5-byte grid is held HERE, by fixed-stride slicing plus the 0-4 byte remainder
    // surviving to the next receive — not by the reader, whose maximumLength is 65536.
    // Never consume a partial unit: discarding one desyncs every later packet by its
    // width, and a misaligned type-3 reads as a plausible touch (wandering cursor).
    private func drainTouch(_ conn: Conn, _ index: Int) {
        guard case .video = conn.state else { return }
        if index == COMPOSITE { drainCompositeTouch(conn); return }
        guard index < sources.count else { return }
        let src = sources[index]
        var off = conn.buf.startIndex
        let end = conn.buf.endIndex
        while end - off >= 5 {
            let pkt = Data(conn.buf[off ..< off + 5])
            off += 5
            switch Protocol.parse(pkt) {
            case .touch:
                touchQueue.async { handleTouch(pkt, src) }
            case .resize(let w, let h):
                handleResize(src, w, h)   // net queue: pure state + one dispatch, never touchQueue —
                                          // that queue blocks behind raiseWindow's AX calls
            case .invalid:
                break                     // types 4...255 reserved; drop, keep the grid
            }
        }
        conn.buf = off == end ? Data() : Data(conn.buf[off ..< end])
    }

    // A composite viewer's touches arrive in whole-frame coordinates: hit-test the pane
    // under the point (topmost z first), replay the packet in that pane's own space, and
    // route it to that pane's source. A touch on the black background is dropped.
    private func drainCompositeTouch(_ conn: Conn) {
        var off = conn.buf.startIndex
        let end = conn.buf.endIndex
        while end - off >= 5 {
            let pkt = Data(conn.buf[off ..< off + 5])
            off += 5
            switch Protocol.parse(pkt) {
            case .touch(let type, let x, let y):
                let nx = Double(x) / 65535.0, ny = Double(y) / 65535.0
                guard let p = layout.panes.sorted(by: { $0.z > $1.z })
                        .first(where: { nx >= $0.x && nx <= $0.x + $0.w && ny >= $0.y && ny <= $0.y + $0.h }),
                      let src = sources.first(where: { $0.id == p.src && $0.alive }) else { break }
                let lx = UInt16((nx - p.x) / p.w * 65535), ly = UInt16((ny - p.y) / p.h * 65535)
                let local = Data([UInt8(type), UInt8(lx >> 8), UInt8(lx & 0xff), UInt8(ly >> 8), UInt8(ly & 0xff)])
                touchQueue.async { handleTouch(local, src) }
            case .resize(let w, let h):
                // rotation still resizes: route to the primary, which handleResize vets anyway
                if let primary = sources.first { handleResize(primary, w, h) }
            case .invalid:
                break
            }
        }
        conn.buf = off == end ? Data() : Data(conn.buf[off ..< end])
    }

    // type-3: the device's viewport declaration, honoured only from a subscriber of the
    // primary display source. A window: pane's dimensions are the Mac window's, not the
    // phone's — and a secondary pane must never be able to restart the whole server.
    private func handleResize(_ src: Source, _ w: Int, _ h: Int) {
        sawTypeThree = true
        // the latch is set FIRST and unconditionally: the --ios timer reads it to decide
        // whether to nag "open the app", so a locked device that is streaming happily
        // would otherwise be nagged forever
        if PANEL_LOCK != nil { return }
        guard src.isPrimary, src.isDisplay, src.displayID != 0, src.alive else {
            NSLog("type-3 \(w)x\(h) from non-viewport subscriber (\(src.id)) — ignored")
            return
        }
        // scale BEFORE comparing: pxW/pxH are already scaled, so comparing the raw
        // report against them would restart forever whenever IOS_SCALE != 1
        let sw = Int(Double(w) * IOS_SCALE) & ~3, sh = Int(Double(h) * IOS_SCALE) & ~3
        guard Protocol.shouldRestart(current: (Int(pxW), Int(pxH)), reported: (sw, sh)) else { return }
        guard !restarting else { return }
        restarting = true
        NSLog("device reports \(w)x\(h) -> \(sw)x\(sh) (was \(pxW)x\(pxH)) — restarting to rebuild the virtual display")
        DispatchQueue.global(qos: .utility).async {
            // atomic: the watcher reads this on a 2 s tick and a torn read launches garbage
            try? "\(sw) \(sh)".write(toFile: shareDir + "/dims.ios", atomically: true, encoding: .utf8)
            exit(0)   // watcher relaunches at the new size; process death is the teardown,
                      // same as dropSource's exit(1) — there is no stopCapture anywhere
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
                if droppable && conn.pending > 2 { conn.dropped += 1; continue }
                conn.sent += 1
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
            // per-connection counters, summed per source and zeroed in the same pass —
            // a subscriber that disconnected took its counters with it
            var sent = [Int: Int](), drops = [Int: Int]()
            for conn in self.conns.values {
                guard case .video(let i) = conn.state else { continue }
                sent[i, default: 0] += conn.sent
                drops[i, default: 0] += conn.dropped
                conn.sent = 0
                conn.dropped = 0
            }
            for src in sources where src.alive {
                let total = (sent[src.index] ?? 0) + (drops[src.index] ?? 0)
                guard total > 100, Double(drops[src.index] ?? 0) / Double(total) > 0.25 else { continue }
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
    desc.name = DEVICE_LABEL
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

func makeCameraStream(for src: Source, device: AVCaptureDevice) throws {
    let session = AVCaptureSession()
    // ponytail: fixed 720p (fallback native) — good enough for a pane; pick per-box modes if bandwidth bites
    if session.canSetSessionPreset(.hd1280x720) { session.sessionPreset = .hd1280x720 }
    let input = try AVCaptureDeviceInput(device: device)
    guard session.canAddInput(input) else {
        throw NSError(domain: "aeasy", code: 1,
                      userInfo: [NSLocalizedDescriptionKey: "cannot open camera '\(device.localizedName)'"])
    }
    session.addInput(input)

    let out = AVCaptureVideoDataOutput()
    out.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
    out.alwaysDiscardsLateVideoFrames = true    // encoder backlog must drop frames, not queue them
    let delegate = CameraOutput(source: src)
    out.setSampleBufferDelegate(delegate, queue: src.sampleQueue)
    guard session.canAddOutput(out) else {
        throw NSError(domain: "aeasy", code: 1,
                      userInfo: [NSLocalizedDescriptionKey: "cannot read camera '\(device.localizedName)'"])
    }
    session.addOutput(out)

    // cap the device at the configured FPS where the format allows it. Virtual cameras
    // (OBS) expose discrete ranges like "30.00-30.00" whose true duration is 1000000/30000030,
    // so a hand-built CMTime(1, 30) lands outside the range and AVFoundation throws an
    // uncatchable NSInvalidArgumentException — always clamp with the range's own CMTimes.
    let want = Double(src.fps)
    if let range = device.activeFormat.videoSupportedFrameRateRanges
        .min(by: { abs($0.maxFrameRate - want) < abs($1.maxFrameRate - want) }),
       (try? device.lockForConfiguration()) != nil {
        if range.maxFrameRate <= want {
            device.activeVideoMinFrameDuration = range.minFrameDuration
        } else if range.minFrameRate >= want {
            device.activeVideoMinFrameDuration = range.maxFrameDuration
        } else {
            device.activeVideoMinFrameDuration = CMTime(value: 1, timescale: Int32(want))
        }
        device.unlockForConfiguration()
    }

    let dims = CMVideoFormatDescriptionGetDimensions(device.activeFormat.formatDescription)
    src.encW = Int(dims.width)
    src.encH = Int(dims.height)

    src.encoder.onHeader = { [weak src] h in
        guard let src else { return }
        server?.setHeader(h, src.index)
    }
    src.encoder.onEncoded = { [weak src] data, isKey in
        guard let src else { return }
        server?.broadcast(data, from: src.index, droppable: !isKey)
    }
    src.camOutput = delegate
    src.camSession = session
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
            // The grant is per-binary, so one covers all three servers — but the prompt is
            // per-process, and three of them start together after a rebuild. Only the slot
            // that will actually post events asks.
            if inputAllowed() {
                AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary)
                // an iOS client is a legacy video client and never opens the control channel,
                // so the no_accessibility error message can't reach it — notify on the Mac instead
                if IOS_MODE { notify("Taps from the iPhone do nothing until Accessibility is granted to aeasy-server") }
            }
        }
        if IOS_MODE, !SOURCE_IDS.contains("display") {
            NSLog("iOS client with no display source — rotation will not resize (check `aeasy sources`)")
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
        var resolved: [(id: String, display: SCDisplay?, window: SCWindow?, camera: AVCaptureDevice?)] = []
        for id in SOURCE_IDS {
            if id == "display" {
                guard let d = displays.displays.first(where: { $0.displayID == vdispID }) else {
                    NSLog("virtual display missing from the capture list — skipping"); continue
                }
                resolved.append((id, d, nil, nil))
            } else if id.hasPrefix("window:") {
                let app = String(id.dropFirst("window:".count))
                guard let win = windows.windows
                        .filter({ $0.owningApplication?.applicationName.localizedCaseInsensitiveContains(app) == true })
                        .max(by: { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }) else {
                    let names = Set(windows.windows.compactMap { $0.owningApplication?.applicationName }).sorted()
                    NSLog("window of '\(app)' not found — skipping. running apps: \(names.joined(separator: ", "))")
                    continue
                }
                resolved.append((id, nil, win, nil))
            } else if id.hasPrefix("camera:") {
                let name = String(id.dropFirst("camera:".count))
                guard await AVCaptureDevice.requestAccess(for: .video) else {
                    NSLog("camera access denied — System Settings > Privacy & Security > Camera > aeasy-server")
                    continue
                }
                let ds = AVCaptureDevice.DiscoverySession(
                    deviceTypes: [.builtInWideAngleCamera, .externalUnknown],
                    mediaType: .video, position: .unspecified)
                guard let dev = ds.devices.first(where: { $0.localizedName.localizedCaseInsensitiveContains(name) }) else {
                    NSLog("camera '\(name)' not found — connected: \(ds.devices.map(\.localizedName).joined(separator: ", "))")
                    continue
                }
                resolved.append((id, nil, nil, dev))
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
                // iOS reports half-native points (Protocol.reportedSize), so the panel has 2x
                // the pixels — capture the retina backing or the iPad upscales it blurry
                let mult = IOS_MODE ? 2.0 : 1.0
                let (w, h) = fitEven(Double(pxW) * mult, Double(pxH) * mult, into: box.0 * mult, box.1 * mult)
                _ = try makeStream(for: src, filter: SCContentFilter(display: display, excludingWindows: []),
                                   width: w, height: h, scalesToFit: false)
            } else if let win = entry.window {
                src.windowID = win.windowID
                src.windowPID = win.owningApplication?.processID ?? 0
                let (w, h) = fitEven(win.frame.width * 2, win.frame.height * 2, into: box.0, box.1)  // 2x for retina sharpness
                _ = try makeStream(for: src, filter: SCContentFilter(desktopIndependentWindow: win),
                                   width: w, height: h, scalesToFit: true)
                NSLog("capturing window '\(win.title ?? "?")' of \(win.owningApplication?.applicationName ?? "?")")
            } else if let cam = entry.camera {
                try makeCameraStream(for: src, device: cam)
                NSLog("capturing camera '\(cam.localizedName)'")
            }
            built.append(src)
        }
        sources = built
        layout.load(sources.map(\.id))

        let s = try TCPServer()
        server = s
        s.startHealthCheck()

        if sources.count > 1 {
            // canvas = the primary's encode size, so a composite viewer costs no extra pixels
            let w = sources[0].encW > 0 ? sources[0].encW : Int(pxW)
            let h = sources[0].encH > 0 ? sources[0].encH : Int(pxH)
            compositor = Compositor(width: w, height: h)
            NSLog("composite stream \(w)x\(h) for legacy viewers (\(sources.count) panes)")
        }

        // The app cannot be launched remotely (no `am start` on iOS), so tell the user.
        // Trigger on "no type-3 packet", never "no TCP connection": iproxy accept()s the
        // local dial BEFORE trying the usbmux side, so with the app closed the relay
        // still connects, subscribes, and drops — a connection latch would never fire.
        if IOS_MODE {
            s.queue.asyncAfter(deadline: .now() + 5) { [weak s] in
                if let s, !s.sawTypeThree { notify("Open AEasy Display on your iPhone") }
            }
        }

        for src in sources {
            try await src.stream?.startCapture()
            src.camSession?.startRunning()
        }
        NSLog("capture started for \(sources.count) source(s)")
    } catch {
        NSLog("failed: \(error.localizedDescription) — check Screen Recording permission in System Settings")
        exit(1)
    }
}

RunLoop.main.run()
