import AppKit
import CPasteCore
import SwiftUI

/// SwiftUI's macOS 13 onDrag API supplies one item. File groups use the native
/// dragging session API so each URL remains a separate pasteboard item.
struct ClipboardDragSource: ViewModifier {
    let item: ClipboardItem
    let imageURL: URL?
    @StateObject private var source = MultipleFileDragController()

    @ViewBuilder
    func body(content: Content) -> some View {
        if item.kind == .file, item.fileURLs.count > 1 {
            content
                .background(MultipleFileDragAnchor(source: source, item: item).allowsHitTesting(false))
        } else {
            content.onDrag {
                ClipboardDragExport.providers(for: item, imageURL: imageURL).first ?? NSItemProvider()
            }
        }
    }
}

@MainActor
private final class MultipleFileDragController: NSObject, ObservableObject, NSDraggingSource {
    private struct MouseDown {
        let event: NSEvent
        let item: ClipboardItem
    }
    private struct StartingDrag {
        let id: UUID
        let windowNumber: Int
        let downTimestamp: TimeInterval
        var mouseUp: NSEvent?
    }

    private weak var anchor: NSView?
    private var item: ClipboardItem?
    private var mouseDown: MouseDown?
    private var session: NSDraggingSession?
    private var activeSessionID: UUID?
    private var starting: StartingDrag?

    func attach(to anchor: NSView, item: ClipboardItem) {
        if self.anchor !== anchor { mouseDown = nil }
        self.anchor = anchor
        self.item = item
        #if CPASTE_NATIVE_DRAG_TRACE
        trace("source.attach")
        #endif
        MultipleFileDragEventMonitor.shared.attach(self)
    }

    func detach(from anchor: NSView) {
        #if CPASTE_NATIVE_DRAG_TRACE
        trace("source.detach.request requestedAnchor=\(NativeFileDragTrace.id(anchor))")
        #endif
        guard self.anchor === anchor else { return }
        mouseDown = nil
        item = nil
        self.anchor = nil
        #if CPASTE_NATIVE_DRAG_TRACE
        trace("source.detach.accepted")
        #endif
        MultipleFileDragEventMonitor.shared.detach(self)
        returnHeldMouseUp()
    }

    /// Only the mouse-up belonging to an already-starting native drag can be
    /// held. All ordinary click/menu events continue through their usual path.
    func observe(_ event: NSEvent) -> Bool {
        #if CPASTE_NATIVE_DRAG_TRACE
        trace("source.observe", event: event)
        #endif
        guard let anchor, let window = anchor.window,
              window.isVisible, window.attachedSheet == nil,
              NSApp.modalWindow == nil || NSApp.modalWindow === window,
              !anchor.isHiddenOrHasHiddenAncestor,
              event.windowNumber == window.windowNumber
        else {
            mouseDown = nil
            #if CPASTE_NATIVE_DRAG_TRACE
            trace("source.observe.rejectedWindow", event: event)
            #endif
            return false
        }

        if event.type == .leftMouseUp, var pending = starting,
           pending.id == activeSessionID, pending.mouseUp == nil,
           event.windowNumber == pending.windowNumber, event.timestamp >= pending.downTimestamp {
            pending.mouseUp = event
            starting = pending
            mouseDown = nil
            #if CPASTE_NATIVE_DRAG_TRACE
            trace("source.starting.heldUp", event: event)
            #endif
            return true
        }

        // A hosting view can report a visibleRect larger than this background
        // anchor. A file drag must still originate inside the actual card.
        let dragBounds = anchor.bounds.intersection(anchor.visibleRect)
        switch event.type {
        case .leftMouseDown:
            mouseDown = nil
            let point = anchor.convert(event.locationInWindow, from: nil)
            guard activeSessionID == nil, let item,
                  dragBounds.contains(point),
                  !event.modifierFlags.contains(.control),
                  !startsOnNativeControl(event, in: window)
            else {
                #if CPASTE_NATIVE_DRAG_TRACE
                trace("source.down.rejected", event: event)
                #endif
                return false
            }
            // Freeze both the original native down event and the source data.
            // SwiftUI may update/reorder the card before the next mouse event.
            mouseDown = MouseDown(event: event, item: item)
            #if CPASTE_NATIVE_DRAG_TRACE
            trace("source.down.seeded", event: event)
            #endif
        case .leftMouseDragged:
            guard activeSessionID == nil, let down = mouseDown,
                  event.timestamp >= down.event.timestamp,
                  dragBounds.contains(anchor.convert(down.event.locationInWindow, from: nil))
            else {
                mouseDown = nil
                #if CPASTE_NATIVE_DRAG_TRACE
                trace("source.drag.rejected", event: event)
                #endif
                return false
            }
            let dx = event.locationInWindow.x - down.event.locationInWindow.x
            let dy = event.locationInWindow.y - down.event.locationInWindow.y
            guard dx * dx + dy * dy >= 36 else {
                #if CPASTE_NATIVE_DRAG_TRACE
                trace("source.drag.belowThreshold", event: event)
                #endif
                return false
            }
            mouseDown = nil
            begin(item: down.item, mouseDownEvent: down.event, anchor: anchor)
        default:
            mouseDown = nil
            #if CPASTE_NATIVE_DRAG_TRACE
            trace("source.seed.cleared", event: event)
            #endif
        }
        return false
    }

