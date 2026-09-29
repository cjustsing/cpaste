#!/usr/bin/env swift
import AppKit
import ImageIO
import UniformTypeIdentifiers

// Package the approved original without generative edits or color retouching.
// The crop and circular-corner mask follow its outer tile, leaving card details intact.
let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let directory = root.appendingPathComponent("Resources/AppIcon", isDirectory: true)
let sourceURL = root.appendingPathComponent("docs/design/app-icon/liquid-glass-v2.png")
guard let source = CGImageSourceCreateWithURL(sourceURL as CFURL, nil),
      let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
      image.width == 1_254, image.height == 1_254,
      let tile = image.cropping(to: CGRect(x: 166, y: 146, width: 922, height: 938))
else {
    fatalError("Expected the approved 1254 x 1254 original icon artwork")
}

let iconset = directory.appendingPathComponent("AppIcon.iconset", isDirectory: true)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

func render(size: Int, to url: URL) throws {
    guard let context = CGContext(
        data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { fatalError("Could not create icon context") }
    context.scaleBy(x: CGFloat(size) / 1_024, y: CGFloat(size) / 1_024)
    context.setAllowsAntialiasing(true)
    context.setShouldAntialias(true)
    context.interpolationQuality = .high
    // Fit the approved tile at the normal macOS icon inset without distorting it.
    let scale = 824.0 / 938.0
    let width = 922.0 * scale
    let bounds = CGRect(x: (1_024 - width) / 2, y: 100, width: width, height: 824)
    context.addPath(CGPath(
        roundedRect: bounds, cornerWidth: 228 * scale, cornerHeight: 228 * scale, transform: nil
    ))
    context.clip()
    context.draw(tile, in: bounds)
    guard let output = context.makeImage(),
          let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)
    else { fatalError("Could not encode icon") }
    CGImageDestinationAddImage(destination, output, nil)
    guard CGImageDestinationFinalize(destination) else { fatalError("Could not save icon") }
}

try render(size: 1_024, to: directory.appendingPathComponent("AppIcon-1024.png"))
for (name, size) in [
    ("icon_16x16.png", 16), ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32), ("icon_32x32@2x.png", 64),
    ("icon_48x48.png", 48),
    ("icon_128x128.png", 128), ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256), ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512), ("icon_512x512@2x.png", 1_024)
] {
    try render(size: size, to: iconset.appendingPathComponent(name))
}
let process = Process()
process.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
process.arguments = ["-c", "icns", iconset.path, "-o", directory.appendingPathComponent("CPaste.icns").path]
try process.run()
process.waitUntilExit()
guard process.terminationStatus == 0 else { fatalError("iconutil failed") }
print("Generated 1024 px icon, complete iconset, and CPaste.icns")
