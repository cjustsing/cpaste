import AppKit
import CPasteCore
import CoreGraphics
import Foundation
import UniformTypeIdentifiers

private final class VisualResourceProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var counts: [String: Int] = [:]
    private var active = 0
    private var peak = 0
    private var mainThreadCalls = 0
    private var gates: [String: DispatchSemaphore] = [:]

    func block(_ key: String) { lock.lock(); gates[key] = DispatchSemaphore(value: 0); lock.unlock() }
    func release(_ key: String) {
        lock.lock(); let gate = gates[key]; lock.unlock()
        gate?.signal()
    }
    func count(_ key: String) -> Int { lock.lock(); defer { lock.unlock() }; return counts[key, default: 0] }
    var maximum: Int { lock.lock(); defer { lock.unlock() }; return peak }
    var mainCalls: Int { lock.lock(); defer { lock.unlock() }; return mainThreadCalls }

    func load(_ key: String, width: Int = 1, missing: Bool = false, delay: TimeInterval = 0) -> CGImage? {
        lock.lock()
        counts[key, default: 0] += 1
        active += 1
        peak = max(peak, active)
        if Thread.isMainThread { mainThreadCalls += 1 }
        let gate = gates[key]
        lock.unlock()
        if let gate { _ = gate.wait(timeout: .now() + 5) }
        if delay > 0 { Thread.sleep(forTimeInterval: delay) }
        lock.lock(); active -= 1; lock.unlock()
        if missing { return nil }
        return CGContext(
            data: nil, width: width, height: 1, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )?.makeImage()
    }
}

private final class VisualResourceClock: @unchecked Sendable {
    private let lock = NSLock()
    private var instant: TimeInterval = 100
    func read() -> TimeInterval { lock.lock(); defer { lock.unlock() }; return instant }
    func advance(_ value: TimeInterval) { lock.lock(); instant += value; lock.unlock() }
}

@MainActor
private func resourceWait(_ message: String, until condition: () -> Bool) async {
    let deadline = Date().addingTimeInterval(3)
    while !condition(), Date() < deadline { try? await Task.sleep(nanoseconds: 1_000_000) }
    check(condition(), message)
}

@MainActor
private func testImageRequestsCoalesceAndRespectWorkerBudget() async {
    let probe = VisualResourceProbe()
    let pipeline = ImageRequestPipeline(maximumConcurrentOperations: 2)
    await withTaskGroup(of: CGImage?.self) { group in
        for index in 0..<12 {
            let key = index < 4 ? "shared" : "unique-\(index)"
            group.addTask { await pipeline.image(for: key) { probe.load(key, delay: 0.03) } }
        }
        for await image in group { check(image != nil, "each coalesced image waiter must receive the decoded image") }
    }
    check(probe.maximum == 2, "image decoding must use its two-operation budget")
    check(probe.count("shared") == 1, "concurrent requests for the same image must share one decode")
    check(probe.mainCalls == 0, "synchronous image loaders must run off the main thread")
}

@MainActor
private func testCancellingOneImageWaiterKeepsOtherWaiters() async {
    let probe = VisualResourceProbe()
    probe.block("shared")
    let pipeline = ImageRequestPipeline(maximumConcurrentOperations: 1)
    let first = Task { await pipeline.image(for: "shared") { probe.load("shared", width: 3) } }
    await resourceWait("the shared request should start") { probe.count("shared") == 1 }
    let second = Task { await pipeline.image(for: "shared") { probe.load("duplicate", width: 4) } }
    // Let the second caller enter the actor while the controlled first decode is held.
    try? await Task.sleep(nanoseconds: 30_000_000)
    first.cancel()
    let cancelledImage = await first.value
    check(cancelledImage == nil, "a cancelled image waiter must promptly finish without an image")
    probe.release("shared")
    let remainingImage = await second.value
    check(remainingImage?.width == 3 && probe.count("duplicate") == 0, "cancelling one waiter must preserve the shared decode for another waiter")
}