    #if CPASTE_NATIVE_DRAG_TRACE
    private func trace(_ phase: String, event: NSEvent? = nil) {
        let window = anchor?.window
        let geometry = anchor.map {
            "bounds=\(NativeFileDragTrace.rect($0.bounds)) visibleRect=\(NativeFileDragTrace.rect($0.visibleRect)) dragBounds=\(NativeFileDragTrace.rect($0.bounds.intersection($0.visibleRect))) hidden=\($0.isHiddenOrHasHiddenAncestor)"
        } ?? "anchorGeometry=nil"
        let eventState = event.map { " " + NativeFileDragTrace.event($0) } ?? ""
        NativeFileDragTrace.write(
            "\(phase) source=\(NativeFileDragTrace.id(self)) anchor=\(NativeFileDragTrace.id(anchor)) window=\(window?.windowNumber ?? -1) visible=\(window?.isVisible ?? false) sheet=\(window?.attachedSheet != nil) modalWindow=\(NSApp.modalWindow?.windowNumber ?? -1) active=\(activeSessionID?.uuidString ?? "nil") session=\(NativeFileDragTrace.id(session)) downSeed=\(mouseDown != nil) starting=\(starting?.id.uuidString ?? "nil") heldUp=\(starting?.mouseUp != nil) \(geometry)\(eventState)"
        )
    }
    #endif

    private func startsOnNativeControl(_ event: NSEvent, in window: NSWindow) -> Bool {
        guard let content = window.contentView else { return true }
        var hit = content.hitTest(content.convert(event.locationInWindow, from: nil))
        while let view = hit {
            #if CPASTE_NATIVE_DRAG_TRACE
            NativeFileDragTrace.write("source.hit source=\(NativeFileDragTrace.id(self)) viewType=\(String(reflecting: type(of: view)))")
            #endif
            if let field = view as? NSTextField {
                if field.isEditable || field.isSelectable { return true }
            } else if view is NSControl || view is NSTextView { return true }
            hit = view.superview
        }
        return false
    }

    private func begin(item: ClipboardItem, mouseDownEvent: NSEvent, anchor: NSView) {
        let items = ClipboardDragExport.draggingItems(for: item)
        #if CPASTE_NATIVE_DRAG_TRACE
        trace("source.begin.providers count=\(items.count)", event: mouseDownEvent)
        #endif
        guard items.count > 1 else { return }
        let origin = anchor.convert(mouseDownEvent.locationInWindow, from: nil)
        let icon = NSImage(systemSymbolName: "doc.fill", accessibilityDescription: nil)
        for (index, draggingItem) in items.enumerated() {
            let offset = CGFloat(min(index, 5)) * 3
            let frame = NSRect(x: origin.x - 20 + offset, y: origin.y - 20 - offset, width: 40, height: 40)
            draggingItem.setDraggingFrame(frame, contents: icon)
        }
        let sessionID = UUID()
        activeSessionID = sessionID
        starting = StartingDrag(id: sessionID, windowNumber: mouseDownEvent.windowNumber, downTimestamp: mouseDownEvent.timestamp, mouseUp: nil)
        #if CPASTE_NATIVE_DRAG_TRACE
        trace("source.begin.call", event: mouseDownEvent)
        #endif
        // Begin directly in native event dispatch, using the actual mouse-down
        // event required by AppKit. No SwiftUI gesture owns this drag's mouse-up.
        let session = anchor.beginDraggingSession(with: items, event: mouseDownEvent, source: self)
        #if CPASTE_NATIVE_DRAG_TRACE
        trace("source.begin.return returnedSession=\(NativeFileDragTrace.id(session)) sameID=\(activeSessionID == sessionID)")
        #endif
        // AppKit may run tracking callbacks before this method returns.
        if activeSessionID == sessionID { configure(session) }
    }

