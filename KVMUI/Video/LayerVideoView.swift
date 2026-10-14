import AVFoundation
import CoreMedia

#if os(macOS)
import AppKit
typealias PlatformView = NSView
#else
import UIKit
typealias PlatformView = UIView
#endif

/// Draws a `FrameStream`: H.264 through AVSampleBufferDisplayLayer (hardware decode),
/// JPEG frames as layer contents. Reports the decoded size so the screen can lay out exactly.
final class LayerVideoView: PlatformView, FrameRenderer {
    var onVideoSize: ((CGSize) -> Void)?

    private let displayLayer = AVSampleBufferDisplayLayer()
    private let imageLayer = CALayer()
    private var lastSize: CGSize = .zero

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
        DispatchQueue.main.async { if self.imageLayer.contents != nil { self.imageLayer.contents = nil } }
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
