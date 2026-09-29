#!/usr/bin/env swift
import AppKit
import ImageIO
import UniformTypeIdentifiers

// Package the approved original without generative edits or color retouching.
// Inset the crop and mask into the opaque tile to exclude generated edge speckles.
let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let directory = root.appendingPathComponent("Resources/AppIcon", isDirectory: true)
let sourceURL = root.appendingPathComponent("docs/design/app-icon/contrast-cards-v2.png")
guard let source = CGImageSourceCreateWithURL(sourceURL as CFURL, nil),
      let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
      image.width == 1_254, image.height == 1_254,
      let tile = image.cropping(to: CGRect(x: 126, y: 126, width: 1_002, height: 1_002))
else {
    fatalError("Expected the approved 1254 x 1254 original icon artwork")
}

// Generated solid artwork can contain near-opaque alpha throughout its interior.
// Preserve its straight RGB bytes while making the tile fully opaque; macOS
// otherwise treats it as a translucent glyph and adds a separate backplate.
let opaqueTile = NSBitmapImageRep(cgImage: tile)
guard opaqueTile.bitsPerSample == 8, opaqueTile.samplesPerPixel == 4,
      opaqueTile.bitmapFormat == .alphaNonpremultiplied,
      let pixels = opaqueTile.bitmapData
else { fatalError("Expected straight RGBA icon pixels") }
for y in 0..<opaqueTile.pixelsHigh {
    for x in 0..<opaqueTile.pixelsWide {
        pixels[y * opaqueTile.bytesPerRow + x * 4 + 3] = 255
    }
}
guard let solidTile = opaqueTile.cgImage else { fatalError("Could not normalize icon alpha") }

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
    // Fit the opaque square tile at the normal macOS icon inset.
    // Crop only the background so the cards retain their original proportions.
    let scale = 824.0 / 1_002.0
    let bounds = CGRect(x: 100, y: 100, width: 824, height: 824)
    context.addPath(CGPath(
        roundedRect: bounds, cornerWidth: 252 * scale, cornerHeight: 252 * scale, transform: nil
    ))
    context.clip()
    context.draw(solidTile, in: bounds)
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
