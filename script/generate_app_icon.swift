#!/usr/bin/env swift

import AppKit
import CoreGraphics
import Foundation

private let canvasSize = 1024
private let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
private let resources = root.appendingPathComponent("Sources/QuotaDot/Resources", isDirectory: true)
private let pngURL = resources.appendingPathComponent("AppIcon.png")
private let icnsURL = resources.appendingPathComponent("AppIcon.icns")

private func color(_ hex: UInt32, alpha: CGFloat = 1) -> CGColor {
    CGColor(
        red: CGFloat((hex >> 16) & 0xff) / 255,
        green: CGFloat((hex >> 8) & 0xff) / 255,
        blue: CGFloat(hex & 0xff) / 255,
        alpha: alpha
    )
}

private func roundedRect(_ rect: CGRect, radius: CGFloat) -> CGPath {
    CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
}

private func drawArc(
    in context: CGContext,
    center: CGPoint,
    radius: CGFloat,
    startDegrees: CGFloat,
    endDegrees: CGFloat,
    width: CGFloat,
    color: CGColor
) {
    context.setStrokeColor(color)
    context.setLineWidth(width)
    context.setLineCap(.round)
    context.addArc(
        center: center,
        radius: radius,
        startAngle: startDegrees * .pi / 180,
        endAngle: endDegrees * .pi / 180,
        clockwise: false
    )
    context.strokePath()
}

private func makeIcon(size: Int) -> NSBitmapImageRep {
    let scale = CGFloat(size) / CGFloat(canvasSize)
    guard let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: size,
        pixelsHigh: size,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    ), let graphics = NSGraphicsContext(bitmapImageRep: bitmap) else {
        fatalError("Unable to create \(size)px bitmap")
    }
    bitmap.size = NSSize(width: size, height: size)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = graphics
    defer { NSGraphicsContext.restoreGraphicsState() }

    let context = graphics.cgContext
    context.scaleBy(x: scale, y: scale)
    context.setAllowsAntialiasing(true)
    context.clear(CGRect(x: 0, y: 0, width: canvasSize, height: canvasSize))

    let tile = CGRect(x: 56, y: 56, width: 912, height: 912)
    let tilePath = roundedRect(tile, radius: 222)

    context.addPath(tilePath)
    context.setFillColor(color(0x090A0C))
    context.fillPath()

    context.addPath(tilePath)
    context.setStrokeColor(color(0x34373D))
    context.setLineWidth(4)
    context.strokePath()

    let center = CGPoint(x: 512, y: 514)
    drawArc(in: context, center: center, radius: 272, startDegrees: -42, endDegrees: 225, width: 72, color: color(0x282C33))
    drawArc(in: context, center: center, radius: 272, startDegrees: -42, endDegrees: 148, width: 72, color: color(0x4C9AFF))

    context.setStrokeColor(color(0xF5F7FA))
    context.setLineWidth(50)
    context.setLineCap(.round)
    context.addEllipse(in: CGRect(x: 395, y: 397, width: 234, height: 234))
    context.strokePath()
    context.move(to: CGPoint(x: 592, y: 431))
    context.addLine(to: CGPoint(x: 675, y: 348))
    context.strokePath()

    context.setFillColor(color(0x4C9AFF))
    context.fillEllipse(in: CGRect(x: 703, y: 721, width: 30, height: 30))

    return bitmap
}

private func pngData(for bitmap: NSBitmapImageRep) -> Data? {
    return bitmap.representation(using: .png, properties: [:])
}

try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
guard let masterData = pngData(for: makeIcon(size: canvasSize)) else {
    fatalError("Unable to encode AppIcon.png")
}
try masterData.write(to: pngURL, options: .atomic)

let temporaryRoot = FileManager.default.temporaryDirectory
    .appendingPathComponent("QuotaDot-AppIcon-\(UUID().uuidString)", isDirectory: true)
let iconset = temporaryRoot.appendingPathComponent("AppIcon.iconset", isDirectory: true)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

let representations: [(String, Int)] = [
    ("icon_16x16.png", 16),
    ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32),
    ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128),
    ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256),
    ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512),
    ("icon_512x512@2x.png", 1024)
]

for (name, size) in representations {
    guard let data = pngData(for: makeIcon(size: size)) else { fatalError("Unable to encode \(name)") }
    try data.write(to: iconset.appendingPathComponent(name), options: .atomic)
}

let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["--convert", "icns", iconset.path, "--output", icnsURL.path]
try iconutil.run()
iconutil.waitUntilExit()
guard iconutil.terminationStatus == 0 else { fatalError("iconutil failed") }

try? FileManager.default.removeItem(at: temporaryRoot)
print("Generated \(pngURL.path) and \(icnsURL.path)")
