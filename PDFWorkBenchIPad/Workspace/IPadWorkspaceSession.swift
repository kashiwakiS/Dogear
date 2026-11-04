#if os(iOS)
import Combine
import PDFKit
import UIKit

@MainActor
final class IPadGroupWorkspace: ObservableObject {
    let state: GroupWorkspaceState
    let export = IPadDocumentExportPresenter()
    let feedback: OperationFeedbackCenter
    let document: PDFDocumentStore
    let noteDraftRecovery: IPadInlineNoteDraftRecovery
    let highlightDraftRecovery: IPadHighlightDraftRecovery
    let researchPresentation = IPadResearchPresentation()
    @Published var navigation: PDFReaderUIKitNavigation?
    @Published var selection: PDFSelection?
    @Published var inlineNoteSession: IPadInlineNoteEditingSession? {
        didSet { noteDraftRecovery.track(inlineNoteSession) }
    }
    @Published var highlightEditingSession: IPadHighlightEditingSession? {
        didSet { highlightDraftRecovery.track(highlightEditingSession) }
    }
    @Published var showsResearch = false {
        didSet { if oldValue != showsResearch { cancelEvidencePreview() } }
    }
    var zoomPercent = 100.0
    var zoomMode: PDFZoomState.Mode = .fitPage
    var zoomIsFit: Bool {
        get { zoomMode != .custom }
        set { zoomMode = newValue ? .fitPage : .custom }
    }
    var pageOffset: PDFPageOffset?
    @Published var reference: IPadReferencePreview?
    private var evidenceTask: Task<Void, Never>?
    private var evidenceTicket: UUID?
    var libraryBinding: IPadWorkingCopyLibraryBinding?
    private var researchPreparation: (token: UUID, prepare: () -> Bool)?

    @discardableResult
    func registerResearchPresentationPreparation(_ prepare: @escaping () -> Bool) -> UUID {
        let token = UUID()
        researchPreparation = (token, prepare)
        return token
    }

    func unregisterResearchPresentationPreparation(_ token: UUID) {
        if researchPreparation?.token == token { researchPreparation = nil }
    }

    func prepareResearchForPresentationTransition() -> Bool {
        researchPreparation?.prepare() ?? true
    }

    var canBeginInlineNote: Bool {
        inlineNoteSession == nil && highlightEditingSession == nil && !noteDraftRecovery.hasUnresolvedRecord
    }
    var canBeginHighlight: Bool {
        highlightEditingSession == nil && inlineNoteSession == nil && !highlightDraftRecovery.hasUnresolvedRecord
    }

    func restoreHighlightIfNeeded() {
        guard highlightEditingSession == nil else { _ = highlightDraftRecovery.flush(); return }
        if let note = inlineNoteSession, !note.isFinished {
            highlightDraftRecovery.track(nil)
            return
        }
        if let restored = highlightDraftRecovery.restore() {
            highlightEditingSession = restored
            showsResearch = false
            if let page = restored.draft.annotation.page {
                navigate(pageIndex: restored.draft.document.index(for: page), bounds: restored.baselineBounds)
            }
        }
    }

    func restoreInlineNoteIfNeeded() {
        guard inlineNoteSession == nil else { noteDraftRecovery.flush(); return }
        if let highlight = highlightEditingSession, !highlight.isFinished {
            noteDraftRecovery.track(nil)
            return
        }
        if let restored = noteDraftRecovery.restore() {
            inlineNoteSession = restored
            showsResearch = false
            navigate(pageIndex: restored.draft.document.index(for: restored.draft.page), bounds: restored.bounds)
        }
    }

    @discardableResult
    func flushInlineNote() -> Bool { noteDraftRecovery.flush() }
    @discardableResult
    func flushHighlight() -> Bool { highlightDraftRecovery.flush() }

