import Foundation

/// Private preference suites; never changes the user's language or main menu.
@MainActor
enum AppLanguageDiagnostics {
    static func run() -> (checks: Int, failures: [String]) {
        var checks = 0
        var failures: [String] = []
        func check(_ condition: @autoclosure () -> Bool, _ message: String) {
            checks += 1
            if !condition() { failures.append(message) }
        }

        let suiteName = "DogearLanguageDiagnostics-\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            return (1, ["Could not create an isolated language preference suite."])
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let fresh = AppLanguageStore(userDefaults: defaults)
        check(fresh.selection == .system, "An empty preference suite did not follow the system language.")
        defaults.set("unknown-language", forKey: AppLanguage.defaultsKey)
        check(AppLanguageStore(userDefaults: defaults).selection == .system,
              "An unknown language preference did not use the system fallback.")
        defaults.set(AppLanguage.english.rawValue, forKey: AppLanguage.defaultsKey)
        let store = AppLanguageStore(userDefaults: defaults)
        check(store.selection == .english && store.locale.identifier == "en",
              "The English preference did not restore its explicit locale.")
        check(AppLanguage.simplifiedChinese.locale.identifier == "zh-Hans",
              "Simplified Chinese did not retain its explicit locale.")

        var refreshes: [AppLanguage] = []
        var persistedBeforeRefresh = false
        store.installPlatformLocalizationRefreshHandler { language in
            refreshes.append(language)
            persistedBeforeRefresh = defaults.string(forKey: AppLanguage.defaultsKey) == language.rawValue
        }
        check(refreshes.isEmpty, "Installing a platform handler unexpectedly changed menu localization.")
        store.selection = .simplifiedChinese
        check(refreshes == [.simplifiedChinese] && persistedBeforeRefresh,
              "A language change did not persist before synchronously refreshing the platform adapter.")
        check(store.locale.identifier == "zh-Hans"
              && AppLanguageStore(userDefaults: defaults).selection == .simplifiedChinese,
              "The changed language failed to persist across store recreation.")
        store.refreshMenuBarLocalization()
        check(refreshes == [.simplifiedChinese, .simplifiedChinese],
              "An explicit platform refresh did not use the current language.")

        fresh.selection = .english
        check(fresh.selection == .english && defaults.string(forKey: AppLanguage.defaultsKey) == AppLanguage.english.rawValue,
              "Language preferences required a platform adapter to save.")

        #if os(macOS)
        var lifecycleStore: AppLanguageStore? = AppLanguageStore(userDefaults: defaults)
        var adapter: AppLanguageMacMenuAdapter? = AppLanguageMacMenuAdapter(languageStore: lifecycleStore!, notificationCenter: NotificationCenter())
        weak var weakAdapter = adapter
        adapter = nil
        check(weakAdapter == nil, "The store's refresh handler retained its macOS menu adapter.")
        weakAdapter = nil
        weak var secondWeakStore = lifecycleStore
        adapter = AppLanguageMacMenuAdapter(languageStore: lifecycleStore!, notificationCenter: NotificationCenter())
        lifecycleStore = nil
        check(secondWeakStore == nil, "A retained macOS menu adapter kept its language store alive.")
        secondWeakStore = nil
        adapter = nil
        #endif

        return (checks, failures)
    }
}
