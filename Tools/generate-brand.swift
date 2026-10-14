#!/usr/bin/env swift
// Renders the KVM Client mark, app icons and README artwork with CoreGraphics, so every size
// comes from the same geometry. Run from the repository root:
//     swift Tools/generate-brand.swift

import AppKit
import CoreGraphics
import Foundation

// MARK: - Geometry

/// The mark: one monoline stroke with round caps reading K-V-M. A stem, the K's arm meeting it,
/// the leg running down into a V and back up into the M's last stem.
/// Units: 225 × 120 box (stroke centre lines), stroke 34.
enum Mark {
    static let size = CGSize(width: 225, height: 120)
    static let stroke: CGFloat = 34

    static func path(in rect: CGRect) -> CGPath {
        let sx = rect.width / size.width, sy = rect.height / size.height
        // Design coordinates are y-down; CoreGraphics is y-up.
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: rect.minX + x * sx, y: rect.maxY - y * sy) }
        let path = CGMutablePath()
        // Stem of the K.
        path.move(to: p(0, 0))
        path.addLine(to: p(0, 120))
        // Arm, from the top down into the stem…
        path.move(to: p(108, 0))
        path.addLine(to: p(0, 72))
        // …then the leg dives into the V and climbs into the M's stem.
        path.move(to: p(14, 63))
        path.addLine(to: p(112, 120))
        path.addLine(to: p(225, 0))
        path.addLine(to: p(225, 120))
        return path
    }

    /// Bounding box including the stroke, for a mark of centre-line width `width`.
    static func outerSize(width: CGFloat) -> CGSize {
        let scale = width / size.width
        return CGSize(width: width + stroke * scale, height: size.height * scale + stroke * scale)
    }
}

// MARK: - Palette

struct Palette {
    static let backgroundTop = CGColor(red: 0.11, green: 0.13, blue: 0.19, alpha: 1)
    static let backgroundBottom = CGColor(red: 0.04, green: 0.05, blue: 0.08, alpha: 1)
    static let markStart = CGColor(red: 0.37, green: 0.92, blue: 0.83, alpha: 1)   // teal
    static let markEnd = CGColor(red: 0.38, green: 0.55, blue: 0.98, alpha: 1)     // blue
    static let glow = CGColor(red: 0.30, green: 0.75, blue: 0.95, alpha: 0.35)
}

let space = CGColorSpace(name: CGColorSpace.sRGB)!

func gradient(_ colors: [CGColor]) -> CGGradient {
    CGGradient(colorsSpace: space, colors: colors as CFArray, locations: nil)!
}

// MARK: - Drawing

/// Draws the mark centred in `rect`, `width` wide (centre lines), filled with the brand gradient
/// or a flat colour.
func drawMark(_ ctx: CGContext, center: CGPoint, width: CGFloat, color: CGColor? = nil, glow: Bool = false) {
    let scale = width / Mark.size.width
    let rect = CGRect(x: center.x - width / 2, y: center.y - Mark.size.height * scale / 2,
                      width: width, height: Mark.size.height * scale)
    let path = Mark.path(in: rect)
    let lineWidth = Mark.stroke * scale

    ctx.saveGState()
    if glow {
        ctx.setShadow(offset: .zero, blur: lineWidth * 1.4, color: Palette.glow)
    }
    ctx.addPath(path)
    ctx.setLineWidth(lineWidth)
    ctx.setLineCap(.round)
    ctx.setLineJoin(.round)
    if let color {
        ctx.setStrokeColor(color)
        ctx.strokePath()
    } else {
        ctx.replacePathWithStrokedPath()
        ctx.clip()
        let outer = Mark.outerSize(width: width)
        ctx.drawLinearGradient(gradient([Palette.markStart, Palette.markEnd]),
                               start: CGPoint(x: center.x - outer.width / 2, y: center.y + outer.height / 2),
                               end: CGPoint(x: center.x + outer.width / 2, y: center.y - outer.height / 2),
                               options: [])
    }
    ctx.restoreGState()
}

func drawBackground(_ ctx: CGContext, rect: CGRect, cornerRadius: CGFloat) {
    let shape = CGPath(roundedRect: rect, cornerWidth: cornerRadius, cornerHeight: cornerRadius, transform: nil)
    ctx.saveGState()
    ctx.addPath(shape)
    ctx.clip()
    ctx.drawLinearGradient(gradient([Palette.backgroundTop, Palette.backgroundBottom]),
                           start: CGPoint(x: rect.midX, y: rect.maxY), end: CGPoint(x: rect.midX, y: rect.minY), options: [])
    // Soft light from above, like a lit screen.
    ctx.drawRadialGradient(gradient([CGColor(red: 0.35, green: 0.6, blue: 1, alpha: 0.16), CGColor(red: 0, green: 0, blue: 0, alpha: 0)]),
                           startCenter: CGPoint(x: rect.midX, y: rect.maxY), startRadius: 0,
                           endCenter: CGPoint(x: rect.midX, y: rect.maxY), endRadius: rect.height * 0.9, options: [])
    ctx.restoreGState()
    // Hairline edge.
    ctx.saveGState()
    ctx.addPath(shape)
    ctx.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.08))
    ctx.setLineWidth(max(1, rect.width / 512))
    ctx.strokePath()
    ctx.restoreGState()
}

