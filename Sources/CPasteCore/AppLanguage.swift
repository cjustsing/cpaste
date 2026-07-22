import Foundation

public enum AppLanguage: String, CaseIterable, Codable, Sendable {
    case system
    case simplifiedChinese
    case english

    public static func resolved(savedRawValue: String?) -> AppLanguage {
        savedRawValue.flatMap(AppLanguage.init(rawValue:)) ?? .system
    }

    public func usesChinese(preferredLanguages: [String]) -> Bool {
        switch self {
        case .system:
            return preferredLanguages.first?.lowercased().hasPrefix("zh") == true
        case .simplifiedChinese:
            return true
        case .english:
            return false
        }
    }
}
