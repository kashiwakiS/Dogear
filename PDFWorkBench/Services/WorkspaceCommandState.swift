import Foundation

/// A platform host registers the currently selected workspace's reader actions.
/// Window/scene eligibility (key window, sheets, foreground state) belongs to that host.
@MainActor
final class WorkspaceCommandState {
    private weak var workspace: GroupWorkspaceState?
    private var currentHandlers: PDFWorkbenchCommandHandlers?

    var workspaceID: UUID? {
        guard let workspace, workspace.isActive, !workspace.isClosed else { return nil }
        return workspace.id
    }

    var handlers: PDFWorkbenchCommandHandlers? {
        workspaceID == nil ? nil : currentHandlers
    }

    func activate(workspace: GroupWorkspaceState, handlers: PDFWorkbenchCommandHandlers) {
        guard workspace.isActive, !workspace.isClosed else { return }
        self.workspace = workspace
        currentHandlers = handlers
    }

    func deactivate(workspaceID: UUID) {
        guard workspace?.id == workspaceID else { return }
        workspace = nil
        currentHandlers = nil
    }
}