    private func configure(_ session: NSDraggingSession) {
        self.session = session
        session.draggingFormation = .stack
        session.animatesToStartingPositionsOnCancelOrFail = true
        #if CPASTE_NATIVE_DRAG_TRACE
        trace("source.session.configured")
        #endif
    }

    func draggingSession(_ session: NSDraggingSession, willBeginAt screenPoint: NSPoint) {
        #if CPASTE_NATIVE_DRAG_TRACE
        trace("source.willBegin callbackSession=\(NativeFileDragTrace.id(session))")
        #endif
        guard self.session == nil || self.session === session else { return }
        let pending = starting?.id == activeSessionID ? starting : nil
        // Clear the starting phase before reposting. If the local monitor sees
        // this same event again it must pass it to native tracking exactly once.
        if pending != nil { starting = nil }
        configure(session)
        if let pending, pending.id == activeSessionID, let mouseUp = pending.mouseUp {
            #if CPASTE_NATIVE_DRAG_TRACE
            trace("source.willBegin.postHeldUp", event: mouseUp)
            #endif
            NSApp.postEvent(mouseUp, atStart: true)
        }
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        #if CPASTE_NATIVE_DRAG_TRACE
        trace("source.operationMask context=\(context.rawValue) callbackSession=\(NativeFileDragTrace.id(session))")
        #endif
        return .copy
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        #if CPASTE_NATIVE_DRAG_TRACE
        trace("source.ended callbackSession=\(NativeFileDragTrace.id(session)) operation=\(operation.rawValue) matches=\(self.session == nil || self.session === session)")
        #endif
        guard self.session == nil || self.session === session else { return }
        mouseDown = nil
        self.session = nil
        activeSessionID = nil
        returnHeldMouseUp()
        #if CPASTE_NATIVE_DRAG_TRACE
        trace("source.ended.cleared")
        #endif
    }

    private func returnHeldMouseUp() {
        let mouseUp = starting?.mouseUp
        starting = nil
        if let mouseUp {
            #if CPASTE_NATIVE_DRAG_TRACE
            trace("source.cancel.postHeldUp", event: mouseUp)
            #endif
            NSApp.postEvent(mouseUp, atStart: true)
        }
    }
}

/// One local monitor serves attached file cards. Ordinary events are unchanged;
/// only a native drag's early mouse-up is held until its tracking loop starts.
@MainActor
private final class MultipleFileDragEventMonitor {
    static let shared = MultipleFileDragEventMonitor()
    private struct WeakSource { weak var value: MultipleFileDragController? }
    private var sources: [ObjectIdentifier: WeakSource] = [:]
    private var monitor: Any?

    func attach(_ source: MultipleFileDragController) {
        sources[ObjectIdentifier(source)] = WeakSource(value: source)
        #if CPASTE_NATIVE_DRAG_TRACE
        NativeFileDragTrace.write("monitor.attach source=\(NativeFileDragTrace.id(source)) count=\(sources.count) installed=\(monitor != nil)")
        #endif
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [
            .leftMouseDown, .leftMouseDragged, .leftMouseUp,
            .rightMouseDown, .otherMouseDown, .scrollWheel, .keyDown
        ]) { [weak self] event in
            #if CPASTE_NATIVE_DRAG_TRACE
            NativeFileDragTrace.write("monitor.callback " + NativeFileDragTrace.event(event))
            #endif
            guard let self else { return event }
            return self.observe(event)
        }
        #if CPASTE_NATIVE_DRAG_TRACE
        NativeFileDragTrace.write("monitor.installed count=\(sources.count) installed=\(monitor != nil)")
        #endif
    }

    func detach(_ source: MultipleFileDragController) {
        sources[ObjectIdentifier(source)] = nil
        #if CPASTE_NATIVE_DRAG_TRACE
        NativeFileDragTrace.write("monitor.detach source=\(NativeFileDragTrace.id(source)) count=\(sources.count)")
        #endif
        removeUnusedSources()
    }

    private func observe(_ event: NSEvent) -> NSEvent? {
        removeUnusedSources()
        // Native tracking can reenter event dispatch or detach views. Snapshot
        // the weak registry before calling a source that starts a session.
        let attached = sources.values.compactMap(\.value)
        #if CPASTE_NATIVE_DRAG_TRACE
        NativeFileDragTrace.write("monitor.dispatch count=\(attached.count)")
        #endif
        var consumed = false
        for source in attached {
            if source.observe(event) { consumed = true }
        }
        return consumed ? nil : event
    }

    private func removeUnusedSources() {
        sources = sources.filter { $0.value.value != nil }
        if sources.isEmpty, let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
            #if CPASTE_NATIVE_DRAG_TRACE
            NativeFileDragTrace.write("monitor.removed count=0")
            #endif
        }
    }
}

