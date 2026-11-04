#if os(iOS)
import PDFKit
import SwiftUI

struct IPadReaderView: View {
    @ObservedObject var workspace: IPadGroupWorkspace
    @ObservedObject var store: PDFDocumentStore
    @ObservedObject var library: LibraryStore
    var isPresentationActive = true
    let onInteraction: () -> Void
    @State private var inlineNoteLayout: (sessionID: UUID, layout: PDFReaderUIKitOverlayLayout)?
    @State private var inlineNoteTargetBounds: (sessionID: UUID, bounds: CGRect)?
    @State private var showsInspector = false
    @State private var pendingHighlight: HighlightEditDraft?
    @State private var pendingFreeText: FreeTextEditDraft?
    @State private var pendingPageAction: (() -> Void)?
    @State private var showsPages = false
    @State private var pageNumber = ""
    @State private var showsPageEntry = false
    @State private var pageEntryDocument: PDFDocument?
    @FocusState private var pageEntryFocused: Bool
    @State private var inputMode: PDFReaderUIKitInputMode = .read
    @State private var focusSearchOnPresentation = false
    @FocusState private var documentSearchFocused: Bool

    private var readerCommandsAvailable: Bool {
        isPresentationActive && workspace.inlineNoteSession == nil && workspace.highlightEditingSession == nil && !showsInspector && !showsPages
            && store.pendingConfirmation == nil && store.pendingExportOptions == nil
            && workspace.export.ticket == nil && workspace.state.isActive && !workspace.state.isClosed
    }

