import SwiftUI
import WebRTC

/// Remote display + input capture. The platform view lays the WebRTC video out aspect-fit and
/// translates local keyboard/mouse/touch events into HID reports for the session.
struct RemoteScreenView {
    let session: KVMSession
    var capturesSystemShortcuts = true
    /// iOS/iPadOS: on-screen keyboard with an extra-keys bar. Reset to false when the user dismisses it.
    var showsSoftwareKeyboard: Binding<Bool> = .constant(false)
}

/// Shared geometry: the rect the video occupies inside the container, and the mapping
/// from a point in that rect to the device's 0...32767 absolute coordinates.
enum ScreenGeometry {
    static func videoRect(videoSize: CGSize, in bounds: CGRect) -> CGRect {
        guard videoSize.width > 0, videoSize.height > 0, bounds.width > 0, bounds.height > 0 else { return bounds }
        let scale = min(bounds.width / videoSize.width, bounds.height / videoSize.height)
        let size = CGSize(width: videoSize.width * scale, height: videoSize.height * scale)
        return CGRect(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2,
                      width: size.width, height: size.height)
    }

    /// `point` must be in a top-left-origin coordinate space.
    static func absolute(_ point: CGPoint, in videoRect: CGRect) -> (x: Int, y: Int) {
        let nx = min(max((point.x - videoRect.minX) / videoRect.width, 0), 1)
        let ny = min(max((point.y - videoRect.minY) / videoRect.height, 0), 1)
        return (Int((nx * 32767).rounded()), Int((ny * 32767).rounded()))
    }
}

/// Turns continuous scroll deltas (trackpads) into discrete wheel notches.
struct ScrollAccumulator {
    private var accumulated: CGFloat = 0
    var pointsPerNotch: CGFloat = 24

    mutating func notches(for delta: CGFloat, precise: Bool) -> Int {
        guard precise else { return delta == 0 ? 0 : (delta > 0 ? 1 : -1) }
        accumulated += delta
        let notches = Int(accumulated / pointsPerNotch)
        accumulated -= CGFloat(notches) * pointsPerNotch
        return notches
    }

    mutating func reset() { accumulated = 0 }
}

#if os(macOS)

extension RemoteScreenView: NSViewRepresentable {
    func makeNSView(context: Context) -> MacScreenView {
        MacScreenView(session: session)
    }

    func updateNSView(_ view: MacScreenView, context: Context) {
        view.capturesSystemShortcuts = capturesSystemShortcuts
        view.attach(track: session.videoTrack)
        view.sourceSize = session.sourceSize
    }

    static func dismantleNSView(_ view: MacScreenView, coordinator: ()) {
        view.attach(track: nil)
    }
}

final class MacScreenView: NSView, RTCVideoViewDelegate {
    private let session: KVMSession
    private let videoView = RTCMTLNSVideoView(frame: .zero)
    private var track: RTCVideoTrack?
    private var keyboard = KeyboardState()
    private var buttons = 0
    private var scroll = ScrollAccumulator()
    private var keyMonitor: Any?
    private let interceptor = SystemKeyInterceptor()
    var capturesSystemShortcuts = true { didSet { updateCapture() } }

    /// Frame size from the decoder; falls back to the device-reported HDMI resolution.
    private var videoSize: CGSize = .zero {
        didSet {
            needsLayout = true
            aspectLock.videoSize = videoSize == .zero ? nil : videoSize
        }
    }
    var sourceSize: CGSize = .zero { didSet { if videoSize == .zero { needsLayout = true } } }
    private lazy var aspectLock = WindowAspectLock(view: self)

    init(session: KVMSession) {
        self.session = session
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        videoView.delegate = self
        addSubview(videoView)
        interceptor.handler = { [weak self] event in self?.handleKey(event) }
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        return bounds.contains(local) ? self : nil
    }

    func attach(track newTrack: RTCVideoTrack?) {
        guard newTrack !== track else { return }
        track?.remove(videoView)
        track = newTrack
        newTrack?.add(videoView)
    }

    private var currentVideoRect: CGRect {
        ScreenGeometry.videoRect(videoSize: videoSize == .zero ? sourceSize : videoSize, in: bounds)
    }

    override func layout() {
        super.layout()
        videoView.frame = currentVideoRect
        aspectLock.viewDidLayout()
    }

