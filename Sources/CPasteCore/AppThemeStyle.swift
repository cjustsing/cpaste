public enum AppThemeStyle: String, CaseIterable, Codable, Sendable {
    case standard
    case liquidGlass

    public static func available(onMacOSMajorVersion majorVersion: Int) -> [AppThemeStyle] {
        majorVersion >= 26 ? [.standard, .liquidGlass] : [.standard]
    }

    public static func resolved(
        savedRawValue: String?,
        onMacOSMajorVersion majorVersion: Int
    ) -> AppThemeStyle {
        let availableStyles = available(onMacOSMajorVersion: majorVersion)
        if let savedRawValue,
           let savedStyle = AppThemeStyle(rawValue: savedRawValue),
           availableStyles.contains(savedStyle) {
            return savedStyle
        }

        return majorVersion >= 26 ? .liquidGlass : .standard
    }
}
