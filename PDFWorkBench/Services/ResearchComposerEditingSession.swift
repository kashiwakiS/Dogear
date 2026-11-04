import Combine
import Foundation

/// A registration belongs to one installed native composer, even when a
/// workspace moves to another window with the same editor identity.
nonisolated struct ResearchComposerLease: Equatable, Sendable {
    let sessionID: UUID
    let editorID: UUID
    let registrationID: UUID
}

nonisolated struct ResearchComposerSnapshot: Equatable, Sendable {
    let text: String
    let textRevision: Int
}

nonisolated enum ResearchComposerTextSaveResult: Equatable, Sendable {
    case accepted(revision: Int, persisted: Bool)
    case notOwner, staleRevision, missingSession
}

/// Rejected native input remains visible to the user and survives relaunch.
/// It is separate from the shared draft and cannot replace another writer.
nonisolated struct ResearchComposerConflict: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    let sessionID: UUID
    let editorID: UUID
    var text: String
    var updatedAt: Date
    var isResolved = false
}

/// The UI retains this object while its native field is mounted. Reading text
/// never acknowledges a new revision: only a safe native echo can do that.
@MainActor
final class ResearchComposerEditingSession: ObservableObject {
    let editorID: UUID
    @Published private(set) var sessionID: UUID?
    @Published private(set) var lease: ResearchComposerLease?
    @Published private(set) var nativeInstallationID: UUID?
    @Published private(set) var localText = ""
    @Published private(set) var error: String?
    @Published private(set) var hasLocalConflict = false
    private let store: ResearchStore
    private var expectedTextRevision: Int?
    private var prepareNativeInput: (() -> Bool)?
    private var conflictID: UUID?
    private var pendingRestoredConflictID: UUID?
    private var pendingNativeBeforeRestoreText: String?
    private var unacknowledgedNativeBaseline: String?
    private var reservedNativeInstallations: [UUID: UUID] = [:]
    private var seenNativeInstallations: Set<UUID> = []
    private var detachedConflictIDs: [UUID: UUID] = [:]
    private var isPreparing = false

    init(store: ResearchStore, editorID: UUID = UUID()) {
        self.store = store; self.editorID = editorID
    }

    var ownsEditor: Bool { lease.map { store.composerOwner(sessionID: $0.sessionID) == $0 } ?? false }
    var text: String {
        if hasLocalConflict { return localText }
        return sessionID.flatMap { store.session(id: $0)?.draft.text } ?? ""
    }

    /// A busy composer remains readable. Reinstalling the same workspace first
    /// prepares its previous installation, then receives a fresh registration.
    @discardableResult
    func bind(sessionID: UUID, prepareNativeInput: @escaping () -> Bool) -> Bool {
        if self.sessionID != sessionID {
            guard release() else { return false }
            self.sessionID = sessionID
            localText = store.session(id: sessionID)?.draft.text ?? ""
            expectedTextRevision = nil; conflictID = nil; pendingRestoredConflictID = nil
            nativeInstallationID = nil; pendingNativeBeforeRestoreText = nil
            unacknowledgedNativeBaseline = nil
            hasLocalConflict = false; error = nil
        }
        if nativeInstallationID == nil { self.prepareNativeInput = prepareNativeInput }
        if ownsEditor { return true }
        guard !hasLocalConflict else { return false }
        guard store.session(id: sessionID) != nil else { return false }
        guard let value = store.claimComposerEditor(sessionID: sessionID, editorID: editorID,
            prepare: { [weak self] in self?.prepareForTransition() ?? true },
            didReplaceText: { [weak self] in self?.didReplaceCanonicalText() }) else { return false }
        install(value)
        return true
    }

