#if os(macOS)
import AppKit

/// Keeps a window sized so that one of its subviews (the remote screen) has exactly the remote
/// display's aspect ratio, whatever chrome surrounds it (toolbar, sidebar).
///
/// `NSWindow.contentAspectRatio` can't express "content minus chrome", so this sits in front of the
/// window's existing delegate (owned by SwiftUI), answers `windowWillResize(_:to:)` itself and
/// forwards everything else untouched.
final class WindowAspectLock: NSObject, NSWindowDelegate {
    private weak var window: NSWindow?
    private weak var view: NSView?
    private weak var original: NSWindowDelegate?
    private var pendingFit = false

    /// Remote display size in pixels; nil until the first decoded frame.
    var videoSize: CGSize? {
        didSet {
            guard videoSize != oldValue, let videoSize else { return }
            let isFirstSize = oldValue == nil
            fitWindow(initial: isFirstSize || oldValue.map { !$0.hasSameRatio(as: videoSize) } ?? true)
        }
    }

    init(view: NSView) {
        self.view = view
        super.init()
    }

    func attach(to window: NSWindow) {
        guard self.window !== window || window.delegate !== self else { return }
        detach()
        self.window = window
        original = window.delegate
        window.delegate = self
    }

    func detach() {
        if let window, window.delegate === self { window.delegate = original }
        window = nil
        original = nil
    }

    /// Call from the view's layout: re-fits when the view changed size without the window being
    /// resized by the user (sidebar shown/hidden, toolbar changes...).
    func viewDidLayout() {
        guard let window, window.delegate !== self else {
            scheduleFitIfNeeded()
            return
        }
        // SwiftUI replaced the delegate: put ourselves back in front of the new one.
        original = window.delegate
        window.delegate = self
        scheduleFitIfNeeded()
    }

    private func scheduleFitIfNeeded() {
        guard !pendingFit, let window, let view, let videoSize, canAdjust(window),
              !view.bounds.size.hasSameRatio(as: videoSize, tolerance: 1 / window.backingScaleFactor) else { return }
        pendingFit = true
        DispatchQueue.main.async { [weak self] in
            self?.pendingFit = false
            self?.fitWindow(initial: false)
        }
    }

    private func canAdjust(_ window: NSWindow) -> Bool {
        !window.styleMask.contains(.fullScreen) && !window.inLiveResize && window.isVisible
    }

    // MARK: Sizing

    private func chrome(of window: NSWindow, view: NSView) -> CGSize {
        CGSize(width: window.frame.width - view.bounds.width, height: window.frame.height - view.bounds.height)
    }

    /// `initial`: pick a comfortable size for this resolution (1 pt per pixel, capped to the screen).
    /// Otherwise keep the current width and fix the height.
    private func fitWindow(initial: Bool) {
        guard let window, let view, let videoSize, canAdjust(window), view.bounds.width > 0 else { return }
        let chrome = chrome(of: window, view: view)
        let visible = (window.screen ?? NSScreen.main)?.visibleFrame ?? window.frame
        let maxContent = CGSize(width: visible.width - chrome.width, height: visible.height - chrome.height)

        var content = initial ? videoSize : CGSize(width: view.bounds.width, height: view.bounds.width * videoSize.height / videoSize.width)
        let scale = min(1, maxContent.width / content.width, maxContent.height / content.height)
        content = CGSize(width: content.width * scale, height: content.height * scale)

        var size = round(CGSize(width: content.width + chrome.width, height: content.height + chrome.height), window)
        size.width = max(size.width, window.minSize.width)
        size.height = max(size.height, window.minSize.height)

        // Keep the top-left corner in place, then pull the window back on screen if needed.
        var frame = NSRect(x: window.frame.minX, y: window.frame.maxY - size.height, width: size.width, height: size.height)
        frame.origin.x = min(max(frame.minX, visible.minX), visible.maxX - frame.width)
        frame.origin.y = min(max(frame.minY, visible.minY), visible.maxY - frame.height)
        guard frame != window.frame else { return }
        window.setFrame(frame, display: true, animate: !initial)
    }

    func windowWillResize(_ sender: NSWindow, to frameSize: NSSize) -> NSSize {
        let proposed = original?.windowWillResize?(sender, to: frameSize) ?? frameSize
        guard let view, let videoSize, videoSize.width > 0, videoSize.height > 0 else { return proposed }
        let chrome = chrome(of: sender, view: view)
        let ratio = videoSize.width / videoSize.height
        var content = CGSize(width: proposed.width - chrome.width, height: proposed.height - chrome.height)
        // Follow whichever dimension the user is dragging.
        if abs(proposed.width - sender.frame.width) >= abs(proposed.height - sender.frame.height) {
            content.height = content.width / ratio
        } else {
            content.width = content.height * ratio
        }
        return round(CGSize(width: content.width + chrome.width, height: content.height + chrome.height), sender)
    }

    private func round(_ size: CGSize, _ window: NSWindow) -> CGSize {
        let scale = window.backingScaleFactor
        return CGSize(width: (size.width * scale).rounded() / scale, height: (size.height * scale).rounded() / scale)
    }

    // MARK: Forwarding to SwiftUI's delegate

    override func responds(to selector: Selector!) -> Bool {
        super.responds(to: selector) || (original?.responds(to: selector) ?? false)
    }

    override func forwardingTarget(for selector: Selector!) -> Any? {
        original?.responds(to: selector) == true ? original : super.forwardingTarget(for: selector)
    }
}

private extension CGSize {
    func hasSameRatio(as other: CGSize, tolerance: CGFloat = 0.5) -> Bool {
        guard width > 0, height > 0, other.width > 0, other.height > 0 else { return true }
        // Compare the height this width would need against the actual height, in points.
        return abs(width * other.height / other.width - height) <= max(tolerance, 0.5)
    }
}
#endif