    /// Preparation happens before revoking commands/presentation or releasing
    /// ownership. Evaluate every checkpoint, even if a different editor fails.
    func prepareEditingForTransition() -> Bool {
        let researchReady = prepareResearchForPresentationTransition()
        let noteReady = flushInlineNote()
        let highlightReady = flushHighlight()
        libraryBinding?.flushZoom()
        return researchReady && noteReady && highlightReady
    }

    func undoDocumentChange() {
        guard state.isActive, !state.isClosed, let native = document.document,
              noteDraftRecovery.prepareDocumentUndo(in: native),
              highlightDraftRecovery.prepareDocumentUndo(in: native) else { return }
        document.undoDocumentChange()
        noteDraftRecovery.didUndoDocument(in: native)
        highlightDraftRecovery.didUndoDocument(in: native)
    }

    /// Each native evidence action owns one revocable presentation request.
    /// Cancellation is also checked after resolution because providers may
    /// complete an already-cancelled read or cooperative text validation.
    func beginEvidencePreview(resolve: @escaping @MainActor () async throws -> ResolvedResearchEvidence,
                              title: String, onError: @escaping (String) -> Void) {
        cancelEvidencePreview()
        guard state.isActive, !state.isClosed, showsResearch else { return }
        let ticket = UUID(); evidenceTicket = ticket
        evidenceTask = Task { [weak self] in
            do {
                let result = try await resolve()
                guard let self, !Task.isCancelled, self.evidenceTicket == ticket,
                      self.state.isActive, !self.state.isClosed, self.showsResearch else { return }
                self.evidenceTicket = nil; self.evidenceTask = nil
                self.reference = .init(document: result.document, pageIndex: result.pageIndex,
                    bounds: result.rect, title: title)
            } catch {
                guard let self, !Task.isCancelled, self.evidenceTicket == ticket,
                      self.state.isActive, !self.state.isClosed, self.showsResearch else { return }
                self.evidenceTicket = nil; self.evidenceTask = nil
                onError(error.localizedDescription)
            }
        }
    }

    func cancelEvidencePreview() {
        evidenceTicket = nil; evidenceTask?.cancel(); evidenceTask = nil
        reference = nil
    }

    var pendingNavigation: PDFReaderUIKitNavigation? {
        guard let navigation, !navigation.isAccepted,
              navigation.document === document.document else { return nil }
        return navigation
    }

    func acknowledgeNavigation(in document: PDFDocument, requestID: UUID) {
        guard self.document.document === document,
              navigation?.document === document, navigation?.id == requestID,
              navigation?.isAccepted == true else { return }
        navigation = nil
    }

    func readingState(for document: PDFDocument) -> PDFReaderUIKitReadingState {
        let selected = selection.flatMap { native -> PDFSelection? in
            guard let expected = self.document.currentTextSelection,
                  PDFTextSelectionService.snapshot(of: native, in: document) == expected else { return nil }
            return native
        }
        return .init(document: document, pageIndex: self.document.currentPageIndex,
                     selection: selected, zoom: zoomMode == .fitWidth ? .fitWidth : (zoomIsFit ? .fit : .percent(zoomPercent)),
                     pageOffset: pageOffset)
    }

    func restoreZoom(from saved: PDFZoomState?) {
        if saved?.mode == .custom, let factor = saved?.scaleFactor, factor.isFinite, factor > 0 {
            zoomIsFit = false; zoomPercent = factor * 100
        } else {
            zoomMode = saved?.mode == .fitWidth ? .fitWidth : .fitPage
            zoomPercent = 100
        }
    }

