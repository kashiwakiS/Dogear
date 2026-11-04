#if os(iOS)
import PDFKit
import SwiftUI
import UniformTypeIdentifiers

/// Native presentation of app-owned Research content. Sources and drafts belong
/// to the durable session, not to the PDF that happens to be open in this view.
@MainActor
struct IPadResearchView: View {
    @ObservedObject var library: LibraryStore
    @ObservedObject var documentStore: PDFDocumentStore
    @ObservedObject var storage: ResearchStore
    @ObservedObject var runtime: ResearchRuntime
    let groupID: UUID
    let viewID: UUID
    let isPresentationActive: Bool
    let onInteraction: () -> Void
    let onShowEvidence: (ResearchEvidence) -> Void
    let onExport: (DocumentExportRequest) -> Void
    let onPreparePresentationChange: (@escaping () -> Bool) -> Void
    @StateObject private var presentation: ResearchWorkspaceState
    @State private var showingSources = false
    @State private var sourcePickerSessionID: UUID?
    @State private var sourcePickerFileID: UUID?
    @State private var showingNotes = false
    @State private var pendingNoteID: UUID?
    @State private var pendingNoteAction: (() -> Void)?
    @State private var selectedNote: IPadResearchNoteSelection?
    @State private var previewAttachment: ResearchAttachment?
    @State private var regionCapture: IPadResearchRegionCaptureRequest?
    @State private var showingImageImporter = false
    @State private var imageImportRequest: ResearchImageImportRequest?
    @State private var localError: String?
    @State private var deletingSession: ResearchSession?
    @State private var deletingNote: ResearchNote?
    @StateObject private var composerCommands = IPadResearchTextEditingCommands()
    @StateObject private var composerEditing: ResearchComposerEditingSession

    init(library: LibraryStore, documentStore: PDFDocumentStore,
         storage: ResearchStore, runtime: ResearchRuntime, groupID: UUID, viewID: UUID,
         isPresentationActive: Bool = true,
         onInteraction: @escaping () -> Void = {},
         onShowEvidence: @escaping (ResearchEvidence) -> Void,
         onExport: @escaping (DocumentExportRequest) -> Void,
         onPreparePresentationChange: @escaping (@escaping () -> Bool) -> Void = { _ in }) {
        self.library = library
        self.documentStore = documentStore
        self.storage = storage
        self.runtime = runtime
        self.groupID = groupID
        self.viewID = viewID
        self.isPresentationActive = isPresentationActive
        self.onInteraction = onInteraction
        self.onShowEvidence = onShowEvidence
        self.onExport = onExport
        self.onPreparePresentationChange = onPreparePresentationChange
        _presentation = StateObject(wrappedValue: ResearchWorkspaceState(windowSessionID: viewID))
        _composerEditing = StateObject(wrappedValue: ResearchComposerEditingSession(store: storage, editorID: viewID))
    }

