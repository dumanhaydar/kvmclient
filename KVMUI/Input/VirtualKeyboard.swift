#if os(iOS)
import UIKit

/// On-screen keyboard input: characters are typed through the remote layout table so the remote
/// OS produces exactly the character tapped, whatever its keyboard layout.
extension TouchScreenView {
    var hasText: Bool { true } // keeps Backspace enabled

    func insertText(_ text: String) {
        session.type(text, extraModifier: consumeSticky())
    }

    func deleteBackward() {
        tapKey(HIDUsage.backspace)
    }

    func tapKey(_ usage: UInt8) {
        session.enqueueTyping([(usage, consumeSticky())])
    }

    private func consumeSticky() -> UInt8 {
        let modifier = stickyModifier
        if modifier != 0 { stickyModifier = 0 }
        return modifier
    }

    func toggleSticky(_ bit: UInt8) {
        stickyModifier ^= bit
    }

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned, wantsSoftwareKeyboard {
            wantsSoftwareKeyboard = false
            onSoftwareKeyboardDismissed?()
        }
        return resigned
    }
}

/// Keys missing from the iOS keyboard: Esc, Tab, sticky modifiers, arrows, navigation and F-keys.
final class ExtraKeysBar: UIInputView {
    private weak var screen: TouchScreenView?
    private var modifierButtons: [(bit: UInt8, button: UIButton)] = []

    private static let modifiers: [(title: String, bit: UInt8)] = [
        ("Ctrl", 0x01), ("Alt", 0x04), ("Win", 0x08),
    ]

    private static let functionKeys: [(title: String, usage: UInt8)] = (0..<12).map { index in
        (title: "F\(index + 1)", usage: UInt8(0x3A + index))
    }

    private static let keys: [(title: String, usage: UInt8)] = [
        ("Esc", 0x29), ("Tab", 0x2B), ("←", 0x50), ("↑", 0x52), ("↓", 0x51), ("→", 0x4F),
        (String(localized: "Del"), 0x4C), (String(localized: "Home"), 0x4A), (String(localized: "End"), 0x4D), ("PgUp", 0x4B), ("PgDn", 0x4E),
    ] + functionKeys

    init(screen: TouchScreenView) {
        self.screen = screen
        super.init(frame: CGRect(x: 0, y: 0, width: 0, height: 48), inputViewStyle: .keyboard)
        allowsSelfSizing = false

        let stack = UIStackView()
        stack.axis = .horizontal
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false

        for modifier in Self.modifiers {
            let button = makeButton(modifier.title) { [weak self] in self?.screen?.toggleSticky(modifier.bit) }
            modifierButtons.append((modifier.bit, button))
            stack.addArrangedSubview(button)
        }
        for key in Self.keys {
            stack.addArrangedSubview(makeButton(key.title) { [weak self] in self?.screen?.tapKey(key.usage) })
        }

        let scroll = UIScrollView()
        scroll.showsHorizontalScrollIndicator = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(stack)

        let hide = UIButton(type: .system, primaryAction: UIAction(image: UIImage(systemName: "keyboard.chevron.compact.down")) { [weak self] _ in
            _ = self?.screen?.resignFirstResponder()
            self?.screen?.becomeFirstResponder() // keep receiving hardware keys and touches
        })
        hide.translatesAutoresizingMaskIntoConstraints = false

        addSubview(scroll)
        addSubview(hide)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            scroll.topAnchor.constraint(equalTo: topAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            scroll.trailingAnchor.constraint(equalTo: hide.leadingAnchor, constant: -8),
            hide.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            hide.centerYAnchor.constraint(equalTo: centerYAnchor),
            stack.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor),
            stack.centerYAnchor.constraint(equalTo: scroll.frameLayoutGuide.centerYAnchor),
            stack.heightAnchor.constraint(equalToConstant: 36),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    func update(sticky: UInt8) {
        for (bit, button) in modifierButtons {
            button.configuration?.baseBackgroundColor = sticky & bit != 0 ? .tintColor : Self.keyBackground
            button.configuration?.baseForegroundColor = sticky & bit != 0 ? .white : .label
        }
    }

    /// Opaque, like the keys of the system keyboard: the bar floats over the black remote screen.
    private static let keyBackground = UIColor { $0.userInterfaceStyle == .dark ? .systemGray4 : .white }

    private func makeButton(_ title: String, action: @escaping () -> Void) -> UIButton {
        var config = UIButton.Configuration.filled()
        config.title = title
        config.baseBackgroundColor = Self.keyBackground
        config.baseForegroundColor = .label
        config.cornerStyle = .medium
        config.contentInsets = NSDirectionalEdgeInsets(top: 4, leading: 10, bottom: 4, trailing: 10)
        return UIButton(configuration: config, primaryAction: UIAction { _ in action() })
    }
}
#endif
