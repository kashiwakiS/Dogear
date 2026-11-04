#if os(macOS)
import AppKit
import Foundation

/// The macOS scene owns this adapter. It synchronously installs the original
/// menu mutation hooks while the portable store only owns language preferences.
@MainActor
final class AppLanguageMacMenuAdapter: NSObject {
    private weak var languageStore: AppLanguageStore?
    private let notifications: NotificationCenter

    init(languageStore: AppLanguageStore, notificationCenter: NotificationCenter = .default) {
        self.languageStore = languageStore
        notifications = notificationCenter
        super.init()

        languageStore.installPlatformLocalizationRefreshHandler { [weak self] language in
            self?.refresh(language: language)
        }

        for name in [NSWindow.didBecomeKeyNotification, NSApplication.didBecomeActiveNotification,
                     NSApplication.didUpdateNotification, NSMenu.didBeginTrackingNotification] {
            notificationCenter.addObserver(self, selector: #selector(reapplyMenuBarLocalization), name: name, object: nil)
        }
        for name in [NSMenu.didAddItemNotification, NSMenu.didChangeItemNotification] {
            notificationCenter.addObserver(self, selector: #selector(localizeMutatedMenu), name: name, object: nil)
        }
    }

    private func refresh(language: AppLanguage) {
        MenuBarLocalizer.apply(language: language)
    }

    @objc private func reapplyMenuBarLocalization() {
        guard let languageStore else { return }
        refresh(language: languageStore.selection)
    }

    @objc private func localizeMutatedMenu() {
        guard let languageStore else { return }
        MenuBarLocalizer.applyImmediately(language: languageStore.selection)
    }

    deinit { notifications.removeObserver(self) }
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
        Pair(english: "Pages", chinese: "页面"),
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

    private static var isApplying = false

    static func apply(language: AppLanguage) {
        let usesChinese = usesChinese(for: language)

        applyImmediately(usingChinese: usesChinese)

        DispatchQueue.main.async {
            applyImmediately(usingChinese: usesChinese)
        }
        // SwiftUI may replace the AppKit main menu after a scene/window change.
        // Reapply once after that rebuild settles so the app-only override wins.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            applyImmediately(usingChinese: usesChinese)
        }
    }

    static func applyImmediately(language: AppLanguage) {
        applyImmediately(usingChinese: usesChinese(for: language))
    }

    private static func usesChinese(for language: AppLanguage) -> Bool {
        let usesChinese: Bool
        switch language {
        case .simplifiedChinese:
            usesChinese = true
        case .english:
            usesChinese = false
        case .system:
            usesChinese = Locale.preferredLanguages.first?.hasPrefix("zh") == true
        }

        return usesChinese
    }

    private static func applyImmediately(usingChinese: Bool) {
        guard !isApplying else { return }
        isApplying = true
        defer { isApplying = false }

        // Menu mutation notifications are synchronous. Correct rebuilt items
        // before AppKit gets a chance to draw the system-language title.
        localizeMainMenu(usingChinese: usingChinese)
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
#endif
