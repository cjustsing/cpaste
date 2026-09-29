import AppKit
import CPasteCore
import Foundation

func testLargeTextKeepsFullContentWithBoundedPreviews() {
    let text = "长文开头 👨‍👩‍👧‍👦\n" + String(repeating: "abcdefg 中文段落\r\n", count: 350_000) + "CPasteTailNeedle"
    check(text.utf8.count > 7 * 1_024 * 1_024, "fixture must exceed 7 MiB")
    let pasteboard = NSPasteboard(name: .init("CPasteLargeText-\(UUID().uuidString)"))
    pasteboard.setString(text, forType: .string)
    defer { pasteboard.releaseGlobally() }
    let started = CFAbsoluteTimeGetCurrent()
    guard let captured = PasteboardReader.read(from: pasteboard) else {
        check(false, "large text must be captured")
        return
    }
    check(captured.kind == .text && captured.text == text, "capture must preserve the entire long text")
    check(captured.title.count <= 93, "long text title must stay bounded")
    check(captured.subtitle == "\(text.utf8.count) bytes", "large text should use its stored size summary")

    let directory = makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = ClipboardStore(storageDirectory: directory)
    store.insertCaptured(captured)
    let reloaded = ClipboardStore(storageDirectory: directory)
    check(reloaded.items.first?.text == text, "persistence must not truncate the original content")
    check(reloaded.filteredItems(search: "cpastetailneedle").count == 1, "search must find text beyond the preview, ignoring case")
    check(reloaded.filteredItems(search: "missing-needle").isEmpty, "large text must not produce false search matches")
    for limit in [ClipboardText.cardLimit, ClipboardText.inspectorLimit] {
        let preview = ClipboardText.excerpt(text, limit: limit)
        check(preview.text.unicodeScalars.count <= limit, "rendered preview must be bounded")
        check(preview.isTruncated, "large text preview must indicate omitted content")
        check(text.hasPrefix(preview.text), "preview must preserve the beginning of the text")
    }
    let item = reloaded.items[0]
    check(PasteboardWriter.write(item, blobDirectory: store.blobDirectory, to: pasteboard), "long text must copy successfully")
    check(pasteboard.string(forType: .string) == text, "copy must include content beyond the preview")
    check(PasteboardWriter.writePlainText(item, to: pasteboard), "long text must support plain text paste")
    check(pasteboard.string(forType: .string) == text, "plain text paste must preserve all content")
    print("Large text capture/search/persistence/paste checks: \(String(format: "%.3f", CFAbsoluteTimeGetCurrent() - started))s")
}

func testTextExcerptsPreserveSmallAndUnicodeContent() {
    for text in ["", "短文本", "line 1\r\nline 2", "👨‍👩‍👧‍👦 cafe\u{301}"] {
        let preview = ClipboardText.excerpt(text, limit: ClipboardText.cardLimit)
        check(preview.text == text && !preview.isTruncated, "short previews must preserve their exact content")
    }
    let combining = "e" + String(repeating: "\u{301}", count: 100_000)
    let preview = ClipboardText.excerpt(combining, limit: 32)
    check(preview.text.unicodeScalars.count == 32 && preview.isTruncated, "even a single giant grapheme must have a bounded preview")
    check(ClipboardText.title(for: "\n  first\n second \n") == "first second", "title should flatten ordinary multiline text")
    check(ClipboardText.summary(for: "hello") == "5 characters", "small text retains character counts")
    check(ClipboardText.summary(for: "first\nsecond") == "2 lines", "small multiline text retains line counts")
}
