#if os(iOS)
import Combine
import Foundation

/// A scene owns presentation of retained, real workspace sessions. This record
/// stores identifiers only; PDFs, drafts, editing leases and Undo stay in their
/// existing owners.
@MainActor
final class IPadWindowTabs: ObservableObject {
    private struct Saved: Codable {
        let windowID: UUID
        let tabIDs: [UUID]
        let selectedID: UUID?
        let closedTabIDs: [UUID]?
    }
    private struct TransferIntent: Codable {
        let token: UUID
        let sourceWindowID: UUID
        let targetWindowID: UUID
        let tabID: UUID
        let sourceReplacementID: UUID?
    }
    private static let transferIntentKey = "Dogear.iPad.WindowTabTransferIntent"
    private static var activeTransferToken: UUID?

    let windowID: UUID
    @Published private(set) var sessions: [IPadWorkspaceSession] = []
    @Published private(set) var selectedID: UUID?
    @Published private(set) var pendingTransfer: IPadWindowTabTransferTicket?
    @Published private(set) var closedTabIDs: [UUID] = []
    @Published private(set) var requiresTransferRecovery = false
    var onChange: (() -> Void)?
    private let defaults: UserDefaults
    private let library: LibraryStore
    private let makeSession: @MainActor (UUID) -> IPadWorkspaceSession
    private let activateExistingEditor: @MainActor (UUID) -> Bool
    private var restoredIDs: Set<UUID> = []
    private var isClosed = false
    fileprivate var isTransferring = false
    fileprivate var cancelPendingTransfer: (() -> Void)?

    init(windowID: UUID, services: IPadApplicationServices,
         defaults: UserDefaults = .standard, restore: Bool = true,
         sessionFactory: (@MainActor (UUID) -> IPadWorkspaceSession)? = nil,
         activateExistingEditor: (@MainActor (UUID) -> Bool)? = nil) {
        self.windowID = windowID; self.defaults = defaults
        library = services.library
        makeSession = sessionFactory ?? { IPadWorkspaceSession(id: $0, services: services, userDefaults: defaults) }
        self.activateExistingEditor = activateExistingEditor ?? {
            DocumentAccessCoordinator.shared.activateExistingEditor(fileID: $0)
        }
        guard Self.repairPendingTransfer(defaults: defaults) else {
            requiresTransferRecovery = true
            return
        }
        guard restore else { return }
        restoreMetadata()
    }

    private func restoreMetadata() {
        let saved = defaults.data(forKey: persistenceKey).flatMap { try? JSONDecoder().decode(Saved.self, from: $0) }
        var seen = Set<UUID>()
        let ids = saved?.windowID == windowID ? (saved?.tabIDs ?? []).filter { seen.insert($0).inserted } : []
        var seenClosed = Set<UUID>()
        closedTabIDs = (saved?.closedTabIDs ?? []).filter { seenClosed.insert($0).inserted }
        sessions = (ids.isEmpty ? [windowID] : ids).map { makeSession($0) }
        selectedID = saved?.selectedID.flatMap { id in sessions.contains(where: { $0.id == id }) ? id : nil } ?? sessions.first?.id
        for session in sessions { session.setPresented(session.id == selectedID) }
        persist()
    }

    var selectedSession: IPadWorkspaceSession? { selectedID.flatMap { session(for: $0) } }
    var acceptsUserActions: Bool { !isClosed && !isTransferring && !requiresTransferRecovery }
    var transferRecoveryError: String? {
        requiresTransferRecovery ? L10n.string("Could not restore a tab move. Retry before opening another tab.") : nil
    }

    @discardableResult
    func retryTransferRecovery() -> Bool {
        guard !isClosed, !isTransferring else { return false }
        guard requiresTransferRecovery else { return true }
        guard sessions.isEmpty, Self.repairPendingTransfer(defaults: defaults) else { return false }
        restoreMetadata()
        requiresTransferRecovery = false
        onChange?()
        return true
    }
    func session(for id: UUID) -> IPadWorkspaceSession? { sessions.first { $0.id == id } }
    func closedTabTitle(tabID: UUID) -> String {
        guard let fileID = rememberedFileID(tabID: tabID),
              let file = library.allFiles.first(where: { $0.id == fileID }) else { return L10n.string("New Tab") }
        return file.displayName
    }

