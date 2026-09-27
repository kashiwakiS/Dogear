import SwiftUI
import AppKit
import Observation
import PDFKit
import UniformTypeIdentifiers

struct ContentView: View {
    @StateObject private var documentStore: PDFDocumentStore
    @StateObject private var feedbackCenter: OperationFeedbackCenter
    @StateObject private var aiReadingStore: AIReadingStore
    @StateObject private var aiHighlightStore: AIHighlightGenerationStore
    @StateObject private var importController = LibraryImportController()
    @StateObject private var researchWorkspace: ResearchWorkspaceState
    @ObservedObject private var researchStore = ResearchStore.shared
    @ObservedObject private var researchRuntime = ResearchRuntime.shared
    @State private var researchEvidencePreview: ResearchEvidence?
    @State private var researchRegionCapture: ResearchRegionCapture?
    @State private var pendingResearchSelection: ResearchInputBlock?
    @State private var researchSplitStart = 0.5
    @State private var researchReadingPosition = PDFReadingPositionCache()
    @State private var researchZoomMode = "fitWidth"
    @State private var researchViewGeneration = 0
    @State private var windowFrameController = WindowFrameController()
    @ObservedObject private var workspaceContext: GroupWorkspaceContext
    private var groupTitlebarController: GroupWorkspaceTitlebarController { workspaceContext.titlebarController }
    @ObservedObject private var externalPDFOpenCoordinator = ExternalPDFOpenCoordinator.shared
    @ObservedObject var libraryStore: LibraryStore
    let initialGroupID: UUID?
    let initialSessionID: UUID?

    @Environment(\.workspaceOpenWindow) private var openWindow
    @State private var activeGroupID: UUID
    @State private var windowSessionID: UUID
    @State private var didOpenLaunchArgument = false
    @State private var didApplyInitialGroup = false
    @State private var isShowingFileImporter = false
    @State private var pickerGroupID: UUID?
    @State private var pickerTrigger: FeedbackTrigger?
    @State private var fileInfoItem: LibraryFile?
    @State private var fileToOpenAfterInfo: UUID?
    @State private var filesForNewGroup: [UUID] = []
    @State private var discardItem: LibraryFile?
    @State private var discardRequest: WorkingCopyDiscardRequest?
    @State private var isShowingDiscardConfirmation = false
    @State private var isShowingNewGroupSheet = false
    @State private var groupToOpenAfterSheet: UUID?
    @State private var isShowingRenameGroupSheet = false
    @State private var isShowingDeleteGroupConfirmation = false
    @State private var isShowingRemoveLibraryItemConfirmation = false
    @State private var groupPendingRename: LibraryGroup?
    @State private var groupPendingDeletion: LibraryGroup?
    @State private var libraryItemPendingRemoval: LibraryItem?
    @State private var isShowingPageOrganizer = false
    @State private var windowSidebarState = WindowSidebarState()
    @State private var newGroupName = ""
    @State private var librarySidebarDragStartWidth: CGFloat = 300
    @State private var annotationSidebarDragStartWidth: CGFloat = 284
    @State private var latestContentWidth: CGFloat = 984
    @State private var lockedWorkspaceWidth: CGFloat?
    @State private var workspaceLockID = UUID()
    @State private var annotationTransition: AnnotationSidebarTransition?
    @State private var pageJumpText = "1"
    @State private var readingDisplayStyle: PDFReadingDisplayStyle = .continuous
    @State private var isNightMode = false
    @State private var isMarginCanvasVisible = true
    @State private var zoomCommandCounter = 0
    @State private var zoomCommand: PDFZoomCommand?
    @State private var zoomScalePercent = 100
    @State private var pendingZoomPersistence: PendingPDFZoomPersistence?
    @State private var zoomPersistenceTask: Task<Void, Never>?
    @State private var activeFindScope: ReaderFindScope = .documentText
    @State private var findFocusRequest: ReaderFindRequest?
    @State private var findFocusRequestID = 0
    @State private var focusedReaderFindScope: ReaderFindScope?

    private let librarySidebarRange: ClosedRange<CGFloat> = 240...440
    // Includes the reserved 16-point resize target. The ReaderSidebarView
    // content therefore retains its previous 220...390-point width range.
    private let annotationSidebarRange: ClosedRange<CGFloat> = 236...406
    private let centerMinimumWidth: CGFloat = 520
    private let sidebarHandleWidth: CGFloat = 16
    private let minimumWorkspaceWithoutAnnotation: CGFloat = 520

    private var isLibraryNavigatorVisible: Bool {
        get { windowSidebarState.isLibraryVisible }
        nonmutating set { windowSidebarState.isLibraryVisible = newValue }
    }

    private var librarySidebarWidth: CGFloat {
        get { windowSidebarState.libraryWidth }
        nonmutating set { windowSidebarState.libraryWidth = newValue }
    }

    private var isAnnotationSidebarVisible: Bool {
        get { windowSidebarState.isVisible }
        nonmutating set { windowSidebarState.isVisible = newValue }
    }

    private var annotationSidebarWidth: CGFloat {
        get { windowSidebarState.width }
        nonmutating set { windowSidebarState.width = newValue }
    }

    init(
        libraryStore: LibraryStore,
        initialGroupID: UUID? = nil,
        initialSessionID: UUID? = nil,
        workspaceContext: GroupWorkspaceContext? = nil
    ) {
        let feedbackCenter = OperationFeedbackCenter()
        _feedbackCenter = StateObject(wrappedValue: feedbackCenter)
        _documentStore = StateObject(
            wrappedValue: PDFDocumentStore(feedbackCenter: feedbackCenter)
        )
        _aiReadingStore = StateObject(wrappedValue: AIReadingStore())
        _aiHighlightStore = StateObject(wrappedValue: AIHighlightGenerationStore())
        let resolvedSessionID = workspaceContext?.workspaceID ?? initialSessionID ?? UUID()
        _workspaceContext = ObservedObject(wrappedValue: workspaceContext ?? GroupWorkspaceContext(
            payload: GroupWindowPayload(sessionID: resolvedSessionID,
                groupID: initialGroupID ?? libraryStore.initialWindowGroupID)))
        _researchWorkspace = StateObject(wrappedValue: ResearchWorkspaceState(windowSessionID: resolvedSessionID))
        self.libraryStore = libraryStore
        self.initialGroupID = initialGroupID
        self.initialSessionID = initialSessionID
        _activeGroupID = State(initialValue: initialGroupID ?? libraryStore.initialWindowGroupID)
        _windowSessionID = State(initialValue: resolvedSessionID)
    }

