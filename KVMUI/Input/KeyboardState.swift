import Foundation

/// Tracks pressed keys and builds boot-protocol keyboard reports (up to 6 keys + modifier byte).
/// Modifiers use their HID usages 0xE0...0xE7, which map 1:1 onto the modifier bits.
struct KeyboardState {
    private(set) var keys: [UInt8] = []
    private(set) var modifier: UInt8 = 0

    static func isModifier(_ usage: UInt8) -> Bool { (0xE0...0xE7).contains(usage) }

    /// Returns true when the report changed.
    mutating func press(_ usage: UInt8) -> Bool {
        if Self.isModifier(usage) {
            let bit: UInt8 = 1 << (usage - 0xE0)
            guard modifier & bit == 0 else { return false }
            modifier |= bit
            return true
        }
        guard !keys.contains(usage) else { return false }
        if keys.count == 6 { keys.removeFirst() }
        keys.append(usage)
        return true
    }

    mutating func release(_ usage: UInt8) -> Bool {
        if Self.isModifier(usage) {
            let bit: UInt8 = 1 << (usage - 0xE0)
            guard modifier & bit != 0 else { return false }
            modifier &= ~bit
            return true
        }
        guard let index = keys.firstIndex(of: usage) else { return false }
        keys.remove(at: index)
        return true
    }

    mutating func releaseAll() -> Bool {
        let changed = !keys.isEmpty || modifier != 0
        keys = []
        modifier = 0
        return changed
    }
}

enum HIDUsage {
    static let capsLock: UInt8 = 0x39
    static let delete: UInt8 = 0x4C
    static let escape: UInt8 = 0x29
    static let tab: UInt8 = 0x2B
    static let backspace: UInt8 = 0x2A
    static let leftControl: UInt8 = 0xE0
    static let leftShift: UInt8 = 0xE1
    static let leftAlt: UInt8 = 0xE2
    static let leftMeta: UInt8 = 0xE3
    static let rightAlt: UInt8 = 0xE6
}

/// Predefined combos sent as a press followed by a release.
struct KeyCombo: Identifiable {
    let id: String
    let title: String
    let usages: [UInt8]

    static let all: [KeyCombo] = [
        KeyCombo(id: "cad", title: String(localized: "Ctrl + Alt + Delete"), usages: [HIDUsage.leftControl, HIDUsage.leftAlt, HIDUsage.delete]),
        KeyCombo(id: "cab", title: String(localized: "Ctrl + Alt + Backspace"), usages: [HIDUsage.leftControl, HIDUsage.leftAlt, HIDUsage.backspace]),
        KeyCombo(id: "alttab", title: "Alt + Tab", usages: [HIDUsage.leftAlt, HIDUsage.tab]),
        KeyCombo(id: "meta", title: String(localized: "Windows / Super Key"), usages: [HIDUsage.leftMeta]),
        KeyCombo(id: "esc", title: String(localized: "Escape"), usages: [HIDUsage.escape]),
    ]
}

extension KVMSession {
    func send(_ combo: KeyCombo) {
        var state = KeyboardState()
        for usage in combo.usages { _ = state.press(usage) }
        sendKeyboard(keys: state.keys, modifier: state.modifier)
        sendKeyboard(keys: [], modifier: 0)
    }
}
