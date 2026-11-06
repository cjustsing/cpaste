import AppKit
import CPasteCore
import CoreGraphics
import Foundation
import SwiftUI

private var resourceCleanup: (() -> Void)?
private func resourceCheck(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else {
        fputs("Resource check failed: \(message)\n", stderr)
        resourceCleanup?()
        exit(1)
    }
}

private enum ResourceDecodeProbe {
    static let lock = NSLock()
    static var active = 0
    static var maximum = 0
    static var calls = 0
    static let image: CGImage = {
        let context = CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        return context.makeImage()!
    }()
    static func decode() -> CGImage? {
        lock.lock()
        active += 1
        calls += 1
        maximum = max(maximum, active)
        lock.unlock()
        Thread.sleep(forTimeInterval: 0.12)
        lock.lock()
        active -= 1
        lock.unlock()
        return image
    }
}

// Shadow only the synchronous decoder dependency. The production cache and its
// scheduling/cancellation code are compiled unmodified into this same module.
private enum ImageThumbnailDecoder {
    static func thumbnail(at url: URL, maxPixelSize: Int) -> CGImage? { ResourceDecodeProbe.decode() }
}

private final class ResourceIconWorkspace {
    static let shared = ResourceIconWorkspace()
    private let lock = NSLock()
    private(set) var calls = 0
    private(set) var mainThreadCalls = 0
    func urlForApplication(withBundleIdentifier identifier: String) -> URL? {
        lock.lock()
        calls += 1
        if Thread.isMainThread { mainThreadCalls += 1 }
        lock.unlock()
        return nil
    }
    func icon(forFile path: String) -> NSImage { NSImage(size: NSSize(width: 64, height: 64)) }
}

private final class ResourceIconFileSystem {
    static let shared = ResourceIconFileSystem()
    let homeDirectoryForCurrentUser = URL(fileURLWithPath: "/resource-fixture-home", isDirectory: true)
    func contentsOfDirectory(at url: URL, includingPropertiesForKeys keys: [URLResourceKey]?, options: Foundation.FileManager.DirectoryEnumerationOptions) throws -> [URL] { [] }
}

// __PRODUCTION_RESOURCE_CODE__

private func testMultipleFileProviders() async {
    let directory = Foundation.FileManager.default.temporaryDirectory.appendingPathComponent("CPasteDragChecks-\(UUID().uuidString)", isDirectory: true)
    try! Foundation.FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    resourceCleanup = { try? Foundation.FileManager.default.removeItem(at: directory) }
    let first = directory.appendingPathComponent("第一项.txt")
    let second = directory.appendingPathComponent("second.txt")
    try! Data("first fixture 中文".utf8).write(to: first)
    try! Data("second fixture".utf8).write(to: second)
    let item = ClipboardItem(kind: .file, title: "Two files", text: first.path + "\n" + second.path, fileURLs: [first.absoluteString, second.absoluteString], contentHash: "two-file-fixture")
    let providers = resourceDragProviders(item: item, imageURL: nil)
    print("Drag fixture: urls=\(item.fileURLs.count), providers=\(providers.count)")
    resourceCheck(providers.count == 2, "a multi-file card must export one provider for every file, not only its first URL")
    resourceCleanup?()
    resourceCleanup = nil
}

private func testThumbnailConcurrencyBudget() async {
    let cache = TimelineThumbnailCache()
    await withTaskGroup(of: CGImage?.self) { group in
        for index in 0..<8 {
            group.addTask {
                await cache.thumbnail(for: URL(fileURLWithPath: "/resource-thumbnail-\(index).png"), maxPixelSize: 512)
            }
        }
        for await result in group { resourceCheck(result != nil, "controlled decode must complete") }
    }
    print("Thumbnail fixture: decodes=\(ResourceDecodeProbe.calls), maxActive=\(ResourceDecodeProbe.maximum)")
    resourceCheck(ResourceDecodeProbe.maximum <= 2, "thumbnail decoding must obey the two-operation budget")
}

@MainActor
private func testMissingSourceIconCache() async {
    let cache = SourceApplicationIconCache()
    _ = await cache.icon(bundleIdentifier: "local.cpaste.fixture.missing")
    _ = await cache.icon(bundleIdentifier: "local.cpaste.fixture.missing")
    print("Icon fixture: lookups=\(ResourceIconWorkspace.shared.calls), mainThread=\(ResourceIconWorkspace.shared.mainThreadCalls)")
    resourceCheck(ResourceIconWorkspace.shared.calls == 1, "a missing source application must be cached instead of repeatedly scanning applications")
    resourceCheck(ResourceIconWorkspace.shared.mainThreadCalls == 0, "source icon lookup must run off the main thread")
}

private var resourceFinished = false
Task { @MainActor in
    switch CommandLine.arguments.dropFirst().first ?? "all" {
    case "drag": await testMultipleFileProviders()
    case "thumbnail": await testThumbnailConcurrencyBudget()
    case "icon": await testMissingSourceIconCache()
    case "all":
        await testMultipleFileProviders()
        await testThumbnailConcurrencyBudget()
        await testMissingSourceIconCache()
    default: resourceCheck(false, "unknown resource check mode")
    }
    print("CPaste resource checks passed")
    resourceFinished = true
}
while !resourceFinished { RunLoop.current.run(until: Date().addingTimeInterval(0.005)) }
