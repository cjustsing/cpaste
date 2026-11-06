import Combine
import CPasteCore
import Foundation

private func waitForSearch(_ message: String, timeout: TimeInterval = 5, until condition: () -> Bool) {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition(), Date() < deadline {
        RunLoop.current.run(until: Date().addingTimeInterval(0.002))
    }
    check(condition(), message)
}

func testBackgroundSearchUsesWorkerAndPublishesOnMain() {
    let queue = DispatchQueue(label: "CPasteSearchChecks.worker")
    queue.suspend()
    let item = ClipboardItem(kind: .text, title: "Fixture", text: "background needle", contentHash: "worker")
    let search = ClipboardSearch(items: [item], revision: 1, debounceInterval: 0, queue: queue)
    var publishedOnMain = false
    let subscription = search.$result.compactMap { $0 }.sink { _ in
        publishedOnMain = Thread.isMainThread
    }
    search.search(query: .init(text: "needle"))
    RunLoop.current.run(until: Date().addingTimeInterval(0.03))
    check(search.result == nil, "matching must wait for its background worker, leaving the main run loop free")
    queue.resume()
    waitForSearch("worker search should finish") { search.result != nil }
    check(publishedOnMain, "search results must be published on the main thread")
    check(search.result?.items.map(\.id) == [item.id], "worker search should return the matching item")
    withExtendedLifetime(subscription) {}
}

func testBackgroundSearchPreservesFullTextAndFilterSemantics() {
    let longText = String(repeating: "abcdefg 中文段落 👨‍👩‍👧‍👦\r\n", count: 80_000) + "TAILNeedle 中文结尾"
    let textItem = ClipboardItem(kind: .text, title: "Long text", text: longText, contentHash: "long-search", sourceAppName: "Safari", sourceBundleIdentifier: "com.apple.Safari", isPinned: true)
    let urlItem = ClipboardItem(kind: .url, title: "TailNeedle", text: "https://example.com/TailNeedle", contentHash: "url-search")
    let search = ClipboardSearch(items: [textItem, urlItem], revision: 3, debounceInterval: 0)
    let tailQuery = ClipboardSearchQuery(text: "  tailneedle 中文结尾\n", kind: .text, pinnedOnly: true)
    search.search(query: tailQuery)
    waitForSearch("search should reach Unicode text beyond the preview") { search.matchingItems(query: tailQuery, revision: 3) != nil }
    check(search.result?.items.map(\.id) == [textItem.id], "full-text search must preserve case-insensitive substring and scope semantics")

    let sourceQuery = ClipboardSearchQuery(text: "COM.APPLE.SAFARI")
    search.search(query: sourceQuery)
    waitForSearch("source metadata should remain searchable") { search.matchingItems(query: sourceQuery, revision: 3) != nil }
    check(search.result?.items.map(\.id) == [textItem.id], "source bundle identifiers must remain searchable")
    let fileItem = ClipboardItem(kind: .file, title: "File", fileURLs: ["file:///tmp/Example%20Document.txt"], contentHash: "file-search")
    search.update(items: [fileItem, urlItem], revision: 4)
    let fileQuery = ClipboardSearchQuery(text: "document.txt", kind: .file)
    search.search(query: fileQuery)
    waitForSearch("file references should remain searchable") { search.matchingItems(query: fileQuery, revision: 4) != nil }
    check(search.result?.items.map(\.id) == [fileItem.id], "file URL fields must remain searchable")
}

func testBackgroundSearchLatestQueryAndRevisionWin() {
    let queue = DispatchQueue(label: "CPasteSearchChecks.latest")
    queue.suspend()
    let old = ClipboardItem(kind: .text, title: "Old", text: "old needle", contentHash: "old-search")
    let new = ClipboardItem(kind: .text, title: "New", text: "new needle", contentHash: "new-search", isPinned: true)
    let search = ClipboardSearch(items: [old], revision: 1, debounceInterval: 0, queue: queue)
    var deliveredQueries: [String] = []
    let subscription = search.$result.compactMap { $0 }.sink { deliveredQueries.append($0.query.text) }
    search.search(query: .init(text: "old"))
    search.update(items: [new], revision: 2)
    let latest = ClipboardSearchQuery(text: "new", kind: .text, pinnedOnly: true)
    search.search(query: latest)
    check(search.matchingItems(query: latest, revision: 2) == nil, "pending queries must not expose old rows")
    queue.resume()
    waitForSearch("latest search should finish") { search.matchingItems(query: latest, revision: 2) != nil }
    check(search.result?.items.map(\.id) == [new.id], "deleted rows must not survive a data revision")
    check(deliveredQueries == ["new"], "superseded queries must not publish results")

    // Before the UI has submitted its next query, the read gate must already
    // reject a result for a different query or revision (e.g. an immediate Enter).
    check(search.matchingItems(query: .init(text: "different"), revision: 2) == nil, "unsubmitted input must not reuse results from the previous query")
    check(search.matchingItems(query: latest, revision: 3) == nil, "new store revisions must reject old results immediately")
    search.update(items: [ClipboardItem(kind: .text, title: "Unpinned", text: "new needle", contentHash: "unpinned-search")], revision: 3)
    check(search.result == nil, "changing pin state must immediately invalidate the old result")
    waitForSearch("pin-state replacement search should finish") { search.matchingItems(query: latest, revision: 3) != nil }
    check(search.result?.items.isEmpty == true, "pinned-only search must exclude items after they are unpinned")
    withExtendedLifetime(subscription) {}
}

