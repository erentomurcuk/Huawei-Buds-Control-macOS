#!/usr/bin/env swift

// Generates Resources/AppIcon.icns for Huawei Audio Control.
//
// Run from the repository root:  swift Tools/make-icon.swift
// The artwork is drawn with Core Graphics so it stays crisp at every size and
// does not depend on SF Symbols (which are not intended for app icons).

import Foundation
import AppKit
import CoreGraphics

// Resolve the repository from this script, not the caller's working directory,
// so `swift /path/to/Tools/make-icon.swift` works from anywhere.
let projectDirectory = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .deletingLastPathComponent()
let resources = projectDirectory.appendingPathComponent("Resources")
let iconset = resources.appendingPathComponent("AppIcon.iconset")
let icns = resources.appendingPathComponent("AppIcon.icns")

try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

// MARK: - Drawing

func rounded(_ rect: CGRect, _ radius: CGFloat) -> CGPath {
    CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
}

func color(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: r, green: g, blue: b, alpha: a)
}

let space = CGColorSpace(name: CGColorSpace.sRGB)!

/// A single earbud as a path, drawn in a top-left origin box of
/// `height` × 0.66·height. The driver is drawn as a separate grille ring.
func budPath(height h: CGFloat) -> CGPath {
    let w = h * 0.66
    let path = CGMutablePath()
    path.addEllipse(in: CGRect(x: 0, y: 0, width: w, height: w * 0.86))
    let stem = CGRect(x: w * 0.37, y: w * 0.56, width: w * 0.26, height: h - w * 0.56)
    path.addRoundedRect(in: stem, cornerWidth: w * 0.13, cornerHeight: w * 0.13)
    path.addEllipse(in: CGRect(x: w * 0.12, y: w * 0.17, width: w * 0.40, height: w * 0.40))
    return path
}

func drawBud(_ context: CGContext, center: CGPoint, height: CGFloat, rotation: CGFloat, mirrored: Bool) {
    let w = height * 0.66

    context.saveGState()
    context.translateBy(x: center.x, y: center.y)
    context.rotate(by: rotation)
    if mirrored { context.scaleBy(x: -1, y: 1) }
    context.translateBy(x: -w / 2, y: -height / 2)

    context.setShadow(offset: CGSize(width: 0, height: height * 0.045),
                      blur: height * 0.09,
                      color: color(0, 0, 0, 0.38))

    // Light vertical gradient makes the flat white shape feel moulded.
    context.saveGState()
    context.addPath(budPath(height: height))
    context.clip()
    let shades = [color(1, 1, 1), color(0.86, 0.93, 1)] as CFArray
    let gradient = CGGradient(colorsSpace: space, colors: shades, locations: [0, 1])!
    context.drawLinearGradient(gradient,
                               start: CGPoint(x: 0, y: 0),
                               end: CGPoint(x: 0, y: height),
                               options: [])
    context.restoreGState()

    // Crisp edge on top of the gradient.
    context.addPath(budPath(height: height))
    context.setStrokeColor(color(1, 1, 1, 0.55))
    context.setLineWidth(max(1, height * 0.006))
    context.strokePath()

    // Speaker grille ring around the cut-out.
    context.setStrokeColor(color(1, 1, 1, 0.30))
    context.setLineWidth(max(1, height * 0.005))
    context.strokeEllipse(in: CGRect(x: w * 0.09, y: w * 0.14,
                                    width: w * 0.46, height: w * 0.46))

    context.restoreGState()
}

