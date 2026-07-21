import AppKit
import SwiftUI

enum HistoryKeyboardCommand: Equatable {
    case previous
    case next
    case first
    case last
    case paste
    case pastePlainText
    case copy
    case togglePinned
    case delete
    case closeOrClearSearch
    case toggleInspector
    case focusSearch
    case focusTimeline
    case quickPaste(Int)
    case showHistory
    case showPinned
    case showSettings
    case toggleCapture
}

struct HistoryKeyboardMonitor: NSViewRepresentable {
    var isSearchFocused: Bool
    var handle: (HistoryKeyboardCommand) -> Bool

    func makeCoordinator() -> Coordinator {
        Coordinator(isSearchFocused: isSearchFocused, handle: handle)
    }

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        context.coordinator.hostView = view
        context.coordinator.install()
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.hostView = nsView
        context.coordinator.isSearchFocused = isSearchFocused
        context.coordinator.handle = handle
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.uninstall()
    }

    final class Coordinator {
        weak var hostView: NSView?
        var isSearchFocused: Bool
        var handle: (HistoryKeyboardCommand) -> Bool
        private var monitor: Any?

        init(isSearchFocused: Bool, handle: @escaping (HistoryKeyboardCommand) -> Bool) {
            self.isSearchFocused = isSearchFocused
            self.handle = handle
        }

        func install() {
            guard monitor == nil else {
                return
            }

            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self,
                      let window = self.hostView?.window,
                      event.window === window,
                      let command = self.command(for: event),
                      self.handle(command)
                else {
                    return event
                }
                return nil
            }
        }

        func uninstall() {
            if let monitor {
                NSEvent.removeMonitor(monitor)
            }
            monitor = nil
        }

        private func command(for event: NSEvent) -> HistoryKeyboardCommand? {
            Self.command(
                forKeyCode: event.keyCode,
                modifierFlags: event.modifierFlags,
                isSearchFocused: isSearchFocused
            )
        }

        static func command(
            forKeyCode keyCode: UInt16,
            modifierFlags: NSEvent.ModifierFlags,
            isSearchFocused: Bool
        ) -> HistoryKeyboardCommand? {
            let flags = modifierFlags.intersection(.deviceIndependentFlagsMask)
            let hasCommand = flags.contains(.command)
            let hasShift = flags.contains(.shift)
            let hasOption = flags.contains(.option)
            let hasControl = flags.contains(.control)

            if hasOption, !hasCommand, !hasShift, !hasControl {
                switch keyCode {
                case 18:
                    return .showHistory
                case 19:
                    return .showPinned
                default:
                    return nil
                }
            }

            if hasCommand, !hasOption, !hasControl {
                if let number = Self.numberKeyCodes[keyCode] {
                    return .quickPaste(number)
                }

                switch keyCode {
                case 3:
                    return .focusSearch
                case 8 where !isSearchFocused:
                    return .copy
                case 43:
                    return .showSettings
                case 17:
                    return .toggleCapture
                case 126:
                    return .first
                case 125:
                    return .last
                default:
                    return nil
                }
            }

            guard !hasCommand, !hasOption, !hasControl else {
                return nil
            }

            switch keyCode {
            case 53:
                return .closeOrClearSearch
            case 36, 76:
                return hasShift ? .pastePlainText : .paste
            case 48:
                return isSearchFocused ? .focusTimeline : .focusSearch
            case 125 where isSearchFocused:
                return .focusTimeline
            case 49 where !isSearchFocused:
                return .toggleInspector
            case 35 where !isSearchFocused:
                return .togglePinned
            case 51 where !isSearchFocused,
                 117 where !isSearchFocused:
                return .delete
            case 123 where !isSearchFocused:
                return .previous
            case 124 where !isSearchFocused:
                return .next
            case 126 where !isSearchFocused:
                return .previous
            case 125 where !isSearchFocused:
                return .next
            default:
                return nil
            }
        }

        private static let numberKeyCodes: [UInt16: Int] = [
            18: 1,
            19: 2,
            20: 3,
            21: 4,
            23: 5,
            22: 6,
            26: 7,
            28: 8,
            25: 9
        ]

        deinit {
            uninstall()
        }
    }
}
