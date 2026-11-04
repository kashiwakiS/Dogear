#if os(macOS)
import AppKit
import SwiftUI

/// Native sheets retain their drafts. Normal Quit must not destroy them before
/// the user explicitly saves or confirms discard. This is not PDF persistence.
@MainActor
enum MacAnnotationEditorLifecycle {
    final class Registration {
        weak var window: NSWindow?
        let token: UUID?
        var hasUnsubmittedInput: () -> Bool
        init(window: NSWindow?, token: UUID? = nil, hasUnsubmittedInput: @escaping () -> Bool) {
            self.window = window; self.token = token; self.hasUnsubmittedInput = hasUnsubmittedInput
        }
    }
    private static var registrations: [UUID: Registration] = [:]

    static func register(_ id: UUID, window: NSWindow?, token: UUID? = nil,
                         hasUnsubmittedInput: @escaping () -> Bool) {
        registrations[id] = Registration(window: window, token: token, hasUnsubmittedInput: hasUnsubmittedInput)
    }
    static func unregister(_ id: UUID, token: UUID? = nil) {
        if let token, registrations[id]?.token != token { return }
        registrations[id] = nil
    }

    static var unfinishedWindow: NSWindow? {
        registrations.values.first { $0.window != nil && $0.hasUnsubmittedInput() }?.window
    }
}

/// SwiftUI may cache a dismissed sheet and its appear state. The native
/// attachment is authoritative; no parallel presentation flag is maintained.
struct MacAnnotationEditorLifetime: NSViewRepresentable {
    let id: UUID
    let hasUnsubmittedInput: () -> Bool

    func makeNSView(context: Context) -> Host {
        let host = Host()
        host.update(id: id, hasUnsubmittedInput: hasUnsubmittedInput)
        return host
    }
    func updateNSView(_ host: Host, context: Context) {
        host.update(id: id, hasUnsubmittedInput: hasUnsubmittedInput)
    }
    static func dismantleNSView(_ host: Host, coordinator: ()) {
        host.unregister()
    }
    final class Host: NSView {
        private let token = UUID()
        private var id: UUID?
        private var hasUnsubmittedInput: () -> Bool = { false }

        func update(id: UUID, hasUnsubmittedInput: @escaping () -> Bool) {
            if self.id != id { unregister(); self.id = id }
            self.hasUnsubmittedInput = hasUnsubmittedInput
            register()
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            register()
        }

        private func register() {
            guard let id, let window else { unregister(); return }
            let hasInput = hasUnsubmittedInput
            // Sheet attachment survives parent minimization, while a cached
            // detached sheet cannot veto Quit or retain another draft's owner.
            MacAnnotationEditorLifecycle.register(id, window: window, token: token) { [weak window] in
                window?.sheetParent != nil && hasInput()
            }
        }

        func unregister() {
            guard let id else { return }
            MacAnnotationEditorLifecycle.unregister(id, token: token)
        }
    }
}
#endif
