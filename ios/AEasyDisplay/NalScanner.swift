// Incremental Annex-B splitter. NWConnection delivers arbitrary Data chunks, so this
// is a buffer scanner, not a byte-at-a-time port of the Android NalReader. A NAL is
// emitted when the NEXT start code arrives (same semantics as the Android reader);
// the tail — including a start code split across two receives — stays buffered.

import Foundation

final class NalScanner {
    private var buf: [UInt8] = []
    private var payloadStart = -1   // -1: no start code seen yet

    /// Feed a chunk, get complete NAL payloads: start codes stripped, and the trailing
    /// zeros that belong to the *next* start code trimmed with `min(zeros, 3)` — which
    /// handles 3- and 4-byte start codes and HEVC cabac_zero_words alike, exactly as
    /// the Android `contentLen = size - min(zeros, 3)` does.
    func feed(_ chunk: Data) -> [Data] {
        buf.append(contentsOf: chunk)
        var nals: [Data] = []
        var i = payloadStart >= 0 ? max(payloadStart, 0) : 0
        var zeros = 0
        // count zeros immediately before i (a split start code may straddle chunks)
        var j = i - 1
        while j >= 0 && buf[j] == 0 { zeros += 1; j -= 1 }

        while i < buf.count {
            let b = buf[i]
            if b == 0 {
                zeros += 1
            } else {
                if b == 1 && zeros >= 2 {
                    let cut = i - min(zeros, 3)          // strip the start code's zeros
                    if payloadStart >= 0 && cut > payloadStart {
                        nals.append(Data(buf[payloadStart..<cut]))
                    }
                    payloadStart = i + 1
                }
                zeros = 0
            }
            i += 1
        }

        if payloadStart >= 0 {
            buf.removeFirst(payloadStart)                 // keep the in-progress NAL
            payloadStart = 0
        } else if buf.count > 3 {
            buf.removeFirst(buf.count - 3)                // keep enough for a split start code
        }
        return nals
    }

    func reset() { buf.removeAll(); payloadStart = -1 }
}