func render(width: Int, height: Int, _ draw: (CGContext) -> Void) -> Data {
    let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                        space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.interpolationQuality = .high
    draw(ctx)
    let image = ctx.makeImage()!
    return NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])!
}

func write(_ data: Data, _ path: String) {
    let url = URL(fileURLWithPath: path)
    try! FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try! data.write(to: url)
    print("wrote", path)
}

// MARK: - Outputs

let iconSet = "KVMUI/Assets.xcassets/AppIcon.appiconset"

/// iOS: full-bleed square, the system applies its own mask.
write(render(width: 1024, height: 1024) { ctx in
    drawBackground(ctx, rect: CGRect(x: 0, y: 0, width: 1024, height: 1024), cornerRadius: 0)
    drawMark(ctx, center: CGPoint(x: 512, y: 512), width: 560, glow: true)
}, "\(iconSet)/icon-ios-1024.png")

/// macOS: rounded square inset in the canvas with a drop shadow (Big Sur grid: 824 pt on 1024).
func macIcon(_ pixels: Int) -> Data {
    render(width: pixels, height: pixels) { ctx in
        let s = CGFloat(pixels) / 1024
        ctx.scaleBy(x: s, y: s)
        let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 24, color: CGColor(red: 0, green: 0, blue: 0, alpha: 0.35))
        ctx.addPath(CGPath(roundedRect: tile, cornerWidth: 185, cornerHeight: 185, transform: nil))
        ctx.setFillColor(Palette.backgroundBottom)
        ctx.fillPath()
        ctx.restoreGState()
        drawBackground(ctx, rect: tile, cornerRadius: 185)
        drawMark(ctx, center: CGPoint(x: 512, y: 512), width: 450, glow: pixels >= 128)
    }
}
for (points, scales) in [(16, [1, 2]), (32, [1, 2]), (128, [1, 2]), (256, [1, 2]), (512, [1, 2])] {
    for scale in scales {
        write(macIcon(points * scale), "\(iconSet)/icon-mac-\(points)@\(scale)x.png")
    }
}

/// README artwork.
write(macIcon(512), "assets/icon.png")
write(render(width: 1280, height: 640) { ctx in
    drawBackground(ctx, rect: CGRect(x: 0, y: 0, width: 1280, height: 640), cornerRadius: 0)
    drawMark(ctx, center: CGPoint(x: 640, y: 390), width: 330, glow: true)
    let title = NSAttributedString(string: "KVM Client", attributes: [
        .font: NSFont.systemFont(ofSize: 64, weight: .semibold),
        .foregroundColor: NSColor.white,
    ])
    let subtitle = NSAttributedString(string: "Native macOS, iPadOS & iOS client for IP-KVMs", attributes: [
        .font: NSFont.systemFont(ofSize: 28, weight: .regular),
        .foregroundColor: NSColor(white: 1, alpha: 0.6),
    ])
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
    title.draw(at: CGPoint(x: 640 - title.size().width / 2, y: 130))
    subtitle.draw(at: CGPoint(x: 640 - subtitle.size().width / 2, y: 82))
    NSGraphicsContext.restoreGraphicsState()
}, "assets/social-preview.png")

// SVG versions of the mark for the README (crisp, themable).
func svgPath() -> String {
    "M17 17V137 M125 17L17 89 M31 80L129 137L242 17V137"
}
let svgSize = "viewBox=\"0 0 259 154\""
let svgStroke = "fill=\"none\" stroke-width=\"34\" stroke-linecap=\"round\" stroke-linejoin=\"round\""
for (name, color) in [("logo-light", "#0B0D14"), ("logo-dark", "#FFFFFF")] {
    let svg = """
    <svg xmlns="http://www.w3.org/2000/svg" \(svgSize) width="259" height="154">
      <path d="\(svgPath())" stroke="\(color)" \(svgStroke)/>
    </svg>
    """
    write(Data(svg.utf8), "assets/\(name).svg")
}
let gradientSVG = """
<svg xmlns="http://www.w3.org/2000/svg" \(svgSize) width="259" height="154">
  <defs>
    <linearGradient id="g" x1="0" y1="1" x2="1" y2="0">
      <stop offset="0" stop-color="#5EEBD4"/>
      <stop offset="1" stop-color="#618CFA"/>
    </linearGradient>
  </defs>
  <path d="\(svgPath())" stroke="url(#g)" \(svgStroke)/>
</svg>
"""
write(Data(gradientSVG.utf8), "assets/logo.svg")