    func videoView(_ videoView: RTCVideoRenderer, didChangeVideoSize size: CGSize) {
        DispatchQueue.main.async { self.videoSize = size }
    }

    // MARK: Focus

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        removeObservers()
        guard let window else {
            interceptor.stop()
            aspectLock.detach()
            return
        }
        aspectLock.attach(to: window)
        window.makeFirstResponder(self)
        // Fallback when the Accessibility permission isn't granted: a local monitor still sees key
        // events before the menu bar, so ⌘Q, ⌘W, ⌘H... reach the remote machine (but not ⌘Tab/⌘Space).
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp, .flagsChanged]) { [weak self] event in
            guard let self, self.capturesSystemShortcuts,
                  event.window === self.window, self.window?.firstResponder === self else { return event }
            self.handleKey(event)
            return nil
        }
        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(windowKeyChanged), name: NSWindow.didBecomeKeyNotification, object: window)
        center.addObserver(self, selector: #selector(windowKeyChanged), name: NSWindow.didResignKeyNotification, object: window)
        center.addObserver(self, selector: #selector(windowKeyChanged), name: NSApplication.didBecomeActiveNotification, object: nil)
        center.addObserver(self, selector: #selector(windowKeyChanged), name: NSApplication.didResignActiveNotification, object: nil)
        updateCapture()
    }

    private func removeObservers() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        NotificationCenter.default.removeObserver(self)
    }

    deinit {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        interceptor.stop()
        aspectLock.detach()
    }

    @objc private func windowKeyChanged() {
        if window?.isKeyWindow != true { releaseEverything() }
        updateCapture()
    }

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        DispatchQueue.main.async { self.updateCapture() }
        return accepted
    }

    override func resignFirstResponder() -> Bool {
        releaseEverything()
        let resigned = super.resignFirstResponder()
        DispatchQueue.main.async { self.updateCapture() }
        return resigned
    }

    /// The system-wide tap is only on while this view has keyboard focus in the active, key window.
    private func updateCapture() {
        interceptor.isActive = capturesSystemShortcuts
            && NSApp.isActive
            && window?.isKeyWindow == true
            && window?.firstResponder === self
    }

    /// ⌃⌥⌘ held together hands the keyboard back to macOS (click the screen to capture again).
    private func releaseCapture() {
        releaseEverything()
        window?.makeFirstResponder(nil)
    }

    private func releaseEverything() {
        if keyboard.releaseAll() { sendKeyboard() }
        if buttons != 0 {
            buttons = 0
            sendMouse(at: lastMouseLocation)
        }
    }

    // MARK: Keyboard

    override func keyDown(with event: NSEvent) { handleKey(event) }
    override func keyUp(with event: NSEvent) { handleKey(event) }
    override func flagsChanged(with event: NSEvent) { handleKey(event) }

    private func handleKey(_ event: NSEvent) {
        guard let usage = MacKeyMap.hidUsage(for: event.keyCode) else { return }
        switch event.type {
        case .keyDown:
            // The remote OS does its own auto-repeat while the key is held.
            if !event.isARepeat, keyboard.press(usage) { sendKeyboard() }
        case .keyUp:
            if keyboard.release(usage) { sendKeyboard() }
        case .flagsChanged:
            if usage == HIDUsage.capsLock {
                // macOS reports Caps Lock as a toggle, not as press/release.
                _ = keyboard.press(usage); sendKeyboard()
                _ = keyboard.release(usage); sendKeyboard()
            } else if let mask = Self.deviceModifierMask[usage] {
                let isDown = event.modifierFlags.rawValue & mask != 0
                if isDown ? keyboard.press(usage) : keyboard.release(usage) { sendKeyboard() }
                if isDown, keyboard.keys.isEmpty, Self.isReleaseChord(keyboard.modifier) { releaseCapture() }
            }
        default:
            break
        }
    }

    private static func isReleaseChord(_ modifier: UInt8) -> Bool {
        let control = modifier & 0x11 != 0, alt = modifier & 0x44 != 0, meta = modifier & 0x88 != 0
        return control && alt && meta
    }

    /// Device-dependent (left/right specific) bits of NSEvent.modifierFlags, from IOLLEvent.h.
    private static let deviceModifierMask: [UInt8: UInt] = [
        0xE0: 0x0001, 0xE4: 0x2000, // control
        0xE1: 0x0002, 0xE5: 0x0004, // shift
        0xE3: 0x0008, 0xE7: 0x0010, // command → meta
        0xE2: 0x0020, 0xE6: 0x0040, // option → alt
    ]

    private func sendKeyboard() {
        session.sendKeyboard(keys: keyboard.keys, modifier: keyboard.modifier)
    }

    // MARK: Mouse

    private var lastMouseLocation: CGPoint = .zero
    private var trackingArea: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    private func sendMouse(at point: CGPoint) {
        lastMouseLocation = point
        let position = ScreenGeometry.absolute(point, in: currentVideoRect)
        session.sendAbsoluteMouse(x: position.x, y: position.y, buttons: buttons)
    }

    private func location(of event: NSEvent) -> CGPoint {
        convert(event.locationInWindow, from: nil)
    }

    private static func buttonMask(_ event: NSEvent) -> Int {
        switch event.buttonNumber {
        case 0: 1
        case 1: 2
        case 2: 4
        default: 0
        }
    }

    private func press(_ event: NSEvent) {
        if window?.firstResponder !== self { window?.makeFirstResponder(self) }
        buttons |= Self.buttonMask(event)
        sendMouse(at: location(of: event))
    }

    private func release(_ event: NSEvent) {
        buttons &= ~Self.buttonMask(event)
        sendMouse(at: location(of: event))
    }

    override func mouseMoved(with event: NSEvent) { sendMouse(at: location(of: event)) }
    override func mouseDragged(with event: NSEvent) { sendMouse(at: location(of: event)) }
    override func rightMouseDragged(with event: NSEvent) { sendMouse(at: location(of: event)) }
    override func otherMouseDragged(with event: NSEvent) { sendMouse(at: location(of: event)) }
    override func mouseDown(with event: NSEvent) { press(event) }
    override func mouseUp(with event: NSEvent) { release(event) }
    override func rightMouseDown(with event: NSEvent) { press(event) }
    override func rightMouseUp(with event: NSEvent) { release(event) }
    override func otherMouseDown(with event: NSEvent) { press(event) }
    override func otherMouseUp(with event: NSEvent) { release(event) }

    override func scrollWheel(with event: NSEvent) {
        if event.phase == .began { scroll.reset() }
        let notches = scroll.notches(for: event.scrollingDeltaY, precise: event.hasPreciseScrollingDeltas)
        if notches != 0 { session.sendWheel(notches) }
    }
}