    private func rememberedFileID(tabID: UUID) -> UUID? {
        guard let groupID = library.state.windowSessions.filter({ $0.id == tabID })
            .max(by: { $0.updatedAt < $1.updatedAt })?.groupID else { return nil }
        return library.openSession(for: groupID, sessionID: tabID)?.selectedFileID
    }

    /// Repair only identifiers before constructing sessions. An interrupted
    /// accepted claim belongs to its destination, and the source receives the
    /// same captured blank identity when its last tab moved.
    @discardableResult
    static func repairPendingTransfer(defaults: UserDefaults = .standard) -> Bool {
        guard activeTransferToken == nil else { return false }
        guard let data = defaults.data(forKey: transferIntentKey) else { return true }
        guard let intent = try? JSONDecoder().decode(TransferIntent.self, from: data),
              intent.sourceWindowID != intent.targetWindowID,
              intent.sourceReplacementID != intent.tabID else { return false }
        func read(_ windowID: UUID) -> (valid: Bool, saved: Saved?) {
            guard let data = defaults.data(forKey: persistenceKey(windowID)) else { return (true, nil) }
            guard let saved = try? JSONDecoder().decode(Saved.self, from: data),
                  saved.windowID == windowID else { return (false, nil) }
            return (true, saved)
        }
        let sourceRecord = read(intent.sourceWindowID)
        let targetRecord = read(intent.targetWindowID)
        guard sourceRecord.valid, targetRecord.valid else { return false }
        let oldSource = sourceRecord.saved
        let oldTarget = targetRecord.saved
        let targetIDs = Set(oldTarget?.tabIDs ?? [])
        guard targetIDs.isEmpty || targetIDs == Set([intent.tabID]) else { return false }
        var seen = Set<UUID>()
        var sourceIDs = (oldSource?.tabIDs ?? []).filter { $0 != intent.tabID && seen.insert($0).inserted }
        if sourceIDs.isEmpty {
            guard let replacement = intent.sourceReplacementID else { return false }
            sourceIDs = [replacement]
        }
        let sourceSelected = oldSource?.selectedID.flatMap { sourceIDs.contains($0) ? $0 : nil } ?? sourceIDs.first
        let source = Saved(windowID: intent.sourceWindowID, tabIDs: sourceIDs, selectedID: sourceSelected,
                           closedTabIDs: oldSource?.closedTabIDs ?? [])
        let target = Saved(windowID: intent.targetWindowID, tabIDs: [intent.tabID], selectedID: intent.tabID,
                           closedTabIDs: oldTarget?.closedTabIDs ?? [])
        guard let sourceData = try? JSONEncoder().encode(source),
              let targetData = try? JSONEncoder().encode(target) else { return false }
        defaults.set(sourceData, forKey: persistenceKey(intent.sourceWindowID))
        defaults.set(targetData, forKey: persistenceKey(intent.targetWindowID))
        // Clearing is last; repeating repair after either metadata write is safe.
        defaults.removeObject(forKey: transferIntentKey)
        return true
    }

    /// Call after the scene activation handlers have been installed. Restored
    /// background tabs remain lazy so they cannot acquire a duplicate writer.
    @discardableResult
    func restoreSelectedTab() -> Bool {
        guard acceptsUserActions, let session = selectedSession, session.acceptsUserActions else { return false }
        if restoredIDs.contains(session.id) { return true }
        guard session.selectGroup(session.groupID), selectedSession === session else { return false }
        restoredIDs.insert(session.id)
        return true
    }

    @discardableResult
    func select(tabID: UUID) -> Bool {
        guard acceptsUserActions, let target = session(for: tabID), target.acceptsUserActions else { return false }
        if selectedSession === target { return restoreSelectedTab() }
        let previous = selectedSession
        // Leaving the visible editor must be durable. Revealing an existing
        // hidden owner is also how its failed checkpoint's Retry UI is reached;
        // requiring that owner's successful write first would trap its draft.
        guard previous?.prepareForPresentationTransition() != false,
              acceptsUserActions, target.acceptsUserActions,
              selectedSession === previous, session(for: tabID) === target else { return false }
        previous?.setPresented(false)
        target.setPresented(true)
        selectedID = target.id
        persist(); onChange?()
        return restoreSelectedTab()
    }

    /// The shared PDF owner supplies its actual session, not a new file open.
    @discardableResult
    func activateSession(_ captured: IPadWorkspaceSession) -> Bool {
        guard sessions.contains(where: { $0 === captured }) else { return false }
        return select(tabID: captured.id)
    }

