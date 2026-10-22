import CoreGraphics
import Foundation

/// A KVM that doesn't exist: renders a fake Linux server desktop and reacts to the keyboard and
/// mouse like a real remote machine would. Lets people (and App Review) try the app without
/// hardware, and is what the App Store screenshots show.
@MainActor
final class DemoDriver: KVMDriver {
    weak var delegate: KVMDriverDelegate?

    private let stream = FrameStream()
    private var desktop = DemoDesktop()
    private var pressedKeys: Set<UInt8> = []
    private var buttons = 0
    private var characters: [CharacterKey: Character] = [:]
    private var ticker: Task<Void, Never>?

    private let renderQueue = DispatchQueue(label: "kvmclient.demo.render", qos: .userInteractive)
    private var isRendering = false
    private var needsRender = false

    private struct CharacterKey: Hashable {
        let usage: UInt8
        let shift: Bool
        let altGr: Bool
    }

    init(keyboardLayout: String?) {
        setKeyboardLayout(keyboardLayout ?? "en-US")
        if let command = Screenshots.demoCommand {
            desktop.terminal.input = command
            desktop.terminal.enter()
        }
    }

    func connect(credentials: Credentials) async throws {
        delegate?.driver(progress: "Connexion à l'appareil de démonstration…")
        try? await Task.sleep(for: .milliseconds(500))
        delegate?.driver(video: .frames(stream))
        delegate?.driver(sourceSize: DemoDesktop.size)
        delegate?.driverDidConnect()
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                self?.desktop.tick()
                self?.render()
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
    }

    func disconnect() {
        ticker?.cancel()
        ticker = nil
    }

    // MARK: Rendering

    /// Coalesced: at most one frame in flight, the latest state wins.
    private func render() {
        guard !isRendering else { needsRender = true; return }
        isRendering = true
        let snapshot = desktop
        renderQueue.async { [stream, weak self] in
            if let image = DemoScreen.render(snapshot) { stream.pushImage(image) }
            Task { @MainActor in self?.renderDidFinish() }
        }
    }

    private func renderDidFinish() {
        isRendering = false
        if needsRender {
            needsRender = false
            render()
        }
    }

    // MARK: Input

    func sendKeyboard(keys: [UInt8], modifier: UInt8) {
        let shift = modifier & 0x22 != 0, control = modifier & 0x11 != 0, altGr = modifier & 0x40 != 0
        for usage in keys where !pressedKeys.contains(usage) {
            switch usage {
            case 0x28, 0x58: desktop.terminal.enter()
            case 0x2A: desktop.terminal.backspace()
            case 0x06 where control: desktop.terminal.interrupt()      // ⌃C
            case 0x0F where control: desktop.terminal.clear()          // ⌃L
            case 0x18 where control: desktop.terminal.input = ""       // ⌃U
            default:
                guard !control else { break }
                if let character = characters[CharacterKey(usage: usage, shift: shift, altGr: altGr)] {
                    desktop.terminal.type(character)
                }
            }
        }
        pressedKeys = Set(keys)
        desktop.cursorVisible = true
        render()
    }

    func sendAbsoluteMouse(x: Int, y: Int, buttons: Int) {
        let point = CGPoint(x: CGFloat(x) / 32767 * DemoDesktop.size.width,
                            y: CGFloat(y) / 32767 * DemoDesktop.size.height)
        let wasDown = self.buttons & 1 != 0, isDown = buttons & 1 != 0
        self.buttons = buttons
        desktop.pointer = point
        if isDown && !wasDown { desktop.press(at: point) }
        if isDown && wasDown { desktop.drag(to: point) }
        if !isDown && wasDown { desktop.release() }
        render()
    }

    func sendWheel(_ delta: Int) {
        desktop.scroll(delta)
        render()
    }

    func setKeyboardLayout(_ code: String) {
        characters = [:]
        guard let layout = KeyboardLayout.named(code) else { return }
        for (string, stroke) in layout.chars where stroke.acc == nil && stroke.d == nil {
            guard let character = string.first, string.count == 1, character != "\n", character != "\t" else { continue }
            characters[CharacterKey(usage: stroke.k, shift: stroke.s == 1, altGr: stroke.a == 1)] = character
        }
    }
}

// MARK: - Desktop model

struct DemoDesktop {
    static let size = CGSize(width: 1920, height: 1080)
    static let topBarHeight: CGFloat = 36
    static let titleBarHeight: CGFloat = 40

    enum WindowID { case terminal, monitor }

    struct Window {
        let id: WindowID
        let title: String
        var frame: CGRect
        var isVisible = true