    /// One immutable native installation supplies all callbacks. Keep the old
    /// preparation until it has yielded; an old host cannot borrow a new lease
    /// from this same UI object after a remount.
    @discardableResult
    func attachNativeHost(sessionID: UUID, installationID: UUID,
                          prepareNativeInput: @escaping () -> Bool) -> Bool {
        guard self.sessionID == sessionID else { return false }
        guard reservedNativeInstallations[sessionID] == nil
            || reservedNativeInstallations[sessionID] == installationID
            || nativeInstallationID == installationID else { return false }
        guard !seenNativeInstallations.contains(installationID)
            || nativeInstallationID == installationID else { return false }
        if nativeInstallationID == installationID {
            self.prepareNativeInput = prepareNativeInput
            if ownsEditor { return true }
            return bind(sessionID: sessionID, prepareNativeInput: prepareNativeInput)
        }
        let oldInstallation = nativeInstallationID
        let value: ResearchComposerLease?
        if ownsEditor {
            value = store.claimComposerEditor(sessionID: sessionID, editorID: editorID,
                prepare: { [weak self] in self?.prepareForTransition() ?? true },
                didReplaceText: { [weak self] in self?.didReplaceCanonicalText() })
            guard value != nil else { return false }
        } else {
            if hasLocalConflict {
                guard retrySave(), self.prepareNativeInput?() != false, retrySave() else { return false }
                adoptLatestAfterArchiving()
            }
            value = store.claimComposerEditor(sessionID: sessionID, editorID: editorID,
                prepare: { [weak self] in self?.prepareForTransition() ?? true },
                didReplaceText: { [weak self] in self?.didReplaceCanonicalText() })
        }
        guard self.sessionID == sessionID, nativeInstallationID == oldInstallation else {
            if let value { _ = store.releaseComposerEditor(value) }
            return false
        }
        nativeInstallationID = installationID
        seenNativeInstallations.insert(installationID)
        self.prepareNativeInput = prepareNativeInput
        if let value { install(value) }
        return ownsEditor
    }

    /// Called once when a Coordinator is created. This does not claim a lease
    /// or publish during rendering; it rejects a never-attached old task after
    /// a newer installation has already been requested.
    func reserveNativeHost(sessionID: UUID, installationID: UUID) {
        reservedNativeInstallations[sessionID] = installationID
    }

    @discardableResult
    func acceptNativeText(_ text: String, installationID: UUID, sessionID: UUID) -> Bool {
        guard self.sessionID == sessionID, nativeInstallationID == installationID else {
            preserveDetachedText(text, installationID: installationID, sessionID: sessionID)
            return false
        }
        return acceptCurrentNativeText(text)
    }

    func externalTextApplied(_ text: String, installationID: UUID, sessionID: UUID) {
        guard self.sessionID == sessionID, nativeInstallationID == installationID else { return }
        acknowledgeExternalText(text)
    }

    @discardableResult
    func detachNativeHost(installationID: UUID, sessionID: UUID) -> Bool {
        guard self.sessionID == sessionID, nativeInstallationID == installationID else { return true }
        guard release() else { return false }
        nativeInstallationID = nil; prepareNativeInput = nil
        return true
    }

    private func preserveDetachedText(_ text: String, installationID: UUID, sessionID: UUID) {
        guard store.session(id: sessionID)?.draft.text != text else { return }
        let previousID = detachedConflictIDs[installationID] ?? installationID
        let id = nextConflictID(previousID: previousID, sessionID: sessionID, text: text)
        detachedConflictIDs[installationID] = id
        if let previous = store.composerConflicts.first(where: { $0.id == id }),
           store.session(id: sessionID)?.appliedComposerConflictIDs?.contains(id) == true,
           previous.text == text {
            _ = store.saveComposerConflict(previous)
            return
        }
        let record = ResearchComposerConflict(id: id, sessionID: sessionID,
            editorID: editorID, text: text, updatedAt: Date())
        _ = store.saveComposerConflict(record)
    }

    private func nextConflictID(previousID: UUID, sessionID: UUID, text: String) -> UUID {
        if store.session(id: sessionID)?.appliedComposerConflictIDs?.contains(previousID) == true,
           store.composerConflicts.first(where: { $0.id == previousID })?.text != text { return UUID() }
        return previousID
    }

    @discardableResult
    func takeOver() -> Bool {
        guard let sessionID else { return false }
        let archivedLocal = hasLocalConflict
        if archivedLocal {
            guard retrySave(), prepareNativeInput?() != false, retrySave() else { return false }
        }
        if ownsEditor {
            if archivedLocal { adoptLatestAfterArchiving() }
            return true
        }
        guard let value = store.takeOverComposerEditor(sessionID: sessionID, editorID: editorID,
            prepare: { [weak self] in self?.prepareForTransition() ?? true },
            didReplaceText: { [weak self] in self?.didReplaceCanonicalText() }) else {
            error = L10n.string("The other Research editor could not save its input. Keep editing there or retry saving.")
            return false
        }
        if archivedLocal { adoptLatestAfterArchiving() }
        install(value)
        return true
    }