#else

extension RemoteScreenView: UIViewRepresentable {
    func makeUIView(context: Context) -> TouchScreenView {
        TouchScreenView(session: session)
    }

    func updateUIView(_ view: TouchScreenView, context: Context) {
        view.attach(track: session.videoTrack)
        view.sourceSize = session.sourceSize
        view.onSoftwareKeyboardDismissed = { showsSoftwareKeyboard.wrappedValue = false }
        view.wantsSoftwareKeyboard = showsSoftwareKeyboard.wrappedValue
    }

    static func dismantleUIView(_ view: TouchScreenView, coordinator: ()) {
        view.attach(track: nil)
    }
}

final class TouchScreenView: UIView, RTCVideoViewDelegate, UIKeyInput, UIGestureRecognizerDelegate {
    let session: KVMSession
    private let videoView = RTCMTLVideoView(frame: .zero)
    private var track: RTCVideoTrack?
    private var keyboard = KeyboardState()
    private var buttons = 0
    private var lastLocation: CGPoint = .zero
    private var scroll = ScrollAccumulator()

    // Zoom: nil shows the whole remote screen; otherwise the rect the video occupies (larger than fit).
    private var zoomedRect: CGRect?
    private var lastBoundsSize: CGSize = .zero
    private static let maxZoom: CGFloat = 6
    private let resetZoomButton = UIButton(type: .system)
    private var pinch: UIPinchGestureRecognizer!
    private var twoFingerPan: UIPanGestureRecognizer!

    // Finger as mouse: the press is held back briefly so a second finger (zoom/pan/right-click)
    // can arrive without the remote machine seeing a click or a drag.
    private var trackedTouch: UITouch?
    private var touchStart: CGPoint = .zero
    private var pendingPress: DispatchWorkItem?
    private var pressSent = false

