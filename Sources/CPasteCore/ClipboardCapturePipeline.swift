import Foundation

/// An immutable copy of one pasteboard representation. Obtain it on the main
/// thread; image decoding, hashing and file materialization can then run on a
/// worker without sharing NSPasteboard or NSImage instances between threads.
public struct ClipboardSnapshot: Sendable {
    enum Payload: Sendable {
        case files([String], sourceBundleIdentifier: String?)
        case image(Data, type: String)
        case pdf(Data)
        case url(String)
        case text(String)
    }

    let payload: Payload

    var imageType: String? {
        if case let .image(_, type) = payload { return type }
        return nil
    }
}

enum ClipboardSnapshotResult {
    case snapshot(ClipboardSnapshot)
    case ignored
    case unavailable
}