    private func adoptLatestAfterArchiving() {
        let previousNativeText = localText
        hasLocalConflict = false; conflictID = nil; pendingRestoredConflictID = nil
        pendingNativeBeforeRestoreText = nil
        localText = sessionID.flatMap { store.composerSnapshot(sessionID: $0)?.text } ?? ""
        unacknowledgedNativeBaseline = previousNativeText
        expectedTextRevision = nil; error = nil
    }

    private func install(_ value: ResearchComposerLease) {
        let previousNativeText = unacknowledgedNativeBaseline ?? localText
        lease = value
        if !hasLocalConflict { localText = store.composerSnapshot(sessionID: value.sessionID)?.text ?? "" }
        // A new lease must not authorize the old native contents before echo.
        expectedTextRevision = nil
        unacknowledgedNativeBaseline = previousNativeText
        if !hasLocalConflict { error = nil }
    }

    private func didReplaceCanonicalText() {
        guard ownsEditor, !hasLocalConflict, let sessionID,
              let snapshot = store.composerSnapshot(sessionID: sessionID) else { return }
        unacknowledgedNativeBaseline = localText
        if localText != snapshot.text { localText = snapshot.text }
        expectedTextRevision = nil
        if store.saveFailures["sessions/\(sessionID.uuidString)"] != nil {
            error = ResearchStoreError.storageUnavailable.localizedDescription
        }
    }

    /// Called only after the native field accepts a model echo without marked
    /// text. A binding getter or an ignored external replacement cannot call it.
    func externalTextApplied(_ text: String) {
        guard nativeInstallationID == nil else { return }
        acknowledgeExternalText(text)
    }

    private func acknowledgeExternalText(_ text: String) {
        guard !hasLocalConflict, ownsEditor, let sessionID,
              let snapshot = store.composerSnapshot(sessionID: sessionID), snapshot.text == text else { return }
        if localText != text { localText = text }
        expectedTextRevision = snapshot.textRevision
        unacknowledgedNativeBaseline = nil
    }

    @discardableResult
    func acceptNativeText(_ text: String) -> Bool {
        guard nativeInstallationID == nil else { return false }
        return acceptCurrentNativeText(text)
    }

    private func acceptCurrentNativeText(_ text: String) -> Bool {
        if expectedTextRevision == nil, text == unacknowledgedNativeBaseline { return false }
        if expectedTextRevision == nil, pendingRestoredConflictID != nil {
            if text != pendingNativeBeforeRestoreText,
               let sessionID, let installationID = nativeInstallationID {
                preserveDetachedText(text, installationID: installationID, sessionID: sessionID)
            }
            return false
        }
        if localText != text { localText = text }
        guard !hasLocalConflict else { return rejectLocalText(text) }
        guard let lease, lease.sessionID == sessionID, let revision = expectedTextRevision else {
            return rejectLocalText(text)
        }
        switch store.saveComposerText(text, lease: lease, expectedTextRevision: revision) {
        case .accepted(let nextRevision, let persisted):
            expectedTextRevision = nextRevision
            if !persisted { error = ResearchStoreError.storageUnavailable.localizedDescription }
            else if !hasLocalConflict { error = nil }
            return persisted
        case .notOwner, .staleRevision, .missingSession:
            return rejectLocalText(text)
        }
    }

    private func rejectLocalText(_ text: String) -> Bool {
        guard let sessionID else { return false }
        // An equal late echo has no unsaved user value to archive.
        if !hasLocalConflict, store.session(id: sessionID)?.draft.text == text { return false }
        hasLocalConflict = true
        let id = nextConflictID(previousID: conflictID ?? UUID(), sessionID: sessionID, text: text)
        if let previous = store.composerConflicts.first(where: { $0.id == id }),
           store.session(id: sessionID)?.appliedComposerConflictIDs?.contains(id) == true,
           previous.text == text {
            conflictID = id
            _ = store.saveComposerConflict(previous)
            return false
        }
        let record = ResearchComposerConflict(id: id, sessionID: sessionID,
            editorID: editorID, text: text, updatedAt: Date())
        conflictID = record.id
        let saved = store.saveComposerConflict(record)
        error = saved
            ? L10n.string("This input was kept separately because another Research editor changed the draft. Restore it to merge with the latest input.")
            : ResearchStoreError.storageUnavailable.localizedDescription
        return false
    }

