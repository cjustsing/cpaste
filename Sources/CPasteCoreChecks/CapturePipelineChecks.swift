import AppKit
import CPasteCore
import Foundation
import ImageIO

private final class CaptureStageThreadProbe: FileManager, @unchecked Sendable {
    private let lock = NSLock()
    private var observedThreads: [Bool] = []

    var stageThreads: [Bool] {
        lock.lock()
        defer { lock.unlock() }
        return observedThreads
    }

    override func createFile(atPath path: String, contents data: Data?, attributes attr: [FileAttributeKey: Any]? = nil) -> Bool {
        if path.contains(".png-") {
            lock.lock()
            observedThreads.append(Thread.isMainThread)
            lock.unlock()
        }
        return super.createFile(atPath: path, contents: data, attributes: attr)
    }
}

/// Add a valid ancillary PNG comment so a decode/TIFF/PNG round-trip cannot
/// accidentally satisfy the original-byte check by using the same encoder.
private func capturePNGFixture() -> Data {
    let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: 4, pixelsHigh: 3, bitsPerSample: 8,
        samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 16, bitsPerPixel: 32
    )!
    for offset in 0..<(bitmap.bytesPerRow * bitmap.pixelsHigh) {
        bitmap.bitmapData![offset] = UInt8([48, 128, 192, 255][offset % 4])
    }
    let png = bitmap.representation(using: .png, properties: [:])!
    check(Array(png.suffix(8).prefix(4)) == Array("IEND".utf8), "the PNG fixture must end in a complete IEND chunk")
    let body = Data("Comment\0CPaste original PNG bytes fixture".utf8)
    let type = Data("tEXt".utf8)
    func bigEndian(_ value: UInt32) -> [UInt8] {
        [UInt8((value >> 24) & 255), UInt8((value >> 16) & 255), UInt8((value >> 8) & 255), UInt8(value & 255)]
    }
    var crc: UInt32 = 0xffff_ffff
    for byte in type + body {
        crc ^= UInt32(byte)
        for _ in 0..<8 { crc = (crc >> 1) ^ ((crc & 1) == 0 ? 0 : 0xedb8_8320) }
    }
    var result = Data(png.dropLast(12))
    result.append(contentsOf: bigEndian(UInt32(body.count)))
    result.append(type)
    result.append(body)
    result.append(contentsOf: bigEndian(crc ^ 0xffff_ffff))
    result.append(png.suffix(12))
    return result
}

func testCapturedPNGPreservesOriginalBytes() {
    let png = capturePNGFixture()
    let source = CGImageSourceCreateWithData(png as CFData, nil)!
    let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
    check(image?.width == 4 && image?.height == 3, "the ancillary PNG fixture must decode as a valid full image")
    let captured: CapturedClipboardContent?
    do {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        check(pasteboard.setData(png, forType: .png), "the named PNG fixture must publish")
        captured = PasteboardReader.read(from: pasteboard)
    }
    check(captured?.kind == .image, "a valid direct PNG must be captured as an image")
    check(captured?.imagePNGData == png, "capture must reuse complete original PNG bytes instead of TIFF/PNG re-encoding")
    check(captured?.contentHash == ContentHasher.hash(data: png), "PNG identity must hash the exact retained bytes")
    check(captured?.subtitle == "4 x 3", "original PNG capture must retain full pixel dimensions")
}

func testMonitoredImageBlobStagesOffMainThread() {
    let directory = makeTemporaryDirectory()
    let pasteboard = NSPasteboard.withUniqueName()
    let manager = CaptureStageThreadProbe()
    let store = ClipboardStore(storageDirectory: directory, fileManager: manager)
    let monitor = ClipboardMonitor(pasteboard: pasteboard, store: store)
    monitor.start()
    let previousGeneration = pasteboard.changeCount
    pasteboard.clearContents()
    check(pasteboard.setData(capturePNGFixture(), forType: .png), "the monitored named PNG fixture must publish")
    check(pasteboard.changeCount != previousGeneration, "the monitored PNG fixture must advance the pasteboard generation")
    let deadline = Date().addingTimeInterval(2)
    while (store.items.isEmpty || manager.stageThreads.isEmpty) && Date() < deadline {
        RunLoop.current.run(until: Date().addingTimeInterval(0.01))
    }
    let stages = manager.stageThreads
    let itemCount = store.items.count
    monitor.stop()
    let saved = store.save()
    pasteboard.releaseGlobally()
    try? FileManager.default.removeItem(at: directory)

    check(itemCount == 1 && !stages.isEmpty, "the monitor must finish a real PNG capture and attachment stage")
    check(stages.allSatisfy { !$0 }, "monitored image attachment I/O must run off the main thread")
    check(saved, "the temporary image history must flush after capture completes")
}
