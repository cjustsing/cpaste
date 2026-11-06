import Combine
import Foundation

public struct ClipboardSearchQuery: Equatable {
    public let text: String
    public let kind: ClipboardKind?
    public let pinnedOnly: Bool

    public init(text: String, kind: ClipboardKind? = nil, pinnedOnly: Bool = false) {
        self.text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        self.kind = kind
        self.pinnedOnly = pinnedOnly
    }

    public var isEmpty: Bool { text.isEmpty }

    public func includes(_ item: ClipboardItem) -> Bool {
        (kind == nil || item.kind == kind) && (!pinnedOnly || item.isPinned)
    }
}

public struct ClipboardSearchResult {
    public let query: ClipboardSearchQuery
    public let revision: UInt64
    public let items: [ClipboardItem]
}

/// Main-thread query state with full-text matching confined to a serial worker.
/// Results belong to both a query and a store revision; callers must supply both
/// when reading them, including before SwiftUI has delivered an `onChange`.
public final class ClipboardSearch: ObservableObject {
    @Published public private(set) var result: ClipboardSearchResult?

    private var snapshot: [ClipboardItem]
    private var revision: UInt64
    private var query = ClipboardSearchQuery(text: "")
    private var submittedRevision: UInt64?
    private var isActive = false
    private let queue: DispatchQueue
    private let debounceInterval: TimeInterval
    private var pendingWork: DispatchWorkItem?
    private let generationLock = NSLock()
    private var generation: UInt64 = 0

    public init(
        items: [ClipboardItem] = [],
        revision: UInt64 = 0,
        debounceInterval: TimeInterval = 0.08,
        queue: DispatchQueue = DispatchQueue(label: "local.cpaste.search", qos: .userInitiated)
    ) {
        self.snapshot = items
        self.revision = revision
        self.debounceInterval = max(0, debounceInterval)
        self.queue = queue
    }

    deinit {
        pendingWork?.cancel()
    }

    public func update(items: [ClipboardItem], revision: UInt64) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard self.revision != revision else { return }
        snapshot = items
        self.revision = revision
        if isActive {
            restart()
        } else {
            invalidate()
        }
    }

    public func search(query: ClipboardSearchQuery) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard !isActive || self.query != query || submittedRevision != revision else { return }
        self.query = query
        isActive = true
        restart()
    }

    public func matchingItems(query: ClipboardSearchQuery, revision: UInt64) -> [ClipboardItem]? {
        guard let result, result.query == query, result.revision == revision else { return nil }
        return result.items
    }

    public func cancel() {
        dispatchPrecondition(condition: .onQueue(.main))
        isActive = false
        invalidate()
    }

    private func invalidate() {
        generationLock.lock()
        generation &+= 1
        generationLock.unlock()
        pendingWork?.cancel()
        pendingWork = nil
        submittedRevision = nil
        result = nil
    }

    private func isCurrent(_ candidate: UInt64) -> Bool {
        generationLock.lock()
        defer { generationLock.unlock() }
        return generation == candidate
    }

    private func restart() {
        invalidate()
        let query = query
        let revision = revision
        submittedRevision = revision
        if query.isEmpty {
            result = ClipboardSearchResult(query: query, revision: revision, items: snapshot.filter(query.includes))
            return
        }

        // Copy-on-write snapshots share their strings. No full-text hashing,
        // comparisons, or normalization occurs on the submitting thread.
        let items = snapshot
        generationLock.lock()
        let requestGeneration = generation
        generationLock.unlock()
        let work = DispatchWorkItem { [weak self] in
            dispatchPrecondition(condition: .notOnQueue(.main))
            guard let self, self.isCurrent(requestGeneration) else { return }
            var matches: [ClipboardItem] = []
            for item in items {
                guard self.isCurrent(requestGeneration) else { return }
                if query.includes(item), item.matches(query.text) {
                    matches.append(item)
                }
            }
            guard self.isCurrent(requestGeneration) else { return }
            let result = ClipboardSearchResult(query: query, revision: revision, items: matches)
            DispatchQueue.main.async { [weak self] in
                guard let self, self.isCurrent(requestGeneration) else { return }
                self.pendingWork = nil
                self.result = result
            }
        }
        pendingWork = work
        if debounceInterval == 0 {
            queue.async(execute: work)
        } else {
            queue.asyncAfter(deadline: .now() + debounceInterval, execute: work)
        }
    }
}
