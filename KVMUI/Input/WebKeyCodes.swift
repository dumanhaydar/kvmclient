import Foundation

/// HID usage → JavaScript `KeyboardEvent.code` name, for firmwares that take key names
/// (PiKVM, TinyPilot). Positional, like the HID usages themselves.
enum WebKeyCodes {
    static func code(for usage: UInt8) -> String? { table[usage] }

    private static let table: [UInt8: String] = {
        var table: [UInt8: String] = [:]
        for (index, letter) in "ABCDEFGHIJKLMNOPQRSTUVWXYZ".enumerated() {
            table[UInt8(0x04 + index)] = "Key\(letter)"
        }
        for digit in 1...9 { table[UInt8(0x1E + digit - 1)] = "Digit\(digit)" }
        table[0x27] = "Digit0"
        for number in 1...12 { table[UInt8(0x3A + number - 1)] = "F\(number)" }
        for number in 13...24 { table[UInt8(0x68 + number - 13)] = "F\(number)" }
        for digit in 1...9 { table[UInt8(0x59 + digit - 1)] = "Numpad\(digit)" }
        table[0x62] = "Numpad0"
        let named: [UInt8: String] = [
            0x28: "Enter", 0x29: "Escape", 0x2A: "Backspace", 0x2B: "Tab", 0x2C: "Space",
            0x2D: "Minus", 0x2E: "Equal", 0x2F: "BracketLeft", 0x30: "BracketRight", 0x31: "Backslash",
            0x32: "IntlHash", 0x33: "Semicolon", 0x34: "Quote", 0x35: "Backquote", 0x36: "Comma",
            0x37: "Period", 0x38: "Slash", 0x39: "CapsLock",
            0x46: "PrintScreen", 0x47: "ScrollLock", 0x48: "Pause", 0x49: "Insert", 0x4A: "Home",
            0x4B: "PageUp", 0x4C: "Delete", 0x4D: "End", 0x4E: "PageDown",
            0x4F: "ArrowRight", 0x50: "ArrowLeft", 0x51: "ArrowDown", 0x52: "ArrowUp",
            0x53: "NumLock", 0x54: "NumpadDivide", 0x55: "NumpadMultiply", 0x56: "NumpadSubtract",
            0x57: "NumpadAdd", 0x58: "NumpadEnter", 0x63: "NumpadDecimal", 0x64: "IntlBackslash",
            0x65: "ContextMenu", 0x66: "Power", 0x67: "NumpadEqual",
            0x87: "IntlRo", 0x88: "KanaMode", 0x89: "IntlYen", 0x8A: "Convert", 0x8B: "NonConvert",
            0xE0: "ControlLeft", 0xE1: "ShiftLeft", 0xE2: "AltLeft", 0xE3: "MetaLeft",
            0xE4: "ControlRight", 0xE5: "ShiftRight", 0xE6: "AltRight", 0xE7: "MetaRight",
        ]
        table.merge(named) { $1 }
        return table
    }()
}

/// Turns successive full keyboard reports into individual key down/up transitions, for
/// firmwares that take key events rather than reports.
struct KeyTransitionTracker {
    private var pressed: Set<UInt8> = []

    /// Usages released first, then pressed, so modifiers are down before the key they modify.
    mutating func update(keys: [UInt8], modifier: UInt8) -> (released: [UInt8], pressed: [UInt8]) {
        var now = Set(keys)
        for bit in 0..<8 where modifier & (1 << bit) != 0 { now.insert(0xE0 + UInt8(bit)) }
        let released = pressed.subtracting(now).sorted()
        let newlyPressed = now.subtracting(pressed).sorted { lhs, rhs in
            // modifiers (0xE0...) first
            KeyboardState.isModifier(lhs) != KeyboardState.isModifier(rhs) ? KeyboardState.isModifier(lhs) : lhs < rhs
        }
        pressed = now
        return (released, newlyPressed)
    }

    var currentlyPressed: Set<UInt8> { pressed }
}
