import Foundation

public enum CaptureInsertionResult {
    case inserted
    case discarded
    case failed
}

/// Materialized on the persistence worker, then accepted or discarded on main.
/// Its lease keeps attachments alive until that decision is published.
struct PreparedClipboardCapture {
    let leaseID: UUID
    let content: CapturedClipboardContent
    let capturedAt: Date
    let fileURLs: [String]
    let blobFilename: String?
}