    init(id: UUID, groupID: UUID, documentStore: PDFDocumentStore? = nil,
         feedbackCenter: OperationFeedbackCenter? = nil,
         accessCoordinator: DocumentAccessCoordinator? = nil,
         noteDraftDirectoryURL: URL? = nil, highlightDraftDirectoryURL: URL? = nil) {
        state = GroupWorkspaceState(id: id, groupID: groupID)
        feedback = feedbackCenter ?? OperationFeedbackCenter()
        document = documentStore ?? PDFDocumentStore(feedbackCenter: feedback,
            accessCoordinator: accessCoordinator ?? .shared, exportPresenter: export)
        noteDraftRecovery = IPadInlineNoteDraftRecovery(workspaceID: id, store: document, feedback: feedback,
            directoryURL: noteDraftDirectoryURL)
        highlightDraftRecovery = IPadHighlightDraftRecovery(workspaceID: id, store: document, feedback: feedback,
            directoryURL: highlightDraftDirectoryURL)
        document.setUndoManager(state.undoManager)
    }
    func navigate(pageIndex: Int, bounds: CGRect? = nil, selection: PDFSelection? = nil,
                  zoom: ResearchZoomCommand? = nil, pageOffset: PDFPageOffset? = nil) {
        guard let pdf = document.document, pdf.page(at: pageIndex) != nil else { return }
        if let zoom {
            switch zoom {
            case .fit: zoomMode = .fitPage
            case .fitWidth: zoomMode = .fitWidth
            case .percent(let value): zoomMode = .custom; zoomPercent = value
            }
        }
        self.pageOffset = pageOffset
        navigation = .init(document: pdf, pageIndex: pageIndex, bounds: bounds, selection: selection, zoom: zoom, pageOffset: pageOffset)
    }
}

struct IPadReferencePreview: Identifiable {
    let id = UUID()
    let document: PDFDocument
    let pageIndex: Int
    let bounds: CGRect?
    let title: String
}

/// Shared Store saves may finish while Research is visible or a Group is
/// retained off screen. Keep its copy record in Library independently of Reader
/// view mounting. The binding owns the same stable file/document identity that
/// the host successfully passed to Store; a new open cannot redirect old saves.
@MainActor
final class IPadWorkingCopyLibraryBinding {
    private var observation: AnyCancellable?
    private var originalObservation: AnyCancellable?
    private weak var store: PDFDocumentStore?
    private weak var library: LibraryStore?
    private weak var boundDocument: PDFDocument?
    private var boundOriginalPath: String?
    private var fileID: UUID?
    private var suspended = false
    private var zoomTask: Task<Void, Never>?
    private var pendingZoom: (fileID: UUID, value: PDFZoomState)?
    init(store: PDFDocumentStore, library: LibraryStore) {
        self.store = store; self.library = library
        observation = store.$currentWorkingCopyURL.sink { [weak self] url in
            guard let self, !self.suspended, let document = self.boundDocument,
                  self.store?.document === document, let library = self.library,
                  self.store?.selectedPDFURL?.libraryComparablePath == self.boundOriginalPath,
                  let id = self.fileID, let file = library.allFiles.first(where: { $0.id == id }) else { return }
            library.updateWorkingCopyURL(url, for: file)
        }
        originalObservation = store.$selectedPDFURL.sink { [weak self] url in
            guard let self, !self.suspended, let document = self.boundDocument,
                  self.store?.document === document, let path = url?.libraryComparablePath,
                  let id = self.fileID, let library = self.library,
                  let file = library.allFiles.first(where: { $0.id == id }),
                  file.canonicalPath == path else { return }
            // The shared coordinator publishes this only after the exact-content
            // relink commits Library. It retains the native PDF and its Undo.
            self.boundOriginalPath = path
        }
    }
    func bind(fileID: UUID) {
        self.fileID = fileID; boundDocument = store?.document
        boundOriginalPath = store?.selectedPDFURL?.libraryComparablePath
        if let library, let file = library.allFiles.first(where: { $0.id == fileID }) {
            library.updateWorkingCopyURL(store?.currentWorkingCopyURL, for: file)
        }
    }
    func suspendUpdates() { suspended = true }
    func resumeUpdates() { suspended = false }

    func owns(fileID: UUID) -> Bool {
        self.fileID == fileID && boundDocument != nil && store?.document === boundDocument
    }

    func recordPage(_ page: Int, in document: PDFDocument) {
        guard boundDocument === document, store?.document === document,
              let library, let file = library.allFiles.first(where: { $0.id == fileID }) else { return }
        library.updateLastPage(for: file.url, pageIndex: page)
    }

