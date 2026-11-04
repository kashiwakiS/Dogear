import Combine
import Foundation

/// Isolated workspace lifetime checks, without a native window, host registry,
/// persisted Library, PDF file, or provider configuration.
@MainActor
enum GroupWorkspaceStateDiagnostics {
    static func run() async -> (checks: Int, failures: [String]) {
        var checks = 0
        var failures: [String] = []
        func check(_ condition: @autoclosure () -> Bool, _ message: String) {
            checks += 1
            if !condition() { failures.append(message) }
        }

        let groupID = UUID()
        let firstID = UUID()
        let first = GroupWorkspaceState(id: firstID, groupID: groupID)
        let second = GroupWorkspaceState(id: UUID(), groupID: groupID)
        let firstManager = first.undoManager
        check(first.id == firstID && first.workspaceID == firstID && first.groupID == groupID,
              "Shared workspace creation replaced the session or Group identity.")
        check(first.id != second.id && first.undoManager !== second.undoManager,
              "Two workspaces for one Group shared identity or document Undo ownership.")

        var changes = 0
        let observation = first.objectWillChange.sink { changes += 1 }
        check(!first.updateGroupID(groupID) && changes == 0,
              "An unchanged Group published a spurious workspace state change.")
        let otherGroupID = UUID()
        check(first.updateGroupID(otherGroupID) && first.groupID == otherGroupID && changes == 1,
              "A real Group change did not publish once through the shared state.")
        check(first.id == firstID && first.undoManager === firstManager,
              "Changing Group context replaced the workspace identity or Undo manager.")

        var activation: [Bool] = []
        var closed = 0
        first.setLifecycleHandlers(onActivate: { activation.append($0) }, onClose: { closed += 1 })
        check(activation.isEmpty, "Initial lifecycle registration delivered inside the view attachment update.")
        first.setActive(true)
        check(first.isActive && activation == [true], "Workspace selection did not immediately activate its lifecycle.")
        await drainMainQueue()
        check(activation == [true, true], "Deferred registration did not use the current selected state.")
        let changesBeforeRepeat = changes
        first.setActive(true)
        check(changes == changesBeforeRepeat && activation == [true, true],
              "Repeated selection re-published or re-fired activation.")

        firstManager.groupsByEvent = false
        second.undoManager.groupsByEvent = false
        let firstValue = UndoValue(manager: firstManager)
        let secondValue = UndoValue(manager: second.undoManager)
        defer {
            observation.cancel()
            firstManager.removeAllActions()
            second.undoManager.removeAllActions()
        }
        firstValue.edit(3)
        secondValue.edit(8)
        first.setActive(false)
        first.notifyActivation() // Presentation detachment can redeliver inactivity.
        first.setActive(true)
        check(activation.suffix(3) == [false, false, true] && first.undoManager === firstManager,
              "Presentation transfer changed workspace lifetime or editing history ownership.")
        firstManager.undo()
        check(firstValue.value == 0 && secondValue.value == 8 && second.undoManager.canUndo,
              "Workspace Undo consumed another workspace's history after a host transition.")
        first.setActive(false)
        first.setActive(true)
        firstManager.redo()
        check(firstValue.value == 3 && secondValue.value == 8,
              "Deactivation/reactivation discarded pending document Redo.")

        let eventCountBeforeClose = activation.count
        check(first.finishClosing() && first.isClosed && !first.isActive && closed == 1,
              "Terminal close did not end the workspace exactly once.")
        check(activation.count == eventCountBeforeClose + 1 && activation.last == false,
              "Terminal close did not deliver one final inactive lifecycle callback.")
        check(!first.finishClosing() && closed == 1, "Repeated close invoked editor-release handlers twice.")
        first.setActive(true)
        first.notifyActivation()
        first.setLifecycleHandlers(onActivate: { activation.append($0) }, onClose: { closed += 1 })
        check(!first.isActive && activation.count == eventCountBeforeClose + 1 && closed == 1,
              "A closed workspace accepted handlers or reactivated.")
        check(!first.updateGroupID(groupID) && first.groupID == otherGroupID,
              "A closed workspace accepted a late Group update.")

        let pending = GroupWorkspaceState(id: UUID(), groupID: groupID)
        var pendingEvents: [Bool] = []
        var pendingCloseCount = 0
        pending.setLifecycleHandlers(onActivate: { pendingEvents.append($0) }, onClose: { pendingCloseCount += 1 })
        pending.finishClosing()
        await drainMainQueue()
        check(pendingEvents == [false] && pendingCloseCount == 1,
              "Deferred initial activation ran after terminal close.")

        let replacement = GroupWorkspaceState(id: UUID(), groupID: groupID)
        var oldEvents: [Bool] = []
        var newEvents: [Bool] = []
        replacement.setLifecycleHandlers(onActivate: { oldEvents.append($0) }, onClose: {})
        replacement.setLifecycleHandlers(onActivate: { newEvents.append($0) }, onClose: {})
        await drainMainQueue()
        check(oldEvents.isEmpty && newEvents == [false],
              "Replacing lifecycle handlers duplicated initial delivery or invoked stale handlers.")
        replacement.finishClosing()
        return (checks, failures)
    }

    private static func drainMainQueue() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
    }

    @MainActor
    private final class UndoValue {
        let manager: UndoManager
        private(set) var value = 0
        init(manager: UndoManager) { self.manager = manager }
        func edit(_ newValue: Int) {
            manager.beginUndoGrouping()
            set(newValue)
            manager.endUndoGrouping()
        }
        private func set(_ newValue: Int) {
            let previous = value
            manager.registerUndo(withTarget: self) { target in target.set(previous) }
            value = newValue
        }
    }
}
