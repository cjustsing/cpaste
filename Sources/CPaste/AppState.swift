import CPasteCore
import Foundation

final class AppState: ObservableObject {
    @Published var statusMessage = CPasteL10n.text("就绪", "Ready")
    @Published var isCapturePaused = false
    @Published var isHotKeyRegistered = true
    @Published var panelPresentationID = UUID()
    @Published private(set) var themeStyle: AppThemeStyle

    init(themeStyle: AppThemeStyle = AppEnvironment.themeStyle) {
        self.themeStyle = themeStyle
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