    private var windowWorkspace: some View {
        GeometryReader { proxy in
            let workspaceWidth = workspaceWidth(for: proxy.size.width)

            ZStack(alignment: .bottomTrailing) {
                ZStack(alignment: .leading) {
                    if isLibraryNavigatorVisible {
                        librarySidebar
                    }

                    workspace(availableWidth: workspaceWidth)
                        .frame(width: workspaceWidth, height: proxy.size.height)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)

                    if isLibraryNavigatorVisible {
                        librarySidebarResizeHandle(availableWidth: proxy.size.width)
                            .offset(x: librarySidebarWidth - sidebarHandleWidth / 2)
                            .zIndex(1)
                    }
                }

                OperationFeedbackHUD(feedbackCenter: feedbackCenter)
                    .padding(16)
                    .zIndex(10)
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
            .clipped()
            .onAppear {
                latestContentWidth = proxy.size.width
                constrainSidebarWidths(totalAvailableWidth: proxy.size.width)
            }
            .onChange(of: proxy.size.width) { _, newWidth in
                latestContentWidth = newWidth
                constrainSidebarWidths(totalAvailableWidth: newWidth)
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            readingToolbar
            LibraryImportProgressView(controller: importController)
            Divider()
            windowWorkspace
        }
        .background(
            HostingWindowAccessor { window in
                synchronizeWorkspace(window: window)
            }
        )
        .frame(minWidth: minimumWindowWidth, minHeight: 680)
        .navigationTitle(documentStore.displayedDocumentTitle)
        .documentInteractions(store: documentStore)
        .fileImporter(isPresented: $isShowingFileImporter, allowedContentTypes: [.pdf, .folder],
                      allowsMultipleSelection: true) { result in
            switch result {
            case .success(let urls):
                let groupID = pickerGroupID ?? activeGroupID
                if urls.count == 1, let url = urls.first, url.isPDFFileURL {
                    let access = url.startAccessingSecurityScopedResource()
                    defer { if access { url.stopAccessingSecurityScopedResource() } }
                    openPDFInSelectedGroup(url, groupID: groupID, trigger: pickerTrigger)
                } else { startImport(urls, groupID: groupID, assignToGroup: false) }
            case .failure(let error):
                postFeedback(L10n.string(String.LocalizationValue(error.localizedDescription)), kind: .error, action: "Open PDF")
            }
        }
        .sheet(item: $fileInfoItem, onDismiss: {
            if let id = fileToOpenAfterInfo {
                fileToOpenAfterInfo = nil
                if let file = libraryStore.allFiles.first(where: { $0.id == id }) { openLibraryItem(file) }
            }
        }) { file in
            LibraryFileInfoView(library: libraryStore, fileID: file.id,
                onExport: exportWorkingCopy, onReveal: revealInFinder,
                onOpenNew: { url in
                    let file = libraryStore.upsertOpenedURL(url, groupID: activeGroupID, sessionID: windowSessionID)
                    fileToOpenAfterInfo = file.id
                    fileInfoItem = nil
                })
        }
        .alert("Discard all changes?", isPresented: $isShowingDiscardConfirmation) {
            Button("Discard Changes", role: .destructive) {
                do { try discardRequest?.discard(library: libraryStore) }
                catch { postFeedback(L10n.string(String.LocalizationValue(error.localizedDescription)), kind: .error, action: "Discard Changes") }
                discardItem = nil; discardRequest = nil
            }
            Button("Save Copy As…") { if let discardItem { exportWorkingCopy(for: discardItem) }; discardItem = nil }
            Button("Cancel", role: .cancel) { discardItem = nil }
        } message: {
            Text("This deletes the app-managed working copy. The original file will not be changed.")
        }
        .sheet(isPresented: $isShowingNewGroupSheet, onDismiss: {
            if let groupID = groupToOpenAfterSheet {
                groupToOpenAfterSheet = nil
                openGroupWorkspace(groupID)
            }
        }) {
            GroupNameSheet(title: "New Group", actionTitle: "Create", groupName: $newGroupName) {
                createGroupFromSheet()
            }
        }
        .sheet(isPresented: $isShowingRenameGroupSheet) {
            GroupNameSheet(title: "Rename Group", actionTitle: "Rename", groupName: $newGroupName) {
                renameGroupFromSheet()
            }
        }
        .confirmationDialog(
            "Delete Group",
            isPresented: $isShowingDeleteGroupConfirmation,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                deletePendingGroup()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(deleteGroupConfirmationMessage)
        }
        .confirmationDialog(
            "Remove from Library",
            isPresented: $isShowingRemoveLibraryItemConfirmation,
            titleVisibility: .visible
        ) {
            Button("Remove", role: .destructive) {
                removePendingLibraryItem()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(removeLibraryItemConfirmationMessage)
        }
        .sheet(isPresented: $isShowingPageOrganizer) {
            PageOrganizerView(documentStore: documentStore)
        }
        .sheet(item: $researchEvidencePreview) { evidence in
            ResearchEvidencePreview(evidence: evidence, library: libraryStore)
        }
        .sheet(item: $researchRegionCapture) { capture in
            ResearchRegionCaptureSheet(document: capture.document, pageIndex: capture.pageIndex,
                source: capture.source, sessionID: capture.sessionID)
        }
        .simultaneousGesture(TapGesture().onEnded {
            ResearchCommandService.shared.userDidInteract(viewID: windowSessionID)
        })
        .onAppear {
            documentStore.originalOverwriteHandler = { id in
                Task { try? await libraryStore.captureOriginalFingerprint(for: id, replacingExisting: true) }
            }
            applyInitialGroupIfNeeded()
            openLaunchArgumentIfNeeded()
            openPendingExternalPDFIfNeeded()
        }
        .onOpenURL { url in
            importURLs([url], destination: .currentWindow)
        }
        .onReceive(externalPDFOpenCoordinator.$pendingOpenRequest) { request in
            guard let request, workspaceContext.isActive, workspaceContext.window?.isKeyWindow == true else {
                return
            }

            importURLs(request.urls, destination: .currentWindow)
            externalPDFOpenCoordinator.clear(request)
        }
        .onChange(of: activeGroupID) { _, groupID in
            workspaceContext.updateGroupID(groupID)
        }
        .onChange(of: documentStore.currentWorkingCopyURL) { _, newWorkingCopyURL in
            updateCurrentDocumentWorkingCopyURL(newWorkingCopyURL)
        }
        .onChange(of: documentStore.currentPageIndex) { _, _ in
            syncPageJumpText()
        }
        .onChange(of: documentStore.selectedPDFURL) { _, _ in
            flushPendingZoomPersistence()
            syncPageJumpText()
            aiReadingStore.documentDidChange(
                to: documentStore.selectedPDFURL?.libraryComparablePath
            )
            aiHighlightStore.documentDidChange(to: documentStore.document)
            pendingResearchSelection = nil
            ResearchCommandService.shared.userDidInteract(viewID: windowSessionID)
        }
        .onChange(of: researchWorkspace.wide) { _, _ in
            lockedWorkspaceWidth = nil
            annotationTransition = nil
        }
        .onDisappear {
            flushPendingZoomPersistence()
        }
        .onDrop(of: [UTType.fileURL], isTargeted: nil) { providers in
            return FileDropSupport.loadFileURLs(from: providers) { urls in
                importURLs(urls, destination: .currentWindow)
            }
        }
    }

    private var librarySidebar: some View {
        LibrarySidebarView(
            libraryStore: libraryStore,
            selectedGroupID: activeGroupID,
            sessionID: windowSessionID,
            selectedURL: documentStore.selectedPDFURL,
            currentWorkingCopyURL: documentStore.currentWorkingCopyURL,
            onSelectGroup: selectGroup,
            onCreateGroup: showNewGroupSheet,
            onRenameGroup: showRenameGroupSheet,
            onDeleteGroup: requestDeleteGroup,
            onSetGroupArchived: setGroupArchived,
            onOpenGroupInNewWindow: openGroupInNewWindow,
            onOpen: openLibraryItem,
            onRemoveFromLibrary: requestRemoveFromLibrary,
            onDiscardAllChanges: discardAllChanges,
            onFileInfo: { fileInfoItem = $0 },
            onCreateGroupFromFiles: { ids in
                filesForNewGroup = ids; newGroupName = ""; isShowingNewGroupSheet = true
            },
            onImportURLsToGroup: { urls, group in
                importURLs(urls, destination: .group(group.id))
            },
            onImportURLsToCurrentWindow: { urls in
                importURLs(urls, destination: .currentWindow)
            }
        )
        .frame(width: librarySidebarWidth)
    }

    private func librarySidebarResizeHandle(availableWidth: CGFloat) -> some View {
        SidebarResizeHandle(
            width: sidebarHandleWidth,
            onBegin: {
                librarySidebarDragStartWidth = librarySidebarWidth
                lockWorkspaceWidth()
            },
            onDrag: { translation in
                resizeLibrarySidebar(
                    by: translation,
                    availableWidth: availableWidth
                )
            },
            onEnd: {
                librarySidebarDragStartWidth = librarySidebarWidth
                releaseWorkspaceWidthAfterWindowSettles()
            }
        )
    }

    private var researchCurrentFileID: UUID? { libraryStore.file(for: documentStore.selectedPDFURL)?.id }

    private func researchPanel(compact: Bool) -> some View {
        ResearchPanelView(library: libraryStore, sessionID: $researchWorkspace.sessionID,
            currentFileID: researchCurrentFileID, mainStore: documentStore, viewID: windowSessionID,
            compact: compact, onAddSelection: addResearchSelection, onCaptureRegion: captureResearchRegion,
            onViewEvidence: showResearchEvidence, onShowLibrary: { openWindow?(id: "research-library") },
            onToggleWide: {
                ResearchCommandService.shared.userDidInteract(viewID: windowSessionID)
                if !researchWorkspace.wide { researchWorkspace.focusesResearch = true }
                researchWorkspace.wide.toggle()
            })
    }

    private func ensureResearchSession() -> UUID {
        if let id = researchWorkspace.sessionID, researchStore.session(id: id) != nil { return id }
        let id = researchStore.createSession(title: L10n.string("New research session"),
            sourceSelection: ResearchSourceSelection(fileIDs: researchCurrentFileID.map { [$0] } ?? []))
        researchWorkspace.sessionID = id
        return id
    }

    private func currentResearchSource() -> ResearchSourceSnapshot? {
        guard let file = libraryStore.file(for: documentStore.selectedPDFURL),
              let read = try? DocumentAccessCoordinator.shared.readSnapshot(fileID: file.id,
                originalURL: libraryStore.resolvedURL(for: file), workingCopyURL: file.workingCopyURL) else { return nil }
        return ResearchSourceSnapshot(fileID: file.id, displayName: file.displayName, fingerprint: read.contentVersion)
    }

    private func addResearchSelection() {
        let id = ensureResearchSession()
        guard var session = researchStore.session(id: id) else { return }
        if let pendingResearchSelection { session.draft.blocks.append(pendingResearchSelection) }
        else if let selection = documentStore.currentTextSelection, !selection.isEmpty, let source = currentResearchSource() {
            for passage in selection.passages {
                let bounds = passage.bounds
                let evidence = ResearchEvidence(source: source, kind: .pdfText,
                    anchor: ResearchPageAnchor(pageIndex: passage.pageNumber - 1, x: bounds.minX, y: bounds.minY,
                        width: bounds.width, height: bounds.height), excerpt: passage.text)
                session.draft.blocks.append(ResearchInputBlock(kind: .pdfText, text: passage.text, evidence: evidence))
            }
            if selection.passages.isEmpty {
                session.draft.blocks.append(ResearchInputBlock(kind: .discussion, text: selection.text))
            }
        } else if let annotation = documentStore.selectedAnnotation, let source = currentResearchSource() {
            let text = [annotation.text, annotation.note].filter { !$0.isEmpty }.joined(separator: "\n")
            let kind: ResearchSourceKind = annotation.isAIGenerated ? .discussion : .annotation
            let evidence = ResearchEvidence(source: source, kind: kind,
                anchor: ResearchPageAnchor(pageIndex: annotation.pageIndex), excerpt: text, annotationID: annotation.id)
            session.draft.blocks.append(ResearchInputBlock(kind: kind, text: text, evidence: evidence))
        } else {
            researchRuntime.setError(L10n.string("Select PDF text or a margin note first."), sessionID: id)
            return
        }
        _ = researchStore.saveDraft(session.draft, sessionID: id)
    }

    private func captureResearchRegion() {
        let id = ensureResearchSession()
        guard let file = libraryStore.file(for: documentStore.selectedPDFURL) else { return }
        do {
            let read = try DocumentAccessCoordinator.shared.readSnapshot(fileID: file.id,
                originalURL: libraryStore.resolvedURL(for: file), workingCopyURL: file.workingCopyURL)
            researchRegionCapture = ResearchRegionCapture(document: read.document, pageIndex: documentStore.currentPageIndex,
                source: ResearchSourceSnapshot(fileID: file.id, displayName: file.displayName, fingerprint: read.contentVersion), sessionID: id)
        } catch { reportResearchError(error) }
    }

    private func showResearchEvidence(_ evidence: ResearchEvidence) {
        ResearchCommandService.shared.userDidInteract(viewID: windowSessionID)
        guard evidence.source?.fileID == researchCurrentFileID, evidence.kind != .image else {
            researchEvidencePreview = evidence
            return
        }
        Task { @MainActor in
            do {
                let resolved = try await ResearchEvidenceResolver.resolve(evidence, library: libraryStore)
                guard evidence.source?.fileID == researchCurrentFileID else { researchEvidencePreview = evidence; return }
                navigateResearch(to: PDFNavigationTarget(pageIndex: resolved.pageIndex,
                    point: resolved.rect.map { CGPoint(x: $0.minX, y: $0.maxY) }, relativePagePosition: nil))
            } catch { researchEvidencePreview = evidence }
        }
    }

    private func navigateResearch(to target: PDFNavigationTarget) {
        documentStore.navigate(to: DocumentOutlineEntry(id: UUID().uuidString, title: "Research", level: 0,
            target: target, source: .detectedHeading))
    }

    private func reportResearchError(_ error: Error) {
        researchRuntime.setError(error.localizedDescription, sessionID: ensureResearchSession())
    }

    private func synchronizeWorkspace(window: NSWindow?) {
        workspaceContext.setLifecycleHandlers(onActivate: { host in
            if let host {
                bindWindowPresentation(host)
                WorkspaceCommandRouter.shared.activate(workspace: workspaceContext, handlers: commandHandlers)
                bindResearchWindow(host)
                openPendingExternalPDFIfNeeded()
            } else {
                flushPendingZoomPersistence()
                WorkspaceCommandRouter.shared.deactivate(workspaceID: windowSessionID)
                ResearchCommandService.shared.userDidInteract(viewID: windowSessionID)
            }
        }, onClose: {
            flushPendingZoomPersistence()
            documentStore.releaseEditorAccess()
            ResearchCommandService.shared.unregister(viewID: windowSessionID)
            WorkspaceCommandRouter.shared.deactivate(workspaceID: windowSessionID)
        })
        workspaceContext.updateMinimumContentSize(NSSize(width: minimumWindowWidth, height: 680))
        documentStore.setUndoManager(workspaceContext.undoManager)
        documentStore.setEditorActivationHandler { [weak workspaceContext] in workspaceContext?.select() }
        groupTitlebarController.update(
            workspace: workspaceContext,
            context: nativeTabPreviewContext,
            groups: ([LibraryGroup.ungrouped] + libraryStore.activeUserGroups).map {
                GroupWorkspaceChoice(id: $0.id, name: $0.localizedName)
            },
            onOpenFile: openTabPreviewItem,
            onOpenGroup: { openGroupWorkspace($0) },
            onNewGroup: showNewGroupSheet,
            onTemporaryWorkspace: { workspaceContext.openWorkspace(GroupWindowPayload(groupID: LibraryGroup.ungroupedID)) }
        )
        guard workspaceContext.isActive, let window else { return }
        bindWindowPresentation(window)
        window.title = documentStore.displayedDocumentTitle
        if window.isKeyWindow {
            WorkspaceCommandRouter.shared.activate(workspace: workspaceContext, handlers: commandHandlers)
        }
        bindResearchWindow(window)
    }

    private func bindWindowPresentation(_ window: NSWindow) {
        let controller = WindowFrameControllerRegistry.shared.controller(for: window)
        if windowFrameController !== controller { windowFrameController = controller }
        windowSidebarState = WindowSidebarRegistry.shared.state(for: window, fallback: windowSidebarState)
        controller.activateWorkspace(windowSessionID, libraryVisible: isLibraryNavigatorVisible,
            libraryWidth: libraryExpansionWidth, minimumWidth: minimumWindowWidth)
    }

    private func bindResearchWindow(_ window: NSWindow?) {
        guard window != nil else { return }
        ResearchCommandService.shared.register(viewID: windowSessionID, handlers: ResearchCommandHandlers(
            snapshot: {
                ResearchWorkspaceViewState(mainFileID: researchCurrentFileID, pageIndex: documentStore.currentPageIndex,
                    zoomPercent: Double(zoomScalePercent), wideAI: researchWorkspace.wide,
                    visibleGroupIDs: Array(documentStore.visibleAIHighlightGroupIDs),
                    referenceFileID: researchEvidencePreview?.source?.fileID,
                    referencePageIndex: researchEvidencePreview?.anchor?.pageIndex,
                    pageOffsetX: researchReadingPosition.position(for: documentStore.document)?.point.map { Double($0.x) },
                    pageOffsetY: researchReadingPosition.position(for: documentStore.document)?.point.map { Double($0.y) }, zoomMode: researchZoomMode,
                    highlightGroups: documentStore.aiHighlightGroups.prefix(50).map { ResearchHighlightGroupState(id: $0.id,
                        title: String(($0.title ?? "").prefix(160)), visible: documentStore.isAIHighlightGroupVisible($0.id)) },
                    selectedText: documentStore.currentTextSelection.map { String($0.text.prefix(4_000)) },
                    selectedAnnotationText: documentStore.selectedAnnotation.map { String(($0.text + "\n" + $0.note).prefix(4_000)) },
                    selectionWasClipped: (documentStore.currentTextSelection?.text.count ?? 0) > 4_000
                        || (documentStore.selectedAnnotation.map { $0.text.count + $0.note.count + 1 } ?? 0) > 4_000,
                    highlightGroupsWereClipped: documentStore.aiHighlightGroups.count > 50)
            },
            showSource: { fileID, pageIndex in
                guard let file = libraryStore.allFiles.first(where: { $0.id == fileID }) else { throw ResearchCommandError.outsideSources }
                let read = try DocumentAccessCoordinator.shared.readSnapshot(fileID: file.id,
                    originalURL: libraryStore.resolvedURL(for: file), workingCopyURL: file.workingCopyURL)
                guard pageIndex >= 0, pageIndex < read.document.pageCount else { throw ResearchCommandError.invalidArguments }
                if fileID == researchCurrentFileID {
                    navigateResearch(to: PDFNavigationTarget(pageIndex: pageIndex, point: nil, relativePagePosition: nil))
                } else {
                    researchEvidencePreview = ResearchEvidence(source: ResearchSourceSnapshot(fileID: file.id,
                        displayName: file.displayName, fingerprint: read.contentVersion), kind: .file,
                        anchor: ResearchPageAnchor(pageIndex: pageIndex), excerpt: "")
                }
                researchViewGeneration += 1
            },
            setZoom: { command in
                switch command {
                case .fit: runZoomCommand(.fitWidth, trigger: .pointer)
                case .percent(let value): runZoomCommand(.custom(value), trigger: .pointer)
                }
            },
            setWideAI: { researchWorkspace.wide = $0 },
            setGroupVisible: { fileID, groupID, visible in
                guard fileID == researchCurrentFileID,
                      documentStore.aiHighlightGroups.contains(where: { $0.id == groupID }) else { throw ResearchCommandError.invalidArguments }
                documentStore.setAIHighlightGroupVisible(groupID, isVisible: visible)
            },
            restore: { previous in
                guard previous.mainFileID == researchCurrentFileID else { throw ResearchCommandError.viewUnavailable }
                researchWorkspace.wide = previous.wideAI
                runZoomCommand(previous.zoomMode == "fitWidth" ? .fitWidth : previous.zoomMode == "fitPage" ? .fitPage : .custom(previous.zoomPercent), trigger: .pointer)
                for group in documentStore.aiHighlightGroups {
                    documentStore.setAIHighlightGroupVisible(group.id, isVisible: previous.visibleGroupIDs.contains(group.id))
                }
                let point = previous.pageOffsetX.flatMap { x in previous.pageOffsetY.map { CGPoint(x: x, y: $0) } }
                navigateResearch(to: PDFNavigationTarget(pageIndex: previous.pageIndex, point: point, relativePagePosition: nil))
                researchEvidencePreview = nil
            }, validateSource: { source in
                guard let file = libraryStore.allFiles.first(where: { $0.id == source.fileID }) else { throw ResearchCommandError.outsideSources }
                let read = try DocumentAccessCoordinator.shared.readSnapshot(fileID: file.id,
                    originalURL: libraryStore.resolvedURL(for: file), workingCopyURL: file.workingCopyURL)
                guard read.contentVersion == source.fingerprint else { throw DocumentAccessError.sourceChanged }
            }))
    }

    private func workspaceLayout(availableWidth: CGFloat) -> ResearchWorkspaceLayout {
        ResearchWorkspaceLayout(availableWidth: availableWidth,
            annotationWidth: annotationTransition?.annotationWidth ?? visibleAnnotationSidebarWidth,
            showsResearch: researchWorkspace.wide, readerFraction: researchWorkspace.fraction,
            focusesResearch: researchWorkspace.focusesResearch,
            fixedReadingAreaWidth: annotationTransition?.readingAreaWidth)
    }

    private func workspace(availableWidth: CGFloat) -> some View {
        let layout = workspaceLayout(availableWidth: availableWidth)
        return HStack(spacing: 0) {
            HStack(spacing: 0) {
                // Keep the native PDF view at one structural identity, including
                // the narrow-window focus switch. Clip only its allocated pane.
                readerWorkspace
                    .frame(width: max(centerMinimumWidth, layout.readerWidth))
                    .frame(width: layout.readerWidth, alignment: .leading)
                    .clipped()
                    .opacity(layout.readerWidth > 0 ? 1 : 0)
                    .allowsHitTesting(layout.readerWidth > 0)
                    .accessibilityHidden(layout.readerWidth == 0)
                if researchWorkspace.wide {
                    HStack(spacing: 0) {
                        if layout.canSplit {
                            SidebarResizeHandle(width: ResearchWorkspaceLayout.dividerWidth, dividerAlignment: .leading,
                                onBegin: { researchSplitStart = layout.readerWidth / layout.readingAreaWidth },
                                onDrag: { translation in
                                    researchWorkspace.fraction = min(0.75, max(0.25,
                                        researchSplitStart + translation / layout.readingAreaWidth))
                                    ResearchCommandService.shared.userDidInteract(viewID: windowSessionID)
                                }, onEnd: {})
                        }
                        researchPanel(compact: false)
                            .frame(width: max(ResearchWorkspaceLayout.minimumResearchWidth, layout.researchWidth))
                            .frame(width: layout.researchWidth, alignment: .leading)
                            .clipped()
                    }
                    .opacity(layout.researchWidth > 0 ? 1 : 0)
                    .allowsHitTesting(layout.researchWidth > 0)
                    .accessibilityHidden(layout.researchWidth == 0)
                    .transition(.opacity)
                }
            }
            .frame(width: layout.readingAreaWidth, alignment: .leading)
            .clipped()
            // During native window animation, reveal/clip this pane while the
            // PDF and AI retain their pre-toggle sizes. Keep it alive on close.
            if isAnnotationSidebarVisible || annotationTransition != nil {
                HStack(spacing: 0) {
                    annotationResizeHandle(availableWidth: availableWidth)
                    ReaderSidebarView(documentStore: documentStore, aiStore: aiReadingStore,
                        aiHighlightStore: aiHighlightStore, activeFindScope: $activeFindScope,
                        findFocusRequest: findFocusRequest, onFindFieldFocusChanged: { scope in
                            focusedReaderFindScope = scope
                            if scope != nil { findFocusRequest = nil }
                        }, showsAsk: false)
                }
                .frame(width: layout.annotationWidth)
                .background(Color(nsColor: .controlBackgroundColor))
                .clipped()
            }
        }
        .frame(width: availableWidth, alignment: .leading)
        .animation(.easeInOut(duration: 0.22), value: researchWorkspace.wide)
        .animation(.easeInOut(duration: 0.22), value: researchWorkspace.focusesResearch)
    }

    private var readerWorkspace: some View {
        documentArea
            .frame(minWidth: centerMinimumWidth, maxWidth: .infinity, maxHeight: .infinity)
    }

    private func annotationResizeHandle(availableWidth: CGFloat) -> some View {
        SidebarResizeHandle(
            width: sidebarHandleWidth,
            dividerAlignment: .leading,
            onBegin: {
                annotationSidebarDragStartWidth = annotationSidebarWidth
            },
            onDrag: { translation in
                resizeAnnotationSidebar(
                    by: translation,
                    availableWidth: availableWidth
                )
            },
            onEnd: {
                annotationSidebarDragStartWidth = annotationSidebarWidth
            }
        )
    }

    private var readingToolbar: some View {
        ViewThatFits(in: .horizontal) {
            readingToolbarContents(compact: false)
            readingToolbarContents(compact: true)
        }
        .buttonStyle(.plain)
        .controlSize(.small)
        .padding(.horizontal, 12)
        .frame(height: 44)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private func readingToolbarContents(compact: Bool) -> some View {
        HStack(spacing: compact ? 5 : 8) {
            FlatToolbarIconControl(title: "Library", systemImage: "sidebar.left") {
                toggleLibraryNavigator(trigger: .toolbar)
            }
            .help(isLibraryNavigatorVisible ? "Hide Library Navigator" : "Show Library Navigator")
            FlatToolbarIconControl(title: "Open", systemImage: "folder") { openPDF(trigger: .toolbar) }
                .help("Open PDF")
            Text(verbatim: documentStore.displayedDocumentTitle)
                .lineLimit(1).truncationMode(.middle)
            .font(.system(size: 12, weight: .medium))
            .frame(minWidth: 60, maxWidth: .infinity, alignment: .leading)
            .help(documentStore.selectedPDFURL?.path ?? L10n.string("No PDF Open"))
            if !compact {
                HStack(spacing: 4) { readingEditButtons }
            } else {
                Menu {
                    Button("Add Highlight") { documentStore.requestHighlightFromCurrentSelection(trigger: .toolbar) }
                        .disabled(!documentStore.canAddHighlightToCurrentSelection)
                    Button("Add Free Text Note") { documentStore.requestFreeTextNote(trigger: .toolbar) }
                        .disabled(documentStore.document == nil)
                    Button("Organize Pages") { isShowingPageOrganizer = true }
                        .disabled(documentStore.document == nil)
                    Button("Delete Current Page") { documentStore.deleteCurrentPageFromWorkingCopy(trigger: .toolbar) }
                        .disabled(!documentStore.canDeleteCurrentPage)
                    Divider()
                    Button("Research sessions and notes") { openWindow?(id: "research-library") }
                    Button("Return to previous reading position") { returnToPreviousReadingPosition() }
                } label: { Image(systemName: "ellipsis").frame(width: 24, height: 28) }
                .menuStyle(.borderlessButton).fixedSize()
                .help("Reading actions")
                .accessibilityLabel("Reading actions")
            }
            Divider().frame(height: 18)
            readingPanelButtons(compact: compact)
        }
    }

    @ViewBuilder
    private var readingEditButtons: some View {
        FlatToolbarIconControl(title: "Highlight", systemImage: "highlighter",
            isEnabled: documentStore.canAddHighlightToCurrentSelection) {
                documentStore.requestHighlightFromCurrentSelection(trigger: .toolbar)
            }.help("Add Highlight")
        FlatToolbarIconControl(title: "Free Text", systemImage: "text.bubble",
            isEnabled: documentStore.document != nil) {
                documentStore.requestFreeTextNote(trigger: .toolbar)
            }.help("Add Free Text Note")
        FlatToolbarIconControl(title: "Page Organizer", systemImage: "rectangle.stack",
            isEnabled: documentStore.document != nil) { isShowingPageOrganizer = true }
            .help("Organize Pages")
        FlatToolbarIconControl(title: "Delete Page", systemImage: "trash",
            isEnabled: documentStore.canDeleteCurrentPage) {
                documentStore.deleteCurrentPageFromWorkingCopy(trigger: .toolbar)
            }.help("Delete Current Page")
    }

    @ViewBuilder
    private func readingPanelButtons(compact: Bool) -> some View {
        if !compact {
            Button { openWindow?(id: "research-library") } label: {
                Image(systemName: "books.vertical").frame(width: 28, height: 28)
            }
            .help("Research sessions and notes")
            .accessibilityLabel("Research sessions and notes")
        }
        Button {
            ResearchCommandService.shared.userDidInteract(viewID: windowSessionID)
            if !researchWorkspace.wide { researchWorkspace.focusesResearch = true }
            researchWorkspace.wide.toggle()
        } label: {
            Label("AI", systemImage: "sparkles")
                .padding(.horizontal, 8).frame(height: 28)
                .background(researchWorkspace.wide ? Color.accentColor.opacity(0.12) : .clear,
                    in: RoundedRectangle(cornerRadius: 6))
                .foregroundStyle(researchWorkspace.wide ? Color.accentColor : .secondary)
        }
        .help(researchWorkspace.wide ? "Hide AI workspace" : "Show AI workspace")
        .accessibilityAddTraits(researchWorkspace.wide ? .isSelected : [])
        if researchWorkspace.wide, !workspaceLayout(availableWidth: workspaceWidth(for: latestContentWidth)).canSplit {
            Picker("Workspace focus", selection: $researchWorkspace.focusesResearch) {
                Text("PDF").tag(false)
                Text("AI").tag(true)
            }.pickerStyle(.segmented).labelsHidden().frame(width: 90)
        }
        if !compact {
            Button(action: returnToPreviousReadingPosition) {
                Image(systemName: "arrow.uturn.backward").frame(width: 28, height: 28)
            }
            .help("Return to previous reading position")
            .accessibilityLabel("Return to previous reading position")
        }
        Button { toggleAnnotationSidebar(trigger: .toolbar) } label: {
            Image(systemName: "sidebar.right")
                .frame(width: 30, height: 28)
                .background(isAnnotationSidebarVisible ? Color.accentColor.opacity(0.12) : .clear,
                    in: RoundedRectangle(cornerRadius: 6))
                .foregroundStyle(isAnnotationSidebarVisible ? Color.accentColor : .secondary)
        }
        .accessibilityLabel("Annotations")
        .accessibilityAddTraits(isAnnotationSidebarVisible ? .isSelected : [])
        .help(isAnnotationSidebarVisible ? "Hide Annotations Sidebar" : "Show Annotations Sidebar")
    }

    private func returnToPreviousReadingPosition() {
        do { try ResearchCommandService.shared.returnToPreviousView(viewID: windowSessionID) }
        catch { reportResearchError(error) }
        researchViewGeneration += 1
    }

    private var commandHandlers: PDFWorkbenchCommandHandlers {
        PDFWorkbenchCommandHandlers(
            openPDF: {
                openPDF(trigger: .command(shortcut: "Command-O"))
            },
            savePDF: {
                documentStore.savePDF(
                    trigger: .command(shortcut: "Command-S")
                )
            },
            showFileInfo: {
                fileInfoItem = libraryStore.file(for: documentStore.selectedPDFURL)
            },
            createLibraryGroup: showNewGroupSheet,
            toggleLibraryNavigator: {
                toggleLibraryNavigator(
                    trigger: .command(shortcut: "Command-Option-L")
                )
            },
            toggleAnnotationSidebar: {
                toggleAnnotationSidebar(
                    trigger: .command(shortcut: "Command-Option-R")
                )
            },
            addCurrentDocumentToSelectedGroup: addCurrentDocumentToSelectedGroup,
            removeCurrentDocumentFromSelectedGroup: removeCurrentDocumentFromSelectedGroup,
            addHighlight: {
                documentStore.requestHighlightFromCurrentSelection(
                    trigger: .command(shortcut: nil)
                )
            },
            addFreeTextNote: {
                documentStore.requestFreeTextNote(trigger: .command(shortcut: nil))
            },
            showPageOrganizer: {
                isShowingPageOrganizer = true
            },
            toggleDogear: {
                documentStore.toggleDogearOnCurrentPage(
                    trigger: .command(shortcut: "D")
                )
            },
            deleteCurrentPage: {
                documentStore.deleteCurrentPageFromWorkingCopy(
                    trigger: .command(shortcut: nil)
                )
            },
            goToPreviousPage: {
                ResearchCommandService.shared.userDidInteract(viewID: windowSessionID)
                documentStore.goToRelativePage(
                    offset: -1,
                    trigger: .command(shortcut: "Command-Up")
                )
            },
            goToNextPage: {
                ResearchCommandService.shared.userDidInteract(viewID: windowSessionID)
                documentStore.goToRelativePage(
                    offset: 1,
                    trigger: .command(shortcut: "Command-Down")
                )
            },
            goToFirstPage: {
                ResearchCommandService.shared.userDidInteract(viewID: windowSessionID)
                documentStore.goToFirstPage(
                    trigger: .command(shortcut: "Command-Option-Up")
                )
            },
            goToLastPage: {
                ResearchCommandService.shared.userDidInteract(viewID: windowSessionID)
                documentStore.goToLastPage(
                    trigger: .command(shortcut: "Command-Option-Down")
                )
            },
            zoomIn: {
                ResearchCommandService.shared.userDidInteract(viewID: windowSessionID)
                runZoomCommand(
                    .zoomIn,
                    trigger: .command(shortcut: "Command-Plus")
                )
            },
            zoomOut: {
                ResearchCommandService.shared.userDidInteract(viewID: windowSessionID)
                runZoomCommand(
                    .zoomOut,
                    trigger: .command(shortcut: "Command-Minus")
                )
            },
            actualSize: {
                ResearchCommandService.shared.userDidInteract(viewID: windowSessionID)
                runZoomCommand(
                    .actualSize,
                    trigger: .command(shortcut: "Command-0")
                )
            },
            fitWidth: {
                ResearchCommandService.shared.userDidInteract(viewID: windowSessionID)
                runZoomCommand(
                    .fitWidth,
                    trigger: .command(shortcut: "Command-2")
                )
            },
            fitPage: {
                ResearchCommandService.shared.userDidInteract(viewID: windowSessionID)
                runZoomCommand(
                    .fitPage,
                    trigger: .command(shortcut: "Command-1")
                )
            },
            setDisplayStyle: { style in
                ResearchCommandService.shared.userDidInteract(viewID: windowSessionID)
                setReadingDisplayStyle(style, trigger: .command(shortcut: nil))
            },
            showFind: {
                ResearchCommandService.shared.userDidInteract(viewID: windowSessionID)
                performFindAction(.showFindPanel)
            },
            findNext: {
                ResearchCommandService.shared.userDidInteract(viewID: windowSessionID)
                performFindAction(.next)
            },
            findPrevious: {
                ResearchCommandService.shared.userDidInteract(viewID: windowSessionID)
                performFindAction(.previous)
            },
            exportAnnotatedCopy: {
                documentStore.exportAnnotatedCopy(trigger: .command(shortcut: nil))
            },
            exportAnnotationsMarkdown: {
                documentStore.exportAnnotationsMarkdown(trigger: .command(shortcut: nil))
            },
            exportKeywordOutline: {
                documentStore.exportFallbackKeywordOutline(trigger: .command(shortcut: nil))
            },
            isLibraryNavigatorVisible: isLibraryNavigatorVisible,
            isAnnotationSidebarVisible: isAnnotationSidebarVisible,
            canUseDocumentCommands: documentStore.document != nil && !isShowingPageOrganizer && fileInfoItem == nil,
            canAddCurrentDocumentToSelectedGroup: canAddCurrentDocumentToSelectedGroup,
            canRemoveCurrentDocumentFromSelectedGroup: canRemoveCurrentDocumentFromSelectedGroup,
            canAddHighlight: documentStore.canAddHighlightToCurrentSelection && !isShowingPageOrganizer && fileInfoItem == nil,
            canGoToPreviousPage: canGoToPreviousPage,
            canGoToNextPage: canGoToNextPage,
            canDeleteCurrentPage: documentStore.canDeleteCurrentPage && !isShowingPageOrganizer && fileInfoItem == nil
        )
    }

    @ViewBuilder
    private var documentArea: some View {
        if let document = documentStore.document {
            VStack(spacing: 0) {
                PDFKitView(
                    document: document,
                    selectedAnnotation: documentStore.selectedAnnotation,
                    selectedSearchResult: documentStore.selectedDocumentSearchResult,
                    targetPageIndex: documentStore.currentPageIndex,
                    displayStyle: readingDisplayStyle,
                    initialZoomState: libraryStore.file(for: documentStore.selectedPDFURL)?.lastZoomState
                        ?? .fitWidth,
                    zoomCommand: zoomCommand,
                    outlineNavigationRequest: documentStore.outlineNavigationRequest,
                    outlineEntries: documentStore.outlineEntries,
                    dogears: documentStore.dogears,
                    aiHighlightRailMarkers: documentStore.visibleAIHighlightRailMarkers,
                    isLoadingOutline: documentStore.isLoadingOutline,
                    isNightMode: isNightMode,
                    isMarginCanvasVisible: isMarginCanvasVisible,
                    freeTextRequestID: documentStore.freeTextRequestID,
                    highlightRequest: documentStore.highlightRequest,
                    onSelectOutlineEntry: documentStore.navigate,
                    onSelectDogear: documentStore.navigate,
                    onSelectAIHighlight: { marker in
                        guard let annotation = documentStore.annotations.first(where: {
                            $0.id == marker.annotationID
                        }) else {
                            return
                        }
                        documentStore.selectAnnotation(annotation)
                    },
                    onToggleDogear: {
                        documentStore.toggleDogearOnCurrentPage(
                            trigger: .keyboard(shortcut: "D")
                        )
                    },
                    onToggleDogearAtPage: { pageIndex in
                        documentStore.toggleDogear(onPage: pageIndex, trigger: .pointer)
                    },
                    onSelectMarginAnnotation: { annotationID in
                        guard let annotation = documentStore.annotations.first(where: {
                            $0.id == annotationID
                        }) else {
                            return
                        }
                        documentStore.selectMarginAnnotation(annotation)
                    },
                    onSelectMarginText: { text, pageNumber in
                        pendingResearchSelection = ResearchInputBlock(kind: .annotation, text: text,
                            evidence: currentResearchSource().map { ResearchEvidence(source: $0, kind: .annotation,
                                anchor: ResearchPageAnchor(pageIndex: pageNumber - 1), excerpt: text) })
                    },
                    onHighlightCreated: { trigger in
                        documentStore.markAnnotationsChanged(
                            message: "Highlight added. Saving working copy.",
                            action: "Add Highlight",
                            trigger: trigger
                        )
                    },
                    onHighlightRemoved: { trigger in
                        documentStore.markAnnotationsChanged(
                            message: "Highlight removed. Saving working copy.",
                            action: "Remove Highlight",
                            trigger: trigger
                        )
                    },
                    onAnnotationChanged: {
                        documentStore.markAnnotationsChanged(
                            message: "Annotation changed. Saving working copy.",
                            action: "Move Annotation",
                            trigger: .pointer
                        )
                    },
                    onUndoableAnnotationMutation: { actionName in
                        documentStore.markAnnotationsChanged(
                            message: "Undo/redo applied. Saving working copy.",
                            action: actionName,
                            trigger: .command(shortcut: "Command-Z")
                        )
                    },
                    onFreeTextShortcut: {
                        documentStore.requestFreeTextNote(
                            trigger: .keyboard(shortcut: "T")
                        )
                    },
                    onShortcutActivated: { action, shortcut in
                        postFeedback(
                            action.feedbackMessage,
                            action: action.feedbackAction,
                            trigger: .keyboard(shortcut: shortcut)
                        )
                    },
                    onPageChanged: { pageIndex in
                        documentStore.recordCurrentPage(pageIndex)
                        if let selectedPDFURL = documentStore.selectedPDFURL {
                            libraryStore.updateLastPage(for: selectedPDFURL, pageIndex: pageIndex)
                        }
                    },
                    onScaleChanged: { scaleFactor, zoomState in
                        updateZoomScalePercent(scaleFactor)
                        researchZoomMode = zoomState.mode.rawValue
                        scheduleZoomPersistence(zoomState)
                    },
                    onSelectionChanged: { selection in
                        documentStore.recordTextSelection(selection)
                        if selection?.isEmpty == false { pendingResearchSelection = nil }
                    },
                    documentUndoManager: workspaceContext.undoManager,
                    onUserInteraction: { ResearchCommandService.shared.userDidInteract(viewID: windowSessionID) },
                    onReadingPositionChanged: { researchReadingPosition.update($0, for: document) },
                    canCommitFreeText: { [weak documentStore] document in
                        documentStore?.canEditDocument == true && documentStore?.document === document
                    }
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                Divider()

                readerControlStrip
            }
        } else {
            ContentUnavailableView(
                "No PDF Open",
                systemImage: "doc.richtext",
                description: Text("Choose a PDF file to display it here.")
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var readerControlStrip: some View {
        ViewThatFits(in: .horizontal) {
            readerControls(isCompact: false)
            readerControls(isCompact: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private func readerControls(isCompact: Bool) -> some View {
        HStack(spacing: isCompact ? 6 : 10) {
            Button {
                documentStore.goToFirstPage(trigger: .pointer)
            } label: {
                Image(systemName: "backward.end")
            }
            .disabled(!canGoToPreviousPage)
            .help("First page")

            Button {
                documentStore.goToRelativePage(offset: -1, trigger: .pointer)
            } label: {
                Image(systemName: "chevron.up")
            }
            .disabled(!canGoToPreviousPage)
            .help("Previous page")

            TextField("Page", text: $pageJumpText)
                .textFieldStyle(.roundedBorder)
                .multilineTextAlignment(.trailing)
                .frame(width: isCompact ? 48 : 56)
                .onSubmit {
                    jumpToTypedPage()
                }
                .help("Page number")

            Text("/ \(documentStore.pageCount)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: isCompact ? 40 : 52, alignment: .leading)

            Button {
                documentStore.goToRelativePage(offset: 1, trigger: .pointer)
            } label: {
                Image(systemName: "chevron.down")
            }
            .disabled(!canGoToNextPage)
            .help("Next page")

            Button {
                documentStore.goToLastPage(trigger: .pointer)
            } label: {
                Image(systemName: "forward.end")
            }
            .disabled(!canGoToNextPage)
            .help("Last page")

            Divider()
                .frame(height: 20)

            Button {
                runZoomCommand(.zoomOut, trigger: .pointer)
            } label: {
                Image(systemName: "minus.magnifyingglass")
            }
            .help("Zoom out")

            Text("\(zoomScalePercent)%")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: isCompact ? 42 : 48)

            Button {
                runZoomCommand(.zoomIn, trigger: .pointer)
            } label: {
                Image(systemName: "plus.magnifyingglass")
            }
            .help("Zoom in")

            Menu {
                Button("Actual Size") {
                    runZoomCommand(.actualSize, trigger: .pointer)
                }

                Button("Fit Width") {
                    runZoomCommand(.fitWidth, trigger: .pointer)
                }

                Button("Fit Page") {
                    runZoomCommand(.fitPage, trigger: .pointer)
                }
            } label: {
                Image(systemName: "arrow.up.left.and.arrow.down.right")
            }
            .menuStyle(.borderlessButton)
            .help("Zoom presets")

            if isCompact {
                Menu {
                    ForEach(PDFReadingDisplayStyle.allCases) { style in
                        Button {
                            setReadingDisplayStyle(style, trigger: .pointer)
                        } label: {
                            Label(style.title, systemImage: style.systemImage)
                        }
                    }
                } label: {
                    Image(systemName: readingDisplayStyle.systemImage)
                }
                .menuStyle(.borderlessButton)
                .help("Reading layout")
            } else {
                Picker(
                    "Display",
                    selection: Binding(
                        get: { readingDisplayStyle },
                        set: { setReadingDisplayStyle($0, trigger: .pointer) }
                    )
                ) {
                    ForEach(PDFReadingDisplayStyle.allCases) { style in
                        Label(style.title, systemImage: style.systemImage)
                            .tag(style)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                // Keep AppKit's intrinsic segment width during window animation;
                // a narrower fixed frame makes the control alternate widths.
                .fixedSize(horizontal: true, vertical: false)
                .help("Reading layout")
            }

            Button {
                withAnimation(.easeInOut(duration: 0.18)) {
                    isNightMode.toggle()
                }
                postFeedback(
                    isNightMode ? "Night mode enabled." : "Night mode disabled.",
                    action: "Toggle Night Mode",
                    trigger: .pointer
                )
            } label: {
                Image(systemName: isNightMode ? "sun.max.fill" : "moon.fill")
            }
            .help(isNightMode ? "Use light PDF display" : "Use night PDF display")

            Button {
                isMarginCanvasVisible.toggle()
                postFeedback(
                    isMarginCanvasVisible
                        ? L10n.string("Margin notes shown.")
                        : L10n.string("Margin notes hidden."),
                    action: L10n.string("Toggle Margin Notes"),
                    trigger: .pointer
                )
            } label: {
                Image(systemName: isMarginCanvasVisible
                    ? "rectangle.righthalf.inset.filled"
                    : "rectangle.split.2x1")
            }
            .disabled(readingDisplayStyle == .twoUp)
            .help(readingDisplayStyle == .twoUp
                ? "Margin notes are unavailable in Two-Up layout"
                : isMarginCanvasVisible ? "Hide margin notes" : "Show margin notes")

            Spacer(minLength: 0)
        }
        .fixedSize(horizontal: true, vertical: false)
    }

    private func resizeLibrarySidebar(by translation: CGFloat, availableWidth: CGFloat) {
        let maximumWidth = maximumLibrarySidebarWidth(availableWidth: availableWidth)
        let previousWidth = librarySidebarWidth
        librarySidebarWidth = clamped(
            librarySidebarDragStartWidth + translation,
            to: librarySidebarRange.lowerBound...maximumWidth
        )
        windowFrameController.resizeExpandedWindow(by: librarySidebarWidth - previousWidth)
    }

    private func resizeAnnotationSidebar(by translation: CGFloat, availableWidth: CGFloat) {
        let maximumWidth = maximumAnnotationSidebarWidth(availableWidth: availableWidth)
        let previousWidth = annotationSidebarWidth
        annotationSidebarWidth = clamped(
            annotationSidebarDragStartWidth - translation,
            to: annotationSidebarRange.lowerBound...maximumWidth
        )
        windowFrameController.resizeAnnotationExpandedWindow(
            by: annotationSidebarWidth - previousWidth
        )
    }

    private func constrainSidebarWidths(totalAvailableWidth: CGFloat) {
        // Retained inactive workspaces may still have an older frame. Only the
        // visible workspace can constrain its real host's shared panel widths.
        guard workspaceContext.isActive else { return }
        let leftSidebarAvailableWidth = totalAvailableWidth
            + (isLibraryNavigatorVisible ? 0 : libraryExpansionWidth)
        librarySidebarWidth = clamped(
            librarySidebarWidth,
            to: librarySidebarRange.lowerBound...maximumLibrarySidebarWidth(
                availableWidth: leftSidebarAvailableWidth
            )
        )
        let workspaceAvailableWidth = workspaceWidth(for: totalAvailableWidth)
        annotationSidebarWidth = clamped(
            annotationSidebarWidth,
            to: annotationSidebarRange.lowerBound...maximumAnnotationSidebarWidth(availableWidth: workspaceAvailableWidth)
        )
        librarySidebarDragStartWidth = librarySidebarWidth
        annotationSidebarDragStartWidth = annotationSidebarWidth
    }

    private func maximumLibrarySidebarWidth(availableWidth: CGFloat) -> CGFloat {
        max(
            librarySidebarRange.lowerBound,
            min(
                librarySidebarRange.upperBound,
                availableWidth
                    - visibleAnnotationSidebarWidth
                    - centerMinimumWidth
            )
        )
    }

    private func maximumAnnotationSidebarWidth(availableWidth: CGFloat) -> CGFloat {
        max(
            annotationSidebarRange.lowerBound,
            min(
                annotationSidebarRange.upperBound,
                availableWidth - centerMinimumWidth
            )
        )
    }

    private var visibleLibraryNavigatorWidth: CGFloat {
        isLibraryNavigatorVisible ? libraryExpansionWidth : 0
    }

    private var libraryExpansionWidth: CGFloat {
        librarySidebarWidth
    }

    private var visibleAnnotationSidebarWidth: CGFloat {
        isAnnotationSidebarVisible ? annotationSidebarWidth : 0
    }

    private var annotationExpansionWidth: CGFloat {
        annotationSidebarWidth
    }

    private var minimumWindowWidth: CGFloat {
        minimumWorkspaceWithoutAnnotation
            + visibleAnnotationSidebarWidth
            + visibleLibraryNavigatorWidth
    }

    private func minimumWindowWidth(
        libraryVisible: Bool,
        annotationVisible: Bool
    ) -> CGFloat {
        minimumWorkspaceWithoutAnnotation
            + (annotationVisible ? annotationExpansionWidth : 0)
            + (libraryVisible ? libraryExpansionWidth : 0)
    }

    private func workspaceWidth(for totalAvailableWidth: CGFloat) -> CGFloat {
        if let lockedWorkspaceWidth {
            return min(lockedWorkspaceWidth, totalAvailableWidth)
        }

        return totalAvailableWidth - visibleLibraryNavigatorWidth
    }

    private func clamped(_ value: CGFloat, to range: ClosedRange<CGFloat>) -> CGFloat {
        min(max(value, range.lowerBound), range.upperBound)
    }

    private func toggleLibraryNavigator(trigger: FeedbackTrigger? = nil) {
        lockWorkspaceWidth()

        if isLibraryNavigatorVisible {
            withoutViewAnimation {
                isLibraryNavigatorVisible = false
            }
            windowFrameController.setLibraryNavigatorVisible(
                false,
                expansionWidth: libraryExpansionWidth,
                minimumWidth: minimumWindowWidth(
                    libraryVisible: false,
                    annotationVisible: isAnnotationSidebarVisible
                )
            )
        } else {
            windowFrameController.setLibraryNavigatorVisible(
                true,
                expansionWidth: libraryExpansionWidth,
                minimumWidth: minimumWindowWidth(
                    libraryVisible: true,
                    annotationVisible: isAnnotationSidebarVisible
                )
            )
            withoutViewAnimation {
                isLibraryNavigatorVisible = true
            }
        }

        postFeedback(
            isLibraryNavigatorVisible ? "Library shown." : "Library hidden.",
            action: "Toggle Library",
            trigger: trigger
        )
        releaseWorkspaceWidthAfterWindowSettles()
    }

    private func toggleAnnotationSidebar(trigger: FeedbackTrigger? = nil) {
        let transition = windowFrameController.isFullScreen ? nil : AnnotationSidebarTransition(
            readingAreaWidth: workspaceLayout(availableWidth: workspaceWidth(for: latestContentWidth)).readingAreaWidth,
            annotationWidth: annotationSidebarWidth)
        let willShow = !isAnnotationSidebarVisible
        withoutViewAnimation {
            annotationTransition = transition
            isAnnotationSidebarVisible = willShow
        }
        windowFrameController.setAnnotationSidebarVisible(
            willShow,
            expansionWidth: annotationExpansionWidth,
            minimumWidth: minimumWindowWidth(
                libraryVisible: isLibraryNavigatorVisible,
                annotationVisible: willShow
            ), completion: {
                // A superseded animation must not release a newer width lock.
                guard annotationTransition?.id == transition?.id else { return }
                withoutViewAnimation { annotationTransition = nil }
            }
        )

        postFeedback(
            isAnnotationSidebarVisible
                ? "Annotation sidebar shown."
                : "Annotation sidebar hidden.",
            action: "Toggle Annotation Sidebar",
            trigger: trigger
        )
    }

    private func lockWorkspaceWidth() {
        guard !windowFrameController.isFullScreen else {
            lockedWorkspaceWidth = nil
            workspaceLockID = UUID()
            return
        }

        lockedWorkspaceWidth = workspaceWidth(for: latestContentWidth)
        workspaceLockID = UUID()
    }

    private func releaseWorkspaceWidthAfterWindowSettles() {
        let lockID = workspaceLockID

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.28) {
            guard workspaceLockID == lockID else {
                return
            }

            lockedWorkspaceWidth = nil
        }
    }

    private func withoutViewAnimation(_ updates: () -> Void) {
        var transaction = Transaction()
        transaction.disablesAnimations = true

        withTransaction(transaction) {
            updates()
        }
    }

    private var canGoToPreviousPage: Bool {
        documentStore.currentPageNumber > 1
    }

    private var canGoToNextPage: Bool {
        documentStore.currentPageNumber > 0
            && documentStore.currentPageNumber < documentStore.pageCount
    }

    private func jumpToTypedPage() {
        let trimmedPage = pageJumpText.trimmingCharacters(in: .whitespacesAndNewlines)

        guard let pageNumber = Int(trimmedPage) else {
            syncPageJumpText()
            postFeedback(
                "Enter a page number from 1 to \(max(1, documentStore.pageCount)).",
                kind: .warning,
                action: "Go to Page",
                trigger: .keyboard(shortcut: "Return")
            )
            return
        }

        documentStore.goToPageNumber(
            pageNumber,
            trigger: .keyboard(shortcut: "Return")
        )
        syncPageJumpText()
    }

    private func performFindAction(_ action: NSFindPanelAction) {
        if forwardFindActionToFocusedTextEditor(action) {
            return
        }

        switch action {
        case .showFindPanel:
            if !isAnnotationSidebarVisible {
                toggleAnnotationSidebar(trigger: .command(shortcut: "Command-F"))
            }
            findFocusRequestID += 1
            findFocusRequest = ReaderFindRequest(
                id: findFocusRequestID,
                scope: activeFindScope
            )
        case .next:
            if activeFindScope == .annotations {
                documentStore.selectNextFilteredAnnotation()
            } else {
                documentStore.selectNextDocumentSearchResult()
            }
        case .previous:
            if activeFindScope == .annotations {
                documentStore.selectPreviousFilteredAnnotation()
            } else {
                documentStore.selectPreviousDocumentSearchResult()
            }
        default:
            break
        }
    }

    private func forwardFindActionToFocusedTextEditor(_ action: NSFindPanelAction) -> Bool {
        guard focusedReaderFindScope == nil,
              let textView = NSApp.keyWindow?.firstResponder as? NSTextView
        else {
            return false
        }

        let sender = NSMenuItem()
        sender.tag = Int(action.rawValue)
        return textView.tryToPerform(
            #selector(NSResponder.performTextFinderAction(_:)),
            with: sender
        )
    }

    private func syncPageJumpText() {
        pageJumpText = documentStore.currentPageNumber > 0
            ? "\(documentStore.currentPageNumber)"
            : "1"
    }

    private func runZoomCommand(
        _ action: PDFZoomAction,
        trigger: FeedbackTrigger? = nil
    ) {
        guard documentStore.document != nil else {
            return
        }

        zoomCommandCounter += 1
        zoomCommand = PDFZoomCommand(id: zoomCommandCounter, action: action)
        postFeedback(
            action.feedbackMessage,
            action: action.feedbackAction,
            trigger: trigger
        )
    }

    private func setReadingDisplayStyle(
        _ style: PDFReadingDisplayStyle,
        trigger: FeedbackTrigger?
    ) {
        readingDisplayStyle = style
        postFeedback(
            "Reading layout: \(style.title).",
            action: "Change Reading Layout",
            trigger: trigger
        )
    }

    private func updateZoomScalePercent(_ scaleFactor: CGFloat) {
        guard scaleFactor.isFinite, scaleFactor > 0 else {
            return
        }

        zoomScalePercent = Int((scaleFactor * 100).rounded())
    }

    private func scheduleZoomPersistence(_ zoomState: PDFZoomState) {
        guard let selectedPDFURL = documentStore.selectedPDFURL else {
            return
        }

        pendingZoomPersistence = PendingPDFZoomPersistence(
            url: selectedPDFURL,
            zoomState: zoomState
        )
        zoomPersistenceTask?.cancel()
        zoomPersistenceTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else {
                return
            }
            flushPendingZoomPersistence()
        }
    }

    private func flushPendingZoomPersistence() {
        zoomPersistenceTask?.cancel()
        zoomPersistenceTask = nil
        guard let pendingZoomPersistence else {
            return
        }

        self.pendingZoomPersistence = nil
        libraryStore.updateZoomState(
            pendingZoomPersistence.zoomState,
            for: pendingZoomPersistence.url
        )
    }

    private func postFeedback(
        _ message: String,
        kind: OperationFeedbackKind = .info,
        action: String? = nil,
        trigger: FeedbackTrigger? = nil
    ) {
        feedbackCenter.post(
            message,
            kind: kind,
            action: action,
            trigger: trigger
        )
    }

    private func openPDF(trigger: FeedbackTrigger? = nil) {
        pickerGroupID = activeGroupID
        pickerTrigger = trigger
        isShowingFileImporter = true
    }

    private func openPDFInSelectedGroup(
        _ url: URL,
        groupID requestedGroupID: UUID? = nil,
        trigger: FeedbackTrigger? = nil
    ) {
        guard url.isPDFFileURL else {
            postFeedback(
                "Only PDF files can be opened.",
                kind: .warning,
                action: "Open PDF",
                trigger: trigger
            )
            return
        }

        let targetGroupID = requestedGroupID ?? activeGroupID
        if let existingItem = libraryStore.fileForOpening(at: url) {
            openLibraryItem(existingItem, inGroupID: targetGroupID)
            return
        }
        guard documentStore.openPDF(
            from: url,
            trigger: trigger
        ) else {
            return
        }

        let item = libraryStore.upsertOpenedURL(
            url,
            groupID: targetGroupID,
            sessionID: windowSessionID
        )
        activeGroupID = targetGroupID
        guard documentStore.bindLibraryFile(item.id) else { return }
        Task { try? await libraryStore.captureOriginalFingerprint(for: item.id) }
        libraryStore.updateWorkingCopyURL(documentStore.currentWorkingCopyURL, for: item)
    }

    private func importURLs(_ urls: [URL], destination: ImportDestination) {
        switch destination {
        case .currentWindow: startImport(urls, groupID: activeGroupID, assignToGroup: false)
        case .group(let groupID): startImport(urls, groupID: groupID, assignToGroup: true)
        }
    }

    private func startImport(_ urls: [URL], groupID: UUID, assignToGroup: Bool) {
        guard !importController.isRunning else {
            postFeedback(L10n.string("An import is already running in this workspace."), kind: .warning, action: "Import PDFs")
            return
        }
        let readingURL = documentStore.selectedPDFURL
        let initialGroup = activeGroupID
        importController.start(urls: uniqueFileURLs(urls), library: libraryStore, groupID: groupID,
            sessionID: windowSessionID, assignToGroup: assignToGroup) { file, destination in
                guard activeGroupID == initialGroup, documentStore.selectedPDFURL == readingURL else { return }
                openLibraryItem(file, inGroupID: destination)
            }
    }

    private func uniqueFileURLs(_ urls: [URL]) -> [URL] {
        var seenPaths = Set<String>()
        return urls.filter { url in
            seenPaths.insert(url.libraryComparablePath).inserted
        }
    }

    private func openLibraryItem(_ item: LibraryItem) {
        openLibraryItem(item, inGroupID: activeGroupID)
    }

    private func openLibraryItem(_ item: LibraryItem, in group: LibraryGroup) {
        if group.id == activeGroupID {
            openLibraryItem(item, inGroupID: group.id)
        } else {
            let url = libraryStore.resolvedURL(for: item)
            if DocumentAccessCoordinator.shared.activateExistingEditor(fileID: item.id)
                || DocumentAccessCoordinator.shared.activateExistingEditor(for: url) { return }
            openGroupWorkspace(group.id, selecting: item.id)
        }
    }

    private func openLibraryItem(_ item: LibraryItem, inGroupID groupID: UUID) {
        let url = libraryStore.resolvedURL(for: item)
        if DocumentAccessCoordinator.shared.activateExistingEditor(fileID: item.id)
            || DocumentAccessCoordinator.shared.activateExistingEditor(for: url, excluding: documentStore) {
            return
        }
        if documentStore.openPDF(
            from: url,
            workingCopyURL: libraryStore.openingWorkingCopyURL(for: item),
            initialPageIndex: item.lastPageIndex,
            trigger: .pointer
        ) {
            activeGroupID = groupID
            guard documentStore.bindLibraryFile(item.id) else { return }
            Task { try? await libraryStore.captureOriginalFingerprint(for: item.id) }
            libraryStore.refreshResolvedURL(url, for: item)
            libraryStore.updateWorkingCopyURL(documentStore.currentWorkingCopyURL, for: item)
            libraryStore.recordOpenedFile(item.id, in: groupID, sessionID: windowSessionID)
            return
        }

        libraryStore.markUnavailable(item)
        postFeedback(
            "Library item is unavailable: \(item.displayName).",
            kind: .error,
            action: "Open Library Item",
            trigger: .pointer
        )
    }

    private var nativeTabPreviewContext: NativeTabPreviewContext {
        let items = libraryStore.filesForWindow(
            in: activeGroupID,
            sessionID: windowSessionID
        )
        let duplicateNames = Set(
            Dictionary(grouping: items, by: { $0.displayName.lowercased() })
                .filter { $0.value.count > 1 }
                .keys
        )

        return NativeTabPreviewContext(
            documentTitle: documentStore.document == nil
                ? "No PDF Open"
                : documentStore.selectedDocumentName,
            groupName: libraryStore.group(withID: activeGroupID)?.localizedName
                ?? L10n.string(LibraryGroup.ungroupedLocalizationKey),
            pageDescription: documentStore.pageCount > 0
                ? "Page \(documentStore.currentPageNumber) of \(documentStore.pageCount)"
                : nil,
            hasWorkingCopy: documentStore.currentWorkingCopyURL != nil,
            items: items.map { item in
                let isTemporary = libraryStore.isTemporaryFile(
                    item,
                    in: activeGroupID,
                    sessionID: windowSessionID
                )
                let isUnavailable = item.isUnavailable
                    || (item.bookmarkData == nil
                        && !FileManager.default.fileExists(atPath: item.path))
                let detail: String?

                if duplicateNames.contains(item.displayName.lowercased()) {
                    detail = item.url.deletingLastPathComponent().path
                } else if isUnavailable {
                    detail = "Unavailable"
                } else if isTemporary {
                    detail = "Temporary in this window"
                } else {
                    detail = nil
                }

                return NativeTabPreviewItem(
                    id: item.id,
                    displayName: item.displayName,
                    detail: detail,
                    path: item.path,
                    isSelected: documentStore.selectedPDFURL?.libraryComparablePath == item.path,
                    isTemporary: isTemporary,
                    isUnavailable: isUnavailable,
                    hasWorkingCopy: item.workingCopyURL != nil,
                    lastPageIndex: item.lastPageIndex
                )
            }
        )
    }

    private func openTabPreviewItem(_ fileID: UUID) {
        guard let item = libraryStore.state.files.first(where: { $0.id == fileID }) else {
            return
        }

        openLibraryItem(item)
    }

    private func discardAllChanges(for item: LibraryItem) {
        guard let copy = workingCopyURL(for: item) else { return }
        do {
            discardRequest = try WorkingCopyDiscardRequest(file: item,
                originalURL: libraryStore.resolvedURL(for: item), workingCopyURL: copy)
            discardItem = item
            isShowingDiscardConfirmation = true
        } catch { postFeedback(L10n.string(String.LocalizationValue(error.localizedDescription)), kind: .error, action: "Discard Changes") }
    }

    private func workingCopyURL(for item: LibraryItem) -> URL? {
        if documentStore.selectedPDFURL?.libraryComparablePath == item.path {
            return documentStore.currentWorkingCopyURL ?? item.workingCopyURL
        }

        return item.workingCopyURL
    }

    private func exportWorkingCopy(for item: LibraryItem) {
        guard let sourceURL = workingCopyURL(for: item) else {
            postFeedback(
                "No working copy is available to save.",
                kind: .warning,
                action: "Save Working Copy",
                trigger: .pointer
            )
            return
        }

        guard let destinationURL = SafeFileExportPicker.chooseDestination(
            suggestedName: suggestedDiscardSaveAsName(for: item), contentType: .pdf) else { return }

        do {
            guard let current = libraryStore.allFiles.first(where: { $0.id == item.id }),
                  !SafeDocumentExport.isSameFile(destinationURL, item.url) else {
                throw SafeDocumentExportError.originalDestination
            }
            let original = libraryStore.resolvedURL(for: current)
            let data = try DocumentAccessCoordinator.shared.exportData(fileID: current.id,
                originalURL: original, workingCopyURL: workingCopyURL(for: current) ?? sourceURL)
            try SafeDocumentExport.write(data: data, to: destinationURL, protecting: original)
            postFeedback(
                "Saved copy to \(destinationURL.lastPathComponent). Working copy was kept.",
                kind: .success,
                action: "Save Working Copy",
                trigger: .pointer
            )
        } catch {
            postFeedback(
                "Save As failed. Working copy was kept.",
                kind: .error,
                action: "Save Working Copy",
                trigger: .pointer
            )
        }
    }

    private func revealInFinder(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    private func suggestedDiscardSaveAsName(for item: LibraryItem) -> String {
        let baseName = item.url.deletingPathExtension().lastPathComponent
        return "\(baseName)-working-copy.pdf"
    }

    private func openLaunchArgumentIfNeeded() {
        guard !didOpenLaunchArgument else {
            return
        }

        didOpenLaunchArgument = true

        guard let path = ProcessInfo.processInfo.arguments.dropFirst().first,
              path.lowercased().hasSuffix(".pdf")
        else {
            return
        }

        let url = URL(fileURLWithPath: path)
        if let item = libraryStore.fileForOpening(at: url) {
            openLibraryItem(item)
        } else if documentStore.openPDF(from: url, trigger: .system) {
            let item = libraryStore.upsertOpenedURL(url, refreshBookmark: false,
                groupID: nil, sessionID: windowSessionID)
            guard documentStore.bindLibraryFile(item.id) else { return }
            libraryStore.updateWorkingCopyURL(documentStore.currentWorkingCopyURL, for: item)
            Task { try? await libraryStore.captureOriginalFingerprint(for: item.id) }
        }
    }

    private func openPendingExternalPDFIfNeeded() {
        guard workspaceContext.isActive, workspaceContext.window?.isKeyWindow == true,
              let request = externalPDFOpenCoordinator.pendingOpenRequest else {
            return
        }

        importURLs(request.urls, destination: .currentWindow)
        externalPDFOpenCoordinator.clear(request)
    }

    private func updateCurrentDocumentWorkingCopyURL(_ workingCopyURL: URL?) {
        guard let file = libraryStore.file(for: documentStore.selectedPDFURL) else {
            return
        }

        libraryStore.updateWorkingCopyURL(workingCopyURL, for: file)
    }

    private func applyInitialGroupIfNeeded() {
        guard !didApplyInitialGroup else {
            return
        }

        didApplyInitialGroup = true

        let targetGroupID = initialGroupID ?? activeGroupID

        guard libraryStore.group(withID: targetGroupID) != nil
        else {
            return
        }

        activeGroupID = targetGroupID
        libraryStore.ensureWindowSession(for: targetGroupID, sessionID: windowSessionID)

        if let session = libraryStore.openSession(
            for: targetGroupID,
            sessionID: windowSessionID
        ),
           let selectedFileID = session.selectedFileID,
           let file = libraryStore.state.files.first(where: { $0.id == selectedFileID }) {
            openLibraryItem(file)
        }
    }

    private var canAddCurrentDocumentToSelectedGroup: Bool {
        guard let file = libraryStore.file(for: documentStore.selectedPDFURL),
              activeGroupID != LibraryGroup.ungroupedID,
              let group = libraryStore.group(withID: activeGroupID)
        else {
            return false
        }

        return !libraryStore.isFile(file, in: group)
    }

    private var canRemoveCurrentDocumentFromSelectedGroup: Bool {
        guard let file = libraryStore.file(for: documentStore.selectedPDFURL),
              activeGroupID != LibraryGroup.ungroupedID,
              let group = libraryStore.group(withID: activeGroupID)
        else {
            return false
        }

        return libraryStore.isFile(file, in: group)
    }

    private func addCurrentDocumentToSelectedGroup() {
        guard let file = libraryStore.file(for: documentStore.selectedPDFURL),
              let group = libraryStore.group(withID: activeGroupID)
        else {
            return
        }

        libraryStore.addFile(file, to: group)
    }

    private func removeCurrentDocumentFromSelectedGroup() {
        guard let file = libraryStore.file(for: documentStore.selectedPDFURL),
              let group = libraryStore.group(withID: activeGroupID)
        else {
            return
        }

        libraryStore.removeFile(file, from: group)
    }

    private func showNewGroupSheet() {
        filesForNewGroup = []
        newGroupName = ""
        isShowingNewGroupSheet = true
    }

    private func createGroupFromSheet() {
        do {
            if filesForNewGroup.isEmpty { groupToOpenAfterSheet = libraryStore.createGroup(named: newGroupName)?.id }
            else { groupToOpenAfterSheet = try libraryStore.createGroup(named: newGroupName, containing: filesForNewGroup).id }
            filesForNewGroup = []
            isShowingNewGroupSheet = false
        } catch { postFeedback(L10n.string(String.LocalizationValue(error.localizedDescription)), kind: .error, action: "New Group") }
    }

    private func showRenameGroupSheet(_ group: LibraryGroup) {
        guard !group.isSystemGroup else {
            return
        }

        groupPendingRename = group
        newGroupName = group.name
        isShowingRenameGroupSheet = true
    }

    private func renameGroupFromSheet() {
        guard let group = groupPendingRename else {
            isShowingRenameGroupSheet = false
            return
        }

        if !libraryStore.renameGroup(group, to: newGroupName) {
            postFeedback(
                "Group name is empty or already in use.",
                kind: .warning,
                action: "Rename Group",
                trigger: .pointer
            )
        }

        groupPendingRename = nil
        isShowingRenameGroupSheet = false
    }

    private func requestDeleteGroup(_ group: LibraryGroup) {
        guard !group.isSystemGroup else {
            return
        }

        groupPendingDeletion = group
        isShowingDeleteGroupConfirmation = true
    }

    private func deletePendingGroup() {
        guard let group = groupPendingDeletion else {
            isShowingDeleteGroupConfirmation = false
            return
        }

        if libraryStore.deleteGroup(group), activeGroupID == group.id {
            activeGroupID = LibraryGroup.ungroupedID
        }

        groupPendingDeletion = nil
        isShowingDeleteGroupConfirmation = false
    }

    private func setGroupArchived(_ group: LibraryGroup, _ archived: Bool) {
        guard libraryStore.setGroupArchived(group, archived: archived) else {
            return
        }

        if archived, activeGroupID == group.id {
            activeGroupID = LibraryGroup.ungroupedID
        }
    }

    private func requestRemoveFromLibrary(_ item: LibraryItem) {
        libraryItemPendingRemoval = item
        isShowingRemoveLibraryItemConfirmation = true
    }

    private func removePendingLibraryItem() {
        guard let item = libraryItemPendingRemoval else {
            isShowingRemoveLibraryItemConfirmation = false
            return
        }

        if libraryStore.remove(item) {
            postFeedback(
                "Removed \(item.displayName) from Library. Original and working-copy files were kept.",
                kind: .success,
                action: "Remove from Library",
                trigger: .pointer
            )
        }

        libraryItemPendingRemoval = nil
        isShowingRemoveLibraryItemConfirmation = false
    }

    private var deleteGroupConfirmationMessage: String {
        let ungroupedName = L10n.string(LibraryGroup.ungroupedLocalizationKey)
        guard let group = groupPendingDeletion else {
            return "The group's files will remain in Library and appear under \(ungroupedName) when no other group contains them."
        }

        return "Delete \(group.localizedName)? Files will remain in Library and appear under \(ungroupedName) when no other group contains them."
    }

    private var removeLibraryItemConfirmationMessage: String {
        guard let item = libraryItemPendingRemoval else {
            return "This removes only the Library record. Files on disk will not be deleted."
        }

        return "Remove \(item.displayName) from Library? The original PDF and any working copy will be kept on disk."
    }

    private func selectGroup(_ group: LibraryGroup) {
        guard group.id != activeGroupID else { return }
        openGroupWorkspace(group.id)
    }

    private func openGroupWorkspace(_ groupID: UUID, selecting fileID: UUID? = nil) {
        guard libraryStore.group(withID: groupID) != nil else { return }
        if groupTitlebarController.activateWorkspace(groupID: groupID, fileID: fileID) { return }
        let liveIDs = GroupWorkspaceTitlebarController.activeWorkspaceIDs
        let previous = libraryStore.state.windowSessions
            .filter { $0.groupID == groupID && !liveIDs.contains($0.id) }
            .max { $0.updatedAt < $1.updatedAt }
        let sessionID = previous?.id ?? UUID()
        libraryStore.ensureWindowSession(for: groupID, sessionID: sessionID)
        if let fileID {
            libraryStore.recordOpenedFile(fileID, in: groupID, sessionID: sessionID)
        }
        workspaceContext.openWorkspace(GroupWindowPayload(sessionID: sessionID, groupID: groupID))
    }

    private func openGroupInNewWindow(_ group: LibraryGroup) {
        guard !group.isSystemGroup else {
            return
        }

        workspaceContext.openWorkspace(GroupWindowPayload(groupID: group.id), newWindow: true)
    }
}

private struct PendingPDFZoomPersistence {
    let url: URL
    let zoomState: PDFZoomState
}

private struct FlatToolbarIconControl: View {
    let title: LocalizedStringKey
    let systemImage: String
    var isEnabled = true
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 14, weight: .medium))
                .symbolRenderingMode(.monochrome)
                .foregroundStyle(foregroundColor)
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .onHover { isHovering = isEnabled && $0 }
        .accessibilityLabel(Text(title))
    }

    private var foregroundColor: Color {
        guard isEnabled else {
            return .secondary.opacity(0.45)
        }

        return isHovering ? .primary : .secondary
    }
}

private struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        ContentView(libraryStore: LibraryStore())
    }
}

private enum ImportDestination {
    case currentWindow
    case group(UUID)
}

private extension PDFZoomAction {
    var feedbackAction: String {
        switch self {
        case .zoomIn:
            return "Zoom In"
        case .zoomOut:
            return "Zoom Out"
        case .actualSize:
            return "Actual Size"
        case .fitWidth:
            return "Fit Width"
        case .fitPage:
            return "Fit Page"
        case .custom:
            return "Zoom"
        }
    }

    var feedbackMessage: String {
        "\(feedbackAction)."
    }
}

private extension PDFReadingShortcutAction {
    var feedbackAction: String {
        switch self {
        case .highlight:
            return "Add Highlight"
        case .note:
            return "Add Free Text Note"
        case .dogear:
            return "Toggle Dog-ear"
        case .pageUp:
            return "Previous Page"
        case .pageDown:
            return "Next Page"
        }
    }

    var feedbackMessage: String {
        "\(feedbackAction)."
    }
}

@MainActor
@Observable
private final class WindowSidebarState {
    var isVisible: Bool
    var width: CGFloat
    var isLibraryVisible: Bool
    var libraryWidth: CGFloat

    init(isVisible: Bool = true, width: CGFloat = 284,
         isLibraryVisible: Bool = false, libraryWidth: CGFloat = 300) {
        self.isVisible = isVisible
        self.width = width
        self.isLibraryVisible = isLibraryVisible
        self.libraryWidth = libraryWidth
    }
}

@MainActor
private final class WindowSidebarRegistry {
    static let shared = WindowSidebarRegistry()

    private let statesByWindow = NSMapTable<NSWindow, WindowSidebarState>.weakToStrongObjects()

    private init() {}

    func state(
        for window: NSWindow,
        fallback: WindowSidebarState
    ) -> WindowSidebarState {
        let tabbedWindows = window.tabGroup?.windows ?? [window]

        if let siblingState = tabbedWindows.lazy
            .filter({ $0 !== window })
            .compactMap({ self.statesByWindow.object(forKey: $0) })
            .first {
            associate(siblingState, with: tabbedWindows)
            return siblingState
        }

        if let existingState = statesByWindow.object(forKey: window) {
            associate(existingState, with: tabbedWindows)
            return existingState
        }

        // A detached workspace starts with the old host's values, but its
        // Library and annotation layout then evolve independently in the new window.
        let state = WindowSidebarState(isVisible: fallback.isVisible, width: fallback.width,
            isLibraryVisible: fallback.isLibraryVisible, libraryWidth: fallback.libraryWidth)
        associate(state, with: tabbedWindows)
        return state
    }

    private func associate(
        _ state: WindowSidebarState,
        with windows: [NSWindow]
    ) {
        for window in windows {
            statesByWindow.setObject(state, forKey: window)
        }
    }
}

/// Real host-window identities exercise the same registry and frame coordinator
/// used by ContentView; no Library records, PDFs or workspace Undo are touched.
@MainActor
enum WindowSidebarSharingDiagnostics {
    static func run() -> (checks: Int, failures: [String]) {
        var checks = 0
        var failures: [String] = []
        func check(_ value: Bool, _ message: String) {
            checks += 1
            if !value { failures.append(message) }
        }
        func makeWindow() -> NSWindow {
            let window = NSWindow(contentRect: NSRect(x: 40, y: 40, width: 1000, height: 680),
                                  styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.tabbingMode = .disallowed
            return window
        }
        let host = makeWindow(), otherHost = makeWindow(), detachedHost = makeWindow()
        defer { host.close(); otherHost.close(); detachedHost.close() }
        let registry = WindowSidebarRegistry.shared
        let firstGroup = registry.state(for: host, fallback: WindowSidebarState(
            isVisible: false, width: 310, isLibraryVisible: true, libraryWidth: 320))
        let secondGroup = registry.state(for: host, fallback: WindowSidebarState())
        check(firstGroup === secondGroup && secondGroup.isLibraryVisible && secondGroup.libraryWidth == 320,
              "Switching Group restored per-workspace Library visibility or width instead of the real host's values.")
        secondGroup.isLibraryVisible = false
        secondGroup.libraryWidth = 350
        check(!firstGroup.isLibraryVisible && firstGroup.libraryWidth == 350,
              "A Group's Library toggle/resize did not reach another Group in the same window.")
        let other = registry.state(for: otherHost, fallback: WindowSidebarState())
        other.isLibraryVisible = true
        check(other !== firstGroup && !firstGroup.isLibraryVisible && other.libraryWidth == 300,
              "Independent host windows shared Library visibility or width.")
        let detached = registry.state(for: detachedHost, fallback: firstGroup)
        check(detached !== firstGroup && detached.isLibraryVisible == firstGroup.isLibraryVisible
              && detached.libraryWidth == 350 && !detached.isVisible && detached.width == 310,
              "Detaching did not copy both sidebars' presentation without sharing future mutations.")
        detached.isLibraryVisible = true
        detached.libraryWidth = 280
        detached.isVisible = true
        check(!firstGroup.isLibraryVisible && firstGroup.libraryWidth == 350 && !firstGroup.isVisible,
              "Changing detached sidebars altered their previous host.")
        let merged = registry.state(for: otherHost, fallback: detached)
        check(merged === other && merged.libraryWidth == 300 && merged.isLibraryVisible,
              "Merging a workspace replaced the destination host's sidebar preferences.")

        let geometry = WindowFrameController()
        geometry.setWindow(host)
        defer { geometry.setWindow(nil) }
        firstGroup.isLibraryVisible = true
        firstGroup.libraryWidth = 320
        geometry.activateWorkspace(UUID(), libraryVisible: firstGroup.isLibraryVisible,
            libraryWidth: firstGroup.libraryWidth, minimumWidth: 840)
        let expandedFrame = host.frame
        for _ in 0..<16 {
            let nextGroup = registry.state(for: host, fallback: WindowSidebarState())
            geometry.activateWorkspace(UUID(), libraryVisible: nextGroup.isLibraryVisible,
                libraryWidth: nextGroup.libraryWidth, minimumWidth: 840)
        }
        check(host.frame == expandedFrame,
              "Switching Groups with shared Library state still resized the host window.")
        geometry.setLibraryNavigatorVisible(false, expansionWidth: 320, minimumWidth: 520, animate: false)
        let collapsedWidth = host.frame.width
        geometry.setLibraryNavigatorVisible(true, expansionWidth: 320, minimumWidth: 840, animate: false)
        check(abs(collapsedWidth - (expandedFrame.width - 320)) < 1
              && abs(host.frame.width - expandedFrame.width) < 1,
              "Shared Library state broke explicit toggle collapse/expansion geometry.")
        return (checks, failures)
    }
}

@MainActor
private enum DeferredWindowFrameChange {
    case libraryVisibility(isVisible: Bool, expansionWidth: CGFloat, minimumWidth: CGFloat)
    case annotationVisibility(isVisible: Bool, expansionWidth: CGFloat, minimumWidth: CGFloat)
    case libraryResize(delta: CGFloat)
    case annotationResize(delta: CGFloat)
}

/// Window geometry belongs to the real host, not to an individual retained workspace.
/// Sharing one coordinator also gives full-screen exit exactly one deferred-change consumer.
@MainActor
private final class WindowFrameControllerRegistry {
    static let shared = WindowFrameControllerRegistry()
    private let controllers = NSMapTable<NSWindow, WindowFrameController>.weakToStrongObjects()

    func controller(for window: NSWindow) -> WindowFrameController {
        if let existing = controllers.object(forKey: window) { return existing }
        let controller = WindowFrameController()
        controller.setWindow(window)
        controllers.setObject(controller, forKey: window)
        return controller
    }
}

@MainActor
private final class WindowFrameController {
    private weak var window: NSWindow?
    private var collapsedFrameBeforeExpansion: NSRect?
    private var collapsedFrameBeforeAnnotationExpansion: NSRect?
    private var expectedLibraryExpandedFrame: NSRect?
    private var expectedAnnotationExpandedFrame: NSRect?
    private var fullScreenObservers: [NSObjectProtocol] = []
    private var deferredFullScreenChanges: [DeferredWindowFrameChange] = []
    private var activeWorkspaceID: UUID?
    private var libraryIsVisible = false
    private var libraryWidth: CGFloat = 300

    var isFullScreen: Bool {
        window?.styleMask.contains(.fullScreen) == true
    }

    func setWindow(_ window: NSWindow?) {
        guard self.window !== window else {
            return
        }

        let notificationCenter = NotificationCenter.default
        fullScreenObservers.forEach(notificationCenter.removeObserver)
        fullScreenObservers.removeAll()

        self.window = window
        collapsedFrameBeforeExpansion = nil
        collapsedFrameBeforeAnnotationExpansion = nil
        expectedLibraryExpandedFrame = nil
        expectedAnnotationExpandedFrame = nil
        deferredFullScreenChanges.removeAll()
        activeWorkspaceID = nil
        libraryIsVisible = false

        if let window {
            fullScreenObservers = [
                notificationCenter.addObserver(
                    forName: NSWindow.didExitFullScreenNotification,
                    object: window,
                    queue: .main
                ) { [weak self] _ in
                    Task { @MainActor [weak self] in
                        self?.applyDeferredFullScreenChangesAfterWindowSettles()
                    }
                },
                notificationCenter.addObserver(forName: NSWindow.willCloseNotification,
                    object: window, queue: .main) { [weak self] _ in
                        MainActor.assumeIsolated { self?.setWindow(nil) }
                    }
            ]
        }
    }

    func activateWorkspace(_ workspaceID: UUID, libraryVisible: Bool,
                           libraryWidth: CGFloat, minimumWidth: CGFloat) {
        if activeWorkspaceID == nil {
            // A freshly detached/restored host already has its complete window frame.
            // Adopt that geometry instead of expanding a visible Library a second time.
            activeWorkspaceID = workspaceID
            libraryIsVisible = libraryVisible
            self.libraryWidth = libraryWidth
            if libraryVisible, let window, !isFullScreen {
                var collapsed = window.frame
                collapsed.size.width = max(window.frame.width - libraryWidth, minimumWidth - libraryWidth)
                collapsed.origin.x += window.frame.width - collapsed.width
                collapsedFrameBeforeExpansion = collapsed
                expectedLibraryExpandedFrame = window.frame
            }
            return
        }
        guard activeWorkspaceID != workspaceID else {
            // A normal layout pass may clamp the panel after manual window resizing.
            // Record its actual width without resizing the window back again.
            if libraryIsVisible == libraryVisible { self.libraryWidth = libraryWidth }
            return
        }
        activeWorkspaceID = workspaceID
        if libraryIsVisible != libraryVisible {
            let transitionWidth = libraryVisible ? libraryWidth : self.libraryWidth
            setLibraryNavigatorVisible(libraryVisible, expansionWidth: transitionWidth,
                minimumWidth: minimumWidth, animate: false)
        } else if libraryVisible {
            resizeExpandedWindow(by: libraryWidth - self.libraryWidth)
        }
        self.libraryWidth = libraryWidth
    }

    func setLibraryNavigatorVisible(
        _ isVisible: Bool,
        expansionWidth: CGFloat,
        minimumWidth: CGFloat,
        animate: Bool = true
    ) {
        guard let window, libraryIsVisible != isVisible else {
            return
        }
        libraryIsVisible = isVisible
        libraryWidth = expansionWidth

        let change = DeferredWindowFrameChange.libraryVisibility(
            isVisible: isVisible,
            expansionWidth: expansionWidth,
            minimumWidth: minimumWidth
        )
        guard !isFullScreen else {
            deferFullScreenChange(change)
            return
        }

        apply(change, to: window, animate: animate)
    }

    func setAnnotationSidebarVisible(
        _ isVisible: Bool,
        expansionWidth: CGFloat,
        minimumWidth: CGFloat,
        completion: @escaping @MainActor () -> Void = {}
    ) {
        guard let window else {
            completion()
            return
        }

        let change = DeferredWindowFrameChange.annotationVisibility(
            isVisible: isVisible,
            expansionWidth: expansionWidth,
            minimumWidth: minimumWidth
        )
        guard !isFullScreen else {
            deferFullScreenChange(change)
            completion()
            return
        }

        apply(change, to: window, animate: true, completion: completion)
    }

    func resizeExpandedWindow(by delta: CGFloat) {
        guard delta != 0, let window else {
            return
        }
        libraryWidth += delta

        if isFullScreen {
            deferFullScreenChange(.libraryResize(delta: delta))
            return
        }

        guard collapsedFrameBeforeExpansion != nil else {
            return
        }

        resizeExpandedWindow(window, by: delta)
    }

    func resizeAnnotationExpandedWindow(by delta: CGFloat) {
        guard delta != 0, let window else {
            return
        }

        if isFullScreen {
            deferFullScreenChange(.annotationResize(delta: delta))
            return
        }

        resizeAnnotationExpandedWindow(window, by: delta)
    }

    private func resizeExpandedWindow(_ window: NSWindow, by delta: CGFloat) {
        var resizedFrame = window.frame
        resizedFrame.origin.x -= delta
        resizedFrame.size.width += delta
        resizedFrame = constrainedToVisibleScreen(resizedFrame, for: window)

        adjustRightCollapsedFrameForLeftChange(delta)
        expectedLibraryExpandedFrame = resizedFrame
        if expectedAnnotationExpandedFrame != nil {
            expectedAnnotationExpandedFrame = resizedFrame
        }
        window.setFrame(resizedFrame, display: true, animate: false)
    }

    private func resizeAnnotationExpandedWindow(_ window: NSWindow, by delta: CGFloat) {
        var resizedFrame = window.frame
        resizedFrame.size.width += delta
        resizedFrame = constrainedToVisibleScreen(resizedFrame, for: window)

        adjustLeftCollapsedFrameForRightChange(delta)
        expectedAnnotationExpandedFrame = resizedFrame
        if expectedLibraryExpandedFrame != nil {
            expectedLibraryExpandedFrame = resizedFrame
        }
        window.setFrame(resizedFrame, display: true, animate: false)
    }

    private func expandLeft(
        _ window: NSWindow,
        by expansionWidth: CGFloat,
        minimumWidth: CGFloat,
        animate: Bool
    ) {
        guard collapsedFrameBeforeExpansion == nil else {
            return
        }

        let currentFrame = window.frame
        collapsedFrameBeforeExpansion = currentFrame

        var expandedFrame = currentFrame
        expandedFrame.origin.x -= expansionWidth
        expandedFrame.size.width = max(currentFrame.width + expansionWidth, minimumWidth)
        expandedFrame = constrainedToVisibleScreen(expandedFrame, for: window)

        adjustRightCollapsedFrameForLeftChange(expansionWidth)
        expectedLibraryExpandedFrame = expandedFrame
        if expectedAnnotationExpandedFrame != nil {
            expectedAnnotationExpandedFrame = expandedFrame
        }
        window.setFrame(expandedFrame, display: true, animate: animate)
    }

    private func collapseLeft(
        _ window: NSWindow,
        by expansionWidth: CGFloat,
        minimumWidth: CGFloat,
        animate: Bool
    ) {
        let collapsedFrame: NSRect

        if let collapsedFrameBeforeExpansion,
           let expectedLibraryExpandedFrame,
           framesApproximatelyEqual(window.frame, expectedLibraryExpandedFrame) {
            collapsedFrame = collapsedFrameBeforeExpansion
        } else {
            var fallbackFrame = window.frame
            fallbackFrame.size.width = max(window.frame.width - expansionWidth, minimumWidth)
            fallbackFrame.origin.x += window.frame.width - fallbackFrame.width
            collapsedFrame = fallbackFrame
        }

        self.collapsedFrameBeforeExpansion = nil
        expectedLibraryExpandedFrame = nil
        adjustRightCollapsedFrameForLeftChange(-expansionWidth)
        if expectedAnnotationExpandedFrame != nil {
            expectedAnnotationExpandedFrame = collapsedFrame
        }
        window.setFrame(
            constrainedToVisibleScreen(collapsedFrame, for: window),
            display: true,
            animate: animate
        )
    }

    private func expandRight(
        _ window: NSWindow,
        by expansionWidth: CGFloat,
        minimumWidth: CGFloat,
        animate: Bool,
        completion: @escaping @MainActor () -> Void = {}
    ) {
        guard collapsedFrameBeforeAnnotationExpansion == nil else {
            completion()
            return
        }

        let currentFrame = window.frame
        collapsedFrameBeforeAnnotationExpansion = currentFrame

        var expandedFrame = currentFrame
        expandedFrame.size.width = max(currentFrame.width + expansionWidth, minimumWidth)
        expandedFrame = constrainedToVisibleScreen(expandedFrame, for: window)

        adjustLeftCollapsedFrameForRightChange(expansionWidth)
        expectedAnnotationExpandedFrame = expandedFrame
        if expectedLibraryExpandedFrame != nil {
            expectedLibraryExpandedFrame = expandedFrame
        }
        setAnnotationFrame(expandedFrame, for: window, animate: animate, completion: completion)
    }

    private func collapseRight(
        _ window: NSWindow,
        by expansionWidth: CGFloat,
        minimumWidth: CGFloat,
        animate: Bool,
        completion: @escaping @MainActor () -> Void = {}
    ) {
        let collapsedFrame: NSRect

        if let collapsedFrameBeforeAnnotationExpansion,
           let expectedAnnotationExpandedFrame,
           framesApproximatelyEqual(window.frame, expectedAnnotationExpandedFrame) {
            collapsedFrame = collapsedFrameBeforeAnnotationExpansion
        } else {
            var fallbackFrame = window.frame
            fallbackFrame.size.width = max(window.frame.width - expansionWidth, minimumWidth)
            collapsedFrame = fallbackFrame
        }

        collapsedFrameBeforeAnnotationExpansion = nil
        expectedAnnotationExpandedFrame = nil
        adjustLeftCollapsedFrameForRightChange(-expansionWidth)
        if expectedLibraryExpandedFrame != nil {
            expectedLibraryExpandedFrame = collapsedFrame
        }
        setAnnotationFrame(constrainedToVisibleScreen(collapsedFrame, for: window),
            for: window, animate: animate, completion: completion)
    }

    private func setAnnotationFrame(_ frame: NSRect, for window: NSWindow, animate: Bool,
                                    completion: @escaping @MainActor () -> Void) {
        guard animate else {
            window.setFrame(frame, display: true, animate: false)
            completion()
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = window.animationResizeTime(frame)
            window.animator().setFrame(frame, display: true)
        } completionHandler: {
            Task { @MainActor in completion() }
        }
    }

    private func apply(
        _ change: DeferredWindowFrameChange,
        to window: NSWindow,
        animate: Bool,
        completion: @escaping @MainActor () -> Void = {}
    ) {
        switch change {
        case let .libraryVisibility(isVisible, expansionWidth, minimumWidth):
            if isVisible {
                expandLeft(
                    window,
                    by: expansionWidth,
                    minimumWidth: minimumWidth,
                    animate: animate
                )
            } else {
                collapseLeft(
                    window,
                    by: expansionWidth,
                    minimumWidth: minimumWidth,
                    animate: animate
                )
            }
        case let .annotationVisibility(isVisible, expansionWidth, minimumWidth):
            if isVisible {
                expandRight(
                    window,
                    by: expansionWidth,
                    minimumWidth: minimumWidth,
                    animate: animate, completion: completion
                )
            } else {
                collapseRight(
                    window,
                    by: expansionWidth,
                    minimumWidth: minimumWidth,
                    animate: animate, completion: completion
                )
            }
        case let .libraryResize(delta):
            guard collapsedFrameBeforeExpansion != nil else {
                return
            }
            resizeExpandedWindow(window, by: delta)
        case let .annotationResize(delta):
            resizeAnnotationExpandedWindow(window, by: delta)
        }
    }

    private func deferFullScreenChange(_ change: DeferredWindowFrameChange) {
        switch (deferredFullScreenChanges.last, change) {
        case let (.libraryResize(previousDelta)?, .libraryResize(delta)):
            deferredFullScreenChanges[deferredFullScreenChanges.count - 1] =
                .libraryResize(delta: previousDelta + delta)
        case let (.annotationResize(previousDelta)?, .annotationResize(delta)):
            deferredFullScreenChanges[deferredFullScreenChanges.count - 1] =
                .annotationResize(delta: previousDelta + delta)
        default:
            deferredFullScreenChanges.append(change)
        }
    }

    private func applyDeferredFullScreenChangesAfterWindowSettles() {
        DispatchQueue.main.async { [weak self] in
            guard let self,
                  let window = self.window,
                  !self.isFullScreen,
                  !self.deferredFullScreenChanges.isEmpty
            else {
                return
            }

            let changes = self.deferredFullScreenChanges
            self.deferredFullScreenChanges.removeAll()
            for change in changes {
                self.apply(change, to: window, animate: false)
            }
        }
    }

    private func framesApproximatelyEqual(_ lhs: NSRect, _ rhs: NSRect) -> Bool {
        let tolerance: CGFloat = 1
        return abs(lhs.minX - rhs.minX) <= tolerance
            && abs(lhs.minY - rhs.minY) <= tolerance
            && abs(lhs.width - rhs.width) <= tolerance
            && abs(lhs.height - rhs.height) <= tolerance
    }

    private func adjustRightCollapsedFrameForLeftChange(_ delta: CGFloat) {
        guard var frame = collapsedFrameBeforeAnnotationExpansion else {
            return
        }

        frame.origin.x -= delta
        frame.size.width += delta
        collapsedFrameBeforeAnnotationExpansion = frame
    }

    private func adjustLeftCollapsedFrameForRightChange(_ delta: CGFloat) {
        guard var frame = collapsedFrameBeforeExpansion else {
            return
        }

        frame.size.width += delta
        collapsedFrameBeforeExpansion = frame
    }

    private func constrainedToVisibleScreen(_ frame: NSRect, for window: NSWindow) -> NSRect {
        guard let visibleFrame = (window.screen ?? NSScreen.main)?.visibleFrame else {
            return frame
        }

        var constrainedFrame = frame
        constrainedFrame.size.width = min(constrainedFrame.width, visibleFrame.width)

        if constrainedFrame.minX < visibleFrame.minX {
            constrainedFrame.origin.x = visibleFrame.minX
        }

        if constrainedFrame.maxX > visibleFrame.maxX {
            constrainedFrame.origin.x = visibleFrame.maxX - constrainedFrame.width
        }

        if constrainedFrame.minY < visibleFrame.minY {
            constrainedFrame.origin.y = visibleFrame.minY
        }

        if constrainedFrame.maxY > visibleFrame.maxY {
            constrainedFrame.origin.y = visibleFrame.maxY - constrainedFrame.height
        }

        return constrainedFrame
    }
}

private struct HostingWindowAccessor: NSViewRepresentable {
    let onWindowChange: (NSWindow?) -> Void

    func makeNSView(context: Context) -> HostingWindowAccessorView {
        let view = HostingWindowAccessorView()
        view.onWindowChange = onWindowChange
        return view
    }

    func updateNSView(_ nsView: HostingWindowAccessorView, context: Context) {
        nsView.onWindowChange = onWindowChange

        DispatchQueue.main.async {
            nsView.notifyWindowChanged()
        }
    }
}

private final class HostingWindowAccessorView: NSView {
    var onWindowChange: ((NSWindow?) -> Void)?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        notifyWindowChanged()
    }

    func notifyWindowChanged() {
        onWindowChange?(window)
    }
}

private struct GroupNameSheet: View {
    @Environment(\.dismiss) private var dismiss
    let title: String
    let actionTitle: String
    @Binding var groupName: String
    let onSubmit: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.headline)

            TextField("Group name", text: $groupName)
                .textFieldStyle(.roundedBorder)
                .onSubmit(createIfPossible)

            HStack {
                Spacer()

                Button("Cancel") {
                    dismiss()
                }

                Button(actionTitle) {
                    createIfPossible()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(groupName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 320)
    }

    private func createIfPossible() {
        guard !groupName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return
        }

        onSubmit()
    }
}

private struct SidebarResizeHandle: View {
    let width: CGFloat
    var dividerAlignment: Alignment = .center
    let onBegin: () -> Void
    let onDrag: (CGFloat) -> Void
    let onEnd: () -> Void

    var body: some View {
        ZStack(alignment: dividerAlignment) {
            Rectangle()
                .fill(Color(nsColor: .separatorColor))
                .frame(width: 1)
                .frame(maxHeight: .infinity)
                .allowsHitTesting(false)

            SidebarResizeHitTarget(
                onBegin: onBegin,
                onDrag: onDrag,
                onEnd: onEnd
            )
        }
        .frame(width: width)
        .frame(maxHeight: .infinity)
    }
}

private struct SidebarResizeHitTarget: NSViewRepresentable {
    let onBegin: () -> Void
    let onDrag: (CGFloat) -> Void
    let onEnd: () -> Void

    func makeNSView(context: Context) -> SidebarResizeHitTargetView {
        let view = SidebarResizeHitTargetView()
        view.onBegin = onBegin
        view.onDrag = onDrag
        view.onEnd = onEnd
        return view
    }

    func updateNSView(_ nsView: SidebarResizeHitTargetView, context: Context) {
        nsView.onBegin = onBegin
        nsView.onDrag = onDrag
        nsView.onEnd = onEnd
    }
}

private final class SidebarResizeHitTargetView: NSView {
    var onBegin: (() -> Void)?
    var onDrag: ((CGFloat) -> Void)?
    var onEnd: (() -> Void)?

    private var dragStartX: CGFloat?
    private var trackingArea: NSTrackingArea?
    private var cursorIsPushed = false

    override var isFlipped: Bool {
        true
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        return nil
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()

        if let trackingArea {
            removeTrackingArea(trackingArea)
        }

        let area = NSTrackingArea(
            rect: bounds,
            options: [.activeInKeyWindow, .inVisibleRect, .mouseEnteredAndExited, .cursorUpdate],
            owner: self
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        pushResizeCursorIfNeeded()
    }

    override func mouseExited(with event: NSEvent) {
        popResizeCursorIfNeeded()
    }

    override func mouseDown(with event: NSEvent) {
        dragStartX = event.locationInWindow.x
        onBegin?()
        pushResizeCursorIfNeeded()
    }

    override func mouseDragged(with event: NSEvent) {
        guard let dragStartX else {
            return
        }

        onDrag?(event.locationInWindow.x - dragStartX)
    }

    override func mouseUp(with event: NSEvent) {
        dragStartX = nil
        onEnd?()
    }

    override func cursorUpdate(with event: NSEvent) {
        NSCursor.resizeLeftRight.set()
    }

    deinit {
        popResizeCursorIfNeeded()
    }

    private func pushResizeCursorIfNeeded() {
        guard !cursorIsPushed else {
            return
        }

        NSCursor.resizeLeftRight.push()
        cursorIsPushed = true
    }

    private func popResizeCursorIfNeeded() {
        guard cursorIsPushed else {
            return
        }

        NSCursor.pop()
        cursorIsPushed = false
    }
}

private struct ResearchRegionCapture: Identifiable {
    let id = UUID()
    let document: PDFDocument
    let pageIndex: Int
    let source: ResearchSourceSnapshot
    let sessionID: UUID
}
