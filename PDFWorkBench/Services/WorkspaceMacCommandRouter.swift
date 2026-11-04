#if os(macOS)
import AppKit
import Combine
import Foundation

/// SwiftUI's scene-focused values do not cross independent NSHostingController roots.
/// Keep commands attached to the active workspace of the actual key window.
@MainActor
final class WorkspaceMacCommandRouter: ObservableObject {
    static let shared = WorkspaceMacCommandRouter()
    @Published private var revision = 0
    private weak var workspace: GroupWorkspaceContext?
    private let commandState = WorkspaceCommandState()
    private var observers: [NSObjectProtocol] = []

    private init() {
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification,
                     NSWindow.didEnterFullScreenNotification, NSWindow.didExitFullScreenNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in self?.revision += 1 }
            })
        }
    }

    var activeWorkspace: GroupWorkspaceContext? {
        guard let workspace, workspace.isActive, workspace.window?.isKeyWindow == true,
              workspace.window?.attachedSheet == nil else { return nil }
        return workspace
    }
    var commandWindow: NSWindow? {
        guard let window = NSApp.keyWindow, window.attachedSheet == nil, window.sheetParent == nil else { return nil }
        return window
    }
    var handlers: PDFWorkbenchCommandHandlers? {
        guard let workspace = activeWorkspace, commandState.workspaceID == workspace.workspaceID else { return nil }
        return commandState.handlers
    }
    func activate(workspace: GroupWorkspaceContext, handlers: PDFWorkbenchCommandHandlers) {
        guard workspace.isActive, workspace.window?.isKeyWindow == true else { return }
        self.workspace = workspace
        commandState.activate(workspace: workspace.state, handlers: handlers)
        revision += 1
    }
    func deactivate(workspaceID: UUID) {
        guard workspace?.workspaceID == workspaceID else { return }
        workspace = nil
        commandState.deactivate(workspaceID: workspaceID)
        revision += 1
    }
}

#endif
