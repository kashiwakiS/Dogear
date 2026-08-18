import Combine
import Foundation

enum AppLanguage: String, CaseIterable, Identifiable {
    case system
    case english
    case simplifiedChinese

    static let defaultsKey = "PDFWorkBench.InterfaceLanguage"

    var id: String { rawValue }

    var locale: Locale {
        switch self {
        case .system:
            return .autoupdatingCurrent
        case .english:
            return Locale(identifier: "en")
        case .simplifiedChinese:
            return Locale(identifier: "zh-Hans")
        }
    }

    var displayName: LocalizedStringResource {
        switch self {
        case .system:
            return "Follow System"
        case .english:
            return "English"
        case .simplifiedChinese:
            return "Simplified Chinese"
        }
    }
}

@MainActor
final class AppLanguageStore: ObservableObject {
    static let shared = AppLanguageStore()

    @Published var selection: AppLanguage {
        didSet {
            UserDefaults.standard.set(selection.rawValue, forKey: AppLanguage.defaultsKey)
        }
    }

    private init() {
        let storedValue = UserDefaults.standard.string(forKey: AppLanguage.defaultsKey)
        selection = storedValue.flatMap(AppLanguage.init(rawValue:)) ?? .system
    }

    var locale: Locale {
        selection.locale
    }
}

enum L10n {
    static func string(_ key: String.LocalizationValue) -> String {
        let storedValue = UserDefaults.standard.string(forKey: AppLanguage.defaultsKey)
        let language = storedValue.flatMap(AppLanguage.init(rawValue:)) ?? .system
        return String(localized: key, locale: language.locale)
    }
}
