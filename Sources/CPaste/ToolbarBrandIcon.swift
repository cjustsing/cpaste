import AppKit
import ImageIO
import SwiftUI

/// The toolbar uses the artwork at its final pixel size, without the app icon's inset.
struct ToolbarBrandIcon: View {
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        Group {
            if let image = displayScale > 1 ? Artwork.retina : Artwork.standard {
                Image(decorative: image, scale: displayScale > 1 ? 2 : 1)
            } else {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 28, height: 28)
            }
        }
        .frame(width: 30, height: 30)
        .accessibilityHidden(true)
    }

    private enum Artwork {
        static let standard = load(named: "toolbar-icon")
        static let retina = load(named: "toolbar-icon@2x")

        private static func load(named name: String) -> CGImage? {
            let url = Bundle.main.url(forResource: name, withExtension: "png", subdirectory: "Brand")
                ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
                    .appendingPathComponent("Resources/Brand/\(name).png")
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
            return CGImageSourceCreateImageAtIndex(source, 0, nil)
        }
    }
}