    func recordPosition(page: Int, offset: PDFPageOffset, in document: PDFDocument) {
        guard !suspended, boundDocument === document, store?.document === document, let fileID else { return }
        library?.updateReadingPosition(fileID: fileID, pageIndex: page, offset: offset)
    }

    func recordZoom(percent: Double, isFit: Bool, in document: PDFDocument) {
        guard percent.isFinite, percent > 0 else { return }
        recordZoom(isFit ? .fitPage : .custom(scaleFactor: percent / 100), in: document)
    }

    func recordZoom(_ state: PDFZoomState, in document: PDFDocument) {
        guard !suspended, boundDocument === document, store?.document === document, let id = fileID else { return }
        if pendingZoom?.fileID != id { flushZoom() }
        pendingZoom = (id, state)
        zoomTask?.cancel()
        zoomTask = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: 300_000_000) } catch { return }
            self?.flushZoom()
        }
    }

    func flushZoom() {
        zoomTask?.cancel(); zoomTask = nil
        guard let pendingZoom, let library,
              let file = library.allFiles.first(where: { $0.id == pendingZoom.fileID }) else {
            pendingZoom = nil; return
        }
        self.pendingZoom = nil
        library.updateZoomState(pendingZoom.value, for: file.url)
    }
}

@MainActor
final class IPadWorkspaceSession: ObservableObject {
    let id: UUID
    @Published var groupID: UUID
    @Published private(set) var workspace: IPadGroupWorkspace
    @Published private(set) var workspacesNeedingDraftRecovery: [IPadGroupWorkspace] = []
    private var workspaces: [UUID: IPadGroupWorkspace]
    private let services: IPadApplicationServices
    private let userDefaults: UserDefaults
    private let accessCoordinator: DocumentAccessCoordinator
    private let workspaceFactory: @MainActor (UUID, UUID, DocumentAccessCoordinator) -> IPadGroupWorkspace
    var activateScene: (() -> Void)?
    private var libraryObservation: AnyCancellable?
    private var isClosed = false
    private var isPresented = true
    let importer = LibraryImportController()
    var acceptsUserActions: Bool { !isClosed }

