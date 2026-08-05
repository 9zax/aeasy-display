// Upstream (device -> Mac) packet parsing. Pure — no I/O, no globals — so `mac/check`
// can assert it without Screen Recording, a virtual display or a phone.
// Compiled into both aeasy-server and check.
//
// Every upstream packet is exactly 5 bytes. The 5-byte grid is held by the caller's
// drain loop, which slices fixed 5-byte units and leaves a 0-4 byte remainder buffered
// for the next receive — NOT by the reader, whose maximumLength is 65536.
//
//   [0][x u16 BE][y u16 BE]   touch down
//   [1][x u16 BE][y u16 BE]   touch move
//   [2][x u16 BE][y u16 BE]   touch up / cancel
//   [3][w u16 BE][h u16 BE]   visible panel size, also the rotation signal (iOS)
//
// Types 4...255 are reserved: dropped without disturbing the grid.

import Foundation

enum Packet: Equatable {
    case touch(type: Int, x: UInt16, y: UInt16)
    case resize(w: Int, h: Int)
    case invalid
}

enum Protocol {
    /// Smallest and largest panel edge we will rebuild a virtual display for.
    /// Out-of-range values are dropped, never clamped: a clamp turns a garbage packet
    /// into a restart into a wrong-sized display, and 0 would divide by zero in
    /// LayoutStore.defaultPane (24.0 / Double(pxW)).
    static let minEdge = 320, maxEdge = 8192

    static func parse(_ d: Data) -> Packet {
        guard d.count == 5 else { return .invalid }
        let i = d.startIndex
        let type = Int(d[i])
        let a = UInt16(d[i + 1]) << 8 | UInt16(d[i + 2])
        let b = UInt16(d[i + 3]) << 8 | UInt16(d[i + 4])
        switch type {
        case 0, 1, 2:
            return .touch(type: type, x: a, y: b)
        case 3:
            let w = Int(a), h = Int(b)
            guard (minEdge...maxEdge).contains(w), (minEdge...maxEdge).contains(h) else { return .invalid }
            return .resize(w: w, h: h)
        default:
            return .invalid   // reserved; drop, keep the grid
        }
    }

    /// Equal dimensions must not restart — that is what terminates the resize loop
    /// after exactly one extra restart (server exits, watcher relaunches at the new
    /// size, client reconnects and re-reports, sizes now match, stop).
    static func shouldRestart(current: (Int, Int), reported: (Int, Int)) -> Bool {
        current.0 != reported.0 || current.1 != reported.1
    }

    /// Size an iOS client reports: half the safe area's native pixels, rounded down to
    /// a multiple of 4, scaled by IOS_SCALE.
    ///
    /// Half-pixels, not raw pixels: the virtual display is created with hiDPI = 1 and a
    /// 2x backing, so the reported number becomes the desktop's size in *points*. Raw
    /// native pixels would give a 1179-point desktop on a 2.56" panel (461 pt/in, a
    /// 1.3 mm menu bar). Halving lands the 2x backing on the physical panel instead.
    ///
    /// nativeScale, not scale: they differ on Plus models (8 Plus 2.6087 vs 3.0) and in
    /// Display Zoom. The product is non-integral, so round before truncating or the
    /// 8 Plus reports 1078 instead of 1080.
    static func reportedSize(points: (Double, Double), nativeScale: Double, iosScale: Double = 1.0) -> (Int, Int) {
        let s = min(2.0, max(0.5, iosScale))
        func axis(_ pt: Double) -> Int { Int((pt * nativeScale / 2 * s).rounded()) & ~3 }
        return (axis(points.0), axis(points.1))
    }
}
