#if os(macOS)
import AppKit
import Foundation

/// The view owns this observation; NotificationCenter never owns the view or
/// editor through its callback. Closing or dropping the view removes the token.
@MainActor
final class DocumentEditorWindowCloseObserver: NSObject {
    private var observer: NSObjectProtocol?
    private let onClose: () -> Void

    init(window: NSWindow, onClose: @escaping () -> Void) {
        self.onClose = onClose
        super.init()
        observer = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification,
            object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.stopObserving()
                    self.onClose()
                }
            }
    }

    private func stopObserving() {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
    }

    deinit { if let observer { NotificationCenter.default.removeObserver(observer) } }
}
#endif