    var body: some View {
        let noteSession = workspace.inlineNoteSession
        VStack(spacing: 0) {
            if let document = store.document {
                HStack(spacing: 0) {
                    readerToolbar
                    if let noteSession {
                        Menu {
                            Button("Locate Note", systemImage: "scope") {
                                guard canAccessNote(noteSession) else { return }
                                showNote(noteSession)
                            }
                            Button("Save", systemImage: "checkmark") { saveNote(noteSession) }
                                .disabled(!canCommitNote(noteSession))
                            Button("Cancel", systemImage: "xmark") { cancelNote(noteSession) }
                        } label: {
                            VStack(spacing: 2) {
                                Image(systemName: "square.and.pencil").font(.system(size: 16))
                                Text("Note").font(.system(size: 9))
                            }.frame(width: 44, height: 44).foregroundStyle(Color.accentColor)
                        }
                        .disabled(!canAccessNote(noteSession))
                        .accessibilityLabel("Note Actions").accessibilityIdentifier("ipad.note.resume")
                    }
                }.frame(height: 44)
                if !store.documentSearchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    searchNavigation
                }
                Divider()
                ZStack(alignment: .topLeading) {
                  PDFReaderUIKitView(document: document, navigation: workspace.pendingNavigation,
                    initialReadingState: workspace.readingState(for: document),
                    inputMode: inputMode,
                    overlayTarget: noteOverlayTarget(noteSession, in: document),
                    isPresentationActive: isPresentationActive,
                    onUserInteraction: onInteraction,
                    onPageChanged: { pdf, page in
                        guard store.document === pdf else { return }
                        store.recordCurrentPage(page)
                        workspace.libraryBinding?.recordPage(page, in: pdf)
                    }, onZoomChanged: { pdf, percent, isFit in
                        guard store.document === pdf else { return }
                        workspace.zoomPercent = percent
                    }, onReadingPositionChanged: { pdf, page, offset in
                        guard store.document === pdf else { return }
                        workspace.pageOffset = offset
                        workspace.libraryBinding?.recordPosition(page: page, offset: offset, in: pdf)
                    }, onZoomModeChanged: { pdf, state in
                        guard store.document === pdf else { return }
                        workspace.zoomMode = state.mode
                        workspace.libraryBinding?.recordZoom(state, in: pdf)
                    }, onNavigationAccepted: { pdf, requestID in
                        workspace.acknowledgeNavigation(in: pdf, requestID: requestID)
                    }, onSelectionChanged: { pdf, selection, snapshot in
                        guard store.document === pdf else { return }
                        workspace.selection = selection
                        store.recordTextSelection(snapshot)
                    }, onAnnotationTapped: { pdf, annotation in
                        guard store.document === pdf, readerCommandsAvailable,
                              let item = store.annotations.first(where: { AnnotationExtractor.annotation(matching: $0, in: pdf) === annotation }) else { return }
                        onInteraction(); edit(item)
                    }, onNotePlaced: { pdf, page, bounds in
                        guard store.document === pdf, inputMode == .addNote, readerCommandsAvailable else { return }
                        inputMode = .read
                        beginNoteEditing(store.newFreeTextDraft(page: page, bounds: bounds))
                    }, onKeyboardCommand: { pdf, command in
                        guard store.document === pdf, readerCommandsAvailable, !showsPageEntry else { return }
                        handleKeyboardCommand(command)
                    }, onOpenURL: { url in
                        guard readerCommandsAvailable,
                              ["https", "http", "mailto"].contains(url.scheme?.lowercased() ?? "") else { return }
                        UIApplication.shared.open(url)
                    }, onOverlayLayout: { pdf, page, layout in
                        guard let noteSession, workspace.inlineNoteSession === noteSession,
                              store.document === pdf, noteSession.draft.document === pdf,
                              noteSession.draft.page === page else { return }
                        inlineNoteLayout = layout.map { (noteSession.id, $0) }
                    })
                    .accessibilityIdentifier("ipad.pdfReader")
                  if let noteSession, noteSession.draft.document === document {
                    IPadInlineNoteEditor(session: noteSession,
                        layout: inlineNoteLayout?.sessionID == noteSession.id ? inlineNoteLayout?.layout : nil,
                        canEdit: canCommitNote(noteSession),
                        onBoundsChanged: { id, bounds in
                            guard workspace.inlineNoteSession === noteSession, noteSession.id == id else { return }
                            inlineNoteTargetBounds = (id, bounds)
                        }, onSubmit: {
                            saveNote(noteSession)
                        }).id(noteSession.id)
                    IPadInlineNoteFloatingControls(session: noteSession, store: store,
                        layout: inlineNoteLayout?.sessionID == noteSession.id ? inlineNoteLayout?.layout : nil,
                        isActive: isPresentationActive,
                        canCommit: { canCommitNote(noteSession) },
                        onFinish: { finishNotePresentation(noteSession) }).id(noteSession.id)
                  }
                }.clipped()
                .overlay(alignment: .bottom) {
                    if inputMode != .read {
                        HStack(spacing: 8) {
                            Text(verbatim: L10n.string(inputMode == .selectText ? "Drag over text to select. Use two fingers to scroll or zoom." : "Tap the page with Pencil, a finger, or a pointer to place a note."))
                                .font(.caption).foregroundStyle(.secondary).allowsHitTesting(false)
                            Button("Done") {
                                guard isPresentationActive, workspace.state.isActive, !workspace.state.isClosed else { return }
                                changeInputMode(.read)
                            }.frame(minWidth: 44, minHeight: 44)
                        }
                        .padding(.horizontal, 10)
                        .background {
                            RoundedRectangle(cornerRadius: 8).fill(.regularMaterial).allowsHitTesting(false)
                        }
                        .padding(6)
                        .allowsHitTesting(isPresentationActive)
                        .accessibilityHidden(!isPresentationActive)
                    }
                }
                if let error = store.workingCopySaveError {
                    HStack { Text(verbatim: error).foregroundStyle(.red); Button("Retry Save") { store.retryWorkingCopySave() } }.padding(8)
                } else if store.hasUnsavedChanges {
                    Label("Saving working copy…", systemImage: "arrow.triangle.2.circlepath").font(.caption).padding(6)
                }
            } else {
                ContentUnavailableView("Open a PDF", systemImage: "doc", description: Text("Choose a PDF in the library or import one from Files."))
            }
        }
        .sheet(item: Binding(get: {
            isPresentationActive ? workspace.highlightEditingSession : nil
        }, set: { value in
            guard value == nil, let session = workspace.highlightEditingSession else { return }
            if session.isFinished {
                finishHighlightPresentation(session)
            } else if isPresentationActive, workspace.state.isActive, !workspace.state.isClosed {
                if session.requestDiscard(), session.discard() { finishHighlightPresentation(session) }
            } else {
                _ = workspace.flushHighlight()
            }
        })) { session in
            IPadHighlightEditor(session: session, store: store,
                canCommit: { canCommitHighlight(session) },
                onFinish: { finishHighlightPresentation(session) }).id(session.id)
        }
        .sheet(isPresented: $showsInspector, onDismiss: {
            let nextHighlight = pendingHighlight, nextFreeText = pendingFreeText
            pendingHighlight = nil; pendingFreeText = nil
            focusSearchOnPresentation = false; documentSearchFocused = false
            beginHighlightEditing(nextHighlight); beginNoteEditing(nextFreeText)
        }) { NavigationStack { inspector.navigationTitle("Annotations & Outline").toolbar {
            ToolbarItem(placement: .confirmationAction) { Button("Done") { showsInspector = false } }
        }.onAppear { documentSearchFocused = focusSearchOnPresentation } } }
        .sheet(isPresented: $showsPages, onDismiss: {
            let action = pendingPageAction; pendingPageAction = nil; action?()
        }) { IPadPageOrganizer(workspace: workspace, store: store, onInteraction: onInteraction, onPresentationAction: { action in
            pendingPageAction = action
        }) }
        .onChange(of: store.outlineNavigationRequest) { _, request in
            if let request { workspace.navigate(pageIndex: request.target.pageIndex) }
        }
        .onChange(of: store.document) { _, _ in
            inputMode = .read; inlineNoteLayout = nil
            showsPageEntry = false; pageEntryDocument = nil; pendingHighlight = nil; pendingFreeText = nil
        }
        .onChange(of: store.documentSearchText) { _, _ in cancelPendingSearchNavigation() }
        .onChange(of: isPresentationActive) { _, active in
            if !active { showsPageEntry = false; pageEntryDocument = nil }
        }
        .onChange(of: workspace.inlineNoteSession?.id) { _, _ in
            inlineNoteLayout = nil; inlineNoteTargetBounds = nil
        }
        .onChange(of: readerCommandsAvailable) { _, available in if !available { inputMode = .read } }
        .onAppear {
            if let session = workspace.inlineNoteSession, !session.isFinished,
               store.document === session.draft.document { showNote(session) }
        }
        .onDisappear {
            inputMode = .read
            _ = workspace.inlineNoteSession?.finishIME()
            _ = workspace.flushHighlight()
            workspace.libraryBinding?.flushZoom()
        }
        .alert(store.pendingConfirmation?.title ?? "Confirm", isPresented: Binding(get: { store.pendingConfirmation != nil }, set: { if !$0 { store.pendingConfirmation = nil } })) {
            if let request = store.pendingConfirmation {
                Button(request.confirmTitle, role: .destructive) { store.pendingConfirmation = nil; request.onConfirm() }
                Button("Cancel", role: .cancel) { store.pendingConfirmation = nil }
            }
        } message: { Text(verbatim: store.pendingConfirmation?.message ?? "") }
    }

    private var readerToolbar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
        HStack(spacing: 6) {
            Button { onInteraction(); workspace.navigate(pageIndex: store.currentPageIndex - 1) } label: { Image(systemName: "chevron.left") }.disabled(store.currentPageIndex == 0).accessibilityLabel("Previous Page")
            Button {
                onInteraction(); pageNumber = String(store.currentPageNumber)
                pageEntryDocument = store.document; showsPageEntry = true
            } label: {
                HStack(spacing: 3) {
                    Text("\(store.currentPageNumber) / \(store.pageCount)").font(.caption.monospacedDigit())
                    Image(systemName: "chevron.down").font(.caption2)
                }
            }.accessibilityLabel("Go to Page").accessibilityIdentifier("ipad.reader.pageNumber")
                .popover(isPresented: $showsPageEntry) { pageEntry }
            Button { onInteraction(); workspace.navigate(pageIndex: store.currentPageIndex + 1) } label: { Image(systemName: "chevron.right") }.disabled(store.currentPageIndex + 1 >= store.pageCount).accessibilityLabel("Next Page")
            Button {
                changeInputMode(inputMode == .selectText ? .read : .selectText)
            } label: { Image(systemName: "text.cursor").foregroundStyle(inputMode == .selectText ? Color.accentColor : Color.primary) }
                .accessibilityLabel("Select Text").accessibilityValue(inputMode == .selectText ? "On" : "Off")
                .help("Select Text (⌘⇧S)")
            Button(action: addHighlight) { Image(systemName: "highlighter") }
                .disabled(workspace.selection == nil).accessibilityLabel("Add Highlight").help("Add Highlight (H)")
            Button { changeInputMode(inputMode == .addNote ? .read : .addNote) } label: { Image(systemName: "square.and.pencil") }
                .accessibilityLabel("Place Free Text Note").accessibilityValue(inputMode == .addNote ? "On" : "Off")
                .help("Place Free Text Note (⌘⇧N)")
            Button { onInteraction(); workspace.undoDocumentChange() } label: { Image(systemName: "arrow.uturn.backward") }.disabled(!store.canUndoDocumentChange).accessibilityLabel("Undo").help("Undo (⌘Z)")
            Button { onInteraction(); store.redoDocumentChange() } label: { Image(systemName: "arrow.uturn.forward") }.disabled(!store.canRedoDocumentChange).accessibilityLabel("Redo").help("Redo (⌘⇧Z)")
            Button { showInspector(focusSearch: true) } label: { Image(systemName: "magnifyingglass") }.accessibilityLabel("Find in Document").help("Find in Document (⌘F)")
            Menu {
                Button("Add Free Text Note", systemImage: "square.and.pencil") { changeInputMode(.addNote) }
                Button("Annotations & Outline", systemImage: "list.bullet") { showInspector(focusSearch: false) }
                Button("Page Organizer", systemImage: "square.grid.2x2") { onInteraction(); showsPages = true }
                Button("Toggle Dogear", systemImage: "bookmark") { onInteraction(); store.toggleDogearOnCurrentPage(trigger: .toolbar) }
                Button("Fit Width") { onInteraction(); workspace.navigate(pageIndex: store.currentPageIndex, zoom: .fitWidth) }
                Button("Fit Page") { onInteraction(); workspace.navigate(pageIndex: store.currentPageIndex, zoom: .fit) }
                Button("Actual Size") { onInteraction(); workspace.navigate(pageIndex: store.currentPageIndex, zoom: .percent(100)) }
                Divider()
                Button("Export Annotated Copy") { onInteraction(); store.exportAnnotatedCopy(trigger: .toolbar) }
                Button("Export Annotations Markdown") { onInteraction(); store.exportAnnotationsMarkdown(trigger: .toolbar) }
                Button("Export Keyword Outline") { onInteraction(); store.exportFallbackKeywordOutline(trigger: .toolbar) }
                Divider()
                Button("Delete Current Page", role: .destructive) { onInteraction(); store.deleteCurrentPageFromWorkingCopy(trigger: .toolbar) }.disabled(store.pageCount < 2)
            } label: { Image(systemName: "ellipsis.circle") }.accessibilityLabel("PDF Actions")
        }.buttonStyle(IPadReaderTouchButtonStyle()).padding(.horizontal, 8)
            .disabled(!readerCommandsAvailable)
        }
    }

    private var pageEntry: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Go to Page").font(.headline)
            TextField("Page number", text: $pageNumber)
                .keyboardType(.numberPad).textFieldStyle(.roundedBorder)
                .focused($pageEntryFocused).onSubmit(goToEnteredPage)
                .accessibilityIdentifier("ipad.reader.pageInput")
            Text("1 – \(store.pageCount)").font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("Cancel") { showsPageEntry = false; pageEntryDocument = nil }
                Spacer()
                Button("Go", action: goToEnteredPage)
                    .disabled(PDFPageNumberInput.pageIndex(pageNumber, pageCount: store.pageCount) == nil)
                    .accessibilityIdentifier("ipad.reader.pageGo")
            }.buttonStyle(.bordered).frame(minHeight: 44)
        }.padding().frame(width: 260)
            .presentationCompactAdaptation(.popover)
            .onAppear { pageEntryFocused = true }
    }

    private func goToEnteredPage() {
        guard isPresentationActive, workspace.state.isActive, !workspace.state.isClosed,
              pageEntryDocument === store.document,
              let index = PDFPageNumberInput.pageIndex(pageNumber, pageCount: store.pageCount) else { return }
        onInteraction(); workspace.navigate(pageIndex: index)
        showsPageEntry = false; pageEntryDocument = nil
    }

    private var searchNavigation: some View {
        HStack(spacing: 8) {
            let index = store.documentSearchResults.firstIndex { $0.id == store.selectedDocumentSearchResultID }
            Text("\(index.map { $0 + 1 } ?? 0) / \(store.documentSearchResults.count)").font(.caption.monospacedDigit())
            Text(verbatim: store.documentSearchText).font(.caption).lineLimit(1)
            Spacer(minLength: 0)
            Button { navigateSearch(forward: false) } label: { Image(systemName: "chevron.up") }.accessibilityLabel("Previous Match")
            Button { navigateSearch(forward: true) } label: { Image(systemName: "chevron.down") }.accessibilityLabel("Next Match")
            Button {
                onInteraction(); cancelPendingSearchNavigation(); store.documentSearchText = ""
                workspace.selection = nil; store.recordTextSelection(nil)
                workspace.navigate(pageIndex: store.currentPageIndex, pageOffset: workspace.pageOffset)
            } label: { Image(systemName: "xmark") }.accessibilityLabel("Cancel Search")
        }.buttonStyle(IPadReaderTouchButtonStyle()).padding(.horizontal, 10)
            .disabled(!readerCommandsAvailable)
    }

    private func navigateSearch(forward: Bool) {
        guard readerCommandsAvailable else { return }
        onInteraction()
        if forward { store.selectNextDocumentSearchResult() } else { store.selectPreviousDocumentSearchResult() }
        guard let result = store.selectedDocumentSearchResult,
              store.selectDocumentSearchResult(result) else { return }
        workspace.navigate(pageIndex: result.pageIndex, selection: result.selection)
    }

    private func cancelPendingSearchNavigation() {
        if workspace.navigation?.selection != nil {
            workspace.navigation?.cancel(); workspace.navigation = nil
        }
    }

    private var inspector: some View {
        List {
            Section("Search PDF") {
                TextField("Find in Document", text: $store.documentSearchText).focused($documentSearchFocused)
                ForEach(store.documentSearchResults) { result in
                    Button {
                        guard store.selectDocumentSearchResult(result) else { return }
                        onInteraction(); workspace.navigate(pageIndex: result.pageIndex, selection: result.selection); showsInspector = false
                    } label: {
                        VStack(alignment: .leading) { Text(verbatim: result.snippet).lineLimit(3); Text("Page \(result.pageIndex + 1)").font(.caption) }
                    }
                }
            }
            Section("Annotations") {
                TextField("Search Annotations", text: $store.annotationSearchText)
                Picker("Source", selection: $store.annotationOriginFilter) { ForEach(AnnotationOriginFilter.allCases) { Text($0.displayTitle).tag($0) } }
                Picker("Type", selection: $store.annotationKindFilter) { ForEach(AnnotationKindFilter.allCases) { Text($0.displayTitle).tag($0) } }
                ForEach(store.filteredAnnotations) { item in
                    Button { onInteraction(); store.selectAnnotation(item); workspace.navigate(pageIndex: item.pageIndex); showsInspector = false } label: {
                        VStack(alignment: .leading) { Text(verbatim: item.displayText).lineLimit(3); Text("Page \(item.pageNumber) · \(item.kind.displayTitle)").font(.caption).foregroundStyle(.secondary) }
                    }.contextMenu {
                        Button("Edit") { edit(item) }
                        Button("Delete", role: .destructive) { onInteraction(); store.removeAnnotation(item, trigger: .pointer) }
                    }
                }
            }
            if !store.aiHighlightGroups.isEmpty {
                Section("AI Highlight Groups") { ForEach(store.aiHighlightGroups) { group in
                    Toggle(group.title ?? "AI Highlights", isOn: Binding(get: { store.isAIHighlightGroupVisible(group.id) }, set: { onInteraction(); store.setAIHighlightGroupVisible(group.id, isVisible: $0) }))
                } }
            }
            Section("Dogears") { ForEach(store.dogears) { marker in Button(marker.title) { onInteraction(); workspace.navigate(pageIndex: marker.pageIndex); showsInspector = false } } }
            Section("Outline") { ForEach(store.outlineEntries) { entry in Button(entry.title) { onInteraction(); workspace.navigate(pageIndex: entry.target.pageIndex); showsInspector = false } } }
        }
    }
    private func edit(_ item: PDFAnnotationItem) {
        guard item.kind != .note || workspace.canBeginInlineNote else { return }
        guard item.kind != .highlight || workspace.canBeginHighlight else { return }
        inputMode = .read
        store.selectAnnotation(item)
        let nextHighlight = store.highlightEditDraft(for: item)
        let nextFreeText = store.freeTextEditDraft(for: item)
        if showsInspector {
            pendingHighlight = nextHighlight; pendingFreeText = nextFreeText
            showsInspector = false
        } else { beginHighlightEditing(nextHighlight); beginNoteEditing(nextFreeText) }
    }

    private func beginHighlightEditing(_ draft: HighlightEditDraft?) {
        guard let draft, workspace.canBeginHighlight, workspace.inlineNoteSession == nil,
              store.document === draft.document, workspace.state.isActive,
              !workspace.state.isClosed, isPresentationActive else { return }
        inputMode = .read
        workspace.highlightEditingSession = IPadHighlightEditingSession(draft: draft)
    }

    private func canCommitHighlight(_ session: IPadHighlightEditingSession) -> Bool {
        workspace.highlightEditingSession === session && !session.isFinished
            && workspace.state.isActive && !workspace.state.isClosed && isPresentationActive
            && store.document === session.draft.document && store.canEditDocument
            && workspace.inlineNoteSession == nil && store.pendingConfirmation == nil
            && store.pendingExportOptions == nil && workspace.export.ticket == nil
            && !showsInspector && !showsPages
    }

    private func finishHighlightPresentation(_ session: IPadHighlightEditingSession) {
        guard workspace.highlightEditingSession === session, session.isFinished else { return }
        workspace.highlightEditingSession = nil
        onInteraction()
    }

    private func beginNoteEditing(_ draft: FreeTextEditDraft?) {
        guard let draft, workspace.canBeginInlineNote, workspace.inlineNoteSession == nil,
              store.document === draft.document, workspace.state.isActive,
              !workspace.state.isClosed else { return }
        inputMode = .read
        workspace.inlineNoteSession = IPadInlineNoteEditingSession(draft: draft)
        inlineNoteLayout = nil; inlineNoteTargetBounds = nil
        if !draft.isNew {
            workspace.navigate(pageIndex: draft.document.index(for: draft.page), bounds: draft.originalBounds)
        }
    }

    private func canCommitNote(_ session: IPadInlineNoteEditingSession) -> Bool {
        canAccessNote(session) && store.canEditDocument
            && store.pendingConfirmation == nil && store.pendingExportOptions == nil
            && workspace.export.ticket == nil && workspace.highlightEditingSession == nil && !showsInspector && !showsPages
    }

    private func canAccessNote(_ session: IPadInlineNoteEditingSession) -> Bool {
        workspace.inlineNoteSession === session && !session.isFinished
            && workspace.state.isActive && !workspace.state.isClosed && isPresentationActive
            && store.document === session.draft.document
    }

    private func saveNote(_ session: IPadInlineNoteEditingSession) {
        guard canAccessNote(session) else { return }
        if session.save(in: store, canCommit: { canCommitNote(session) }) { finishNotePresentation(session) }
    }

    private func cancelNote(_ session: IPadInlineNoteEditingSession) {
        guard canAccessNote(session) else { return }
        if session.requestDiscard(), session.discard() { finishNotePresentation(session) }
    }

    private func noteOverlayTarget(_ session: IPadInlineNoteEditingSession?, in document: PDFDocument) -> PDFReaderUIKitOverlayTarget? {
        guard let session, !session.isFinished, session.draft.document === document,
              session.draft.page.document === document else { return nil }
        let bounds: CGRect
        if let target = inlineNoteTargetBounds, target.sessionID == session.id { bounds = target.bounds }
        else { bounds = session.bounds }
        return .init(document: document, page: session.draft.page, bounds: bounds)
    }

    private func finishNotePresentation(_ session: IPadInlineNoteEditingSession) {
        guard workspace.inlineNoteSession === session, session.isFinished else { return }
        workspace.inlineNoteSession = nil
        inlineNoteLayout = nil; inlineNoteTargetBounds = nil
        onInteraction()
    }

    private func showNote(_ session: IPadInlineNoteEditingSession) {
        guard workspace.inlineNoteSession === session, canCommitNote(session),
              session.finishIME(), canCommitNote(session) else { return }
        onInteraction()
        workspace.navigate(pageIndex: session.draft.document.index(for: session.draft.page), bounds: session.bounds)
    }

    private func changeInputMode(_ mode: PDFReaderUIKitInputMode) {
        onInteraction(); inputMode = mode
    }

    private func showInspector(focusSearch: Bool) {
        onInteraction(); inputMode = .read
        focusSearchOnPresentation = focusSearch; showsInspector = true
    }

    private func addHighlight() {
        onInteraction()
        if let selection = workspace.selection, let pdf = store.document,
           store.addHighlights(from: selection, in: pdf, trigger: .toolbar) {
            inputMode = .read
            workspace.selection = nil; store.recordTextSelection(nil)
            workspace.navigate(pageIndex: store.currentPageIndex)
        }
    }

    private func handleKeyboardCommand(_ command: PDFReaderUIKitKeyboardCommand) {
        switch command {
        case .addHighlight: addHighlight()
        case .undo: onInteraction(); workspace.undoDocumentChange()
        case .redo: onInteraction(); store.redoDocumentChange()
        case .previousPage: onInteraction(); workspace.navigate(pageIndex: store.currentPageIndex - 1)
        case .nextPage: onInteraction(); workspace.navigate(pageIndex: store.currentPageIndex + 1)
        case .find: showInspector(focusSearch: true)
        case .nextMatch: navigateSearch(forward: true)
        case .previousMatch: navigateSearch(forward: false)
        case .selectText: changeInputMode(inputMode == .selectText ? .read : .selectText)
        case .placeNote: changeInputMode(inputMode == .addNote ? .read : .addNote)
        case .cancel: changeInputMode(.read)
        }
    }
}