private struct MultipleFileDragAnchor: NSViewRepresentable {
    let source: MultipleFileDragController
    let item: ClipboardItem

    func makeNSView(context: Context) -> NonInteractiveDragAnchor {
        let view = NonInteractiveDragAnchor()
        view.configure(source: source, item: item)
        return view
    }

    func updateNSView(_ nsView: NonInteractiveDragAnchor, context: Context) {
        nsView.configure(source: source, item: item)
    }

    static func dismantleNSView(_ nsView: NonInteractiveDragAnchor, coordinator: ()) { nsView.detach() }
}

private final class NonInteractiveDragAnchor: NSView {
    private var source: MultipleFileDragController?
    private var item: ClipboardItem?

    func configure(source: MultipleFileDragController, item: ClipboardItem) {
        #if CPASTE_NATIVE_DRAG_TRACE
        NativeFileDragTrace.write("anchor.configure anchor=\(NativeFileDragTrace.id(self)) source=\(NativeFileDragTrace.id(source)) window=\(window?.windowNumber ?? -1)")
        #endif
        if self.source !== source { detach() }
        self.source = source
        self.item = item
        updateAttachment()
    }

    func detach() {
        #if CPASTE_NATIVE_DRAG_TRACE
        NativeFileDragTrace.write("anchor.detach anchor=\(NativeFileDragTrace.id(self)) window=\(window?.windowNumber ?? -1)")
        #endif
        source?.detach(from: self)
        source = nil
        item = nil
    }

    private func updateAttachment() {
        guard let source, let item else { return }
        if window == nil { source.detach(from: self) }
        else { source.attach(to: self, item: item) }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        #if CPASTE_NATIVE_DRAG_TRACE
        NativeFileDragTrace.write("anchor.movedToWindow anchor=\(NativeFileDragTrace.id(self)) window=\(window?.windowNumber ?? -1)")
        #endif
        updateAttachment()
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

#if CPASTE_NATIVE_DRAG_TRACE
/// Available only in a custom diagnostic build, for the isolated scene and an
/// explicitly supplied log file. Records geometry/state, never item data/paths.
@MainActor
private enum NativeFileDragTrace {
    private static var sequence = 0
    private static let queue = DispatchQueue(label: "local.cpaste.native-drag-trace")
    private static let output: FileHandle? = {
        let arguments = ProcessInfo.processInfo.arguments
        guard let scene = arguments.firstIndex(of: "--snapshot-preview"),
              arguments.indices.contains(scene + 1),
              (arguments[scene + 1] as NSString).deletingPathExtension == "12-multi-file-drag",
              let flag = arguments.firstIndex(of: "--native-drag-trace-log"),
              arguments.indices.contains(flag + 1)
        else { return nil }
        let url = URL(fileURLWithPath: arguments[flag + 1])
        if !FileManager.default.fileExists(atPath: url.path) {
            guard FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600]) else { return nil }
        }
        return try? FileHandle(forWritingTo: url)
    }()

    static func write(_ message: String) {
        guard let output else { return }
        sequence += 1
        let line = "\(ProcessInfo.processInfo.systemUptime) #\(sequence) \(message)\n"
        let data = Data(line.utf8)
        queue.async {
            _ = try? output.seekToEnd()
            try? output.write(contentsOf: data)
        }
    }

    static func id(_ object: AnyObject?) -> String {
        object.map { String(describing: ObjectIdentifier($0)) } ?? "nil"
    }

    static func rect(_ rect: NSRect) -> String { NSStringFromRect(rect) }

    static func event(_ event: NSEvent) -> String {
        "eventType=\(event.type.rawValue) eventWindow=\(event.windowNumber) eventTime=\(event.timestamp) point=\(NSStringFromPoint(event.locationInWindow)) flags=\(event.modifierFlags.rawValue) pressedButtons=\(NSEvent.pressedMouseButtons)"
    }
}
#endif