    // Software keyboard state (see VirtualKeyboard.swift).
    var wantsSoftwareKeyboard = false {
        didSet {
            guard wantsSoftwareKeyboard != oldValue else { return }
            reloadInputViews()
            if wantsSoftwareKeyboard, !isFirstResponder { becomeFirstResponder() }
        }
    }
    var onSoftwareKeyboardDismissed: (() -> Void)?
    /// Ctrl/Alt/Win toggled on the extra-keys bar, applied to the next key then cleared.
    var stickyModifier: UInt8 = 0 { didSet { extraKeysBar.update(sticky: stickyModifier) } }
    private let emptyInputView = UIView(frame: .zero)
    lazy var extraKeysBar = ExtraKeysBar(screen: self)

    override var inputView: UIView? { wantsSoftwareKeyboard ? nil : emptyInputView }
    override var inputAccessoryView: UIView? { wantsSoftwareKeyboard ? extraKeysBar : nil }

    var autocorrectionType: UITextAutocorrectionType = .no
    var autocapitalizationType: UITextAutocapitalizationType = .none
    var spellCheckingType: UITextSpellCheckingType = .no
    var smartQuotesType: UITextSmartQuotesType = .no
    var smartDashesType: UITextSmartDashesType = .no
    var smartInsertDeleteType: UITextSmartInsertDeleteType = .no
    var inlinePredictionType: UITextInlinePredictionType = .no
    var keyboardType: UIKeyboardType = .default
    var returnKeyType: UIReturnKeyType = .default

    private var videoSize: CGSize = .zero { didSet { setNeedsLayout() } }
    var sourceSize: CGSize = .zero { didSet { if videoSize == .zero { setNeedsLayout() } } }