    @discardableResult
    func addTab() -> IPadWorkspaceSession? {
        guard prepareCurrentTransition() else { return nil }
        let session = makeSession(UUID())
        selectedSession?.setPresented(false)
        sessions.append(session); selectedID = session.id
        restoredIDs.insert(session.id)
        session.setPresented(true)
        persist(); onChange?()
        return session
    }

    /// Pending transfer scenes intentionally start without a placeholder Store.
    /// A failed claim can explicitly become a usable blank window.
    @discardableResult
    func ensureBlankTab() -> IPadWorkspaceSession? {
        guard acceptsUserActions else { return nil }
        if let session = selectedSession { return session }
        guard sessions.isEmpty else { return nil }
        let session = makeSession(windowID)
        sessions = [session]; selectedID = session.id
        restoredIDs.insert(session.id); session.setPresented(true)
        persist(); onChange?()
        return session
    }

    /// Reuse the original presentation identity so its existing draft recovery
    /// records remain reachable. An active PDF owner is activated before any
    /// new workspace or writer is constructed.
    @discardableResult
    func reopenClosedTab(tabID: UUID) -> IPadWorkspaceSession? {
        guard acceptsUserActions, closedTabIDs.contains(tabID), prepareCurrentTransition() else { return nil }
        if let existing = session(for: tabID) {
            guard select(tabID: tabID), selectedSession === existing else { return nil }
            closedTabIDs.removeAll { $0 == tabID }; persist()
            return existing
        }
        let previous = selectedSession
        if let fileID = rememberedFileID(tabID: tabID),
           activateExistingEditor(fileID) { return nil }
        guard !isClosed, selectedSession === previous, closedTabIDs.contains(tabID),
              session(for: tabID) == nil else { return nil }
        let reopened = makeSession(tabID)
        previous?.setPresented(false)
        sessions.append(reopened); selectedID = reopened.id; reopened.setPresented(true)
        persist(); onChange?()
        guard restoreSelectedTab(), selectedSession === reopened else { return nil }
        closedTabIDs.removeAll { $0 == tabID }; persist()
        return reopened
    }

    /// The caller has visibly confirmed this exact tab identifier. Closing a
    /// tab invokes Session's normal durable teardown; switching never does.
    @discardableResult
    func closeConfirmed(tabID: UUID) -> Bool {
        let previous = selectedSession
        guard acceptsUserActions, let target = session(for: tabID), target.acceptsUserActions,
              prepareCurrentTransition(), target.prepareForPresentationTransition(),
              !isClosed, selectedSession === previous,
              session(for: tabID) === target else { return false }
        if pendingTransfer?.tabID == tabID { cancelPendingTransfer?() }
        guard !isClosed, selectedSession === previous,
              let index = sessions.firstIndex(where: { $0 === target }) else { return false }
        let wasSelected = selectedSession === target
        target.setPresented(false); target.close()
        sessions.remove(at: index); restoredIDs.remove(target.id)
        closedTabIDs.removeAll { $0 == target.id }; closedTabIDs.append(target.id)
        if sessions.isEmpty {
            let blank = makeSession(UUID())
            sessions = [blank]; selectedID = blank.id
            restoredIDs.insert(blank.id); blank.setPresented(true)
        } else if wasSelected {
            let next = sessions[min(index, sessions.count - 1)]
            selectedID = next.id; next.setPresented(true)
        }
        persist(); onChange?()
        _ = restoreSelectedTab()
        return true
    }

    @discardableResult
    func closeWindow() -> Bool {
        guard !isClosed else { return true }
        guard !isTransferring, !requiresTransferRecovery else { return false }
        let captured = sessions
        guard captured.allSatisfy({ $0.prepareForPresentationTransition() }),
              !isClosed, captured.count == sessions.count,
              zip(captured, sessions).allSatisfy({ $0.0 === $0.1 }) else { return false }
        cancelPendingTransfer?()
        persist(); isClosed = true
        sessions.forEach { $0.setPresented(false); $0.close() }
        onChange?()
        return true
    }

    func flushReadingState() { sessions.forEach { $0.flushReadingState() } }
    func cancelTransfer() { cancelPendingTransfer?() }
    fileprivate func sharesPersistence(with other: IPadWindowTabs) -> Bool { defaults === other.defaults }

