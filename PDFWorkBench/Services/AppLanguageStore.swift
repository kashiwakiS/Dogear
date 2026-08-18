import Combine
import Foundation
import AppKit

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
final class AppLanguageStore: NSObject, ObservableObject {
    static let shared = AppLanguageStore()

    @Published var selection: AppLanguage {
        didSet {
            UserDefaults.standard.set(selection.rawValue, forKey: AppLanguage.defaultsKey)
            MenuBarLocalizer.apply(language: selection)
        }
    }

    private override init() {
        let storedValue = UserDefaults.standard.string(forKey: AppLanguage.defaultsKey)
        selection = storedValue.flatMap(AppLanguage.init(rawValue:)) ?? .system
        super.init()

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(reapplyMenuBarLocalization),
            name: NSWindow.didBecomeKeyNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(reapplyMenuBarLocalization),
            name: NSApplication.didBecomeActiveNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(reapplyMenuBarLocalization),
            name: NSApplication.didUpdateNotification,
            object: nil
        )
    }

    var locale: Locale {
        selection.locale
    }

    func refreshMenuBarLocalization() {
        MenuBarLocalizer.apply(language: selection)
    }

    @objc private func reapplyMenuBarLocalization() {
        refreshMenuBarLocalization()
    }
}

enum L10n {
    static func string(_ key: String.LocalizationValue) -> String {
        let storedValue = UserDefaults.standard.string(forKey: AppLanguage.defaultsKey)
        let language = storedValue.flatMap(AppLanguage.init(rawValue:)) ?? .system
        return String(localized: key, locale: language.locale)
    }
}

@MainActor
private enum MenuBarLocalizer {
    private struct Pair {
        let english: String
        let chinese: String
    }

    private static let menuTitles = [
        Pair(english: "File", chinese: "文件"),
        Pair(english: "Edit", chinese: "编辑"),
        Pair(english: "View", chinese: "显示"),
        Pair(english: "Library", chinese: "资料库"),
        Pair(english: "Export", chinese: "导出"),
        Pair(english: "Annotation", chinese: "批注"),
        Pair(english: "Window", chinese: "窗口"),
        Pair(english: "Help", chinese: "帮助")
    ]

    private static let standardItems = [
        Pair(english: "About Dogear", chinese: "关于 Dogear"),
        Pair(english: "Settings…", chinese: "设置…"),
        Pair(english: "Services", chinese: "服务"),
        Pair(english: "Hide Dogear", chinese: "隐藏 Dogear"),
        Pair(english: "Hide Others", chinese: "隐藏其他"),
        Pair(english: "Show All", chinese: "全部显示"),
        Pair(english: "Quit Dogear", chinese: "退出 Dogear"),
        Pair(english: "Close", chinese: "关闭"),
        Pair(english: "Close Window", chinese: "关闭窗口"),
        Pair(english: "Undo", chinese: "撤销"),
        Pair(english: "Redo", chinese: "重做"),
        Pair(english: "Cut", chinese: "剪切"),
        Pair(english: "Copy", chinese: "复制"),
        Pair(english: "Paste", chinese: "粘贴"),
        Pair(english: "Paste and Match Style", chinese: "粘贴并匹配样式"),
        Pair(english: "Delete", chinese: "删除"),
        Pair(english: "Select All", chinese: "全选"),
        Pair(english: "Start Dictation…", chinese: "开始听写…"),
        Pair(english: "Emoji & Symbols", chinese: "表情与符号"),
        Pair(english: "Show Toolbar", chinese: "显示工具栏"),
        Pair(english: "Hide Toolbar", chinese: "隐藏工具栏"),
        Pair(english: "Customize Toolbar…", chinese: "自定工具栏…"),
        Pair(english: "Enter Full Screen", chinese: "进入全屏幕"),
        Pair(english: "Exit Full Screen", chinese: "退出全屏幕"),
        Pair(english: "Minimize", chinese: "最小化"),
        Pair(english: "Zoom", chinese: "缩放"),
        Pair(english: "Bring All to Front", chinese: "前置全部窗口"),
        Pair(english: "Dogear Help", chinese: "Dogear 帮助")
    ]

    static func apply(language: AppLanguage) {
        let usesChinese: Bool
        switch language {
        case .simplifiedChinese:
            usesChinese = true
        case .english:
            usesChinese = false
        case .system:
            usesChinese = Locale.preferredLanguages.first?.hasPrefix("zh") == true
        }

        DispatchQueue.main.async {
            localizeMainMenu(usingChinese: usesChinese)
        }
        // SwiftUI may replace the AppKit main menu after a scene/window change.
        // Reapply once after that rebuild settles so the app-only override wins.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            localizeMainMenu(usingChinese: usesChinese)
        }
    }

    private static func localizeMainMenu(usingChinese: Bool) {
        guard let mainMenu = NSApp.mainMenu else { return }

        for item in mainMenu.items {
            apply(menuTitles, to: item, usingChinese: usingChinese)
            localize(item.submenu, usingChinese: usingChinese)
        }
    }

    private static func localize(_ menu: NSMenu?, usingChinese: Bool) {
        guard let menu else { return }
        for item in menu.items {
            apply(standardItems, to: item, usingChinese: usingChinese)
            localize(item.submenu, usingChinese: usingChinese)
        }
    }

    private static func apply(
        _ pairs: [Pair],
        to item: NSMenuItem,
        usingChinese: Bool
    ) {
        guard let pair = pairs.first(where: {
            item.title == $0.english || item.title == $0.chinese
        }) else { return }

        let title = usesChineseTitle(pair, usingChinese: usingChinese)
        if item.title != title {
            item.title = title
        }
        if item.submenu?.title != title {
            item.submenu?.title = title
        }
    }

    private static func usesChineseTitle(_ pair: Pair, usingChinese: Bool) -> String {
        usingChinese ? pair.chinese : pair.english
    }
}
