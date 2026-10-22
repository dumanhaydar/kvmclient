#if os(macOS)
import AppKit
import ApplicationServices

/// HID-level CGEventTap that swallows every keyboard event while active, including the ones macOS
/// normally keeps for itself (⌘Tab, ⌘Space, Mission Control, ⌃←/→...), and hands them to `handler`.
/// Requires the Accessibility permission; without it the tap simply doesn't start.
///
/// The Mac App Store build is sandboxed and never installs the tap. Instead, while active, it turns
/// off app switching through the presentation options, so ⌘Tab arrives as a normal key event
/// (⌘Space and Mission Control still go to macOS).
final class SystemKeyInterceptor {
    var handler: ((NSEvent) -> Void)?

    private var tap: CFMachPort?
    private var source: CFRunLoopSource?

    var isActive = false {
        didSet {
            guard isActive != oldValue else { return }
            if isActive { startIfNeeded() }
            if let tap { CGEvent.tapEnable(tap: tap, enable: isActive) }
            updatePresentationOptions()
        }
    }

    private var addedOptions: NSApplication.PresentationOptions = []

    /// True once the tap is installed, i.e. system shortcuts are really being captured.
    var isRunning: Bool { tap != nil }

    static var isTrusted: Bool { AXIsProcessTrusted() }

    /// App Store build: no Accessibility, no event tap.
    static let isSandboxed = ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] != nil

    /// Shows the system prompt pointing to Privacy & Security › Accessibility.
    static func requestTrust() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        AXIsProcessTrustedWithOptions(options)
    }

    private func startIfNeeded() {
        guard tap == nil, !Self.isSandboxed, Self.isTrusted else { return }
        let types: [CGEventType] = [.keyDown, .keyUp, .flagsChanged]
        let mask = types.reduce(CGEventMask(0)) { $0 | (1 << $1.rawValue) }
        guard let tap = CGEvent.tapCreate(
            tap: .cghidEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: { _, type, event, refcon in
                guard let refcon else { return Unmanaged.passUnretained(event) }
                let interceptor = Unmanaged<SystemKeyInterceptor>.fromOpaque(refcon).takeUnretainedValue()
                return interceptor.handle(type: type, event: event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            print("[keys] CGEventTap creation failed")
            return
        }
        self.tap = tap
        source = CFMachPortCreateRunLoopSource(nil, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
    }

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap, isActive { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        guard isActive, let nsEvent = NSEvent(cgEvent: event) else { return Unmanaged.passUnretained(event) }
        handler?(nsEvent)
        return nil
    }

    /// Without the tap, keep ⌘Tab and ⌘H inside the app. Only flags we added are removed again,
    /// so full screen keeps its own options; disabling app switching requires a hidden Dock.
    private func updatePresentationOptions() {
        var options = NSApp.presentationOptions
        options.subtract(addedOptions)
        addedOptions = []
        if isActive && tap == nil {
            var wanted: NSApplication.PresentationOptions = [.disableProcessSwitching, .disableHideApplication]
            if !options.contains(.hideDock) && !options.contains(.autoHideDock) { wanted.insert(.autoHideDock) }
            addedOptions = wanted.subtracting(options)
            options.formUnion(wanted)
        }
        if options != NSApp.presentationOptions { NSApp.presentationOptions = options }
    }

    func stop() {
        isActive = false
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        if let tap { CFMachPortInvalidate(tap) }
        source = nil
        tap = nil
    }

    deinit { stop() }
}
#endif
