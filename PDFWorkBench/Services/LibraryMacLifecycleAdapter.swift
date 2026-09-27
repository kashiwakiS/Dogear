#if os(macOS)
import AppKit

/// Platform lifecycle events stay outside the portable Library store.
@MainActor
final class LibraryMacLifecycleAdapter {
    private let notifications: NotificationCenter
    private var observers: [NSObjectProtocol] = []

    init(library: LibraryStore, notificationCenter: NotificationCenter = .default) {
        notifications = notificationCenter
        for name in [NSApplication.willTerminateNotification, NSWindow.willCloseNotification] {
            observers.append(notificationCenter.addObserver(forName: name, object: nil, queue: nil) { [weak library] _ in
                MainActor.assumeIsolated { _ = library?.flushPendingPersistence() }
            })
        }
    }

    deinit { for observer in observers { notifications.removeObserver(observer) } }
}
#endif
