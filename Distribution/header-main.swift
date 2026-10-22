
// Header composition, appended to the demo sources by render-header.sh.
import ImageIO
import UniformTypeIdentifiers

nonisolated(unsafe) var renderScale: CGFloat = 1

@main enum Header {
    static func main() {
        let arguments = CommandLine.arguments
        let size = CGSize(width: Double(arguments[1])!, height: Double(arguments[2])!)
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let context = CGContext(data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8, bytesPerRow: 0,
                                space: space, bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!

        // Brand background (y-up): dark base, teal and blue glows.
        context.setFillColor(.rgb(0x0B0D14))
        context.fill(CGRect(origin: .zero, size: size))
        let unit = size.height
        for (center, radius, color) in [(CGPoint(x: size.width * 0.80, y: size.height * 0.95), unit * 1.0, CGColor.rgb(0x5EEBD4, alpha: 0.30)),
                                        (CGPoint(x: size.width * 0.15, y: size.height * 0.05), unit * 1.1, CGColor.rgb(0x618CFA, alpha: 0.32))] {
            let glow = CGGradient(colorsSpace: space, colors: [color, color.copy(alpha: 0)!] as CFArray, locations: [0, 1])!
            context.drawRadialGradient(glow, startCenter: center, startRadius: 0, endCenter: center, endRadius: radius, options: [])
        }

        // The remote screen, centered: about 62% of the height.
        let screenHeight = size.height * 0.62
        renderScale = screenHeight / DemoDesktop.size.height
        var desktop = DemoDesktop()
        for _ in 0..<24 { desktop.tick() }
        desktop.cursorVisible = true
        desktop.terminal.input = "neofetch"
        desktop.terminal.enter()
        let screen = DemoScreen.render(desktop)!
        let frame = CGRect(x: (size.width - screenHeight * 16 / 9) / 2, y: (size.height - screenHeight) / 2,
                           width: screenHeight * 16 / 9, height: screenHeight)
        let bezel = frame.insetBy(dx: -unit * 0.012, dy: -unit * 0.012)
        let corner = unit * 0.022

        context.saveGState()
        context.setShadow(offset: CGSize(width: 0, height: -unit * 0.03), blur: unit * 0.08, color: .rgb(0x000000, alpha: 0.65))
        context.addPath(CGPath(roundedRect: bezel, cornerWidth: corner, cornerHeight: corner, transform: nil))
        context.setFillColor(.rgb(0x05070C))
        context.fillPath()
        context.restoreGState()
        context.addPath(CGPath(roundedRect: bezel, cornerWidth: corner, cornerHeight: corner, transform: nil))
        context.setStrokeColor(.rgb(0xFFFFFF, alpha: 0.10))
        context.setLineWidth(unit * 0.0015)
        context.strokePath()

        context.saveGState()
        context.addPath(CGPath(roundedRect: frame, cornerWidth: corner * 0.5, cornerHeight: corner * 0.5, transform: nil))
        context.clip()
        context.interpolationQuality = .high
        context.draw(screen, in: frame)
        context.restoreGState()

        let destination = CGImageDestinationCreateWithURL(URL(fileURLWithPath: arguments[3]) as CFURL, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, nil)
        CGImageDestinationFinalize(destination)
        print("✓", arguments[3])
    }
}