    /// Preflight saves before unmarking, so a blocked disk leaves the current
    /// native composition and focus intact. A second check covers native commit.
    @discardableResult
    func prepareForTransition() -> Bool {
        guard !isPreparing else { return false }
        if !ownsEditor {
            guard !hasLocalConflict else { return retrySave() }
            return true
        }
        guard !hasLocalConflict, let lease else { return false }
        isPreparing = true
        defer { isPreparing = false }
        if let revision = expectedTextRevision {
            guard savePreflight(lease: lease, revision: revision) else { return false }
        } else {
            guard saveUninstalledPreflight(lease: lease) else { return false }
        }
        guard prepareNativeInput?() != false, ownsEditor, !hasLocalConflict else { return false }
        if let revision = expectedTextRevision { return savePreflight(lease: lease, revision: revision) }
        return saveUninstalledPreflight(lease: lease)
    }

    /// A just-claimed empty installation may be hidden before its first echo.
    /// Saving equal model content cannot authorize any unacknowledged edit.
    private func saveUninstalledPreflight(lease: ResearchComposerLease) -> Bool {
        guard expectedTextRevision == nil, !hasLocalConflict,
              let snapshot = store.composerSnapshot(sessionID: lease.sessionID), localText == snapshot.text else { return false }
        return store.retryComposerPersistence(lease)
    }

    private func savePreflight(lease: ResearchComposerLease, revision: Int) -> Bool {
        switch store.saveComposerText(localText, lease: lease, expectedTextRevision: revision) {
        case .accepted(let nextRevision, let persisted):
            expectedTextRevision = nextRevision
            if !persisted { error = ResearchStoreError.storageUnavailable.localizedDescription }
            else { error = nil }
            return persisted
        case .notOwner, .staleRevision, .missingSession:
            return rejectLocalText(localText)
        }
    }

    @discardableResult
    func release() -> Bool {
        guard let lease else { return !hasLocalConflict || retrySave() }
        if ownsEditor {
            guard store.releaseComposerEditor(lease) else { return false }
        } else if hasLocalConflict && !retrySave() { return false }
        self.lease = nil; expectedTextRevision = nil
        return true
    }

    @discardableResult
    func retrySave() -> Bool {
        if let pendingRestoredConflictID, ownsEditor, let lease {
            guard store.retryComposerPersistence(lease) else { return false }
            return finishConflictRestore(pendingRestoredConflictID)
        }
        if hasLocalConflict, let conflictID,
           let record = store.composerConflicts.first(where: { $0.id == conflictID }) {
            return store.saveComposerConflict(record)
        }
        guard ownsEditor, let lease, let revision = expectedTextRevision else { return false }
        return savePreflight(lease: lease, revision: revision)
    }

    /// User-invoked recovery appends to the latest input. The shared draft is
    /// never replaced with the rejected editor's stale full-text snapshot.
    @discardableResult
    func restoreConflict(_ id: UUID) -> Bool {
        if pendingRestoredConflictID == id { return retrySave() }
        guard ownsEditor, let lease, let sessionID,
              store.composerConflicts.contains(where: { $0.id == id && $0.sessionID == sessionID && !$0.isResolved }) else { return false }
        if hasLocalConflict {
            guard retrySave(), prepareNativeInput?() != false, retrySave() else { return false }
        } else { guard prepareForTransition() else { return false } }
        guard ownsEditor,
              let latest = store.composerSnapshot(sessionID: sessionID) else { return false }
        pendingNativeBeforeRestoreText = latest.text
        switch store.restoreComposerConflict(id, lease: lease, expectedTextRevision: latest.textRevision) {
        case .accepted(_, let persisted):
            localText = store.composerSnapshot(sessionID: sessionID)?.text ?? localText
            // Programmatic content is not native input. Only the next safe
            // echo can authorize this installation to edit the merged text.
            expectedTextRevision = nil
            unacknowledgedNativeBaseline = pendingNativeBeforeRestoreText
            pendingRestoredConflictID = id
            if conflictID == id { conflictID = nil; hasLocalConflict = false }
            guard persisted else {
                error = ResearchStoreError.storageUnavailable.localizedDescription
                return false
            }
            return finishConflictRestore(id)
        case .notOwner, .staleRevision, .missingSession:
            return false
        }
    }

    private func finishConflictRestore(_ id: UUID) -> Bool {
        guard store.resolveComposerConflict(id) else {
            error = ResearchStoreError.storageUnavailable.localizedDescription
            return false
        }
        if conflictID == id { conflictID = nil; hasLocalConflict = false }
        pendingRestoredConflictID = nil
        // Merged text establishes a new history only after native echo.
        expectedTextRevision = nil; error = nil
        pendingNativeBeforeRestoreText = nil
        return true
    }
}
