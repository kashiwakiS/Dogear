import Combine
import Foundation

/// A logical workspace survives changes to its platform host. Its identity and
/// editing history never belong to a window, tab view, or scene implementation.
@MainActor
final class GroupWorkspaceState: ObservableObject, Identifiable {
    let id: UUID
    var workspaceID: UUID { id }
    @Published private(set) var groupID: UUID
    @Published private(set) var isActive = false
    let undoManager = UndoManager()
    private(set) var isClosed = false
    private var onActivate: ((Bool) -> Void)?
    private var onClose: (() -> Void)?

    init(id: UUID, groupID: UUID) {
        self.id = id
        self.groupID = groupID
    }

    /// Registration can occur while a platform view is being attached. The
    /// first delivery is deferred and reads the current selection at delivery.
    func setLifecycleHandlers(onActivate: @escaping (Bool) -> Void, onClose: @escaping () -> Void) {
        guard !isClosed else { return }
        let isInitialRegistration = self.onActivate == nil
        self.onActivate = onActivate
        self.onClose = onClose
        if isInitialRegistration {
            DispatchQueue.main.async { [weak self] in self?.notifyActivation() }
        }
    }

    @discardableResult
    func updateGroupID(_ groupID: UUID) -> Bool {
        guard !isClosed, self.groupID != groupID else { return false }
        self.groupID = groupID
        return true
    }

    func setActive(_ active: Bool) {
        guard !isClosed, isActive != active else { return }
        isActive = active
        notifyActivation()
    }

    /// A platform host can redeliver activation when its presentation changes
    /// without changing the workspace's selected state (for example, a move).
    func notifyActivation() {
        guard !isClosed else { return }
        onActivate?(isActive)
    }

    @discardableResult
    func finishClosing() -> Bool {
        guard !isClosed else { return false }
        isClosed = true
        isActive = false
        onActivate?(false)
        onClose?()
        onActivate = nil
        onClose = nil
        return true
    }
}