    fileprivate func prepareCurrentTransition() -> Bool {
        guard acceptsUserActions else { return false }
        let current = selectedSession
        guard current?.prepareForPresentationTransition() != false else { return false }
        return !isClosed && selectedSession === current
    }

    fileprivate func assignTransfer(_ ticket: IPadWindowTabTransferTicket, cancel: @escaping () -> Void) {
        pendingTransfer = ticket; cancelPendingTransfer = cancel
    }

    fileprivate func clearTransfer(token: UUID) {
        guard pendingTransfer?.token == token else { return }
        pendingTransfer = nil; cancelPendingTransfer = nil
    }

    /// Registry calls both halves synchronously after all guards. No Session
    /// close/reopen, PDF import, or save is performed by a presentation move.
    fileprivate func detachForTransfer(_ session: IPadWorkspaceSession, replacementID: UUID?) {
        let index = sessions.firstIndex(where: { $0 === session })!
        let wasSelected = selectedSession === session
        session.setPresented(false)
        sessions.remove(at: index); restoredIDs.remove(session.id)
        if sessions.isEmpty {
            let blank = makeSession(replacementID!)
            sessions = [blank]; selectedID = blank.id
            restoredIDs.insert(blank.id); blank.setPresented(true)
        } else if wasSelected {
            let next = sessions[min(index, sessions.count - 1)]
            selectedID = next.id; next.setPresented(true)
        }
        persist()
    }

    fileprivate func adoptTransferred(_ session: IPadWorkspaceSession) {
        sessions = [session]; selectedID = session.id
        // The exact live session already owns its PDF; a claim never reopens it.
        restoredIDs.insert(session.id)
        session.setPresented(true)
        persist()
    }

    fileprivate func beginTransferIntent(_ ticket: IPadWindowTabTransferTicket, replacementID: UUID?) -> Bool {
        guard Self.activeTransferToken == nil, defaults.data(forKey: Self.transferIntentKey) == nil,
              let data = try? JSONEncoder().encode(TransferIntent(token: ticket.token,
                sourceWindowID: ticket.sourceWindowID, targetWindowID: ticket.targetWindowID,
                tabID: ticket.tabID, sourceReplacementID: replacementID)) else { return false }
        defaults.set(data, forKey: Self.transferIntentKey)
        Self.activeTransferToken = ticket.token
        return true
    }

    fileprivate func finishTransferIntent(token: UUID) {
        guard Self.activeTransferToken == token else { return }
        defaults.removeObject(forKey: Self.transferIntentKey)
        Self.activeTransferToken = nil
    }

    private static func persistenceKey(_ windowID: UUID) -> String { "Dogear.iPad.WindowTabs.\(windowID.uuidString)" }
    private var persistenceKey: String { Self.persistenceKey(windowID) }
    private func persist() {
        guard let data = try? JSONEncoder().encode(Saved(windowID: windowID, tabIDs: sessions.map(\.id),
            selectedID: selectedID, closedTabIDs: closedTabIDs)) else { return }
        defaults.set(data, forKey: persistenceKey)
    }
}

struct IPadWindowTabTransferTicket: Identifiable, Equatable {
    let token: UUID
    let sourceWindowID: UUID
    let targetWindowID: UUID
    let tabID: UUID
    var id: UUID { token }
}

/// A revocable presentation handoff. Until claim, the source still owns and
/// presents its tab. No PDF data or file access is transferred by this registry.
@MainActor
final class IPadWindowTabTransferRegistry: ObservableObject {
    static let shared = IPadWindowTabTransferRegistry()
    private final class Window {
        weak var tabs: IPadWindowTabs?
        init(_ tabs: IPadWindowTabs) { self.tabs = tabs }
    }
    private final class Entry {
        let ticket: IPadWindowTabTransferTicket
        weak var source: IPadWindowTabs?
        let session: IPadWorkspaceSession
        init(ticket: IPadWindowTabTransferTicket, source: IPadWindowTabs, session: IPadWorkspaceSession) {
            self.ticket = ticket; self.source = source; self.session = session
        }
    }
    private var entries: [UUID: Entry] = [:]
    private var windows: [UUID: Window] = [:]

    @discardableResult
    func register(_ tabs: IPadWindowTabs) -> Bool {
        guard tabs.acceptsUserActions else { return false }
        if let current = windows[tabs.windowID]?.tabs, current !== tabs { return false }
        windows[tabs.windowID] = Window(tabs)
        return true
    }