        var titleBar: CGRect { CGRect(x: frame.minX, y: frame.minY, width: frame.width, height: DemoDesktop.titleBarHeight) }
        var closeButton: CGRect { CGRect(x: frame.maxX - 36, y: frame.minY + 8, width: 24, height: 24) }
        var body: CGRect {
            CGRect(x: frame.minX, y: frame.minY + DemoDesktop.titleBarHeight,
                   width: frame.width, height: frame.height - DemoDesktop.titleBarHeight)
        }
    }

    struct DockItem {
        let window: WindowID?
        let symbol: String
        let colors: (CGColor, CGColor)
        var frame: CGRect
    }

    /// Back to front.
    var windows: [Window] = [
        Window(id: .monitor, title: "System Monitor", frame: CGRect(x: 1150, y: 150, width: 640, height: 440)),
        Window(id: .terminal, title: "admin@homelab-01: ~", frame: CGRect(x: 130, y: 110, width: 1000, height: 640)),
    ]
    var terminal = DemoTerminal()
    var pointer = CGPoint(x: 1360, y: 760)
    var cursorVisible = true
    var cpu: [Double] = (0..<60).map { 14 + 8 * sin(Double($0) / 4) + Double($0 % 7) }
    var memory = 6.4
    var download = 12.4
    var upload = 1.1
    var time: Double = 0
    private var dragging: (id: WindowID, offset: CGSize)?

    var dock: [DockItem] {
        let items: [(WindowID?, String, (CGColor, CGColor))] = [
            (.terminal, ">_", (.rgb(0x2B3240), .rgb(0x11151C))),
            (.monitor, "◔", (.rgb(0x2FBF9B), .rgb(0x177E7A))),
            (nil, "▤", (.rgb(0x5B8CFA), .rgb(0x3557C9))),
            (nil, "⚙", (.rgb(0x8A93A6), .rgb(0x596173))),
        ]
        let side: CGFloat = 60, gap: CGFloat = 16
        let width = CGFloat(items.count) * side + CGFloat(items.count - 1) * gap
        let x0 = (Self.size.width - width) / 2, y = Self.size.height - side - 22
        return items.enumerated().map { index, item in
            DockItem(window: item.0, symbol: item.1, colors: item.2,
                     frame: CGRect(x: x0 + CGFloat(index) * (side + gap), y: y, width: side, height: side))
        }
    }

    mutating func tick() {
        time += 0.25
        let next = 16 + 9 * sin(time / 2.3) + 5 * sin(time * 1.7) + Double.random(in: -3...3)
        cpu.append(min(max(next, 2), 98))
        cpu.removeFirst(cpu.count - 60)
        memory = 6.4 + 0.3 * sin(time / 9)
        download = max(0.2, 12 + 6 * sin(time / 1.9) + Double.random(in: -2...2))
        upload = max(0.1, 1.1 + 0.6 * sin(time / 2.7))
        cursorVisible = Int(time * 2) % 2 == 0
    }

    // MARK: Mouse

    mutating func press(at point: CGPoint) {
        if let item = dock.first(where: { $0.frame.contains(point) }), let id = item.window {
            if let index = windows.firstIndex(where: { $0.id == id }) {
                windows[index].isVisible = true
                bringToFront(index)
            }
            return
        }
        guard let index = windows.lastIndex(where: { $0.isVisible && $0.frame.contains(point) }) else { return }
        if windows[index].closeButton.contains(point) {
            windows[index].isVisible = false
            return
        }
        let window = windows[index]
        bringToFront(index)
        if window.titleBar.contains(point) {
            dragging = (window.id, CGSize(width: point.x - window.frame.minX, height: point.y - window.frame.minY))
        }
    }

    mutating func drag(to point: CGPoint) {
        guard let dragging, let index = windows.firstIndex(where: { $0.id == dragging.id }) else { return }
        var origin = CGPoint(x: point.x - dragging.offset.width, y: point.y - dragging.offset.height)
        origin.y = min(max(origin.y, Self.topBarHeight), Self.size.height - Self.titleBarHeight)
        origin.x = min(max(origin.x, 80 - windows[index].frame.width), Self.size.width - 80)
        windows[index].frame.origin = origin
    }

    mutating func release() {
        dragging = nil
    }

    mutating func scroll(_ delta: Int) {
        guard let terminalWindow = windows.last(where: { $0.isVisible && $0.frame.contains(pointer) }),
              terminalWindow.id == .terminal else { return }
        terminal.scroll(by: delta)
    }

    private mutating func bringToFront(_ index: Int) {
        windows.append(windows.remove(at: index))
    }
}