@MainActor
private func testQueuedCancellationAndRunningBudget() async {
    let probe = VisualResourceProbe()
    probe.block("running")
    probe.block("replacement")
    let pipeline = ImageRequestPipeline(maximumConcurrentOperations: 1)
    let running = Task { await pipeline.image(for: "same-key") { probe.load("running", width: 1) } }
    await resourceWait("a controlled decode should occupy the only slot") { probe.count("running") == 1 }
    let queued = Task { await pipeline.image(for: "queued") { probe.load("queued") } }
    queued.cancel()
    let queuedImage = await queued.value
    check(queuedImage == nil, "cancelling the last queued waiter must finish it promptly")
    running.cancel()
    let runningImage = await running.value
    check(runningImage == nil, "a running cancelled waiter need not wait for its synchronous decoder")
    let replacement = Task { await pipeline.image(for: "same-key") { probe.load("replacement", width: 2) } }
    try? await Task.sleep(nanoseconds: 30_000_000)
    check(probe.count("replacement") == 0, "a cancelled running decoder must retain its worker slot until it returns")
    probe.release("running")
    await resourceWait("replacement work should start after the original decoder actually ends") { probe.count("replacement") == 1 }
    // Hold the replacement while the old completion reaches the actor. A stale
    // completion must not consume the new same-key job or populate its cache.
    try? await Task.sleep(nanoseconds: 30_000_000)
    probe.release("replacement")
    let replacedImage = await replacement.value
    let cachedImage = await pipeline.image(for: "same-key") { probe.load("unexpected", width: 9) }
    check(replacedImage?.width == 2 && cachedImage?.width == 2, "old cancelled completions must not overwrite or remove a replacement request")
    check(probe.count("queued") == 0 && probe.count("unexpected") == 0, "cancelled queued work must never decode, and replacement output should be cached")
    check(probe.maximum == 1, "cancellation must not allow work to exceed the configured concurrency")
}

@MainActor
private func testImagePositiveAndNegativeCacheExpiration() async {
    let clock = VisualResourceClock()
    let probe = VisualResourceProbe()
    let pipeline = ImageRequestPipeline(
        maximumConcurrentOperations: 1, positiveTimeToLive: 5, negativeTimeToLive: 2, clock: { clock.read() }
    )
    for _ in 0..<2 { _ = await pipeline.image(for: "present") { probe.load("present") } }
    for _ in 0..<2 { _ = await pipeline.image(for: "missing") { probe.load("missing", missing: true) } }
    check(probe.count("present") == 1 && probe.count("missing") == 1, "positive and missing icon requests must both be cached")
    clock.advance(2)
    _ = await pipeline.image(for: "missing") { probe.load("missing", missing: true) }
    _ = await pipeline.image(for: "present") { probe.load("present") }
    check(probe.count("missing") == 2 && probe.count("present") == 1, "a negative entry must retry after its shorter TTL without expiring a live icon")
    clock.advance(3)
    _ = await pipeline.image(for: "present") { probe.load("present") }
    check(probe.count("present") == 2, "positive entries must expire so an updated application icon can be discovered")
}

private func draggedString(_ provider: NSItemProvider) async -> String? {
    await withCheckedContinuation { continuation in
        _ = provider.loadObject(ofClass: NSString.self) { value, _ in continuation.resume(returning: value as? String) }
    }
}

private func draggedData(_ provider: NSItemProvider, type: UTType) async -> Data? {
    await withCheckedContinuation { continuation in
        _ = provider.loadDataRepresentation(forTypeIdentifier: type.identifier) { value, _ in continuation.resume(returning: value) }
    }
}

