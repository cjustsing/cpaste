import Foundation
import ServiceManagement

enum LoginItemCommand {
    /// Runs before the app delegate, so diagnostics never start clipboard
    /// capture or open a second history store alongside the running app.
    static func runIfRequested() -> Int32? {
        let arguments = ProcessInfo.processInfo.arguments
        guard arguments.contains("--login-item") else { return nil }
        guard arguments.count == 3, arguments[1] == "--login-item",
              ["status", "enable", "disable"].contains(arguments[2]) else {
            fputs("Usage: CPaste --login-item status|enable|disable\n", stderr)
            return 64
        }
        guard Bundle.main.bundleURL.pathExtension == "app",
              Bundle.main.bundleIdentifier == "local.cpaste.CPaste" else {
            fputs("Login item commands must run from the packaged CPaste.app.\n", stderr)
            return 78
        }

        // The command reports pending approval instead of opening a GUI from
        // a diagnostic process. The regular Settings button opens that pane.
        let controller = LoginItemController(openSettings: {})
        let action = arguments[2]
        if action == "enable" {
            controller.setEnabled(true)
        } else if action == "disable" {
            controller.setEnabled(false)
        }

        let status: String
        switch controller.status {
        case .notRegistered: status = "notRegistered"
        case .enabled: status = "enabled"
        case .requiresApproval: status = "requiresApproval"
        case .notFound: status = "notFound"
        @unknown default: status = "unknown"
        }
        var report: [String: Any] = [
            "bundlePath": Bundle.main.bundleURL.path,
            "version": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "",
            "build": Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "",
            "status": status,
            "enabled": controller.isEnabled,
            "requiresApproval": controller.needsApproval
        ]
        if let error = controller.lastError {
            report["error"] = error.localizedDescription
        }
        do {
            let data = try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys])
            print(String(decoding: data, as: UTF8.self))
        } catch {
            fputs("Could not encode login item status: \(error)\n", stderr)
            return 1
        }
        if controller.lastError != nil { return 1 }
        if action == "enable", !controller.isEnabled { return 2 }
        if action == "disable", controller.isEnabled || controller.needsApproval { return 2 }
        return 0
    }
}
