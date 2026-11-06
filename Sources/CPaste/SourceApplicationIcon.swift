import AppKit
import CPasteCore
import SwiftUI

actor SourceApplicationIconCache {
    static let shared = SourceApplicationIconCache()
    private let pipeline: ImageRequestPipeline

    init() {
        pipeline = ImageRequestPipeline(
            maximumConcurrentOperations: 1,
            totalCostLimit: 4 * 1_024 * 1_024,
            countLimit: 256,
            positiveTimeToLive: 300,
            negativeTimeToLive: 30,
            qualityOfService: .utility
        )
    }

    func icon(bundleIdentifier: String?) async -> CGImage? {
        guard let bundleIdentifier, !bundleIdentifier.isEmpty else { return nil }
        return await pipeline.image(for: bundleIdentifier) {
            SourceApplicationIconLoader.load(bundleIdentifier: bundleIdentifier)
        }
    }
}

private enum SourceApplicationIconLoader {
    static func load(bundleIdentifier: String) -> CGImage? {
        guard let applicationURL = applicationURL(for: bundleIdentifier) else { return nil }
        let workspaceIcon = iconImage(for: applicationURL) ?? NSWorkspace.shared.icon(forFile: applicationURL.path)
        let image = (workspaceIcon.copy() as? NSImage) ?? workspaceIcon
        let size = NSSize(width: 64, height: 64)
        guard let context = CGContext(
            data: nil, width: 64, height: 64, bitsPerComponent: 8, bytesPerRow: 64 * 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        NSGraphicsContext.current?.imageInterpolation = .high
        image.draw(
            in: NSRect(origin: .zero, size: size),
            from: NSRect(origin: .zero, size: image.size),
            operation: .sourceOver,
            fraction: 1
        )
        return context.makeImage()
    }

    private static func applicationURL(for bundleIdentifier: String) -> URL? {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) { return url }
        let fileManager = FileManager.default
        let roots = [
            URL(fileURLWithPath: "/Applications", isDirectory: true),
            URL(fileURLWithPath: "/System/Applications", isDirectory: true),
            URL(fileURLWithPath: "/System/Applications/Utilities", isDirectory: true),
            URL(fileURLWithPath: "/System/Library/CoreServices", isDirectory: true),
            fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Applications", isDirectory: true)
        ]
        for root in roots {
            guard let children = try? fileManager.contentsOfDirectory(
                at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]
            ) else { continue }
            if let match = children.first(where: { url in
                url.pathExtension == "app" && Bundle(url: url)?.bundleIdentifier == bundleIdentifier
            }) { return match }
        }
        return nil
    }

    private static func iconImage(for applicationURL: URL) -> NSImage? {
        guard let bundle = Bundle(url: applicationURL),
              let resourcesURL = bundle.resourceURL,
              let rawName = bundle.object(forInfoDictionaryKey: "CFBundleIconFile") as? String,
              !rawName.isEmpty
        else { return nil }
        let filename = (rawName as NSString).pathExtension.isEmpty ? "\(rawName).icns" : rawName
        return NSImage(contentsOf: resourcesURL.appendingPathComponent(filename, isDirectory: false))
    }
}

struct SourceApplicationIcon: View {
    let name: String?
    let bundleIdentifier: String?
    var size: CGFloat = 28

    @State private var loadedImage: CGImage?
    @State private var loadedBundleIdentifier: String?

    var body: some View {
        Group {
            if loadedBundleIdentifier == bundleIdentifier, let loadedImage {
                Image(decorative: loadedImage, scale: 1, orientation: .up)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
            } else {
                ZStack {
                    RoundedRectangle(cornerRadius: size * 0.22, style: .continuous)
                        .fill(Color.black.opacity(0.20))
                    Text(initials)
                        .font(.system(size: max(8, size * 0.34), weight: .bold, design: .rounded))
                        .foregroundStyle(Color.white.opacity(0.94))
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.22, style: .continuous))
        .accessibilityLabel(name ?? CPasteL10n.text("来源应用", "Source application"))
        .task(id: bundleIdentifier) {
            let requestedIdentifier = bundleIdentifier
            loadedImage = nil
            loadedBundleIdentifier = nil
            let image = await SourceApplicationIconCache.shared.icon(bundleIdentifier: requestedIdentifier)
            guard !Task.isCancelled else { return }
            loadedImage = image
            loadedBundleIdentifier = requestedIdentifier
        }
    }

    private var initials: String {
        let words = (name ?? "App").split(whereSeparator: { $0.isWhitespace || $0 == "-" })
        let value = words.prefix(2).compactMap(\.first).map(String.init).joined()
        return value.isEmpty ? "A" : value.uppercased()
    }
}