    /// Call after a successful normal window close. This only cancels pending
    /// presentation tickets; Session teardown remains the window owner's job.
    func unregister(windowID: UUID) {
        windows.removeValue(forKey: windowID)
        let tickets = entries.values.filter {
            $0.ticket.sourceWindowID == windowID || $0.ticket.targetWindowID == windowID
        }.map(\.ticket)
        for ticket in tickets { cancel(token: ticket.token, sourceWindowID: ticket.sourceWindowID) }
    }

    func pendingTicket(targetWindowID: UUID) -> IPadWindowTabTransferTicket? {
        entries.values.first { $0.ticket.targetWindowID == targetWindowID }?.ticket
    }

    @discardableResult
    func stage(source: IPadWindowTabs, tabID: UUID, targetWindowID: UUID) -> IPadWindowTabTransferTicket? {
        guard source.windowID != targetWindowID, source.acceptsUserActions,
              windows[source.windowID]?.tabs === source, windows[targetWindowID]?.tabs == nil,
              let session = source.session(for: tabID), source.selectedSession === session,
              session.acceptsUserActions, source.prepareCurrentTransition(),
              source.selectedSession === session, pendingTicket(targetWindowID: targetWindowID) == nil else { return nil }
        source.cancelPendingTransfer?()
        guard source.acceptsUserActions, source.selectedSession === session,
              source.session(for: tabID) === session, session.acceptsUserActions,
              windows[source.windowID]?.tabs === source, windows[targetWindowID]?.tabs == nil,
              pendingTicket(targetWindowID: targetWindowID) == nil else { return nil }
        let ticket = IPadWindowTabTransferTicket(token: UUID(), sourceWindowID: source.windowID,
            targetWindowID: targetWindowID, tabID: session.id)
        entries[ticket.token] = Entry(ticket: ticket, source: source, session: session)
        source.assignTransfer(ticket) { [weak self] in
            self?.cancel(token: ticket.token, sourceWindowID: ticket.sourceWindowID)
        }
        return ticket
    }

    func cancel(token: UUID, sourceWindowID: UUID) {
        guard let entry = entries[token], entry.ticket.sourceWindowID == sourceWindowID else { return }
        entries.removeValue(forKey: token)
        entry.source?.clearTransfer(token: token)
    }

    @discardableResult
    func claim(token: UUID, targetWindowID: UUID, into target: IPadWindowTabs) -> IPadWorkspaceSession? {
        guard let entry = entries[token], let source = entry.source,
              entry.ticket.targetWindowID == targetWindowID, target.windowID == targetWindowID,
              source.windowID == entry.ticket.sourceWindowID, source !== target,
              source.sharesPersistence(with: target),
              windows[source.windowID]?.tabs === source, windows[targetWindowID]?.tabs === target,
              target.acceptsUserActions, target.sessions.isEmpty, source.acceptsUserActions,
              source.pendingTransfer == entry.ticket,
              source.session(for: entry.ticket.tabID) === entry.session, entry.session.acceptsUserActions,
              source.prepareCurrentTransition(), entry.session.prepareForPresentationTransition(),
              target.prepareCurrentTransition(), entries[token] === entry,
              source.acceptsUserActions, target.acceptsUserActions, entry.session.acceptsUserActions,
              windows[source.windowID]?.tabs === source, windows[targetWindowID]?.tabs === target,
              target.sessions.isEmpty, source.session(for: entry.ticket.tabID) === entry.session,
              source.pendingTransfer == entry.ticket else { return nil }
        let replacementID: UUID? = source.sessions.count == 1 ? UUID() : nil
        guard source.beginTransferIntent(entry.ticket, replacementID: replacementID) else { return nil }
        // Published changes can synchronously call external observers. Protect
        // collection membership through both halves of this accepted claim.
        source.isTransferring = true; target.isTransferring = true
        // Consume before observable mutations so a reentrant late claim cannot
        // acquire the same session a second time.
        entries.removeValue(forKey: token); source.clearTransfer(token: token)
        source.detachForTransfer(entry.session, replacementID: replacementID)
        target.adoptTransferred(entry.session)
        source.finishTransferIntent(token: token)
        source.isTransferring = false; target.isTransferring = false
        source.onChange?(); target.onChange?()
        return entry.session
    }
}
#endif
