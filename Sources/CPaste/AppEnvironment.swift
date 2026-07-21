import CPasteCore
import Foundation

enum AppEnvironment {
    private static let historyLimitKey = "CPasteHistoryLimit"
    private static let themeStyleKey = "CPasteThemeStyle"

    static var storageDirectory: URL {
        if let rawValue = ProcessInfo.processInfo.environment["CPASTE_STORAGE_DIR"],
           !rawValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return URL(fileURLWithPath: rawValue, isDirectory: true)
        }

        return ClipboardStore.defaultStorageDirectory()
    }

    static var isDemoMode: Bool {
        ProcessInfo.processInfo.arguments.contains("--demo")
    }

    static var historyLimit: Int {
        let savedValue = UserDefaults.standard.integer(forKey: historyLimitKey)
        return savedValue == 0 ? 500 : min(max(savedValue, 50), 5_000)
    }

    static func saveHistoryLimit(_ limit: Int) {
        UserDefaults.standard.set(min(max(limit, 50), 5_000), forKey: historyLimitKey)
    }

    static var availableThemeStyles: [AppThemeStyle] {
        AppThemeStyle.available(onMacOSMajorVersion: operatingSystemMajorVersion)
    }

    static var themeStyle: AppThemeStyle {
        AppThemeStyle.resolved(
            savedRawValue: UserDefaults.standard.string(forKey: themeStyleKey),
            onMacOSMajorVersion: operatingSystemMajorVersion
        )
    }

    static func saveThemeStyle(_ style: AppThemeStyle) {
        let resolvedStyle = availableThemeStyles.contains(style) ? style : .standard
        UserDefaults.standard.set(resolvedStyle.rawValue, forKey: themeStyleKey)
    }

    private static var operatingSystemMajorVersion: Int {
        ProcessInfo.processInfo.operatingSystemVersion.majorVersion
    }
}
