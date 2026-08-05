// AVSampleBufferDisplayLayer decodes internally — no VTDecompressionSession, which
// would emit CVPixelBuffers the layer cannot accept. This is the direct analogue of
// Android's `codec.configure(fmt, holder.surface, ...)`: NALs in, pixels on a layer.
//
// The layer is stricter than MediaCodec, and every rule below is a silent-failure
// mode, not a style choice:
//  - parameter sets go in WITHOUT start codes (opposite of Android's csd-0)
//  - every enqueued NAL carries a 4-byte BE length in place of the start code
//  - the first enqueue after (re)configuration must be an IDR
//  - DisplayImmediately on every sample, or the layer waits on a timebase forever
//  - flush() when requiresFlushToResumeDecoding, then re-arm the IDR gate

import AVFoundation
import CoreMedia
import VideoToolbox

final class Decoder {
    let layer = AVSampleBufferDisplayLayer()

    private var isHEVC = false
    private var sniffed = false
    private var paramSets: [Int: Data] = [:]   // keyed by NAL type, so repeats overwrite
    private var paramBytes = Data()            // concatenated, to detect changes across restarts
    private var format: CMVideoFormatDescription?
    private var waitingForIDR = true
    var onError: ((String) -> Void)?

    init() {
        layer.videoGravity = .resizeAspect     // during the ~2-5 s rotation restart the
                                               // incoming aspect is stale; .resize would stretch
        NotificationCenter.default.addObserver(
            forName: .AVSampleBufferDisplayLayerRequiresFlushToResumeDecodingDidChange,
            object: layer, queue: .main) { [weak self] _ in
            guard let self, self.layer.requiresFlushToResumeDecoding else { return }
            self.layer.flush()
            self.waitingForIDR = true          // post-flush, the next frame must be an IDR again
        }
    }

    func reset() {
        paramSets.removeAll(); paramBytes.removeAll()
        format = nil; sniffed = false; waitingForIDR = true
        layer.flush()
    }

    func consume(_ nal: Data) {
        guard !nal.isEmpty else { return }
        let first = nal[nal.startIndex]

        if !sniffed {
            // server always leads with param sets: HEVC VPS(32) first byte 0x40, H.264 SPS 0x67
            sniffed = true
            isHEVC = (Int(first) >> 1) & 0x3F == 32
            if isHEVC && !VTIsHardwareDecodeSupported(kCMVideoCodecType_HEVC) {
                onError?("This device can't hardware-decode HEVC — set CODEC=h264 in the Mac config")
            }
        }

        let type = isHEVC ? (Int(first) >> 1) & 0x3F : Int(first) & 0x1F

        if isHEVC ? (32...34).contains(type) : (type == 7 || type == 8) {
            paramSets[type] = nal
            let wanted = isHEVC ? [32, 33, 34] : [7, 8]
            guard wanted.allSatisfy({ paramSets[$0] != nil }) else { return }
            let joined = wanted.compactMap { paramSets[$0] }.reduce(Data(), +)
            if joined != paramBytes {          // SPS changes on every rotation restart
                paramBytes = joined
                rebuildFormat(wanted.compactMap { paramSets[$0] })
                waitingForIDR = true
            }
            return
        }

        // VCL filter, as Android: HEVC drops type >= 32, H.264 keeps only 1 and 5
        if isHEVC ? type >= 32 : (type != 1 && type != 5) { return }
        guard let format else { return }

        let isIDR = isHEVC ? (16...21).contains(type) : type == 5
        if waitingForIDR {
            guard isIDR else { return }        // feeding P-frames first drives the layer to .failed
            waitingForIDR = false
        }

        enqueue(nal, format: format)
    }

    private func rebuildFormat(_ sets: [Data]) {
        // pointers must stay alive through the Create call — hence the nested scope dance
        var fmt: CMVideoFormatDescription?
        let statuses: OSStatus = sets.withContiguousPointers { ptrs, sizes in
            if isHEVC {
                return CMVideoFormatDescriptionCreateFromHEVCParameterSets(
                    allocator: nil, parameterSetCount: ptrs.count, parameterSetPointers: ptrs,
                    parameterSetSizes: sizes, nalUnitHeaderLength: 4, extensions: nil,
                    formatDescriptionOut: &fmt)
            } else {
                return CMVideoFormatDescriptionCreateFromH264ParameterSets(
                    allocator: nil, parameterSetCount: ptrs.count, parameterSetPointers: ptrs,
                    parameterSetSizes: sizes, nalUnitHeaderLength: 4,
                    formatDescriptionOut: &fmt)
            }
        }
        if statuses == noErr { format = fmt }
        else { onError?("Video format rejected (\(statuses))") }
    }

    private func enqueue(_ nal: Data, format: CMVideoFormatDescription) {
        // CoreMedia owns the allocation — passing a Swift Data pointer straight into
        // CMBlockBufferCreateWithMemoryBlock is a use-after-free
        var bb: CMBlockBuffer?
        let total = 4 + nal.count
        guard CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: total,
            blockAllocator: kCFAllocatorDefault, customBlockSource: nil, offsetToData: 0,
            dataLength: total, flags: 0, blockBufferOut: &bb) == noErr, let bb else { return }

        var len = UInt32(nal.count).bigEndian
        withUnsafeBytes(of: &len) { _ = CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: bb, offsetIntoDestination: 0, dataLength: 4) }
        nal.withUnsafeBytes { _ = CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: bb, offsetIntoDestination: 4, dataLength: nal.count) }

        var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: .invalid, decodeTimeStamp: .invalid)
        var size = total
        var sbuf: CMSampleBuffer?
        guard CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault, dataBuffer: bb, formatDescription: format,
            sampleCount: 1, sampleTimingEntryCount: 1, sampleTimingArray: &timing,
            sampleSizeEntryCount: 1, sampleSizeArray: &size, sampleBufferOut: &sbuf) == noErr,
            let sbuf else { return }

        // no controlTimebase is ever set, so DisplayImmediately is mandatory — without it
        // the layer displays nothing, forever. Safe: the server disables frame reordering.
        if let atts = CMSampleBufferGetSampleAttachmentsArray(sbuf, createIfNecessary: true) as? [NSMutableDictionary],
           let first = atts.first {
            first[kCMSampleAttachmentKey_DisplayImmediately] = kCFBooleanTrue
        }
        if layer.status == .failed { layer.flush(); waitingForIDR = true; return }
        layer.enqueue(sbuf)
    }
}

private extension Array where Element == Data {
    /// Run `body` with C-style pointer/size arrays over every Data, all kept alive.
    func withContiguousPointers<R>(_ body: ([UnsafePointer<UInt8>], [Int]) -> R) -> R {
        func recurse(_ i: Int, _ ptrs: [UnsafePointer<UInt8>], _ sizes: [Int]) -> R {
            if i == count { return body(ptrs, sizes) }
            return self[i].withUnsafeBytes { raw in
                recurse(i + 1, ptrs + [raw.bindMemory(to: UInt8.self).baseAddress!], sizes + [self[i].count])
            }
        }
        return recurse(0, [], [])
    }
}
