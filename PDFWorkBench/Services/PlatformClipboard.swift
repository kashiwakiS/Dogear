#if canImport(AppKit)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

/// Plain-text copy shared by answer and evidence actions. Native editors keep
/// their richer copy/paste behavior, including image paste and selection Undo.
@MainActor
enum PlatformClipboard {
    static func copyText(_ text: String) {
        #if canImport(AppKit)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #elseif canImport(UIKit)
        UIPasteboard.general.string = text
        #endif
    }
}
