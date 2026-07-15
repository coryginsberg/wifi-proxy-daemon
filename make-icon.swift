import AppKit
import Foundation

// Renders a simple proxy-themed app icon into a macOS `.iconset` directory.
// The mark is a client node on the left and a server node on the right, both
// routed through a central relay (the proxy) drawn as a diamond — a minimal,
// legible metaphor for traffic passing through an intermediary.

let iconSizes: [(name: String, pixels: Int)] = [
    ("icon_16x16", 16),
    ("icon_16x16@2x", 32),
    ("icon_32x32", 32),
    ("icon_32x32@2x", 64),
    ("icon_128x128", 128),
    ("icon_128x128@2x", 256),
    ("icon_256x256", 256),
    ("icon_256x256@2x", 512),
    ("icon_512x512", 512),
    ("icon_512x512@2x", 1024)
]

func drawIcon(pixels: Int) -> Data? {
    let size = CGFloat(pixels)

    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: pixels,
        pixelsHigh: pixels,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    ) else {
        return nil
    }

    rep.size = NSSize(width: size, height: size)

    guard let context = NSGraphicsContext(bitmapImageRep: rep) else {
        return nil
    }

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    let cg = context.cgContext

    // Rounded-rectangle background with a vertical blue gradient.
    let inset = size * 0.06
    let backgroundRect = CGRect(x: inset, y: inset, width: size - 2 * inset, height: size - 2 * inset)
    let cornerRadius = (size - 2 * inset) * 0.22
    let backgroundPath = CGPath(
        roundedRect: backgroundRect,
        cornerWidth: cornerRadius,
        cornerHeight: cornerRadius,
        transform: nil
    )

    let gradientColors = [
        NSColor(calibratedRed: 0.29, green: 0.56, blue: 0.85, alpha: 1).cgColor,
        NSColor(calibratedRed: 0.16, green: 0.38, blue: 0.66, alpha: 1).cgColor
    ] as CFArray

    if let gradient = CGGradient(
        colorsSpace: CGColorSpaceCreateDeviceRGB(),
        colors: gradientColors,
        locations: [0, 1]
    ) {
        cg.saveGState()
        cg.addPath(backgroundPath)
        cg.clip()
        cg.drawLinearGradient(
            gradient,
            start: CGPoint(x: 0, y: size),
            end: CGPoint(x: 0, y: 0),
            options: []
        )
        cg.restoreGState()
    }

    // Proxy mark geometry.
    let centerY = size * 0.5
    let leftX = size * 0.27
    let midX = size * 0.5
    let rightX = size * 0.73
    let endpointRadius = size * 0.058
    let diamondRadius = size * 0.115
    let lineWidth = size * 0.032

    // Connecting lines from each endpoint to the central relay.
    cg.setStrokeColor(NSColor.white.cgColor)
    cg.setLineWidth(lineWidth)
    cg.setLineCap(.round)
    cg.move(to: CGPoint(x: leftX, y: centerY))
    cg.addLine(to: CGPoint(x: midX, y: centerY))
    cg.move(to: CGPoint(x: midX, y: centerY))
    cg.addLine(to: CGPoint(x: rightX, y: centerY))
    cg.strokePath()

    // Endpoint nodes (client and server).
    cg.setFillColor(NSColor.white.cgColor)
    for x in [leftX, rightX] {
        cg.fillEllipse(in: CGRect(
            x: x - endpointRadius,
            y: centerY - endpointRadius,
            width: endpointRadius * 2,
            height: endpointRadius * 2
        ))
    }

    // Central relay diamond (the proxy).
    cg.move(to: CGPoint(x: midX, y: centerY + diamondRadius))
    cg.addLine(to: CGPoint(x: midX + diamondRadius, y: centerY))
    cg.addLine(to: CGPoint(x: midX, y: centerY - diamondRadius))
    cg.addLine(to: CGPoint(x: midX - diamondRadius, y: centerY))
    cg.closePath()
    cg.setFillColor(NSColor.white.cgColor)
    cg.fillPath()

    NSGraphicsContext.restoreGraphicsState()

    return rep.representation(using: .png, properties: [:])
}

guard CommandLine.arguments.count == 2 else {
    FileHandle.standardError.write(Data("usage: make-icon <output-iconset-dir>\n".utf8))
    exit(2)
}

let outputDirectory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)

do {
    try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
} catch {
    FileHandle.standardError.write(Data("Failed to create iconset directory: \(error)\n".utf8))
    exit(1)
}

for icon in iconSizes {
    guard let data = drawIcon(pixels: icon.pixels) else {
        FileHandle.standardError.write(Data("Failed to render \(icon.name)\n".utf8))
        exit(1)
    }

    let fileURL = outputDirectory.appendingPathComponent("\(icon.name).png")
    do {
        try data.write(to: fileURL)
    } catch {
        FileHandle.standardError.write(Data("Failed to write \(icon.name): \(error)\n".utf8))
        exit(1)
    }
}
