#if os(macOS)
import Carbon.HIToolbox

/// macOS virtual key codes (kVK_*) → USB HID keyboard usages. Positional, so the remote
/// machine applies its own layout (AZERTY stays AZERTY if the host is set to AZERTY).
enum MacKeyMap {
    static func hidUsage(for keyCode: UInt16) -> UInt8? {
        // Apple ISO keyboards (e.g. Belgian/French AZERTY) report these two keys swapped
        // compared to their physical position on a PC keyboard.
        if isISOKeyboard {
            if Int(keyCode) == kVK_ISO_Section { return 0x35 }
            if Int(keyCode) == kVK_ANSI_Grave { return 0x64 }
        }
        return table[Int(keyCode)]
    }

    private static var isISOKeyboard: Bool {
        KBGetLayoutType(Int16(LMGetKbdType())) == kKeyboardISO
    }

    private static let table: [Int: UInt8] = [
        kVK_ANSI_A: 0x04, kVK_ANSI_B: 0x05, kVK_ANSI_C: 0x06, kVK_ANSI_D: 0x07,
        kVK_ANSI_E: 0x08, kVK_ANSI_F: 0x09, kVK_ANSI_G: 0x0A, kVK_ANSI_H: 0x0B,
        kVK_ANSI_I: 0x0C, kVK_ANSI_J: 0x0D, kVK_ANSI_K: 0x0E, kVK_ANSI_L: 0x0F,
        kVK_ANSI_M: 0x10, kVK_ANSI_N: 0x11, kVK_ANSI_O: 0x12, kVK_ANSI_P: 0x13,
        kVK_ANSI_Q: 0x14, kVK_ANSI_R: 0x15, kVK_ANSI_S: 0x16, kVK_ANSI_T: 0x17,
        kVK_ANSI_U: 0x18, kVK_ANSI_V: 0x19, kVK_ANSI_W: 0x1A, kVK_ANSI_X: 0x1B,
        kVK_ANSI_Y: 0x1C, kVK_ANSI_Z: 0x1D,
        kVK_ANSI_1: 0x1E, kVK_ANSI_2: 0x1F, kVK_ANSI_3: 0x20, kVK_ANSI_4: 0x21,
        kVK_ANSI_5: 0x22, kVK_ANSI_6: 0x23, kVK_ANSI_7: 0x24, kVK_ANSI_8: 0x25,
        kVK_ANSI_9: 0x26, kVK_ANSI_0: 0x27,
        kVK_Return: 0x28, kVK_Escape: 0x29, kVK_Delete: 0x2A, kVK_Tab: 0x2B, kVK_Space: 0x2C,
        kVK_ANSI_Minus: 0x2D, kVK_ANSI_Equal: 0x2E, kVK_ANSI_LeftBracket: 0x2F,
        kVK_ANSI_RightBracket: 0x30, kVK_ANSI_Backslash: 0x31, kVK_ANSI_Semicolon: 0x33,
        kVK_ANSI_Quote: 0x34, kVK_ANSI_Grave: 0x35, kVK_ANSI_Comma: 0x36, kVK_ANSI_Period: 0x37,
        kVK_ANSI_Slash: 0x38, kVK_CapsLock: 0x39,
        kVK_F1: 0x3A, kVK_F2: 0x3B, kVK_F3: 0x3C, kVK_F4: 0x3D, kVK_F5: 0x3E, kVK_F6: 0x3F,
        kVK_F7: 0x40, kVK_F8: 0x41, kVK_F9: 0x42, kVK_F10: 0x43, kVK_F11: 0x44, kVK_F12: 0x45,
        kVK_F13: 0x68, kVK_F14: 0x69, kVK_F15: 0x6A, kVK_F16: 0x6B, kVK_F17: 0x6C,
        kVK_F18: 0x6D, kVK_F19: 0x6E, kVK_F20: 0x6F,
        kVK_Help: 0x49, kVK_Home: 0x4A, kVK_PageUp: 0x4B, kVK_ForwardDelete: 0x4C,
        kVK_End: 0x4D, kVK_PageDown: 0x4E,
        kVK_RightArrow: 0x4F, kVK_LeftArrow: 0x50, kVK_DownArrow: 0x51, kVK_UpArrow: 0x52,
        kVK_ANSI_KeypadClear: 0x53, kVK_ANSI_KeypadDivide: 0x54, kVK_ANSI_KeypadMultiply: 0x55,
        kVK_ANSI_KeypadMinus: 0x56, kVK_ANSI_KeypadPlus: 0x57, kVK_ANSI_KeypadEnter: 0x58,
        kVK_ANSI_Keypad1: 0x59, kVK_ANSI_Keypad2: 0x5A, kVK_ANSI_Keypad3: 0x5B,
        kVK_ANSI_Keypad4: 0x5C, kVK_ANSI_Keypad5: 0x5D, kVK_ANSI_Keypad6: 0x5E,
        kVK_ANSI_Keypad7: 0x5F, kVK_ANSI_Keypad8: 0x60, kVK_ANSI_Keypad9: 0x61,
        kVK_ANSI_Keypad0: 0x62, kVK_ANSI_KeypadDecimal: 0x63, kVK_ANSI_KeypadEquals: 0x67,
        kVK_ISO_Section: 0x64,
        kVK_JIS_Yen: 0x89, kVK_JIS_Underscore: 0x87, kVK_JIS_Eisu: 0x91, kVK_JIS_Kana: 0x90,
        kVK_Control: 0xE0, kVK_Shift: 0xE1, kVK_Option: 0xE2, kVK_Command: 0xE3,
        kVK_RightControl: 0xE4, kVK_RightShift: 0xE5, kVK_RightOption: 0xE6, kVK_RightCommand: 0xE7,
    ]
}
#endif
