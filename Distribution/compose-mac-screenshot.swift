// Places a captured window on a branded 1440×900 canvas with a caption (App Store Mac size).
//
//   swift Distribution/compose-mac-screenshot.swift <window.png> "<caption>" <out.png>
import CoreGraphics
import CoreText
import Foundation
import ImageIO
import UniformTypeIdentifiers

let arguments = CommandLine.arguments
guard arguments.count == 4,
      let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: arguments[1]) as CFURL, nil),
      let window = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
    print("usage: compose-mac-screenshot.swift <window.png> <caption> <out.png>")
    exit(1)
}
let caption = arguments[2]
let size = CGSize(width: 1440, height: 900)
let space = CGColorSpace(name: CGColorSpace.sRGB)!
func rgb(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

let context = CGContext(data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8, bytesPerRow: 0,
                        space: space, bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!

// Background: the brand's dark base with teal and blue glows (y-up coordinates).
context.setFillColor(rgb(0x0B0D14))
context.fill(CGRect(origin: .zero, size: size))
for (center, radius, color) in [(CGPoint(x: 1240, y: 820), 760.0, rgb(0x5EEBD4, 0.28)),
                                (CGPoint(x: 160, y: 60), 820.0, rgb(0x618CFA, 0.30))] {
    let glow = CGGradient(colorsSpace: space, colors: [color, color.copy(alpha: 0)!] as CFArray, locations: [0, 1])!
    context.drawRadialGradient(glow, startCenter: center, startRadius: 0, endCenter: center, endRadius: radius, options: [])
}

// Caption.
let font = CTFontCreateUIFontForLanguage(.emphasizedSystem, 40, nil)!
let attributes: [NSAttributedString.Key: Any] = [
    NSAttributedString.Key(kCTFontAttributeName as String): font,
    NSAttributedString.Key(kCTForegroundColorAttributeName as String): rgb(0xF4F7FB),
]
let line = CTLineCreateWithAttributedString(NSAttributedString(string: caption, attributes: attributes))
let textWidth = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
context.textPosition = CGPoint(x: (size.width - textWidth) / 2, y: size.height - 86)
CTLineDraw(line, context)

// Window, scaled to fit under the caption.
let area = CGSize(width: size.width - 120, height: size.height - 190)
let scale = min(area.width / CGFloat(window.width), area.height / CGFloat(window.height), 1)
let drawn = CGSize(width: CGFloat(window.width) * scale, height: CGFloat(window.height) * scale)
let frame = CGRect(x: (size.width - drawn.width) / 2, y: (area.height - drawn.height) / 2 + 44, width: drawn.width, height: drawn.height)
context.saveGState()
context.setShadow(offset: CGSize(width: 0, height: -24), blur: 60, color: rgb(0x000000, 0.6))
context.addPath(CGPath(roundedRect: frame, cornerWidth: 12, cornerHeight: 12, transform: nil))
context.setFillColor(rgb(0x000000))
context.fillPath()
context.restoreGState()
context.saveGState()
context.addPath(CGPath(roundedRect: frame, cornerWidth: 12, cornerHeight: 12, transform: nil))
context.clip()
context.interpolationQuality = .high
context.draw(window, in: frame)
context.restoreGState()

let destination = CGImageDestinationCreateWithURL(URL(fileURLWithPath: arguments[3]) as CFURL, UTType.png.identifier as CFString, 1, nil)!
CGImageDestinationAddImage(destination, context.makeImage()!, nil)
CGImageDestinationFinalize(destination)
