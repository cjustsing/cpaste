import AppKit
import CPasteCore
import Foundation

final class AppState: ObservableObject {
    @Published var statusMessage: String
    @Published var storageWarning: String?
    @Published var isCapturePaused = false
    @Published var isHotKeyRegistered = true
    @Published var panelPresentationID = UUID()
    @Published var isPanelVisible = false
    @Published private(set) var language: AppLanguage
    @Published private(set) var themeStyle: AppThemeStyle

    var displayStatusMessage: String {
        storageWarning ?? statusMessage
    }

    init(
        themeStyle: AppThemeStyle = AppEnvironment.themeStyle,
        language: AppLanguage = AppEnvironment.language
    ) {
        self.themeStyle = themeStyle
        self.language = language
        CPasteL10n.language = language
        statusMessage = CPasteL10n.text("就绪", "Ready")
    }

    func setLanguage(_ language: AppLanguage) {
        guard self.language != language else {
            return
        }

        CPasteL10n.language = language
        self.language = language
        NativeAppMenu.install(in: .shared)
        statusMessage = isCapturePaused
            ? CPasteL10n.text("已暂停", "Paused")
            : CPasteL10n.text("就绪", "Ready")
        AppEnvironment.saveLanguage(language)
    }

    func setThemeStyle(_ style: AppThemeStyle) {
        let resolvedStyle = AppEnvironment.availableThemeStyles.contains(style) ? style : .standard
        guard themeStyle != resolvedStyle else {
            return
        }

        themeStyle = resolvedStyle
        AppEnvironment.saveThemeStyle(resolvedStyle)
    }
}
