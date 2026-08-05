// Pure protocol assertions — no permissions, no display, no phone, so this runs in CI.
// The permission-gated end-to-end harness is `make smoke` (test/smoke.py).
// Run: make check

import Foundation

var failures = 0
func expect(_ cond: Bool, _ what: String) {
    if cond { print("  ok   \(what)") } else { print("  FAIL \(what)"); failures += 1 }
}
func pkt(_ b: [UInt8]) -> Data { Data(b) }
func be(_ v: Int) -> [UInt8] { [UInt8(v >> 8), UInt8(v & 0xFF)] }

@main
struct Check {
    static func main() {
        print("touch packets (types 0-2) — the Android regression guard")
        for t in 0...2 {
            expect(Protocol.parse(pkt([UInt8(t)] + be(0) + be(65535))) == .touch(type: t, x: 0, y: 65535),
                   "type \(t) decodes with big-endian coords")
        }
        expect(Protocol.parse(pkt([1] + be(12345) + be(54321))) == .touch(type: 1, x: 12345, y: 54321),
               "move packet round-trips mid-range coords")

        print("type-3 resize")
        for (w, h) in [(372, 664), (588, 1136), (1100, 556), (320, 320), (8192, 8192)] {
            expect(Protocol.parse(pkt([3] + be(w) + be(h))) == .resize(w: w, h: h), "\(w)x\(h) round-trips")
        }

        print("type-3 out of range is dropped, never clamped")
        for (w, h) in [(0, 0), (1, 1), (319, 664), (372, 319), (65535, 65535)] {
            expect(Protocol.parse(pkt([3] + be(w) + be(h))) == .invalid, "\(w)x\(h) rejected")
        }

        print("reserved types stay reserved")
        for t in [4, 5, 99, 255] {
            expect(Protocol.parse(pkt([UInt8(t)] + be(100) + be(100))) == .invalid, "type \(t) invalid")
        }
        expect(Protocol.parse(pkt([0, 0, 0, 0])) == .invalid, "4-byte packet invalid")
        expect(Protocol.parse(pkt([0, 0, 0, 0, 0, 0])) == .invalid, "6-byte packet invalid")

        print("shouldRestart terminates the resize loop")
        expect(!Protocol.shouldRestart(current: (372, 664), reported: (372, 664)), "equal dimensions do not restart")
        expect(Protocol.shouldRestart(current: (372, 664), reported: (664, 372)), "a rotation does restart")
        expect(Protocol.shouldRestart(current: (372, 664), reported: (588, 1136)), "a different device does restart")

        print("reported size — half native pixels, multiple of 4")
        // iPhone 7 portrait, status bar hidden: 375x667 pt @2.0
        expect(Protocol.reportedSize(points: (375, 667), nativeScale: 2.0) == (372, 664), "iPhone 7 -> 372x664")
        // iPhone 15 Pro portrait: 393x759 pt @3.0 safe area
        expect(Protocol.reportedSize(points: (393, 759), nativeScale: 3.0) == (588, 1136), "iPhone 15 Pro -> 588x1136")
        // iPhone 15 Pro landscape: 734x372 pt @3.0
        expect(Protocol.reportedSize(points: (734, 372), nativeScale: 3.0) == (1100, 556), "15 Pro landscape -> 1100x556")
        // iPhone 8 Plus: nativeScale 2.6087, not scale 3.0. 414 * 2.6087 = 1079.9999 -> must round to 1080, not 1078.
        expect(Protocol.reportedSize(points: (414, 736), nativeScale: 1080.0 / 414.0).0 == 540,
               "8 Plus rounds to 540 (half of 1080), not 538")
        for (pts, s) in [((375.0, 667.0), 2.0), ((393.0, 759.0), 3.0), ((414.0, 736.0), 1080.0 / 414.0)] {
            let r = Protocol.reportedSize(points: pts, nativeScale: s)
            expect(r.0 % 4 == 0 && r.1 % 4 == 0, "\(r) is a multiple of 4 on both axes")
        }

        print("IOS_SCALE is the calibration knob, clamped 0.5-2.0")
        let base = Protocol.reportedSize(points: (393, 759), nativeScale: 3.0)
        expect(Protocol.reportedSize(points: (393, 759), nativeScale: 3.0, iosScale: 0.7).0 < base.0,
               "0.7 gives a smaller desktop with bigger text")
        expect(Protocol.reportedSize(points: (393, 759), nativeScale: 3.0, iosScale: 9.0)
               == Protocol.reportedSize(points: (393, 759), nativeScale: 3.0, iosScale: 2.0), "9.0 clamps to 2.0")
        expect(Protocol.reportedSize(points: (393, 759), nativeScale: 3.0, iosScale: 0.01)
               == Protocol.reportedSize(points: (393, 759), nativeScale: 3.0, iosScale: 0.5), "0.01 clamps to 0.5")

        print(failures == 0 ? "\nall assertions passed" : "\n\(failures) FAILED")
        exit(failures == 0 ? 0 : 1)
    }
}