func renderIcon(pixels: Int) -> CGImage? {
    let size = CGFloat(pixels)
    guard let context = CGContext(
        data: nil, width: pixels, height: pixels,
        bitsPerComponent: 8, bytesPerRow: 0, space: space,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
    ) else { return nil }

    // Work in a top-left origin coordinate system.
    context.translateBy(x: 0, y: size)
    context.scaleBy(x: 1, y: -1)
    context.setAllowsAntialiasing(true)
    context.interpolationQuality = .high

    let margin = size * 0.098
    let content = CGRect(x: margin, y: margin,
                         width: size - margin * 2, height: size - margin * 2)
    let radius = content.width * 0.2237

    // Soft drop shadow under the squircle.
    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: size * 0.016),
                      blur: size * 0.05,
                      color: color(0, 0, 0, 0.35))
    context.addPath(rounded(content, radius))
    context.setFillColor(color(0.035, 0.07, 0.16))
    context.fillPath()
    context.restoreGState()

    context.saveGState()
    context.addPath(rounded(content, radius))
    context.clip()

    // Background: deep navy → vivid blue.
    let background = [color(0.035, 0.075, 0.17), color(0.055, 0.31, 0.83)] as CFArray
    let gradient = CGGradient(colorsSpace: space, colors: background, locations: [0, 1])!
    context.drawLinearGradient(gradient,
                               start: CGPoint(x: content.minX, y: content.minY),
                               end: CGPoint(x: content.maxX, y: content.maxY),
                               options: [])

    // Cyan glow behind the buds.
    let glowCenter = CGPoint(x: content.midX, y: content.minY + content.height * 0.42)
    let glowColors = [color(0.13, 0.83, 0.93, 0.38), color(0.13, 0.83, 0.93, 0)] as CFArray
    let glow = CGGradient(colorsSpace: space, colors: glowColors, locations: [0, 1])!
    context.drawRadialGradient(glow,
                               startCenter: glowCenter, startRadius: 0,
                               endCenter: glowCenter, endRadius: content.width * 0.56,
                               options: [])

    // Faint concentric rings suggest noise cancelling without clutter.
    context.setStrokeColor(color(1, 1, 1, 0.075))
    context.setLineWidth(max(1, size * 0.0025))
    for scale in [0.34, 0.46] as [CGFloat] {
        let r = content.width * scale
        context.strokeEllipse(in: CGRect(x: content.midX - r, y: content.midY - r,
                                         width: r * 2, height: r * 2))
    }

    // Two mirrored buds, slightly angled outward.
    let budHeight = content.height * 0.55
    let budWidth = budHeight * 0.66
    let gap = content.width * 0.035
    let leftCenter = CGPoint(x: content.midX - gap / 2 - budWidth / 2,
                             y: content.midY + content.height * 0.015)
    let rightCenter = CGPoint(x: content.midX + gap / 2 + budWidth / 2,
                              y: leftCenter.y)

    drawBud(context, center: leftCenter, height: budHeight, rotation: 0.11, mirrored: false)
    drawBud(context, center: rightCenter, height: budHeight, rotation: -0.11, mirrored: true)

    context.restoreGState()
    return context.makeImage()
}

// MARK: - Write assets

func writePNG(_ image: CGImage, to url: URL) throws {
    let rep = NSBitmapImageRep(cgImage: image)
    guard let data = rep.representation(using: .png, properties: [:]) else {
        throw NSError(domain: "Icon", code: 1,
                      userInfo: [NSLocalizedDescriptionKey: "Could not encode PNG"])
    }
    try data.write(to: url)
}

let variants: [(name: String, pixels: Int)] = [
    ("icon_16x16", 16),
    ("icon_16x16@2x", 32),
    ("icon_32x32", 32),
    ("icon_32x32@2x", 64),
    ("icon_128x128", 128),
    ("icon_128x128@2x", 256),
    ("icon_256x256", 256),
    ("icon_256x256@2x", 512),
    ("icon_512x512", 512),
    ("icon_512x512@2x", 1024),
]

for variant in variants {
    guard let image = renderIcon(pixels: variant.pixels) else {
        fatalError("Could not render \(variant.name)")
    }
    try writePNG(image, to: iconset.appendingPathComponent("\(variant.name).png"))
}

if let master = renderIcon(pixels: 1024) {
    try? writePNG(master, to: resources.appendingPathComponent("AppIcon-1024.png"))
}

let process = Process()
process.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
process.arguments = ["-c", "icns", iconset.path, "-o", icns.path]
try process.run()
process.waitUntilExit()
guard process.terminationStatus == 0 else {
    fatalError("iconutil failed with status \(process.terminationStatus)")
}

print("Wrote \(icns.path)")
