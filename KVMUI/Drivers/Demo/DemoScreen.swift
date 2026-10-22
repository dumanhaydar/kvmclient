import CoreGraphics
import CoreText
import Foundation

/// Draws a `DemoDesktop` into a 1920×1080 image, the way an HDMI capture would see it.
/// Coordinates are top-left based, like the desktop model.
enum DemoScreen {
    private static let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    private static let mono = CTFontCreateWithName("Menlo" as CFString, 17, nil)
    private static let monoBold = CTFontCreateCopyWithSymbolicTraits(mono, 0, nil, .traitBold, .traitBold) ?? mono
    private static func ui(_ size: CGFloat, bold: Bool = false) -> CTFont {
        CTFontCreateUIFontForLanguage(bold ? .emphasizedSystem : .system, size, nil)!
    }

    private static let clockFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("EEEdMMMHHmm")
        return formatter
    }()

    static func render(_ desktop: DemoDesktop) -> CGImage? {
        let size = DemoDesktop.size
        guard let context = CGContext(data: nil, width: Int(size.width), height: Int(size.height),
                                      bitsPerComponent: 8, bytesPerRow: 0, space: colorSpace,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return nil }
        context.translateBy(x: 0, y: size.height)
        context.scaleBy(x: 1, y: -1)
        context.textMatrix = CGAffineTransform(scaleX: 1, y: -1)

        drawWallpaper(context, size: size)
        for window in desktop.windows where window.isVisible {
            drawWindow(context, window, desktop: desktop)
        }
        drawTopBar(context, size: size, desktop: desktop)
        drawDock(context, desktop: desktop)
        drawPointer(context, at: desktop.pointer)
        return context.makeImage()
    }

    // MARK: Desktop

    private static func drawWallpaper(_ context: CGContext, size: CGSize) {
        let base = CGGradient(colorsSpace: colorSpace, colors: [CGColor.rgb(0x0A0F1E), .rgb(0x0E2A40), .rgb(0x0B1424)] as CFArray,
                              locations: [0, 0.55, 1])!
        context.drawLinearGradient(base, start: .zero, end: CGPoint(x: size.width, y: size.height), options: [])
        for (center, radius, color) in [(CGPoint(x: 1500, y: 860), 900.0, CGColor.rgb(0x5EEBD4, alpha: 0.16)),
                                        (CGPoint(x: 300, y: 980), 800.0, CGColor.rgb(0x618CFA, alpha: 0.18)),
                                        (CGPoint(x: 1700, y: 80), 600.0, CGColor.rgb(0x618CFA, alpha: 0.10))] {
            let glow = CGGradient(colorsSpace: colorSpace, colors: [color, color.copy(alpha: 0)!] as CFArray, locations: [0, 1])!
            context.drawRadialGradient(glow, startCenter: center, startRadius: 0, endCenter: center, endRadius: radius, options: [])
        }
    }

    private static func drawTopBar(_ context: CGContext, size: CGSize, desktop: DemoDesktop) {
        let bar = CGRect(x: 0, y: 0, width: size.width, height: DemoDesktop.topBarHeight)
        context.setFillColor(.rgb(0x000000, alpha: 0.55))
        context.fill(bar)
        let white = CGColor.rgb(0xF2F5FA), dim = CGColor.rgb(0xAAB3C5)
        draw(context, "homelab-01", at: CGPoint(x: 22, y: 24), font: ui(15, bold: true), color: white)
        draw(context, "Activities", at: CGPoint(x: 140, y: 24), font: ui(15), color: dim)
        let clock = clockFormatter.string(from: Date())
        draw(context, clock, at: CGPoint(x: size.width / 2, y: 24), font: ui(15, bold: true), color: white, align: .center)
        let status = String(format: "CPU %.0f%%     ↓ %.1f MB/s     192.168.1.42", desktop.cpu.last ?? 0, desktop.download)
        draw(context, status, at: CGPoint(x: size.width - 22, y: 24), font: ui(14), color: dim, align: .right)
    }

    private static func drawDock(_ context: CGContext, desktop: DemoDesktop) {
        let items = desktop.dock
        guard let first = items.first, let last = items.last else { return }
        let plate = CGRect(x: first.frame.minX - 14, y: first.frame.minY - 12,
                           width: last.frame.maxX - first.frame.minX + 28, height: first.frame.height + 24)
        context.addPath(CGPath(roundedRect: plate, cornerWidth: 22, cornerHeight: 22, transform: nil))
        context.setFillColor(.rgb(0x0B0F18, alpha: 0.55))
        context.fillPath()
        for item in items {
            context.saveGState()
            context.addPath(CGPath(roundedRect: item.frame, cornerWidth: 14, cornerHeight: 14, transform: nil))
            context.clip()
            let gradient = CGGradient(colorsSpace: colorSpace, colors: [item.colors.0, item.colors.1] as CFArray, locations: [0, 1])!
            context.drawLinearGradient(gradient, start: CGPoint(x: item.frame.midX, y: item.frame.minY),
                                       end: CGPoint(x: item.frame.midX, y: item.frame.maxY), options: [])
            context.restoreGState()
            draw(context, item.symbol, at: CGPoint(x: item.frame.midX, y: item.frame.midY + 10),
                 font: item.symbol == ">_" ? monoBold : ui(28, bold: true), color: .rgb(0xFFFFFF), align: .center)
            if let id = item.window, desktop.windows.contains(where: { $0.id == id && $0.isVisible }) {
                context.setFillColor(.rgb(0xFFFFFF, alpha: 0.8))
                context.fillEllipse(in: CGRect(x: item.frame.midX - 3, y: item.frame.maxY + 5, width: 6, height: 6))
            }
        }
    }

    // MARK: Windows

    private static func drawWindow(_ context: CGContext, _ window: DemoDesktop.Window, desktop: DemoDesktop) {
        let isFront = desktop.windows.last(where: \.isVisible)?.id == window.id
        let shape = CGPath(roundedRect: window.frame, cornerWidth: 12, cornerHeight: 12, transform: nil)

        context.saveGState()
        context.setShadow(offset: CGSize(width: 0, height: -18), blur: isFront ? 60 : 36,
                          color: .rgb(0x000000, alpha: isFront ? 0.55 : 0.4))
        context.addPath(shape)
        context.setFillColor(window.id == .terminal ? .rgb(0x0E1117) : .rgb(0x141922))
        context.fillPath()
        context.restoreGState()

        context.saveGState()
        context.addPath(shape)
        context.clip()
        context.setFillColor(isFront ? .rgb(0x262C38) : .rgb(0x1E232D))
        context.fill(window.titleBar)
        context.restoreGState()

        draw(context, window.title, at: CGPoint(x: window.titleBar.midX, y: window.titleBar.minY + 26),
             font: ui(15, bold: true), color: isFront ? .rgb(0xE8ECF3) : .rgb(0x8E97A8), align: .center)
        let close = window.closeButton
        context.setFillColor(.rgb(0xFFFFFF, alpha: 0.08))
        context.fillEllipse(in: close)
        context.setStrokeColor(.rgb(0xC9D0DC))
        context.setLineWidth(2)
        context.setLineCap(.round)
        context.strokeLineSegments(between: [CGPoint(x: close.minX + 8, y: close.minY + 8), CGPoint(x: close.maxX - 8, y: close.maxY - 8),
                                             CGPoint(x: close.maxX - 8, y: close.minY + 8), CGPoint(x: close.minX + 8, y: close.maxY - 8)])

        context.addPath(shape)
        context.setStrokeColor(.rgb(0xFFFFFF, alpha: 0.10))
        context.setLineWidth(1)
        context.strokePath()

        context.saveGState()
        context.clip(to: window.body)
        switch window.id {
        case .terminal: drawTerminal(context, in: window.body, terminal: desktop.terminal, cursor: desktop.cursorVisible)
        case .monitor: drawMonitor(context, in: window.body, desktop: desktop)
        }
        context.restoreGState()
    }

    private static func drawTerminal(_ context: CGContext, in rect: CGRect, terminal: DemoTerminal, cursor: Bool) {
        let lineHeight: CGFloat = 25, padding: CGFloat = 18
        let capacity = Int((rect.height - padding * 2) / lineHeight)
        var lines = terminal.lines + [DemoTerminal.Line(prompt: true, text: terminal.input)]
        let end = lines.count - terminal.scrollOffset
        lines = Array(lines[max(0, end - capacity)..<end])
        let green = CGColor.rgb(0x5EEBA0), blue = CGColor.rgb(0x7AA2FF), text = CGColor.rgb(0xD5DBE5)
        for (index, line) in lines.enumerated() {
            let baseline = CGPoint(x: rect.minX + padding, y: rect.minY + padding + CGFloat(index + 1) * lineHeight - 6)
            var x = baseline.x
            if line.prompt {
                x += draw(context, "admin@homelab-01", at: CGPoint(x: x, y: baseline.y), font: monoBold, color: green)
                x += draw(context, ":", at: CGPoint(x: x, y: baseline.y), font: mono, color: text)
                x += draw(context, "~", at: CGPoint(x: x, y: baseline.y), font: monoBold, color: blue)
                x += draw(context, "$ ", at: CGPoint(x: x, y: baseline.y), font: mono, color: text)
            }
            x += draw(context, line.text, at: CGPoint(x: x, y: baseline.y), font: mono, color: text)
            let isInputLine = terminal.scrollOffset == 0 && index == lines.count - 1
            if isInputLine && cursor {
                context.setFillColor(.rgb(0xD5DBE5, alpha: 0.85))
                context.fill(CGRect(x: x + 1, y: baseline.y - 16, width: 10, height: 21))
            }
        }
    }

    private static func drawMonitor(_ context: CGContext, in rect: CGRect, desktop: DemoDesktop) {
        let inner = rect.insetBy(dx: 26, dy: 22)
        let label = CGColor.rgb(0x8E97A8), value = CGColor.rgb(0xE8ECF3)
        let teal = CGColor.rgb(0x5EEBD4), blue = CGColor.rgb(0x618CFA)

        draw(context, "CPU", at: CGPoint(x: inner.minX, y: inner.minY + 16), font: ui(15, bold: true), color: label)
        draw(context, String(format: "%.0f%%", desktop.cpu.last ?? 0), at: CGPoint(x: inner.maxX, y: inner.minY + 16),
             font: ui(15, bold: true), color: value, align: .right)
        let graph = CGRect(x: inner.minX, y: inner.minY + 30, width: inner.width, height: 170)
        context.setFillColor(.rgb(0xFFFFFF, alpha: 0.04))
        context.fill(graph)
        context.setStrokeColor(.rgb(0xFFFFFF, alpha: 0.06))
        context.setLineWidth(1)
        for step in 1..<4 {
            let y = graph.minY + graph.height * CGFloat(step) / 4
            context.strokeLineSegments(between: [CGPoint(x: graph.minX, y: y), CGPoint(x: graph.maxX, y: y)])
        }
        let points = desktop.cpu.enumerated().map { index, sample in
            CGPoint(x: graph.minX + graph.width * CGFloat(index) / CGFloat(desktop.cpu.count - 1),
                    y: graph.maxY - graph.height * CGFloat(sample) / 100)
        }
        let line = CGMutablePath()
        line.addLines(between: points)
        let area = line.mutableCopy()!
        area.addLine(to: CGPoint(x: graph.maxX, y: graph.maxY))
        area.addLine(to: CGPoint(x: graph.minX, y: graph.maxY))
        area.closeSubpath()
        context.saveGState()
        context.addPath(area)
        context.clip()
        let fill = CGGradient(colorsSpace: colorSpace, colors: [teal.copy(alpha: 0.45)!, teal.copy(alpha: 0.02)!] as CFArray, locations: [0, 1])!
        context.drawLinearGradient(fill, start: CGPoint(x: 0, y: graph.minY), end: CGPoint(x: 0, y: graph.maxY), options: [])
        context.restoreGState()
        context.addPath(line)
        context.setStrokeColor(teal)
        context.setLineWidth(2.5)
        context.setLineJoin(.round)
        context.strokePath()

        var y = graph.maxY + 44
        draw(context, "Memory", at: CGPoint(x: inner.minX, y: y), font: ui(15, bold: true), color: label)
        draw(context, String(format: "%.1f GB of 32 GB", desktop.memory), at: CGPoint(x: inner.maxX, y: y),
             font: ui(15), color: value, align: .right)
        bar(context, CGRect(x: inner.minX, y: y + 12, width: inner.width, height: 10), fraction: desktop.memory / 32, color: blue)

        y += 58
        draw(context, "Storage", at: CGPoint(x: inner.minX, y: y), font: ui(15, bold: true), color: label)
        draw(context, "4.3 TB of 8.2 TB", at: CGPoint(x: inner.maxX, y: y), font: ui(15), color: value, align: .right)
        bar(context, CGRect(x: inner.minX, y: y + 12, width: inner.width, height: 10), fraction: 4.3 / 8.2, color: teal)

        y += 58
        draw(context, "Network", at: CGPoint(x: inner.minX, y: y), font: ui(15, bold: true), color: label)
        draw(context, String(format: "↓ %.1f MB/s    ↑ %.1f MB/s", desktop.download, desktop.upload),
             at: CGPoint(x: inner.maxX, y: y), font: ui(15), color: value, align: .right)
    }

    private static func bar(_ context: CGContext, _ rect: CGRect, fraction: Double, color: CGColor) {
        context.addPath(CGPath(roundedRect: rect, cornerWidth: 5, cornerHeight: 5, transform: nil))
        context.setFillColor(.rgb(0xFFFFFF, alpha: 0.08))
        context.fillPath()
        var filled = rect
        filled.size.width *= CGFloat(min(max(fraction, 0), 1))
        context.addPath(CGPath(roundedRect: filled, cornerWidth: 5, cornerHeight: 5, transform: nil))
        context.setFillColor(color)
        context.fillPath()
    }

    // MARK: Pointer

    private static func drawPointer(_ context: CGContext, at point: CGPoint) {
        let shape: [CGPoint] = [(0, 0), (0, 25), (6, 19.5), (10.5, 29), (14.5, 27), (10.2, 18), (18, 18)]
            .map { CGPoint(x: point.x + $0.0 * 1.2, y: point.y + $0.1 * 1.2) }
        let path = CGMutablePath()
        path.addLines(between: shape)
        path.closeSubpath()
        context.saveGState()
        context.setShadow(offset: CGSize(width: 0, height: -2), blur: 4, color: .rgb(0x000000, alpha: 0.5))
        context.addPath(path)
        context.setFillColor(.rgb(0x000000))
        context.fillPath()
        context.restoreGState()
        context.addPath(path)
        context.setFillColor(.rgb(0xFFFFFF))
        context.setStrokeColor(.rgb(0x000000))
        context.setLineWidth(1.6)
        context.setLineJoin(.round)
        context.drawPath(using: .fillStroke)
    }

    // MARK: Text

    private enum Alignment { case left, center, right }

    /// Draws `text` with its baseline at `point`; returns its width.
    @discardableResult
    private static func draw(_ context: CGContext, _ text: String, at point: CGPoint, font: CTFont, color: CGColor, align: Alignment = .left) -> CGFloat {
        guard !text.isEmpty else { return 0 }
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): color,
        ]
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
        let width = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
        let x = switch align {
        case .left: point.x
        case .center: point.x - width / 2
        case .right: point.x - width
        }
        context.textPosition = CGPoint(x: x, y: point.y)
        CTLineDraw(line, context)
        return width
    }
}
