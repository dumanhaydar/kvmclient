import CoreMedia
import Foundation

/// Turns an H.264 (or, with `hevc`, H.265) Annex B byte stream (start-code separated NAL units,
/// as sent by KVMs over HTTP or WebSocket) into CMSampleBuffers, one per access unit, flagged for
/// immediate display.
final class H264AnnexBParser {
    private let hevc: Bool
    private var buffer = Data()
    /// SPS and PPS (plus VPS for H.265), by NAL type.
    private var parameterSets: [UInt8: Data] = [:]
    private var format: CMVideoFormatDescription?
    private var accessUnit: [Data] = []

    init(hevc: Bool = false) {
        self.hevc = hevc
    }

    // NAL unit types: H.264 has a 1-byte header (type in the low 5 bits), H.265 a 2-byte one
    // (type in bits 1...6 of the first byte).
    private var parameterSetTypes: [UInt8] { hevc ? [32, 33, 34] : [7, 8] }
    private var audType: UInt8 { hevc ? 35 : 9 }
    private var seiType: UInt8 { hevc ? 39 : 6 }
    private func type(of nal: Data) -> UInt8? { nal.first.map { hevc ? ($0 >> 1) & 0x3F : $0 & 0x1F } }
    private func isSlice(_ type: UInt8) -> Bool { hevc ? type <= 21 : type == 1 || type == 5 }
    private func isSliceNAL(_ nal: Data) -> Bool { type(of: nal).map(isSlice) ?? false }

    /// `endOfAccessUnit`: the data ends exactly on a frame boundary (e.g. one WebSocket message
    /// per frame), so the frame can be shown now instead of when the next one starts.
    func append(_ data: Data, endOfAccessUnit: Bool = false) -> [CMSampleBuffer] {
        buffer.append(data)
        var samples: [CMSampleBuffer] = []
        // A NAL is complete once the next start code is seen.
        let starts = startCodes()
        for (index, start) in starts.enumerated() {
            let end: Int
            if index + 1 < starts.count {
                end = starts[index + 1].offset
            } else if endOfAccessUnit {
                end = buffer.endIndex
            } else {
                break
            }
            if let sample = consume(buffer.subdata(in: start.payload..<end)) { samples.append(sample) }
        }
        if endOfAccessUnit {
            buffer.removeAll(keepingCapacity: true)
            if accessUnit.contains(where: isSliceNAL), let sample = makeSample(accessUnit) { samples.append(sample) }
            accessUnit.removeAll()
        } else if let last = starts.last {
            buffer.removeSubrange(buffer.startIndex..<last.offset)
        }
        return samples
    }

    private struct StartCode { let offset: Int; let payload: Int }

    private func startCodes() -> [StartCode] {
        buffer.withUnsafeBytes { raw in
            let bytes = raw.bindMemory(to: UInt8.self)
            let base = buffer.startIndex
            var result: [StartCode] = []
            var i = 0
            while i + 3 <= bytes.count {
                if bytes[i] == 0, bytes[i + 1] == 0 {
                    if bytes[i + 2] == 1 {
                        result.append(StartCode(offset: base + i, payload: base + i + 3))
                        i += 3
                        continue
                    }
                    if i + 4 <= bytes.count, bytes[i + 2] == 0, bytes[i + 3] == 1 {
                        result.append(StartCode(offset: base + i, payload: base + i + 4))
                        i += 4
                        continue
                    }
                }
                i += 1
            }
            return result
        }
    }

    /// Returns a sample when `nal` starts a new access unit and a previous one was pending.
    private func consume(_ nal: Data) -> CMSampleBuffer? {
        guard let type = type(of: nal) else { return nil }
        var finished: CMSampleBuffer?

        // AUD, parameter sets, SEI or the first slice of a picture begin a new AU. The first slice
        // has the top bit after the header set (first_mb_in_slice == 0 / first_slice_segment_in_pic_flag).
        let headerLength = hevc ? 2 : 1
        let firstSlice = isSlice(type) && nal.count > headerLength && nal[nal.startIndex + headerLength] & 0x80 != 0
        if type == audType || type == seiType || parameterSetTypes.contains(type) || firstSlice,
           accessUnit.contains(where: isSliceNAL) {
            finished = makeSample(accessUnit)
            accessUnit.removeAll()
        }

        if parameterSetTypes.contains(type) {
            if parameterSets[type] != nal { parameterSets[type] = nal; format = nil }
        } else if type != audType { // AUD carries nothing we need
            accessUnit.append(nal)
        }
        return finished
    }

    private func makeFormat() -> CMVideoFormatDescription? {
        if let format { return format }
        let sets = parameterSetTypes.compactMap { parameterSets[$0] }
        guard sets.count == parameterSetTypes.count, !sets.contains(where: \.isEmpty) else { return nil }
        let pointers = sets.map { set -> UnsafePointer<UInt8> in
            let copy = UnsafeMutablePointer<UInt8>.allocate(capacity: set.count)
            set.copyBytes(to: copy, count: set.count)
            return UnsafePointer(copy)
        }
        defer { pointers.forEach { $0.deallocate() } }
        let sizes = sets.map(\.count)
        var description: CMVideoFormatDescription?
        if hevc {
            CMVideoFormatDescriptionCreateFromHEVCParameterSets(
                allocator: kCFAllocatorDefault, parameterSetCount: sets.count,
                parameterSetPointers: pointers, parameterSetSizes: sizes,
                nalUnitHeaderLength: 4, extensions: nil, formatDescriptionOut: &description)
        } else {
            CMVideoFormatDescriptionCreateFromH264ParameterSets(
                allocator: kCFAllocatorDefault, parameterSetCount: sets.count,
                parameterSetPointers: pointers, parameterSetSizes: sizes,
                nalUnitHeaderLength: 4, formatDescriptionOut: &description)
        }
        format = description
        return description
    }

    /// AVCC: each NAL prefixed with its 4-byte big-endian length.
    private func makeSample(_ nals: [Data]) -> CMSampleBuffer? {
        guard let format = makeFormat() else { return nil }
        var avcc = Data(capacity: nals.reduce(0) { $0 + $1.count + 4 })
        for nal in nals {
            var length = UInt32(nal.count).bigEndian
            avcc.append(Data(bytes: &length, count: 4))
            avcc.append(nal)
        }

        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil,
                                                 blockLength: avcc.count, blockAllocator: kCFAllocatorDefault,
                                                 customBlockSource: nil, offsetToData: 0, dataLength: avcc.count,
                                                 flags: 0, blockBufferOut: &block) == noErr, let block else { return nil }
        let copied = avcc.withUnsafeBytes {
            CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: avcc.count)
        }
        guard copied == noErr else { return nil }

        var sample: CMSampleBuffer?
        var size = avcc.count
        guard CMSampleBufferCreateReady(allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: format,
                                        sampleCount: 1, sampleTimingEntryCount: 0, sampleTimingArray: nil,
                                        sampleSizeEntryCount: 1, sampleSizeArray: &size, sampleBufferOut: &sample) == noErr,
              let sample else { return nil }
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true),
           CFArrayGetCount(attachments) > 0 {
            let dictionary = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(dictionary, Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                                 Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
        }
        return sample
    }
}
