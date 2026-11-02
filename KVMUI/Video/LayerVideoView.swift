import AVFoundation
import CoreImage
import CoreMedia

#if os(macOS)
import AppKit
typealias PlatformView = NSView
#else
import UIKit
typealias PlatformView = UIView
#endif

/// Draws a `FrameStream`: H.264/H.265 through AVSampleBufferDisplayLayer (hardware decode),
/// JPEG frames as layer contents. Reports the decoded size so the screen can lay out exactly.
final class LayerVideoView: PlatformView, FrameRenderer {
    var onVideoSize: ((CGSize) -> Void)?
    /// Normalized part of the frame the remote desktop occupies (see `ContentDetector`).
    var onContentRect: ((CGRect) -> Void)?

    private let displayLayer = AVSampleBufferDisplayLayer()
    private let imageLayer = CALayer()
    private var lastSize: CGSize = .zero
    private var contentRect = ContentDetector.fullFrame
    private var candidateRect: CGRect?
    private var lastDetection = Date.distantPast

    override init(frame: CGRect) {
        super.init(frame: frame)
        #if os(macOS)
        wantsLayer = true
        layer = CALayer()
        #endif
        displayLayer.videoGravity = .resize
        imageLayer.contentsGravity = .resize
        imageLayer.magnificationFilter = .linear
        hostLayer.addSublayer(displayLayer)
        hostLayer.addSublayer(imageLayer)
    }

    required init?(coder: NSCoder) { fatalError() }

    private var hostLayer: CALayer {
        #if os(macOS)
        layer!
        #else
        layer
        #endif
    }

    #if os(macOS)
    override func layout() {
        super.layout()
        layoutLayers()
    }
    #else
    override func layoutSubviews() {
        super.layoutSubviews()
        layoutLayers()
    }
    #endif

    private func layoutLayers() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        displayLayer.frame = bounds
        imageLayer.frame = bounds
        CATransaction.commit()
    }

    func reset() {
        displayLayer.sampleBufferRenderer.flush(removingDisplayedImage: true, completionHandler: nil)
        imageLayer.contents = nil
        lastSize = .zero
        contentRect = ContentDetector.fullFrame
        candidateRect = nil
        onContentRect?(contentRect)
    }

    /// Once a second, from the frame on screen; a rect must be seen twice in a row to be adopted.
    private func detectContent() {
        guard Date().timeIntervalSince(lastDetection) >= 1 else { return }
        lastDetection = Date()
        guard #available(macOS 14.4, iOS 17.4, *),
              let buffer = displayLayer.sampleBufferRenderer.displayedPixelBuffer() else { return }
        guard let detected = ContentDetector.contentRect(of: buffer) else { return }
        defer { candidateRect = detected }
        guard detected == candidateRect, detected != contentRect else { return }
        contentRect = detected
        onContentRect?(detected)
    }

    // MARK: FrameRenderer (called off the main thread)

    func render(sample: CMSampleBuffer) {
        let renderer = displayLayer.sampleBufferRenderer
        if renderer.status == .failed { renderer.flush() }
        renderer.enqueue(sample)
        if let format = CMSampleBufferGetFormatDescription(sample) {
            let dimensions = CMVideoFormatDescriptionGetDimensions(format)
            report(CGSize(width: Int(dimensions.width), height: Int(dimensions.height)))
        }
        DispatchQueue.main.async {
            if self.imageLayer.contents != nil { self.imageLayer.contents = nil }
            self.detectContent()
        }
    }

    func render(image: CGImage) {
        DispatchQueue.main.async {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            self.imageLayer.contents = image
            CATransaction.commit()
        }
        report(CGSize(width: image.width, height: image.height))
    }

    private func report(_ size: CGSize) {
        DispatchQueue.main.async {
            guard size != self.lastSize, size.width > 0 else { return }
            self.lastSize = size
            self.onVideoSize?(size)
        }
    }
}

/// Black bars around the remote desktop (the target outputs a narrower mode than the captured
/// frame). The target's absolute pointer spans only the content, so input must be mapped into it,
/// as the NanoKVM web UI's "automatic calibration" does.
enum ContentDetector {
    static let fullFrame = CGRect(x: 0, y: 0, width: 1, height: 1)

    /// Normalized content rect (`fullFrame` when there are no bars), or nil when it can't tell: the
    /// frame is all background (screen asleep, rebooting). `luma(x, y)` is 0...255.
    static func contentRect(width: Int, height: Int, luma: (Int, Int) -> Int) -> CGRect? {
        guard width > 8, height > 8 else { return nil }
        let background = (luma(2, 2) + luma(width - 3, 2) + luma(2, height - 3) + luma(width - 3, height - 3)) / 4
        guard background < 40 else { return fullFrame }

        /// Column (or row) `index` is bar when nearly all of it matches the corners.
        func isBar(_ index: Int, vertical: Bool) -> Bool {
            let samples = 120, span = vertical ? height : width
            let matches = (0..<samples).filter { i in
                let along = i * (span - 1) / (samples - 1)
                return abs((vertical ? luma(index, along) : luma(along, index)) - background) <= 12
            }.count
            return Double(matches) >= Double(samples) * 0.88
        }
        /// Leading and trailing bar widths along one axis, to the pixel; zero unless symmetric and
        /// plausible (a dark desktop edge isn't a bar).
        func bars(vertical: Bool) -> (Double, Double)? {
            let count = vertical ? width : height
            guard let first = (0..<count).first(where: { !isBar($0, vertical: vertical) }),
                  let last = (0..<count).last(where: { !isBar($0, vertical: vertical) }) else { return nil }
            let lead = Double(first) / Double(count), trail = Double(count - 1 - last) / Double(count)
            let plausible = (0.05...0.425).contains(lead) && (0.05...0.425).contains(trail) && abs(lead - trail) <= 0.02
            // Scaled output is centered, so the bars are equal; dark content at an edge only ever
            // widens a bar, so the narrower one is the true width.
            let bar = min(lead, trail)
            return plausible ? (bar, bar) : (0, 0)
        }

        guard let (left, right) = bars(vertical: true), let (top, bottom) = bars(vertical: false) else { return nil }
        guard left + right + top + bottom > 0 else { return fullFrame }
        return CGRect(x: left, y: top, width: 1 - left - right, height: 1 - top - bottom)
    }

    private static let context = CIContext(options: [.workingColorSpace: NSNull()])

    /// Any pixel format (VideoToolbox can hand back compressed ones, unreadable as plain memory):
    /// downscale through Core Image to 8-bit RGBA, green as luma.
    static func contentRect(of buffer: CVPixelBuffer) -> CGRect? {
        var image = CIImage(cvPixelBuffer: buffer)
        let scale = min(1, 1024 / max(image.extent.width, 1))
        image = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let width = Int(image.extent.width), height = Int(image.extent.height)
        guard width > 8, height > 8 else { return nil }
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        context.render(image, toBitmap: &pixels, rowBytes: width * 4,
                       bounds: CGRect(x: 0, y: 0, width: width, height: height), format: .RGBA8, colorSpace: nil)
        return contentRect(width: width, height: height) { x, y in Int(pixels[(y * width + x) * 4 + 1]) }
    }
}