/// Reader icons have a touch target even when compact width requires scrolling.
private struct IPadReaderTouchButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.frame(minWidth: 44, minHeight: 44)
            .contentShape(Rectangle()).opacity(configuration.isPressed ? 0.5 : 1)
    }
}

struct IPadPageOrganizer: View {
    @ObservedObject var workspace: IPadGroupWorkspace
    @ObservedObject var store: PDFDocumentStore
    let onInteraction: () -> Void
    let onPresentationAction: (@escaping () -> Void) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var selected = Set<Int>()
    var body: some View {
        NavigationStack {
            List(selection: $selected) {
                ForEach(0..<store.pageCount, id: \.self) { index in
                    HStack {
                        if let page = store.document?.page(at: index) { Image(uiImage: page.thumbnail(of: CGSize(width: 60, height: 80), for: .cropBox)).frame(width: 60, height: 80) }
                        Text("Page \(index + 1)")
                    }.tag(index)
                }.onMove { from, to in onInteraction(); store.movePages(fromOffsets: from, toOffset: to); selected.removeAll() }
            }.environment(\.editMode, .constant(.active))
            .navigationTitle("Page Organizer").toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
                ToolbarItemGroup(placement: .bottomBar) {
                    Button("Rotate") { onInteraction(); store.rotatePages(at: IndexSet(selected), clockwise: true) }
                    Button("Duplicate") { onInteraction(); selected = Set(store.duplicatePages(at: IndexSet(selected))) }
                    Button("Export") { schedulePresentation { store.exportPages(at: $0) } }
                    Button("Delete", role: .destructive) { onInteraction(); schedulePresentation { store.deletePagesFromWorkingCopy(at: $0) } }
                }
            }
        }
    }
    private func schedulePresentation(_ action: @escaping (IndexSet) -> Void) {
        guard let document = store.document else { return }
        let pages = IndexSet(selected)
        onPresentationAction {
            guard store.document === document else { return }
            action(pages)
        }
        dismiss()
    }

}
#endif