    init(session: KVMSession) {
        self.session = session
        super.init(frame: .zero)
        backgroundColor = .black
        isMultipleTouchEnabled = true
        clipsToBounds = true
        videoView.delegate = self
        videoView.videoContentMode = .scaleToFill
        videoView.isUserInteractionEnabled = false
        addSubview(videoView)

        let hover = UIHoverGestureRecognizer(target: self, action: #selector(hovered(_:)))
        addGestureRecognizer(hover)

        // Trackpad / mouse wheel only: no touch types, so finger drags stay as pointer drags.
        let scrollPan = UIPanGestureRecognizer(target: self, action: #selector(scrolled(_:)))
        scrollPan.allowedScrollTypesMask = .all
        scrollPan.allowedTouchTypes = []
        addGestureRecognizer(scrollPan)

        pinch = UIPinchGestureRecognizer(target: self, action: #selector(pinched(_:)))
        pinch.delegate = self
        addGestureRecognizer(pinch)

        twoFingerPan = UIPanGestureRecognizer(target: self, action: #selector(panned(_:)))
        twoFingerPan.minimumNumberOfTouches = 2
        twoFingerPan.maximumNumberOfTouches = 2
        twoFingerPan.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
        twoFingerPan.delegate = self
        addGestureRecognizer(twoFingerPan)

        let twoFingerDoubleTap = UITapGestureRecognizer(target: self, action: #selector(toggleZoom(_:)))
        twoFingerDoubleTap.numberOfTouchesRequired = 2
        twoFingerDoubleTap.numberOfTapsRequired = 2
        addGestureRecognizer(twoFingerDoubleTap)

        let twoFingerTap = UITapGestureRecognizer(target: self, action: #selector(rightClick(_:)))
        twoFingerTap.numberOfTouchesRequired = 2
        twoFingerTap.require(toFail: twoFingerDoubleTap)
        addGestureRecognizer(twoFingerTap)

        var config = UIButton.Configuration.filled()
        config.image = UIImage(systemName: "arrow.down.right.and.arrow.up.left")
        config.baseBackgroundColor = UIColor.black.withAlphaComponent(0.55)
        config.baseForegroundColor = .white
        config.cornerStyle = .capsule
        resetZoomButton.configuration = config
        resetZoomButton.addAction(UIAction { [weak self] _ in self?.setZoom(nil, animated: true) }, for: .primaryActionTriggered)
        resetZoomButton.isHidden = true
        resetZoomButton.translatesAutoresizingMaskIntoConstraints = false
        addSubview(resetZoomButton)
        NSLayoutConstraint.activate([
            resetZoomButton.topAnchor.constraint(equalTo: safeAreaLayoutGuide.topAnchor, constant: 12),
            resetZoomButton.trailingAnchor.constraint(equalTo: safeAreaLayoutGuide.trailingAnchor, constant: -12),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    func attach(track newTrack: RTCVideoTrack?) {
        guard newTrack !== track else { return }
        track?.remove(videoView)
        track = newTrack
        newTrack?.add(videoView)
    }

    private var fitRect: CGRect {
        ScreenGeometry.videoRect(videoSize: videoSize == .zero ? sourceSize : videoSize, in: bounds)
    }

    private var currentVideoRect: CGRect { zoomedRect ?? fitRect }

    override func layoutSubviews() {
        super.layoutSubviews()
        if bounds.size != lastBoundsSize {
            // Rotation / resize: start again from the whole screen.
            lastBoundsSize = bounds.size
            zoomedRect = nil
        }
        videoView.frame = currentVideoRect
        resetZoomButton.isHidden = zoomedRect == nil
    }

    // MARK: Zoom & pan

    /// Clamps `rect` so the video never leaves empty space on a side it overflows, and centres it
    /// on axes where it's smaller than the view. Back to nil (fit) at 1×.
    private func setZoom(_ rect: CGRect?, animated: Bool = false) {
        let fit = fitRect
        var newRect: CGRect?
        if var rect, rect.width > fit.width + 0.5 {
            for axis in [\CGRect.origin.x, \CGRect.origin.y] {
                let isX = axis == \CGRect.origin.x
                let length = isX ? rect.width : rect.height
                let available = isX ? bounds.width : bounds.height
                let origin = rect[keyPath: axis]
                rect[keyPath: axis] = length > available
                    ? min(max(origin, available - length), 0)
                    : (available - length) / 2
            }
            newRect = rect
        }
        zoomedRect = newRect
        if animated {
            UIView.animate(withDuration: 0.25) { self.setNeedsLayout(); self.layoutIfNeeded() }
        } else {
            setNeedsLayout()
            layoutIfNeeded()
        }
    }

    private func zoom(by factor: CGFloat, around anchor: CGPoint, animated: Bool = false) {
        let rect = currentVideoRect
        let fit = fitRect
        guard rect.width > 0 else { return }
        let width = min(max(rect.width * factor, fit.width), fit.width * Self.maxZoom)
        let scale = width / rect.width
        setZoom(CGRect(x: anchor.x - (anchor.x - rect.minX) * scale,
                       y: anchor.y - (anchor.y - rect.minY) * scale,
                       width: rect.width * scale, height: rect.height * scale), animated: animated)
    }

    @objc private func pinched(_ recognizer: UIPinchGestureRecognizer) {
        cancelFingerMouse()
        guard recognizer.numberOfTouches >= 2 || recognizer.state == .changed else { return }
        zoom(by: recognizer.scale, around: recognizer.location(in: self))
        recognizer.scale = 1
    }

    @objc private func panned(_ recognizer: UIPanGestureRecognizer) {
        cancelFingerMouse()
        let translation = recognizer.translation(in: self)
        recognizer.setTranslation(.zero, in: self)
        guard let rect = zoomedRect else { return }
        setZoom(rect.offsetBy(dx: translation.x, dy: translation.y))
    }

    @objc private func toggleZoom(_ recognizer: UITapGestureRecognizer) {
        if zoomedRect == nil {
            zoom(by: 2.5, around: recognizer.location(in: self), animated: true)
        } else {
            setZoom(nil, animated: true)
        }
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        let zoomGestures: [UIGestureRecognizer] = [pinch, twoFingerPan]
        return zoomGestures.contains(gestureRecognizer) && zoomGestures.contains(other)
    }

    func videoView(_ videoView: RTCVideoRenderer, didChangeVideoSize size: CGSize) {
        DispatchQueue.main.async { self.videoSize = size }
    }

    // MARK: Hardware keyboard

    override var canBecomeFirstResponder: Bool { true }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil { becomeFirstResponder() }
    }

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        var changed = false
        for press in presses {
            if let usage = press.key.flatMap(Self.usage) { changed = keyboard.press(usage) || changed }
        }
        if changed { sendKeyboard() } else { super.pressesBegan(presses, with: event) }
    }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        var changed = false
        for press in presses {
            if let usage = press.key.flatMap(Self.usage) { changed = keyboard.release(usage) || changed }
        }
        if changed { sendKeyboard() } else { super.pressesEnded(presses, with: event) }
    }

    override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        pressesEnded(presses, with: event)
    }

    /// UIKeyboardHIDUsage values are already USB HID usages.
    private static func usage(_ key: UIKey) -> UInt8? {
        let raw = key.keyCode.rawValue
        return raw > 0 && raw <= 0xFF ? UInt8(raw) : nil
    }

    private func sendKeyboard() {
        session.sendKeyboard(keys: keyboard.keys, modifier: keyboard.modifier)
    }

    // MARK: Pointer & touch

    private func sendMouse(at point: CGPoint) {
        lastLocation = point
        let position = ScreenGeometry.absolute(point, in: currentVideoRect)
        session.sendAbsoluteMouse(x: position.x, y: position.y, buttons: buttons)
    }

    private static func buttons(for event: UIEvent?) -> Int {
        guard let mask = event?.buttonMask else { return 1 }
        var buttons = 0
        if mask.contains(.primary) { buttons |= 1 }
        if mask.contains(.secondary) { buttons |= 2 }
        return buttons == 0 ? 1 : buttons
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        if !isFirstResponder { becomeFirstResponder() }
        if (event?.allTouches?.count ?? touches.count) > 1 {
            // A second finger: this is a zoom, pan or right-click, not a mouse action.
            cancelFingerMouse()
            return
        }
        guard trackedTouch == nil, let touch = touches.first else { return }
        trackedTouch = touch
        touchStart = touch.location(in: self)
        if touch.type == .indirectPointer {
            // Trackpad / mouse click on iPad: no ambiguity, press right away.
            pressFinger(at: touchStart, buttons: Self.buttons(for: event))
        } else {
            let work = DispatchWorkItem { [weak self] in
                guard let self, self.trackedTouch === touch else { return }
                self.pressFinger(at: touch.location(in: self), buttons: 1)
            }
            pendingPress = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
        }
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = trackedTouch, touches.contains(touch) else { return }
        let location = touch.location(in: self)
        if pendingPress != nil, hypot(location.x - touchStart.x, location.y - touchStart.y) > 8 {
            pressFinger(at: touchStart, buttons: 1)
        }
        if pressSent { sendMouse(at: location) }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = trackedTouch, touches.contains(touch) else { return }
        let isTap = pendingPress != nil
        if isTap {
            // Quick tap: click where the finger landed.
            pressFinger(at: touchStart, buttons: 1)
        }
        if pressSent {
            buttons = 0
            sendMouse(at: isTap ? touchStart : touch.location(in: self))
        }
        resetFingerMouse()
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = trackedTouch, touches.contains(touch) else { return }
        cancelFingerMouse()
    }

    private func pressFinger(at point: CGPoint, buttons: Int) {
        pendingPress?.cancel()
        pendingPress = nil
        self.buttons = buttons
        pressSent = true
        sendMouse(at: point)
    }

    /// Abandons the current finger: releases the button if the press already went out.
    private func cancelFingerMouse() {
        if pressSent {
            buttons = 0
            sendMouse(at: lastLocation)
        }
        resetFingerMouse()
    }

    private func resetFingerMouse() {
        pendingPress?.cancel()
        pendingPress = nil
        pressSent = false
        trackedTouch = nil
    }

    @objc private func rightClick(_ recognizer: UITapGestureRecognizer) {
        let point = recognizer.location(in: self)
        buttons = 2
        sendMouse(at: point)
        buttons = 0
        sendMouse(at: point)
    }

    @objc private func hovered(_ recognizer: UIHoverGestureRecognizer) {
        guard buttons == 0 else { return }
        sendMouse(at: recognizer.location(in: self))
    }

    @objc private func scrolled(_ recognizer: UIPanGestureRecognizer) {
        if recognizer.state == .began { scroll.reset() }
        let delta = recognizer.translation(in: self).y
        recognizer.setTranslation(.zero, in: self)
        let notches = scroll.notches(for: delta, precise: true)
        if notches != 0 { session.sendWheel(notches) }
    }
}

#endif