    init(id: UUID, services: IPadApplicationServices, userDefaults: UserDefaults = .standard,
         accessCoordinator: DocumentAccessCoordinator? = nil,
         workspaceFactory: (@MainActor (UUID, UUID, DocumentAccessCoordinator) -> IPadGroupWorkspace)? = nil) {
        self.id = id; self.services = services; self.userDefaults = userDefaults
        self.accessCoordinator = accessCoordinator ?? .shared
        let factory = workspaceFactory ?? { id, groupID, coordinator in
            IPadGroupWorkspace(id: id, groupID: groupID, accessCoordinator: coordinator)
        }
        self.workspaceFactory = factory
        let groupID = services.library.state.windowSessions.filter { $0.id == id }.max(by: { $0.updatedAt < $1.updatedAt })?.groupID ?? services.library.initialWindowGroupID
        self.groupID = groupID
        let workspace = factory(Self.workspaceID(sceneID: id, groupID: groupID, defaults: userDefaults),
                                groupID, self.accessCoordinator)
        workspace.libraryBinding = IPadWorkingCopyLibraryBinding(store: workspace.document, library: services.library)
        self.workspace = workspace; workspaces = [groupID: workspace]
        services.library.ensureWindowSession(for: groupID, sessionID: id)
        libraryObservation = services.library.$state.map { Set($0.groups.map(\.id)) }
            .removeDuplicates().sink { [weak self] _ in
                // Combine publishes before its state setter completes.
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.reconcileGroups(Set(self.services.library.state.groups.map(\.id)))
                }
            }
    }
    private static func workspaceID(sceneID: UUID, groupID: UUID, defaults: UserDefaults) -> UUID {
        // Presentation identity survives relaunch. ResearchCommandService also
        // issues a fresh registration identity, so old navigation leases expire.
        let key = "Dogear.iPad.Workspace.\(sceneID.uuidString).\(groupID.uuidString)"
        if let stored = defaults.string(forKey: key), let id = UUID(uuidString: stored) { return id }
        let id = UUID(); defaults.set(id.uuidString, forKey: key); return id
    }
    private func reconcileGroups(_ groups: Set<UUID>) {
        guard !isClosed else { return }
        for removedID in workspaces.keys.filter({ !groups.contains($0) }) {
            guard let removed = workspaces.removeValue(forKey: removedID) else { continue }
            services.commands.unregister(viewID: removed.state.id)
            if !removed.prepareEditingForTransition() {
                removed.cancelEvidencePreview(); removed.libraryBinding?.flushZoom()
                removed.state.setActive(false)
                workspacesNeedingDraftRecovery.append(removed)
                continue
            }
            removed.cancelEvidencePreview(); removed.libraryBinding?.flushZoom(); removed.libraryBinding = nil
            if let ticket = removed.export.ticket { removed.export.finish(ticket.id, result: .success(nil)) }
            removed.document.releaseEditorAccess()
            _ = removed.state.finishClosing()
            userDefaults.removeObject(forKey: "Dogear.iPad.Workspace.\(id.uuidString).\(removedID.uuidString)")
        }
        if !groups.contains(groupID) {
            _ = activateGroup(LibraryGroup.ungroupedID, restoringSelection: true, preparingCurrent: false)
        }
    }

    /// A removed Group cannot veto a native teardown. Keep the exact failed
    /// draft owner until the user explicitly brings it into a visible Group.
    @discardableResult
    func recoverDraftWorkspace(id workspaceID: UUID) -> Bool {
        guard !isClosed, isPresented,
              let recovered = workspacesNeedingDraftRecovery.first(where: { $0.state.id == workspaceID }),
              !recovered.state.isClosed,
              workspace.export.ticket == nil, workspace.document.pendingExportOptions == nil else { return false }
        guard workspace.prepareEditingForTransition(),
              let group = services.library.createGroup(named: L10n.string("Recovered Draft")) else { return false }
        services.commands.unregister(viewID: workspace.state.id)
        workspace.cancelEvidencePreview(); workspace.libraryBinding?.flushZoom(); workspace.state.setActive(false)
        _ = recovered.state.updateGroupID(group.id)
        if let fileID = recovered.document.captureWritePermit(requestID: UUID())?.fileID {
            services.library.addFile(fileID, to: group.id)
            services.library.recordOpenedFile(fileID, in: group.id, sessionID: id)
        }
        workspaces[group.id] = recovered
        groupID = group.id; workspace = recovered
        workspacesNeedingDraftRecovery.removeAll { $0 === recovered }
        recovered.state.setActive(true)
        services.library.ensureWindowSession(for: group.id, sessionID: id)
        recovered.showsResearch = false
        return true
    }
    @discardableResult
    func selectGroup(_ groupID: UUID) -> Bool {
        activateGroup(groupID, restoringSelection: true)
    }

    /// An explicit file target must not first open a remembered, unrelated PDF.
    @discardableResult
    func open(_ file: LibraryFile, in groupID: UUID) -> Bool {
        guard activateGroup(groupID, restoringSelection: false) else { return false }
        return open(file)
    }

    private func activateGroup(_ groupID: UUID, restoringSelection: Bool, preparingCurrent: Bool = true) -> Bool {
        guard !isClosed, workspace.export.ticket == nil, workspace.document.pendingExportOptions == nil, services.library.group(withID: groupID) != nil else { return false }
        if self.groupID == groupID {
            workspace.state.setActive(isPresented)
            if restoringSelection { restoreSelectedFileIfNeeded() }
            return self.groupID == groupID
        }
        if preparingCurrent {
            guard workspace.prepareEditingForTransition() else { return false }
        }
        services.commands.userDidInteract(viewID: workspace.state.id)
        services.commands.unregister(viewID: workspace.state.id)
        workspace.cancelEvidencePreview()
        workspace.libraryBinding?.flushZoom()
        workspace.state.setActive(false)
        let next = workspaces[groupID] ?? workspaceFactory(
            Self.workspaceID(sceneID: id, groupID: groupID, defaults: userDefaults), groupID, accessCoordinator)
        if next.libraryBinding == nil {
            next.libraryBinding = IPadWorkingCopyLibraryBinding(store: next.document, library: services.library)
        }
        workspaces[groupID] = next
        self.groupID = groupID; workspace = next
        next.state.setActive(isPresented)
        services.library.ensureWindowSession(for: groupID, sessionID: id)
        if restoringSelection { restoreSelectedFileIfNeeded() }
        return self.groupID == groupID
    }
    private func restoreSelectedFileIfNeeded() {
        if workspace.document.document == nil,
           let fileID = services.library.openSession(for: groupID, sessionID: id)?.selectedFileID,
           let file = services.library.allFiles.first(where: { $0.id == fileID }) { open(file) }
    }
    @discardableResult
    func open(_ file: LibraryFile) -> Bool {
        guard !isClosed, workspace.export.ticket == nil,
              workspace.document.pendingExportOptions == nil else { return false }
        let current = workspace
        services.commands.userDidInteract(viewID: current.state.id)
        if current.libraryBinding?.owns(fileID: file.id) == true {
            current.restoreInlineNoteIfNeeded()
            current.restoreHighlightIfNeeded()
            return true
        }
        guard current.prepareResearchForPresentationTransition() else { return false }
        if let highlight = current.highlightEditingSession, !highlight.isFinished {
            guard highlight.finishIME(), !highlight.isDirty else {
                current.showsResearch = false
                current.feedback.post(L10n.string("Save or discard the current highlight comment before opening another PDF."), kind: .warning)
                return false
            }
            guard highlight.discard() else { return false }
            current.highlightEditingSession = nil
        }
        if let note = current.inlineNoteSession, !note.isFinished {
            guard note.finishIME(), !note.isDirty else {
                current.showsResearch = false
                current.navigate(pageIndex: note.draft.document.index(for: note.draft.page), bounds: note.bounds)
                current.feedback.post(L10n.string("Save or discard the current note before opening another PDF."), kind: .warning)
                return false
            }
            guard note.discard() else { return false }
            current.inlineNoteSession = nil
        }
        current.document.setEditorActivationHandler { [weak self, weak current] in
            guard let self, let current, !self.isClosed else { return }
            if self.services.library.group(withID: current.state.groupID) != nil {
                self.selectGroup(current.state.groupID)
            }
            self.activateScene?()
        }
        let url = services.library.resolvedURL(for: file)
        if accessCoordinator.activateExistingEditor(fileID: file.id, excluding: current.document)
            || accessCoordinator.activateExistingEditor(for: url, excluding: current.document) {
            return workspace.document.canEditDocument
                && services.library.file(for: workspace.document.selectedPDFURL)?.id == file.id
        }
        let openingCopy = services.library.openingWorkingCopyURL(for: file)
        current.libraryBinding?.flushZoom()
        current.libraryBinding?.suspendUpdates()
        defer { current.libraryBinding?.resumeUpdates() }
        if current.document.openPDF(from: url, workingCopyURL: openingCopy,
                                    initialPageIndex: file.lastPageIndex), current.document.bindLibraryFile(file.id) {
            current.navigation?.cancel()
            current.navigation = nil
            current.pageOffset = nil
            current.selection = nil
            let restoredPageIndex = current.document.currentPageIndex
            let restoredOffset = restoredPageIndex == file.lastPageIndex ? file.lastPageOffset : nil
            services.library.refreshResolvedURL(url, for: file)
            current.libraryBinding?.bind(fileID: file.id)
            current.restoreZoom(from: services.library.allFiles.first(where: { $0.id == file.id })?.lastZoomState)
            current.navigate(pageIndex: restoredPageIndex, pageOffset: restoredOffset)
            current.noteDraftRecovery.bind(fileID: file.id)
            current.highlightDraftRecovery.bind(fileID: file.id)
            current.restoreInlineNoteIfNeeded()
            current.restoreHighlightIfNeeded()
            services.library.recordOpenedFile(file.id, in: groupID, sessionID: id)
            services.library.updateWorkingCopyURL(current.document.currentWorkingCopyURL, for: file)
            Task { try? await services.library.captureOriginalFingerprint(for: file.id) }
            return true
        }
        // The coordinator may have activated this scene's existing writer in
        // another retained Group. Reveal that actual editor in compact layout.
        return workspace.document.canEditDocument
            && services.library.file(for: workspace.document.selectedPDFURL)?.id == file.id
    }
    func importURLs(_ urls: [URL], groupID: UUID) {
        let capturedWorkspace = workspace
        guard !isClosed, services.library.group(withID: groupID) != nil,
              capturedWorkspace.export.ticket == nil,
              capturedWorkspace.document.pendingExportOptions == nil else { return }
        importer.start(urls: urls, library: services.library, groupID: groupID, sessionID: id,
            assignToGroup: false, mayContinue: { [weak self, weak capturedWorkspace] in
                guard let self, let capturedWorkspace else { return false }
                return !self.isClosed && self.services.library.group(withID: groupID) != nil
                    && capturedWorkspace.export.ticket == nil
                    && capturedWorkspace.document.pendingExportOptions == nil
            }, onOpen: { [weak self] file, importedGroup in
                guard let self, !self.isClosed, self.groupID == groupID,
                      importedGroup == groupID else { return }
                _ = self.open(file, in: groupID)
            })
    }
    func close() {
        guard !isClosed else { return }; isClosed = true
        importer.cancel()
        libraryObservation = nil
        for workspace in Array(workspaces.values) + workspacesNeedingDraftRecovery {
            services.commands.unregister(viewID: workspace.state.id)
            workspace.flushInlineNote()
            _ = workspace.flushHighlight()
            workspace.cancelEvidencePreview(); workspace.libraryBinding?.flushZoom(); workspace.libraryBinding = nil
            if let ticket = workspace.export.ticket { workspace.export.finish(ticket.id, result: .success(nil)) }
            workspace.document.releaseEditorAccess()
            _ = workspace.state.finishClosing()
        }
        _ = services.library.flushPendingPersistence()
    }

    /// A tab transition retains every document and its Undo, but first makes
    /// unfinished native input and reading state durable through their owners.
    @discardableResult
    func prepareForPresentationTransition() -> Bool {
        guard !isClosed else { return false }
        let live = (Array(workspaces.values) + workspacesNeedingDraftRecovery).filter { !$0.state.isClosed }
        guard live.allSatisfy({ $0.export.ticket == nil
            && $0.document.pendingExportOptions == nil && $0.document.pendingConfirmation == nil }) else { return false }
        let prepared = live.map { $0.prepareEditingForTransition() }.allSatisfy { $0 }
        guard prepared, !isClosed else { return false }
        return services.library.flushPendingPersistence()
    }

    /// Hiding a tab revokes presentation capabilities while keeping its writer.
    /// The visible host registers fresh Research commands when it reappears.
    func setPresented(_ presented: Bool) {
        guard !isClosed else { return }
        isPresented = presented
        if !presented {
            workspace.cancelEvidencePreview()
            services.commands.unregister(viewID: workspace.state.id)
        }
        workspace.state.setActive(presented)
    }
    func flushReadingState() {
        (Array(workspaces.values) + workspacesNeedingDraftRecovery).forEach {
            $0.flushInlineNote(); _ = $0.flushHighlight(); $0.libraryBinding?.flushZoom()
        }
        _ = services.library.flushPendingPersistence()
    }
}
#endif
