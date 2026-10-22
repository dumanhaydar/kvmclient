import Foundation

/// Character → keystroke tables for the remote machine's keyboard layout, generated from
/// xkeyboard-config's PC layouts by Tools/generate-keyboard-layouts.py. Used to type text
/// (virtual keyboard, paste) so the remote OS produces exactly the intended characters.
struct KeyboardLayout: Decodable {
    struct Stroke: Decodable {
        let k: UInt8
        let s: Int?
        let a: Int?
        /// Dead key: the remote waits for a following key, so Space is sent to emit the character alone.
        let d: Int?
        /// Accent typed before the base key (e.g. ^ then e for ê).
        let acc: Accent?

        var modifier: UInt8 { Self.modifier(shift: s == 1, altRight: a == 1) }

        static func modifier(shift: Bool, altRight: Bool) -> UInt8 {
            (shift ? 1 << (HIDUsage.leftShift - 0xE0) : 0) | (altRight ? 1 << (HIDUsage.rightAlt - 0xE0) : 0)
        }
    }

    struct Accent: Decodable {
        let k: UInt8
        let s: Int?
        let a: Int?
        var modifier: UInt8 { Stroke.modifier(shift: s == 1, altRight: a == 1) }
    }

    let name: String
    let chars: [String: Stroke]
    /// Set on duplicate entries kept for device codes (e.g. "nl-BE" → "fr-BE").
    let alias: String?

    /// The key presses (usage + modifier byte) needed to type `character`, or nil if unsupported.
    func strokes(for character: Character) -> [(usage: UInt8, modifier: UInt8)]? {
        let key = character == "\r\n" || character == "\r" ? "\n" : String(character)
        guard let stroke = chars[key] else { return nil }
        var strokes: [(UInt8, UInt8)] = []
        if let accent = stroke.acc { strokes.append((accent.k, accent.modifier)) }
        strokes.append((stroke.k, stroke.modifier))
        if stroke.d == 1 { strokes.append((0x2C, 0)) }
        return strokes
    }

    static let all: [String: KeyboardLayout] = {
        guard let url = Bundle.main.url(forResource: "KeyboardLayouts", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let layouts = try? JSONDecoder().decode([String: KeyboardLayout].self, from: data) else { return [:] }
        return layouts
    }()

    /// Sorted (code, name) pairs for pickers.
    static var choices: [(code: String, name: String)] {
        all.filter { $0.value.alias == nil }.map { ($0.key, $0.value.name) }.sorted { $0.name < $1.name }
    }

    /// The layout matching the user's language and region (fr-BE, de-CH…), else en-US.
    static var localeDefault: String {
        let language = Locale.current.language.languageCode?.identifier ?? "en"
        let code = "\(language)-\(Locale.current.region?.identifier ?? "")"
        if let layout = all[code] { return layout.alias ?? code }
        return all.keys.sorted().first { $0.hasPrefix(language + "-") && all[$0]?.alias == nil } ?? "en-US"
    }

    /// Accepts the device's codes ("en_US", "fr-BE") and falls back to US English.
    static func named(_ code: String?) -> KeyboardLayout? {
        let normalized = (code ?? "").replacingOccurrences(of: "_", with: "-")
        return all[normalized] ?? all["en-US"]
    }
}

extension KVMSession {
    /// Types `text` on the remote machine using its keyboard layout. Each key is pressed and
    /// released, waiting for the device to acknowledge, so characters arrive in order.
    func type(_ text: String, extraModifier: UInt8 = 0) {
        let layout = KeyboardLayout.named(keyboardLayout)
        let strokes = text.flatMap { layout?.strokes(for: $0) ?? [] }
        guard !strokes.isEmpty else { return }
        enqueueTyping(strokes.map { ($0.usage, $0.modifier | extraModifier) })
    }
}