func testBackgroundSearchDiscardsAlreadyQueuedCompletions() {
    let queue = DispatchQueue(label: "CPasteSearchChecks.completed")
    let item = ClipboardItem(kind: .text, title: "Fixture", text: "first second", contentHash: "queued-search")
    let search = ClipboardSearch(items: [item], revision: 1, debounceInterval: 0, queue: queue)
    var deliveredQueries: [String] = []
    let subscription = search.$result.compactMap { $0 }.sink { deliveredQueries.append($0.query.text) }
    search.search(query: .init(text: "first"))
    let workerFinished = DispatchSemaphore(value: 0)
    queue.async { workerFinished.signal() }
    check(workerFinished.wait(timeout: .now() + 2) == .success, "first background query should finish while main delivery is withheld")
    let latest = ClipboardSearchQuery(text: "second")
    search.search(query: latest)
    waitForSearch("replacement completion should be delivered") { search.matchingItems(query: latest, revision: 1) != nil }
    check(deliveredQueries == ["second"], "completion queued before a newer query must still be discarded at delivery")
    withExtendedLifetime(subscription) {}
}

func testBackgroundSearchCancelAndEmptyQuery() {
    let queue = DispatchQueue(label: "CPasteSearchChecks.cancel")
    queue.suspend()
    let pinned = ClipboardItem(kind: .text, title: "Pinned", text: "match", contentHash: "cancel-pinned", isPinned: true)
    let other = ClipboardItem(kind: .url, title: "Other", text: "match", contentHash: "cancel-other")
    let search = ClipboardSearch(items: [pinned, other], revision: 1, debounceInterval: 0, queue: queue)
    var deliveries = 0
    let subscription = search.$result.compactMap { $0 }.sink { _ in deliveries += 1 }
    search.search(query: .init(text: "match"))
    search.cancel()
    search.update(items: [pinned], revision: 2)
    queue.resume()
    RunLoop.current.run(until: Date().addingTimeInterval(0.03))
    check(deliveries == 0 && search.result == nil, "closing a search must prevent pending and data-update work from publishing")
    let empty = ClipboardSearchQuery(text: " \n ", kind: .text, pinnedOnly: true)
    search.search(query: empty)
    check(search.matchingItems(query: empty, revision: 2)?.map(\.id) == [pinned.id], "empty searches should immediately apply only lightweight type and pin filters")
    withExtendedLifetime(subscription) {}
}

func testSearchSelectionSurvivesPendingResultsAndRestoresScroll() {
    let first = UUID()
    let previous = UUID()
    let removed = UUID()
    let last = UUID()
    let originalIDs = [first, previous, removed, last]
    var selectedID = TimelineSelection.replacementID(afterRemoving: removed, from: originalIDs)
    check(selectedID == previous, "deleting a middle match should first select its predecessor")

    func apply(_ change: TimelineSelection.Change) {
        if case .select(let id) = change { selectedID = id }
    }
    apply(TimelineSelection.reconcile(selectedID: selectedID, visibleIDs: [], isSearching: true))
    check(selectedID == previous, "pending empty results must preserve the deletion replacement")
    for navigation in [TimelineSelection.Navigation.offset(-1), .offset(1), .index(0), .index(-1)] {
        check(
            TimelineSelection.navigate(navigation, selectedID: selectedID, visibleIDs: [], isSearching: true) == .unchanged,
            "navigation during pending results must not clear or move the retained selection"
        )
    }
    let pendingTarget = TimelineSelection.scrollTarget(
        selectedID: selectedID, visibleIDs: [], isSearching: true, shouldScroll: true
    )
    check(pendingTarget == nil, "pending results must not scroll to an absent row")

    let completedIDs = [first, previous, last]
    apply(TimelineSelection.reconcile(selectedID: selectedID, visibleIDs: completedIDs, isSearching: false))
    check(selectedID == previous, "completed replacement results must retain the predecessor rather than select the first match")
    let restoredTarget = TimelineSelection.scrollTarget(
        selectedID: selectedID, visibleIDs: completedIDs, isSearching: false, shouldScroll: true
    )
    check(restoredTarget == previous && restoredTarget != pendingTarget, "restoring valid results must restore the scroll target even when selectedID never changed")
    check(
        TimelineSelection.scrollTarget(selectedID: selectedID, visibleIDs: completedIDs, isSearching: false, shouldScroll: false) == nil,
        "a pointer selection must not force a scroll when results return"
    )
    apply(TimelineSelection.navigate(.offset(1), selectedID: selectedID, visibleIDs: completedIDs, isSearching: false))
    check(selectedID == last, "navigation should resume from the retained selection after the search completes")

    apply(TimelineSelection.reconcile(selectedID: selectedID, visibleIDs: [], isSearching: true))
    check(selectedID == last, "another pending search must preserve the current selection")
    // IDs remain [] at completion, so the View also reconciles on isSearching.
    apply(TimelineSelection.reconcile(selectedID: selectedID, visibleIDs: [], isSearching: false))
    check(selectedID == nil, "a completed empty result must clear the selection even when its IDs did not change")
    apply(TimelineSelection.reconcile(selectedID: selectedID, visibleIDs: [first], isSearching: false))
    check(selectedID == first, "a later nonempty result should select its first item")
}
