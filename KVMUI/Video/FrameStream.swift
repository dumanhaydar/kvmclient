import CoreMedia
import CoreGraphics
import Foundation
import ImageIO

/// Receives decoded-ready video from a driver. Implemented by the screen's layer-backed video view.
protocol FrameRenderer: AnyObject {
    /// H.264 access unit, ready for AVSampleBufferDisplayLayer. Called on the stream's queue.
    func render(sample: CMSampleBuffer)
    /// Decoded JPEG. Called on the stream's queue.
    func render(image: CGImage)
}

/// Pipe between a non-WebRTC video source (MJPEG, raw H.264) and the screen view.
/// Producers push bytes from any thread; parsing and decoding happen on a private serial queue.
final class FrameStream: @unchecked Sendable {
    private let queue = DispatchQueue(label: "kvm.framestream", qos: .userInteractive)
    private let lock = NSLock()
    private weak var _renderer: FrameRenderer?
    private lazy var h264 = H264AnnexBParser()
    private var jpeg = JPEGScanner()
    private var decodingJPEG = false

    var renderer: FrameRenderer? {
        get { lock.withLock { _renderer } }
        set { lock.withLock { _renderer = newValue } }
    }

    /// Raw H.264 Annex B bytes, in any chunking. Pass `completeFrame` when `data` is exactly one
    /// access unit, to display it without waiting for the next one.
    func pushH264(_ data: Data, completeFrame: Bool = false) {
        queue.async { [self] in
            for sample in h264.append(data, endOfAccessUnit: completeFrame) { renderer?.render(sample: sample) }
        }
    }

    /// Bytes of an MJPEG stream (multipart or bare concatenated JPEGs), in any chunking.
    func pushMJPEG(_ data: Data) {
        queue.async { [self] in
            // Keep only the newest frame: decoding falls behind on slow devices rather than lagging.
            guard let frame = jpeg.append(data).last, !decodingJPEG else { return }
            decodingJPEG = true
            DispatchQueue.global(qos: .userInteractive).async { [self] in
                if let source = CGImageSourceCreateWithData(frame as CFData, nil),
                   let image = CGImageSourceCreateImageAtIndex(source, 0, nil) {
                    renderer?.render(image: image)
                }
                queue.async { self.decodingJPEG = false }
            }
        }
    }

    /// An already decoded frame (demo device).
    func pushImage(_ image: CGImage) {
        queue.async { [self] in renderer?.render(image: image) }
    }

    /// A complete JPEG (e.g. one WebSocket message).
    func pushJPEG(_ frame: Data) {
        pushMJPEG(frame)
    }
}

/// Cuts complete JPEG images (SOI FFD8 … EOI FFD9) out of a byte stream; multipart headers
/// between images are skipped naturally.
struct JPEGScanner {
    private var buffer = Data()

    mutating func append(_ data: Data) -> [Data] {
        buffer.append(data)
        var frames: [Data] = []
        while true {
            guard let start = find([0xFF, 0xD8], from: buffer.startIndex) else {
                buffer.removeAll(keepingCapacity: true)
                break
            }
            guard let end = find([0xFF, 0xD9], from: start + 2) else {
                buffer.removeSubrange(buffer.startIndex..<start)
                break
            }
            frames.append(buffer.subdata(in: start..<(end + 2)))
            buffer.removeSubrange(buffer.startIndex..<(end + 2))
        }
        if buffer.count > 8_000_000 { buffer.removeAll() } // garbage, resync
        return frames
    }

    private func find(_ marker: [UInt8], from index: Int) -> Int? {
        buffer.withUnsafeBytes { raw -> Int? in
            let bytes = raw.bindMemory(to: UInt8.self)
            let base = buffer.startIndex
            var i = index - base
            while i + 1 < bytes.count {
                if bytes[i] == marker[0], bytes[i + 1] == marker[1] { return base + i }
                i += 1
            }
            return nil
        }
    }
}
