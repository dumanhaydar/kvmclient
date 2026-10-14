import CoreMedia
import Foundation

/// Turns an H.264 Annex B byte stream (start-code separated NAL units, as sent by KVMs over
/// HTTP or WebSocket) into CMSampleBuffers, one per access unit, flagged for immediate display.
final class H264AnnexBParser {
    private var buffer = Data()
    private var sps: Data?
    private var pps: Data?
    private var format: CMVideoFormatDescription?
    private var accessUnit: [Data] = []

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
            if accessUnit.contains(where: Self.isSliceNAL), let sample = makeSample(accessUnit) { samples.append(sample) }
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
        guard let header = nal.first else { return nil }
        let type = header & 0x1F
        var finished: CMSampleBuffer?

        // AUD, SPS, PPS, SEI or the first slice of a picture (first_mb_in_slice == 0) begin a new AU.
        let isSlice = type == 1 || type == 5
        let firstSlice = isSlice && nal.count > 1 && nal[nal.startIndex + 1] & 0x80 != 0
        if (type == 9 || type == 7 || type == 8 || type == 6 || firstSlice), accessUnit.contains(where: Self.isSliceNAL) {
            finished = makeSample(accessUnit)
            accessUnit.removeAll()
        }

        switch type {
        case 7:
            if sps != nal { sps = nal; format = nil }
        case 8:
            if pps != nal { pps = nal; format = nil }
        case 9:
            break // AUD carries nothing we need
        default:
            accessUnit.append(nal)
        }
        return finished
    }

    private static func isSliceNAL(_ nal: Data) -> Bool {
        guard let header = nal.first else { return false }
        let type = header & 0x1F
        return type == 1 || type == 5
    }

    private func makeFormat() -> CMVideoFormatDescription? {
        if let format { return format }
        guard let sps, let pps else { return nil }
        var description: CMVideoFormatDescription?
        sps.withUnsafeBytes { spsRaw in
            pps.withUnsafeBytes { ppsRaw in
                let pointers = [spsRaw.bindMemory(to: UInt8.self).baseAddress!, ppsRaw.bindMemory(to: UInt8.self).baseAddress!]
                let sizes = [sps.count, pps.count]
                CMVideoFormatDescriptionCreateFromH264ParameterSets(
                    allocator: kCFAllocatorDefault, parameterSetCount: 2,
                    parameterSetPointers: pointers, parameterSetSizes: sizes,
                    nalUnitHeaderLength: 4, formatDescriptionOut: &description)
            }
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
