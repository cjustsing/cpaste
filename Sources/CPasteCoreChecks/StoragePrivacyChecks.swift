import CPasteCore
import Foundation

private func posixPermissions(at url: URL, fileManager: FileManager) -> Int {
    guard let attributes = try? fileManager.attributesOfItem(atPath: url.path),
          let permissions = attributes[.posixPermissions] as? NSNumber
    else {
        return -1
    }
    return permissions.intValue
}

func testClipboardStorageUsesPrivatePermissions() {
    let fileManager = FileManager.default
    let storageDirectory = makeTemporaryDirectory()
    let blobDirectory = storageDirectory.appendingPathComponent("Blobs", isDirectory: true)
    let historyURL = storageDirectory.appendingPathComponent("history.json", isDirectory: false)
    let existingBlobURL = blobDirectory.appendingPathComponent("existing.png", isDirectory: false)
    defer { try? fileManager.removeItem(at: storageDirectory) }

    do {
        try fileManager.createDirectory(at: blobDirectory, withIntermediateDirectories: true)
        try Data("[]".utf8).write(to: historyURL)
        try Data([0x01, 0x02, 0x03]).write(to: existingBlobURL)
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: storageDirectory.path)
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: blobDirectory.path)
        try fileManager.setAttributes([.posixPermissions: 0o644], ofItemAtPath: historyURL.path)
        try fileManager.setAttributes([.posixPermissions: 0o644], ofItemAtPath: existingBlobURL.path)
    } catch {
        fputs("Check failed: secure storage fixture could not be created: \(error)\n", stderr)
        exit(1)
    }

    let store = ClipboardStore(storageDirectory: storageDirectory)

    check(
        posixPermissions(at: storageDirectory, fileManager: fileManager) == 0o700,
        "storage directory should be restricted to its owner"
    )
    check(
        posixPermissions(at: blobDirectory, fileManager: fileManager) == 0o700,
        "blob directory should be restricted to its owner"
    )
    check(
        posixPermissions(at: historyURL, fileManager: fileManager) == 0o600,
        "existing history should be restricted to its owner"
    )
    check(
        posixPermissions(at: existingBlobURL, fileManager: fileManager) == 0o600,
        "existing blobs should be restricted to their owner"
    )

    store.insertCaptured(CapturedClipboardContent(
        kind: .image,
        title: "Private image",
        imagePNGData: Data([0x89, 0x50, 0x4e, 0x47]),
        contentHash: "private-image"
    ))

    let newBlobURL = blobDirectory.appendingPathComponent("private-image.png", isDirectory: false)
    check(
        posixPermissions(at: historyURL, fileManager: fileManager) == 0o600,
        "new history writes should remain restricted to their owner"
    )
    check(
        posixPermissions(at: newBlobURL, fileManager: fileManager) == 0o600,
        "new blob writes should be restricted to their owner"
    )
}