@MainActor
private func testDragPayloadCompletenessAndNativeFileWriters() async {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("CPasteDragPayload-\(UUID().uuidString)", isDirectory: true)
    do { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]) }
    catch { check(false, "drag fixture directory must be writable"); return }
    defer { try? FileManager.default.removeItem(at: directory) }
    let first = directory.appendingPathComponent("第一项.txt")
    let second = directory.appendingPathComponent("second.txt")
    let folder = directory.appendingPathComponent("folder", isDirectory: true)
    let firstBytes = Data("first fixture 中文 👨‍👩‍👧‍👦".utf8)
    let secondBytes = Data([0, 3, 255, 9])
    do {
        try firstBytes.write(to: first)
        try secondBytes.write(to: second)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
    } catch { check(false, "drag fixtures must be created"); return }
    let text = String(repeating: "原文 👨‍👩‍👧‍👦 e\u{301}\n", count: 40_000) + "TAIL-FULL-DRAG"
    let textItem = ClipboardItem(kind: .text, title: "short preview", text: text, contentHash: "drag-text")
    let textProviders = ClipboardDragExport.providers(for: textItem, imageURL: nil)
    check(textProviders.count == 1, "text drag must remain a single provider")
    let loadedText = await draggedString(textProviders[0])
    check(loadedText == text, "text drag must preserve full Unicode text beyond the preview tail")

    let link = "https://example.com/drag?q=%E4%B8%AD%E6%96%87#full"
    let urlItem = ClipboardItem(kind: .url, title: "link", text: link, contentHash: "drag-url")
    let urlProviders = ClipboardDragExport.providers(for: urlItem, imageURL: nil)
    check(urlProviders.count == 1, "URL drag must remain a single provider")
    let loadedURL: URL? = await withCheckedContinuation { continuation in
        _ = urlProviders.first?.loadObject(ofClass: NSURL.self) { value, _ in continuation.resume(returning: value as? URL) }
    }
    check(loadedURL?.absoluteString == link, "URL drag must preserve the complete URL")

    let png = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 1, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 8, bitsPerPixel: 32)!
    let pngBytes = png.representation(using: .png, properties: [:])!
    let imageURL = directory.appendingPathComponent("original.png")
    try! pngBytes.write(to: imageURL)
    let imageItem = ClipboardItem(kind: .image, title: "image", blobFilename: "original.png", contentHash: "drag-image")
    let imageProviders = ClipboardDragExport.providers(for: imageItem, imageURL: imageURL)
    check(imageProviders.count == 1, "PNG drag must remain a single provider")
    let loadedPNG = await draggedData(imageProviders[0], type: .png)
    check(loadedPNG == pngBytes, "image drag must export the original PNG bytes rather than its thumbnail")

    let fileItem = ClipboardItem(kind: .file, title: "Files", fileURLs: [first.absoluteString, second.absoluteString, folder.absoluteString], contentHash: "drag-files")
    check(ClipboardDragExport.providers(for: fileItem, imageURL: nil).count == 3, "file and directory providers must preserve every selected URL")
    let draggingItems = ClipboardDragExport.draggingItems(for: fileItem)
    let writers = draggingItems.compactMap { $0.item as? NSURL }
    check(writers.count == 3, "native dragging sessions must have a distinct URL writer for every file")
    let pasteboard = NSPasteboard(name: NSPasteboard.Name("local.cpaste.drag-check.\(UUID().uuidString)"))
    defer { pasteboard.releaseGlobally() }
    check(pasteboard.writeObjects(writers), "native URL writers must materialize on a private pasteboard")
    let readURLs = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]
    check(readURLs?.map(\.standardizedFileURL) == [first, second, folder].map(\.standardizedFileURL), "native file drag must preserve every URL and its order")
    check((try? Data(contentsOf: first)) == firstBytes && (try? Data(contentsOf: second)) == secondBytes, "drag preparation must not change source bytes")
    let single = ClipboardItem(kind: .file, title: "One", fileURLs: [first.absoluteString], contentHash: "drag-one")
    check(ClipboardDragExport.providers(for: single, imageURL: nil).count == 1, "single-file drag must remain available")
    var missing = fileItem
    missing.fileURLs[1] = directory.appendingPathComponent("missing.txt").absoluteString
    check(ClipboardDragExport.providers(for: missing, imageURL: nil).isEmpty && ClipboardDragExport.draggingItems(for: missing).isEmpty, "a missing file must reject a group instead of silently exporting only surviving URLs")
}

/// Runs without activating a window or touching NSPasteboard.general.
func runVisualResourceCoreChecks() {
    var finished = false
    Task { @MainActor in
        await testImageRequestsCoalesceAndRespectWorkerBudget()
        await testCancellingOneImageWaiterKeepsOtherWaiters()
        await testQueuedCancellationAndRunningBudget()
        await testImagePositiveAndNegativeCacheExpiration()
        await testDragPayloadCompletenessAndNativeFileWriters()
        finished = true
    }
    while !finished { RunLoop.current.run(until: Date().addingTimeInterval(0.002)) }
}