    private var session: ResearchSession? {
        presentation.sessionID.flatMap { storage.session(id: $0) }
    }
    private var running: Bool { session.flatMap { runtime.jobs[$0.id] } != nil }
    private var currentFile: LibraryFile? { library.file(for: documentStore.selectedPDFURL) }
    private var sourceIDs: [UUID] {
        guard let session else { return [] }
        let members = session.sourceSelection.groupID.map { library.files(in: $0).map(\.id) } ?? []
        return session.sourceSelection.expandedFileIDs(groupMembers: members)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if let session {
                sourceSummary
                Divider()
                conversation(session)
                Divider()
                composer(session)
            } else {
                ContentUnavailableView("Research", systemImage: "text.bubble",
                    description: Text("Keep questions, evidence, and notes together across documents."))
                Button("New research session") { onInteraction(); createSession() }.padding()
            }
        }
        .background(Color(uiColor: .systemBackground))
        .onAppear {
            if session == nil {
                presentation.sessionID = storage.sessions.first?.id
                if session == nil { createSession() }
            }
            registerPresentationBoundary()
            bindComposer()
        }
        .onChange(of: presentation.sessionID) { _, _ in registerPresentationBoundary(); bindComposer() }
        .onChange(of: storage.composerEditorOwners) { _, _ in
            if isPresentationActive, let id = presentation.sessionID, storage.composerOwner(sessionID: id) == nil { bindComposer() }
        }
        .onChange(of: isPresentationActive) { _, active in
            if active { bindComposer() }
            else { _ = composerEditing.release() }
        }
        .onDisappear { _ = composerEditing.release() }
        .sheet(isPresented: $showingSources) { sourcePicker }
        .sheet(isPresented: $showingNotes, onDismiss: {
            if let id = pendingNoteID {
                pendingNoteID = nil
                selectedNote = IPadResearchNoteSelection(id: id)
            }
        }) { noteLibrary }
        .sheet(item: $selectedNote, onDismiss: {
            let action = pendingNoteAction
            pendingNoteAction = nil
            action?()
        }) { item in
            IPadResearchNoteEditor(storage: storage, noteID: item.id,
                onShowEvidence: { evidence in
                    pendingNoteAction = { showEvidence(evidence) }
                    selectedNote = nil
                }, onExport: { request in
                    let captured = DocumentExportRequest(data: request.data,
                        suggestedName: request.suggestedName, contentType: request.contentType,
                        protectedOriginalURL: documentStore.selectedPDFURL)
                    pendingNoteAction = { onExport(captured) }
                    selectedNote = nil
                },
                onDiscussNote: { note in
                    let evidence = ResearchEvidence(source: nil, kind: .note,
                        excerpt: note.body, noteID: note.id, noteRevision: note.revision)
                    mutateDraft { $0.blocks.append(ResearchInputBlock(kind: .note,
                        text: note.body, evidence: evidence)) }
                })
                .id(item.id)
        }
        .sheet(item: $previewAttachment) { attachment in
            IPadResearchAttachmentPreview(attachment: attachment, storage: storage)
        }
        .sheet(item: $regionCapture) { request in
            IPadResearchRegionCapture(request: request, library: library,
                storage: storage, documentStore: documentStore).id(request.id)
        }
        .fileImporter(isPresented: $showingImageImporter, allowedContentTypes: [.image],
            allowsMultipleSelection: true, onCompletion: { result in
                guard let request = imageImportRequest else { return }
                imageImportRequest = nil
                if let error = request.complete(result, store: storage).last {
                    localError = error.localizedDescription
                }
            }, onCancellation: { imageImportRequest = nil })
        .alert("Research", isPresented: Binding(get: { localError != nil },
            set: { if !$0 { localError = nil } })) {
            Button("OK") { localError = nil }
        } message: { Text(verbatim: localError ?? "") }
        .alert("Delete research session?", isPresented: Binding(get: { deletingSession != nil },
            set: { if !$0 { deletingSession = nil } })) {
            Button("Delete", role: .destructive) {
                guard let target = deletingSession else { return }
                runtime.cancel(sessionID: target.id)
                if storage.deleteSession(id: target.id) {
                    if presentation.sessionID == target.id { presentation.sessionID = storage.sessions.first?.id }
                } else { localError = L10n.string("Research could not be saved. Retry saving before sending a request.") }
                deletingSession = nil
            }
            Button("Cancel", role: .cancel) { deletingSession = nil }
        } message: { Text("The conversation will be deleted. Saved notes, attachments, and PDF files are kept.") }
    }

    private var header: some View {
        HStack {
            Menu {
                Button("New research session", systemImage: "plus") { onInteraction(); createSession() }
                ForEach(storage.sessions) { item in
                    Button { selectSession(item.id) } label: {
                        if item.id == presentation.sessionID { Label(item.title, systemImage: "checkmark") }
                        else { Text(verbatim: item.title) }
                    }
                }
                if let session {
                    Divider()
                    Button("Delete research session", role: .destructive) {
                        guard finishComposerEditing() else { return }
                        onInteraction(); deletingSession = session
                    }
                }
            } label: {
                Label(session?.title ?? L10n.string("Research"), systemImage: "text.bubble").lineLimit(1)
            }
            .accessibilityIdentifier("ipad.research.sessions")
            .frame(minHeight: 44)
            Spacer()
            Button { guard finishComposerEditing() else { return }; onInteraction(); showingNotes = true } label: { Image(systemName: "books.vertical") }
                .accessibilityLabel("Research sessions and notes")
                .accessibilityIdentifier("ipad.research.notes")
                .frame(width: 44, height: 44)
            Button { exportSession() } label: { Image(systemName: "square.and.arrow.up") }
                .accessibilityLabel("Export text Markdown")
                .help("Exports text and source references; image files remain in Dogear.")
                .disabled(session == nil)
                .frame(width: 44, height: 44)
        }
        .padding(.horizontal, 8)
    }

    private var sourceSummary: some View {
        HStack {
            Button {
                guard finishComposerEditing() else { return }
                sourcePickerSessionID = presentation.sessionID; sourcePickerFileID = currentFile?.id
                onInteraction(); showingSources = true
            } label: {
                Label("Sources: \(sourceIDs.count)", systemImage: "doc.on.doc")
            }
            .frame(minHeight: 44)
            Spacer()
            Text("BM25").font(.caption).foregroundStyle(.secondary)
        }
        .font(.subheadline)
        .padding(.horizontal, 8)
    }

    private func conversation(_ session: ResearchSession) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    if session.messages.isEmpty {
                        Text("Ask a question, collect several passages, or leave the question empty to create an outline.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(session.messages) { message in
                        messageView(message, sessionID: session.id).id(message.id)
                    }
                    Color.clear.frame(height: 1).id("research-bottom")
                }
                .padding().frame(maxWidth: .infinity, alignment: .leading)
            }
            .onChange(of: session.messages.count) { _, _ in
                withAnimation { proxy.scrollTo("research-bottom", anchor: .bottom) }
            }
        }
    }

    private func messageView(_ message: ResearchMessage, sessionID: UUID) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(message.question.isEmpty ? L10n.string("Document outline") : message.question)
                .font(.headline).textSelection(.enabled)
            if let answer = message.answer {
                IPadResearchAnswer(markdown: answer, sources: message.sourceSnapshot,
                    evidence: message.evidence, onShowEvidence: showEvidence)
                HStack {
                    Button("Copy") { onInteraction(); PlatformClipboard.copyText(answer) }
                    if message.status == .accepted {
                        Button("Save as note") { saveNote(message, sessionID: sessionID) }
                        Button("Quote answer and follow up") {
                            let evidence = ResearchEvidence(source: nil, kind: .discussion,
                                excerpt: answer, messageID: message.id)
                            mutateDraft(sessionID: sessionID) { $0.blocks.append(ResearchInputBlock(kind: .discussion,
                                text: answer, evidence: evidence)) }
                        }
                    }
                }.font(.caption)
            }
            if message.origin == .localOutline {
                Label("Local outline", systemImage: "leaf").font(.caption).foregroundStyle(.secondary)
            }
            ForEach(message.evidence) { item in
                Button { showEvidence(item) } label: {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(verbatim: evidenceTitle(item)).font(.caption.weight(.medium))
                        Text(verbatim: item.excerpt).font(.caption).lineLimit(3)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }.buttonStyle(.plain).foregroundStyle(.tint)
            }
            if !message.operationResults.isEmpty {
                DisclosureGroup("Source coverage and actions") {
                    ForEach(Array(message.operationResults.enumerated()), id: \.offset) { _, result in
                        Text(verbatim: result).font(.caption).frame(maxWidth: .infinity, alignment: .leading)
                    }
                }.font(.caption)
            }
            if let error = message.errorMessage {
                Text(verbatim: error).font(.caption).foregroundStyle(.red).textSelection(.enabled)
            }
            if message.status == .failed || message.status == .cancelled || message.status == .interrupted {
                Button("Restore input") { restoreInput(message.input, sessionID: sessionID) }.disabled(running)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func composer(_ session: ResearchSession) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if !composerEditing.ownsEditor {
                HStack {
                    Text("This input is being edited in another window.").font(.caption).foregroundStyle(.secondary)
                    Spacer(minLength: 4)
                    Button("Edit here") { _ = composerEditing.takeOver() }.frame(minHeight: 44)
                }
            }
            if let error = composerEditing.error {
                HStack {
                    Text(verbatim: error).font(.caption).foregroundStyle(.orange)
                    Button("Retry save") { _ = composerEditing.retrySave() }.frame(minHeight: 44)
                }
            }
            let conflicts = storage.composerConflicts.filter { $0.sessionID == session.id && !$0.isResolved }
            if !conflicts.isEmpty {
                Menu("Recover input", systemImage: "arrow.uturn.backward") {
                    ForEach(conflicts) { record in
                        Button {
                            _ = composerEditing.restoreConflict(record.id)
                        } label: { Text(verbatim: String(record.text.prefix(80))) }
                    }
                }.disabled(!composerEditing.ownsEditor).frame(minHeight: 44)
            }
            if !storage.saveFailures.isEmpty || !storage.loadWarnings.isEmpty {
                HStack {
                    Label("Some research content needs attention.", systemImage: "exclamationmark.triangle")
                    Button("Retry save") { storage.retryFailedSaves() }
                }.font(.caption).foregroundStyle(.orange)
            }
            if let progress = runtime.jobs[session.id] {
                HStack {
                    ProgressView()
                    Text(verbatim: progress.phase).font(.caption)
                    Spacer()
                    Button("Cancel") { onInteraction(); runtime.cancel(sessionID: session.id) }
                }
                Text("\(progress.preparedSources)/\(progress.totalSources) · \(progress.providerTurns) turns · \(progress.toolCalls) tools")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            if let error = runtime.errors[session.id] {
                Text(verbatim: error).font(.caption).foregroundStyle(.red).textSelection(.enabled)
            }
            if !session.draft.blocks.isEmpty {
                ScrollView {
                    VStack(spacing: 8) {
                        ForEach(session.draft.blocks) { block in inputBlock(block, sessionID: session.id) }
                    }
                }.frame(maxHeight: 120)
            }
            if !session.attachmentIDs.isEmpty {
                Text("Markdown export includes text and source references. Image files stay in Dogear.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            IPadResearchNativeTextEditor(text: draftTextBinding(for: session.id),
                commands: composerCommands, identity: session.id,
                isEditable: isPresentationActive && composerEditing.ownsEditor,
                isTitle: false, accessibilityLabel: L10n.string("Research question"), onEditingBoundary: nil,
                onSubmit: { send(sessionID: session.id) },
                composerEditing: composerEditing, composerIsActive: isPresentationActive)
                .frame(minHeight: 72, maxHeight: 130)
                .overlay(alignment: .topLeading) {
                    if session.draft.text.isEmpty {
                        Text("Ask a question, or leave empty for an outline…")
                            .foregroundStyle(.tertiary).padding(8).allowsHitTesting(false)
                    }
                }
                .id(session.id)
                .accessibilityLabel("Research question")
                .accessibilityIdentifier("ipad.research.question")
            HStack {
                Menu("Add evidence", systemImage: "plus") {
                    Button("Add selected passage", systemImage: "text.quote", action: addSelection)
                        .disabled(documentStore.currentTextSelection?.isEmpty != false || running)
                    Button("Choose image…", systemImage: "photo", action: chooseImage)
                        .disabled(running || session.draft.attachmentIDs.count >= ResearchInputLimits.maximumImages)
                    Button("Add page region", systemImage: "viewfinder", action: captureRegion)
                        .disabled(documentStore.document == nil || running || session.draft.attachmentIDs.count >= ResearchInputLimits.maximumImages)
                }
                Spacer()
                Toggle("Allow highlights", isOn: Binding(
                    get: { runtime.sessionAllowsAnnotations(session.id) },
                    set: { onInteraction(); runtime.setAllowsAnnotations($0, sessionID: session.id) }))
                    .font(.caption).disabled(running || !documentStore.canEditDocument)
            }
            HStack {
                if !runtime.cloudAvailable {
                    Label("Cloud AI is off. Leave the input empty for a local outline.", systemImage: "leaf")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Send", systemImage: "arrow.up") {
                    send(sessionID: session.id)
                }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("ipad.research.send")
                .disabled(!composerEditing.ownsEditor || running || (sourceIDs.isEmpty && session.draft.attachmentIDs.isEmpty))
                if !session.draft.attachmentIDs.isEmpty {
                    Button("Send without images") {
                        send(sessionID: session.id, textOnly: true)
                    }.disabled(!composerEditing.ownsEditor || running || sourceIDs.isEmpty)
                }
            }
        }.padding()
    }

    private func inputBlock(_ block: ResearchInputBlock, sessionID: UUID) -> some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                if let evidence = block.evidence {
                    if evidence.source != nil || evidence.noteID != nil || evidence.attachmentID != nil {
                        Button { showEvidence(evidence) } label: { Text(verbatim: evidenceTitle(evidence)).font(.caption) }
                    } else {
                        Text(verbatim: evidenceTitle(evidence)).font(.caption).foregroundStyle(.secondary)
                    }
                }
                Text(verbatim: block.text).font(.caption).lineLimit(3)
            }
            Spacer()
            Button {
                mutateDraft(sessionID: sessionID) { $0.blocks.removeAll { $0.id == block.id } }
            } label: { Image(systemName: "xmark.circle") }
                .accessibilityLabel("Remove passage")
        }
        .padding(8).background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
    }

    private var sourcePicker: some View {
        IPadResearchSourcePicker(library: library, storage: storage,
            sessionID: sourcePickerSessionID, currentFileID: sourcePickerFileID, currentGroupID: groupID)
            .id(sourcePickerSessionID)
    }

    private var noteLibrary: some View {
        NavigationStack {
            List {
                Button("New note", systemImage: "square.and.pencil") {
                    let id = storage.createNote(title: L10n.string("Research note"), body: "")
                    pendingNoteID = id
                    showingNotes = false
                }
                ForEach(storage.notes) { note in
                    Button {
                        pendingNoteID = note.id
                        showingNotes = false
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(verbatim: note.title)
                            Text(verbatim: note.body).font(.caption).lineLimit(2).foregroundStyle(.secondary)
                        }
                    }
                    .swipeActions {
                        Button("Delete", role: .destructive) { onInteraction(); deletingNote = note }
                    }
                    .contextMenu {
                        Button("Delete", role: .destructive) { onInteraction(); deletingNote = note }
                    }
                }
            }
            .navigationTitle("Research notes")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { showingNotes = false } } }
            .alert("Delete research note?", isPresented: Binding(get: { deletingNote != nil },
                set: { if !$0 { deletingNote = nil } })) {
                Button("Delete", role: .destructive) {
                    guard let target = deletingNote else { return }
                    if !storage.deleteNote(id: target.id) {
                        localError = L10n.string("Research could not be saved. Retry saving before sending a request.")
                    }
                    deletingNote = nil
                }
                Button("Cancel", role: .cancel) { deletingNote = nil }
            } message: { Text("The note will be deleted. Research sessions, attachments, and PDF files are kept.") }
        }
    }

    private func createSession() {
        guard finishComposerEditing(), composerEditing.release() else { return }
        presentation.sessionID = storage.createSession(title: L10n.string("New research session"),
            sourceSelection: ResearchSourceSelection(fileIDs: currentFile.map { [$0.id] } ?? []))
    }

    private func finishComposerEditing() -> Bool {
        composerEditing.prepareForTransition()
    }

    private func registerPresentationBoundary() {
        let capturedID = presentation.sessionID
        let owner = presentation, editor = composerEditing
        onPreparePresentationChange {
            guard owner.sessionID == capturedID else { return false }
            return editor.prepareForTransition()
        }
    }

    private func finishComposerEditing(sessionID: UUID) -> Bool {
        guard presentation.sessionID == sessionID, storage.session(id: sessionID) != nil,
              composerEditing.sessionID == sessionID, composerEditing.prepareForTransition() else { return false }
        // Ending composition publishes through the editor's captured binding.
        // That callback may change the presentation before this action resumes.
        return presentation.sessionID == sessionID && storage.session(id: sessionID) != nil
    }

    private func selectSession(_ id: UUID) {
        guard finishComposerEditing(), composerEditing.release() else { return }
        onInteraction(); presentation.sessionID = id
    }

    private func send(sessionID: UUID, textOnly: Bool = false) {
        guard presentation.sessionID == sessionID, storage.session(id: sessionID) != nil,
              isPresentationActive, composerEditing.sessionID == sessionID, composerEditing.ownsEditor,
              runtime.jobs[sessionID] == nil, composerEditing.prepareForTransition() else { return }
        onInteraction()
        runtime.send(sessionID: sessionID, library: library,
            mainStore: documentStore, viewID: viewID, textOnly: textOnly)
    }

    private func mutateDraft(sessionID: UUID? = nil, _ change: (inout ResearchDraft) -> Void) {
        guard let id = sessionID ?? presentation.sessionID,
              let session = storage.session(id: id) else { return }
        var draft = session.draft
        change(&draft)
        guard draft != session.draft else { return }
        onInteraction()
        _ = storage.saveDraft(draft, sessionID: session.id)
    }

    private func draftTextBinding(for sessionID: UUID) -> Binding<String> {
        // An old native editor may commit marked text while its replacement is
        // mounting. Its closure continues to address only its original session.
        Binding(get: {
            composerEditing.sessionID == sessionID ? composerEditing.text : storage.session(id: sessionID)?.draft.text ?? ""
        }, set: { text in
            guard composerEditing.sessionID == sessionID else { return }
            _ = composerEditing.acceptNativeText(text)
        })
    }

    private func bindComposer() {
        guard isPresentationActive, let id = presentation.sessionID else { return }
        let commands = composerCommands
        _ = composerEditing.bind(sessionID: id, prepareNativeInput: {
            return commands.commitMarkedTextAndEndEditing(identity: id)
        })
    }

    private func addSelection() {
        guard let selection = documentStore.currentTextSelection, !selection.isEmpty,
              let file = currentFile else { return }
        guard sourceIDs.contains(file.id) else {
            localError = L10n.string("Add the current PDF to this session’s sources before adding its passage.")
            return
        }
        do {
            let read = try DocumentAccessCoordinator.shared.readSnapshot(fileID: file.id,
                originalURL: library.resolvedURL(for: file), workingCopyURL: file.workingCopyURL)
            let source = ResearchSourceSnapshot(fileID: file.id, displayName: file.displayName,
                fingerprint: read.contentVersion)
            mutateDraft { draft in
                if selection.passages.isEmpty {
                    draft.blocks.append(ResearchInputBlock(kind: .discussion, text: selection.text))
                } else {
                    for passage in selection.passages {
                        let bounds = passage.bounds
                        let evidence = ResearchEvidence(source: source, kind: .pdfText,
                            anchor: ResearchPageAnchor(pageIndex: passage.pageNumber - 1,
                                x: bounds.minX, y: bounds.minY, width: bounds.width, height: bounds.height),
                            excerpt: passage.text)
                        draft.blocks.append(ResearchInputBlock(kind: .pdfText, text: passage.text, evidence: evidence))
                    }
                }
            }
        } catch { localError = error.localizedDescription }
    }

    private func restoreInput(_ input: ResearchDraft, sessionID: UUID) {
        guard runtime.jobs[sessionID] == nil, finishComposerEditing(sessionID: sessionID),
              runtime.jobs[sessionID] == nil else { return }
        // Read the current draft only after marked text has reached this session.
        mutateDraft(sessionID: sessionID) { draft in
            guard draft != input else { return }
            if draft.isEmpty { draft = input }
            else {
                if !input.text.isEmpty { draft.text += (draft.text.isEmpty ? "" : "\n\n") + input.text }
                draft.blocks += input.blocks.map { block in var copy = block; copy.id = UUID(); return copy }
            }
        }
    }

    private func saveNote(_ message: ResearchMessage, sessionID: UUID) {
        guard let answer = message.answer else { return }
        onInteraction()
        let provenance = ResearchNoteProvenance(origin: message.origin, sessionID: sessionID,
            messageID: message.id, evidence: message.evidence)
        let id = storage.createNote(title: String((message.question.isEmpty
            ? L10n.string("Research note") : message.question).prefix(100)), body: answer,
            provenance: [provenance], attachmentIDs: message.input.attachmentIDs)
        selectedNote = IPadResearchNoteSelection(id: id)
    }

    private func chooseImage() {
        guard let session, imageImportRequest == nil, finishComposerEditing() else { return }
        onInteraction()
        imageImportRequest = ResearchImageImportRequest(sessionID: session.id)
        showingImageImporter = true
    }

    private func captureRegion() {
        guard let session, let file = currentFile, let document = documentStore.document,
              finishComposerEditing() else { return }
        onInteraction()
        guard sourceIDs.contains(file.id) else {
            localError = L10n.string("Add the current PDF to this session’s sources before adding its passage.")
            return
        }
        do {
            let read = try DocumentAccessCoordinator.shared.readSnapshot(fileID: file.id,
                originalURL: library.resolvedURL(for: file), workingCopyURL: file.workingCopyURL)
            let source = ResearchSourceSnapshot(fileID: file.id, displayName: file.displayName, fingerprint: read.contentVersion)
            let request = IPadResearchRegionCaptureRequest(sessionID: session.id, source: source,
                document: read.document, pageIndex: documentStore.currentPageIndex, editorDocument: document)
            try request.validate(library: library, storage: storage, store: documentStore)
            regionCapture = request
        } catch { localError = error.localizedDescription }
    }

    private func showEvidence(_ evidence: ResearchEvidence) {
        onInteraction()
        if let id = evidence.attachmentID,
           let attachment = storage.attachments.first(where: { $0.id == id }) {
            previewAttachment = attachment
        } else if let id = evidence.noteID, storage.note(id: id) != nil {
            selectedNote = IPadResearchNoteSelection(id: id)
        } else if evidence.source != nil {
            onShowEvidence(evidence)
        }
    }

    private func exportSession() {
        guard let sessionID = presentation.sessionID,
              finishComposerEditing(sessionID: sessionID) else { return }
        onInteraction()
        guard presentation.sessionID == sessionID,
              let latestSession = storage.session(id: sessionID) else { return }
        do {
            // The factory reads this session's committed draft and freezes the
            // Markdown bytes before the export destination is presented.
            let request = try IPadResearchTextExport.session(id: latestSession.id, storage: storage,
                protectedOriginalURL: documentStore.selectedPDFURL)
            guard presentation.sessionID == sessionID else { return }
            onExport(request)
        } catch { localError = error.localizedDescription }
    }

    private func evidenceTitle(_ evidence: ResearchEvidence) -> String {
        let title = evidence.source?.displayName ?? L10n.string("Discussion background")
        return evidence.anchor.map { title + " — " + L10n.string("Page") + " \($0.pageIndex + 1)" } ?? title
    }
}

private struct IPadResearchNoteSelection: Identifiable { let id: UUID }
#endif
