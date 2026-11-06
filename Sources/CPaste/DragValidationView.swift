import AppKit
import CPasteCore
import SwiftUI

/// An isolated native drag destination for the snapshot preview entry point.
/// Every action and file belongs to this fixture; it never uses live history.
struct DragValidationView: View {
    @StateObject private var fixture = DragValidationFixture()

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(CPasteL10n.text("多文件拖出验收", "Multiple-file drag validation"))
                .font(.title2.bold())
            Text(CPasteL10n.text("将左侧卡片拖到右侧接收区。接收区只校验本页创建的两个临时文件。", "Drag the card into the receiver. Only the two temporary files created by this fixture are accepted."))
                .foregroundStyle(CPasteTheme.textSecondary)
            HStack(spacing: 36) {
                if let item = fixture.item {
                    TimelineCardView(
                        item: item, position: 1, isSelected: fixture.selectionCount > 0,
                        size: CGSize(width: 250, height: 290), imageURL: nil, ageText: "Fixture",
                        select: { fixture.selectionCount += 1 },
                        paste: { fixture.pasteCount += 1 },
                        pastePlainText: { fixture.pasteCount += 1 },
                        copy: { fixture.actionMessage = "Copy action received (fixture only)" },
                        togglePinned: { fixture.item?.isPinned.toggle() },
                        open: { fixture.actionMessage = "Open action received (fixture only)" },
                        delete: { fixture.actionMessage = "Delete action received (fixture only)" }
                    )
                }
                DragValidationDropWell(
                    expected: fixture.files,
                    message: fixture.dropMessage,
                    diagnostic: { fixture.recordDragEvent($0) }
                ) { count in
                    fixture.dropMessage = "\(count) items received · original bytes verified"
                }
                .frame(width: 320, height: 290)
            }
            Text("Selections: \(fixture.selectionCount) · Double-click actions: \(fixture.pasteCount)")
                .font(.system(.body, design: .monospaced))
                .accessibilityIdentifier("drag-fixture-actions")
            Text(fixture.actionMessage)
                .foregroundStyle(CPasteTheme.textSecondary)
                .lineLimit(1)
        }
        .padding(28)
        .frame(width: 730, height: 530)
        .background(CPasteTheme.background)
        .foregroundStyle(CPasteTheme.textPrimary)
        .preferredColorScheme(.dark)
    }
}

@MainActor
private final class DragValidationFixture: ObservableObject {
    @Published var item: ClipboardItem?
    @Published var selectionCount = 0
    @Published var pasteCount = 0
    @Published var actionMessage = "Ready · no live clipboard or history actions"
    @Published var dropMessage = "Drop both temporary files here"
    private(set) var files: [URL: Data] = [:]
    private let directory: URL
    private var dragEvents: [String] = []

    func recordDragEvent(_ event: String) {
        guard dragEvents.last != event else { return }
        dragEvents.append(event)
        if dragEvents.count > 4 { dragEvents.removeFirst() }
        actionMessage = dragEvents.joined(separator: " → ")
    }

    init() {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("CPasteDragPreview-\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let first = directory.appendingPathComponent("第一项.txt")
            let second = directory.appendingPathComponent("second.txt")
            let firstBytes = Data("CPaste native drag fixture 中文\n".utf8)
            let secondBytes = Data("CPaste second native drag fixture 👨‍👩‍👧‍👦\n".utf8)
            try firstBytes.write(to: first, options: [.atomic])
            try secondBytes.write(to: second, options: [.atomic])
            files = [first.standardizedFileURL: firstBytes, second.standardizedFileURL: secondBytes]
            item = ClipboardItem(
                kind: .file, title: "Two temporary files", subtitle: "2 files",
                text: first.path + "\n" + second.path,
                fileURLs: [first.absoluteString, second.absoluteString],
                contentHash: "isolated-drag-fixture", sourceAppName: "Drag Fixture"
            )
        } catch { actionMessage = "Fixture creation failed: \(error.localizedDescription)" }
    }

    deinit { try? FileManager.default.removeItem(at: directory) }
}

private struct DragValidationDropWell: NSViewRepresentable {
    let expected: [URL: Data]
    let message: String
    let diagnostic: (String) -> Void
    let received: (Int) -> Void

    func makeNSView(context: Context) -> DragValidationDestination {
        let view = DragValidationDestination()
        updateNSView(view, context: context)
        return view
    }

    func updateNSView(_ nsView: DragValidationDestination, context: Context) {
        nsView.expected = expected
        nsView.message = message
        nsView.diagnostic = diagnostic
        nsView.received = received
        nsView.setAccessibilityLabel(message)
        nsView.needsDisplay = true
    }
}

private final class DragValidationDestination: NSView {
    var expected: [URL: Data] = [:]
    var message = ""
    var diagnostic: ((String) -> Void)?
    var received: ((Int) -> Void)?
    private var isReceiving = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes([.fileURL])
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        let urls = fixtureURLs(from: sender)
        isReceiving = urls != nil
        diagnostic?(urls.map { "entered: \($0.count) URLs" } ?? "entered: rejected")
        needsDisplay = true
        return isReceiving ? .copy : []
    }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        isReceiving = fixtureURLs(from: sender) != nil
        needsDisplay = true
        return isReceiving ? .copy : []
    }
    override func draggingExited(_ sender: NSDraggingInfo?) {
        diagnostic?("exited")
        isReceiving = false
        needsDisplay = true
    }
    override func draggingEnded(_ sender: NSDraggingInfo) { diagnostic?("ended") }
    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let urls = fixtureURLs(from: sender)
        diagnostic?(urls.map { "prepare: \($0.count) URLs" } ?? "prepare: rejected")
        return urls != nil
    }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        defer { isReceiving = false; needsDisplay = true }
        guard let urls = fixtureURLs(from: sender) else {
            diagnostic?("perform: rejected URLs")
            return false
        }
        guard urls.allSatisfy({ (try? Data(contentsOf: $0)) == expected[$0] }) else {
            diagnostic?("perform: bytes FAIL")
            return false
        }
        diagnostic?("perform: bytes OK")
        received?(urls.count)
        return true
    }

    private func fixtureURLs(from sender: NSDraggingInfo) -> [URL]? {
        guard !expected.isEmpty,
              let values = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]
        else { return nil }
        let urls = values.map(\.standardizedFileURL)
        guard urls.count == expected.count, Set(urls) == Set(expected.keys) else { return nil }
        return urls
    }

    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 2, dy: 2), xRadius: 16, yRadius: 16)
        NSColor(calibratedWhite: 1, alpha: isReceiving ? 0.12 : 0.04).setFill()
        path.fill()
        (isReceiving ? NSColor.systemTeal : NSColor.separatorColor).setStroke()
        path.lineWidth = 2
        path.stroke()
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        let text = NSAttributedString(string: message, attributes: [
            .font: NSFont.systemFont(ofSize: 17, weight: .medium),
            .foregroundColor: NSColor.labelColor,
            .paragraphStyle: paragraph
        ])
        text.draw(in: bounds.insetBy(dx: 28, dy: 105))
    }
}