// MARK: - Terminal

struct DemoTerminal {
    struct Line {
        var prompt = false
        var text: String
    }

    static let prompt = "admin@homelab-01:~$ "

    var lines: [Line] = [
        Line(text: "Welcome to the KVM Client demo. Type \"help\" and press Return."),
        Line(text: ""),
        Line(prompt: true, text: "uptime"),
        Line(text: " 14:32:07 up 41 days,  3:12,  1 user,  load average: 0.21, 0.18, 0.12"),
        Line(prompt: true, text: "df -h /"),
        Line(text: "Filesystem      Size  Used Avail Use% Mounted on"),
        Line(text: "/dev/nvme0n1p2  932G  214G  671G  25% /"),
        Line(prompt: true, text: "systemctl status nginx --no-pager | head -3"),
        Line(text: "● nginx.service - A high performance web server"),
        Line(text: "     Loaded: loaded (/lib/systemd/system/nginx.service; enabled)"),
        Line(text: "     Active: active (running) since Mon 2026-09-08 11:20:41 UTC"),
        Line(prompt: true, text: "docker ps --format \"{{.Names}}: {{.Status}}\""),
        Line(text: "jellyfin: Up 12 days"),
        Line(text: "home-assistant: Up 12 days"),
        Line(text: "nextcloud: Up 12 days"),
    ]
    var input = ""
    /// Lines scrolled back from the bottom.
    var scrollOffset = 0

    mutating func type(_ character: Character) {
        guard input.count < 70 else { return }
        input.append(character)
        scrollOffset = 0
    }

    mutating func backspace() {
        if !input.isEmpty { input.removeLast() }
    }

    mutating func interrupt() {
        lines.append(Line(prompt: true, text: input + "^C"))
        input = ""
        scrollOffset = 0
    }

    mutating func clear() {
        lines = []
        scrollOffset = 0
    }

    mutating func scroll(by delta: Int) {
        scrollOffset = min(max(scrollOffset + delta, 0), max(lines.count - 4, 0))
    }

    mutating func enter() {
        let command = input.trimmingCharacters(in: .whitespaces)
        lines.append(Line(prompt: true, text: input))
        input = ""
        scrollOffset = 0
        if command == "clear" { return clear() }
        lines += Self.output(for: command).map { Line(text: $0) }
        if lines.count > 500 { lines.removeFirst(lines.count - 500) }
    }

    private static func output(for command: String) -> [String] {
        switch command {
        case "": return []
        case "help":
            return ["Commands: help, ls, whoami, uname -a, uptime, date, df -h, free -h, neofetch, clear",
                    "Drag a window by its title bar; scroll here to see earlier output."]
        case "ls": return ["backups  docker-compose.yml  media  notes.txt  scripts"]
        case "whoami": return ["admin"]
        case "uname", "uname -a": return ["Linux homelab-01 6.8.0-45-generic #45-Ubuntu SMP PREEMPT_DYNAMIC x86_64 GNU/Linux"]
        case "uptime": return [" \(clock()) up 41 days,  3:14,  1 user,  load average: 0.17, 0.16, 0.11"]
        case "date": return [Date().formatted(.dateTime.weekday().day().month().year().hour().minute().second())]
        case "df", "df -h":
            return ["Filesystem      Size  Used Avail Use% Mounted on",
                    "/dev/nvme0n1p2  932G  214G  671G  25% /",
                    "/dev/sda1       7.3T  4.1T  2.9T  59% /srv/media"]
        case "free", "free -h":
            return ["               total        used        free      shared  buff/cache   available",
                    "Mem:            31Gi       6.4Gi        18Gi       312Mi       6.9Gi        24Gi",
                    "Swap:          4.0Gi          0B       4.0Gi"]
        case "neofetch":
            return ["admin@homelab-01",
                    "----------------",
                    "OS: Ubuntu 24.04.1 LTS x86_64",
                    "Kernel: 6.8.0-45-generic",
                    "Uptime: 41 days, 3 hours",
                    "CPU: AMD Ryzen 7 5700G (16) @ 4.6GHz",
                    "Memory: 6528MiB / 31958MiB"]
        case "exit", "logout": return ["This is a demo: there is nowhere to log out to."]
        default:
            return ["bash: \(command.split(separator: " ").first ?? ""): command not found"]
        }
    }

    private static func clock() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter.string(from: Date())
    }
}

extension CGColor {
    static func rgb(_ hex: UInt32, alpha: CGFloat = 1) -> CGColor {
        CGColor(srgbRed: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
    }
}
