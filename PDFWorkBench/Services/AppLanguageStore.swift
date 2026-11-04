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
            userDefaults.set(selection.rawValue, forKey: AppLanguage.defaultsKey)
            refreshMenuBarLocalization()
        }
    }

    private let userDefaults: UserDefaults
    private var platformLocalizationRefresh: ((AppLanguage) -> Void)?

    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
        let storedValue = userDefaults.string(forKey: AppLanguage.defaultsKey)
        selection = storedValue.flatMap(AppLanguage.init(rawValue:)) ?? .system
    }

    var locale: Locale {
        selection.locale
    }

    /// A retained platform adapter installs its handler during app startup.
    /// Shared language preferences and localization resources need no AppKit.
    func installPlatformLocalizationRefreshHandler(_ handler: @escaping (AppLanguage) -> Void) {
        platformLocalizationRefresh = handler
    }

    func refreshMenuBarLocalization() {
        platformLocalizationRefresh?(selection)
    }
}

enum L10n {
    static func string(_ key: String.LocalizationValue) -> String {
        let storedValue = UserDefaults.standard.string(forKey: AppLanguage.defaultsKey)
        let language = storedValue.flatMap(AppLanguage.init(rawValue:)) ?? .system
        return string(key, language: language)
    }

    static func string(
        _ key: String.LocalizationValue,
        language: AppLanguage
    ) -> String {
        let resource = AppLocalizationResource.resource(for: language)
        return String(
            localized: key,
            table: resource.table,
            bundle: resource.bundle,
            locale: language.locale
        )
    }
}

private struct AppLocalizationResource {
    let bundle: Bundle
    let table: String?

    static func resource(for language: AppLanguage) -> AppLocalizationResource {
        switch language {
        case .system:
            return AppLocalizationResource(bundle: .main, table: nil)
        case .english:
            return AppLocalizationResource(bundle: englishBundle, table: "DogearEnglish")
        case .simplifiedChinese:
            return AppLocalizationResource(bundle: simplifiedChineseBundle, table: nil)
        }
    }

    private static let englishBundle = localizedBundle(named: "en")
    private static let simplifiedChineseBundle = localizedBundle(named: "zh-Hans")

    private static func localizedBundle(named languageCode: String) -> Bundle {
        guard let path = Bundle.main.path(
            forResource: languageCode,
            ofType: "lproj"
        ), let bundle = Bundle(path: path) else {
            assertionFailure("Missing \(languageCode) localization bundle")
            return .main
        }

        return bundle
    }
}
