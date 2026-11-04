import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct ResearchPanelView: View {
    @ObservedObject var store: ResearchStore
    @ObservedObject var runtime: ResearchRuntime
    @ObservedObject var library: LibraryStore
    @Binding var sessionID: UUID?
    let currentFileID: UUID?
    let mainStore: PDFDocumentStore?
    let viewID: UUID
    let compact: Bool
    let onAddSelection: () -> Void
    let onCaptureRegion: () -> Void
    let onViewEvidence: (ResearchEvidence) -> Void
    let onShowLibrary: () -> Void
    let onToggleWide: () -> Void
    @ObservedObject private var configuration = AIConfigurationStore.shared
    @ObservedObject private var languageStore = AppLanguageStore.shared
    @Environment(\.openWindow) private var openWindow
    @Environment(\.workspaceOpenWindow) private var workspaceOpenWindow
    @State private var showingSources = false
    @State private var expandedProgressRequestID: UUID?
    @State private var isDropTarget = false
    @State private var attachmentPreview: ResearchAttachment?
    @State private var localError: String?
    @State private var showingImageImporter = false
    @State private var imageImportRequest: ResearchImageImportRequest?
    @StateObject private var composerEditing: ResearchComposerEditingSession
    @StateObject private var composerCommands = ResearchTextEditingCommands()

    init(store: ResearchStore? = nil, runtime: ResearchRuntime? = nil, library: LibraryStore,
         sessionID: Binding<UUID?>, currentFileID: UUID?, mainStore: PDFDocumentStore?, viewID: UUID,
         compact: Bool, onAddSelection: @escaping () -> Void, onCaptureRegion: @escaping () -> Void,
         onViewEvidence: @escaping (ResearchEvidence) -> Void, onShowLibrary: @escaping () -> Void,
         onToggleWide: @escaping () -> Void) {
        let resolvedStore = store ?? ResearchStore.shared
        self.store = resolvedStore; self.runtime = runtime ?? .shared; self.library = library
        _sessionID = sessionID
        self.currentFileID = currentFileID; self.mainStore = mainStore; self.viewID = viewID
        self.compact = compact; self.onAddSelection = onAddSelection; self.onCaptureRegion = onCaptureRegion
        self.onViewEvidence = onViewEvidence; self.onShowLibrary = onShowLibrary; self.onToggleWide = onToggleWide
        _composerEditing = StateObject(wrappedValue: ResearchComposerEditingSession(store: resolvedStore, editorID: viewID))
    }

    private var session: ResearchSession? { sessionID.flatMap { store.session(id: $0) } }
    private var running: Bool { sessionID.flatMap { runtime.jobs[$0] } != nil }
    private var sourceIDs: [UUID] {
        guard let session else { return [] }
        let members = session.sourceSelection.groupID.map { library.files(in: $0).map(\.id) } ?? []
        return session.sourceSelection.expandedFileIDs(groupMembers: members)
    }
    private var draft: ResearchDraft { session?.draft ?? ResearchDraft() }
    private var imagesNeedConfirmation: Bool {
        !draft.attachmentIDs.isEmpty && configuration.configuration.imageCapability != .supported
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if let session {
                sourceBar(session)
                Divider()
                conversation(session)
                composer(session)
            } else {
                ContentUnavailableView {
                    Label("Research", systemImage: "text.bubble")
                } description: {
                    Text("Keep questions, evidence, and notes together across documents.")
                } actions: {
                    Button("New research session", action: createSession)
                }
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .overlay {
            if isDropTarget {
                RoundedRectangle(cornerRadius: 8).stroke(Color.accentColor, lineWidth: 2).padding(3).allowsHitTesting(false)
            }
        }
        .onDrop(of: [UTType.image.identifier, UTType.fileURL.identifier], isTargeted: $isDropTarget, perform: receiveDrop)
        .onAppear { if sessionID == nil { createSession() }; bindComposer() }
        .onChange(of: sessionID) { _, _ in bindComposer() }
        .onChange(of: store.composerEditorOwners) { _, _ in
            if let sessionID, store.composerOwner(sessionID: sessionID) == nil { bindComposer() }
        }
        .onDisappear { _ = composerEditing.release() }
        .sheet(item: $attachmentPreview) { attachment in
            ResearchAttachmentPreview(attachment: attachment, store: store)
                .environment(\.locale, languageStore.locale)
        }
        .fileImporter(isPresented: $showingImageImporter, allowedContentTypes: [.image],
            allowsMultipleSelection: true, onCompletion: { result in
                guard let request = imageImportRequest else { return }
                imageImportRequest = nil
                if let error = request.complete(result, store: store).last {
                    localError = error.localizedDescription
                }
            }, onCancellation: { imageImportRequest = nil })
        .alert("Research", isPresented: Binding(get: { localError != nil }, set: { if !$0 { localError = nil } })) {
            Button("OK") { localError = nil }
        } message: { Text(LocalizedStringKey(localError ?? "")) }
        .environment(\.locale, languageStore.locale)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Menu {
                Button("New research session", systemImage: "plus", action: createSession)
                Divider()
                ForEach(store.sessions) { item in
                    Button { selectSession(item.id) } label: {
                        if item.id == sessionID { Label(item.title, systemImage: "checkmark") }
                        else { Text(item.title) }
                    }
                }
            } label: {
                Label(session?.title ?? L10n.string("Research"), systemImage: "text.bubble")
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
            }
            .menuStyle(.borderlessButton)
            .accessibilityLabel("Choose research session")
            Spacer(minLength: 0)
            Button(action: onShowLibrary) {
                Image(systemName: "books.vertical").frame(width: 24, height: 24)
            }
                .help("Research sessions and notes")
                .accessibilityLabel("Research sessions and notes")
            if mainStore != nil {
                Button(action: onToggleWide) {
                    Image(systemName: compact ? "arrow.up.left.and.arrow.down.right" : "xmark")
                        .frame(width: 24, height: 24)
                }
                .help(LocalizedStringKey(compact ? "Show AI workspace" : "Hide AI workspace"))
                .accessibilityLabel(LocalizedStringKey(compact ? "Show AI workspace" : "Hide AI workspace"))
            }
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 12)
        .frame(height: 44)
    }

    private func sourceBar(_ session: ResearchSession) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Button { showingSources.toggle() } label: {
                    Label("Sources: \(sourceIDs.count)", systemImage: "doc.on.doc")
                        .font(.caption.weight(.medium))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .background(Color.primary.opacity(0.055), in: Capsule())
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .popover(isPresented: $showingSources, arrowEdge: .bottom) {
                    sourcePicker(session).environment(\.locale, languageStore.locale)
                }
                Spacer(minLength: 4)
                if let groupID = session.sourceSelection.groupID,
                   let group = library.userGroups.first(where: { $0.id == groupID }) {
                    Label(group.name, systemImage: "folder").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                } else if let fileID = sourceIDs.first,
                          let file = library.allFiles.first(where: { $0.id == fileID }) {
                    Text(file.displayName).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            if let previous = session.messages.last, !running {
                let old = Set(previous.sourceSnapshot.map(\.fileID))
                let current = Set(sourceIDs)
                if old != current {
                    Label("Sources changed: +\(current.subtracting(old).count), −\(old.subtracting(current).count)", systemImage: "arrow.triangle.2.circlepath")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            if sourceIDs.isEmpty {
                Text("Choose files or a Group. Selected images can also be sent directly.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
    }

    private func sourcePicker(_ session: ResearchSession) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Research sources").font(.headline)
            Text("Sources are fixed when you send. Opening a PDF does not change this selection.")
                .font(.caption).foregroundStyle(.secondary)
            Picker("Group", selection: Binding<UUID?>(
                get: { self.session?.sourceSelection.groupID },
                set: { value in mutateSession { $0.sourceSelection.groupID = value } }
            )) {
                Text("No Group").tag(nil as UUID?)
                ForEach(library.userGroups) { group in Text(group.name).tag(Optional(group.id)) }
            }
            if let currentFileID {
                Button("Add current PDF") { setFile(currentFileID, included: true) }
                    .disabled(sourceIDs.contains(currentFileID))
            }
            Text("Additional files").font(.subheadline.weight(.semibold))
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(library.allFiles) { file in
                        Toggle(isOn: Binding(get: { self.session?.sourceSelection.fileIDs.contains(file.id) == true },
                            set: { setFile(file.id, included: $0) })) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(file.displayName).lineLimit(2)
                                Text(file.id.uuidString.prefix(8)).font(.caption2.monospaced()).foregroundStyle(.tertiary)
                            }
                        }
                        .toggleStyle(.checkbox)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }.frame(minHeight: 120, maxHeight: 320)
            Button("Done") { showingSources = false }.frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(16).frame(width: 330)
    }

    private func conversation(_ session: ResearchSession) -> some View {
        ScrollViewReader { proxy in
            // Exact message heights keep scroll offsets stable when long answers
            // enter/leave the viewport; lazy row estimates shift that offset.
            ScrollView {
                VStack(alignment: .leading, spacing: 26) {
                    if session.messages.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Read, ask, keep the evidence.").font(.headline)
                            Text("Ask a question, collect several passages, or leave the question empty to create an outline.")
                                .foregroundStyle(.secondary)
                            if !runtime.cloudAvailable {
                                Label("Cloud AI is off. You can read history, edit notes, and create a local outline.", systemImage: "leaf")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }.padding(.vertical, 12)
                    }
                    ForEach(session.messages) { message in messageCard(message, sessionID: session.id).id(message.id) }
                    Color.clear.frame(height: 1).id("research-bottom")
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 18)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .onChange(of: session.messages.count) { _, _ in
                withAnimation { proxy.scrollTo("research-bottom", anchor: .bottom) }
            }
        }
    }

    private func messageCard(_ message: ResearchMessage, sessionID: UUID) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 0) {
                Spacer(minLength: 24)
                Text(message.question.isEmpty ? L10n.string("Document outline") : message.question)
                    .font(.subheadline)
                    .textSelection(.enabled)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .background(Color.primary.opacity(0.055), in: RoundedRectangle(cornerRadius: 11))
            }
            if !message.input.blocks.isEmpty {
                DisclosureGroup("Included passages and attachments: \(message.input.blocks.count)") {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(message.input.blocks) { block in sentInputBlock(block) }
                    }
                    .padding(.top, 6)
                }.font(.caption).foregroundStyle(.secondary)
            }
            if let answer = message.answer {
                HStack(spacing: 6) {
                    Image(systemName: "sparkles")
                    Text(verbatim: "Dogear")
                }
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
                .padding(.top, 2)
                ResearchSelectableText(text: answer,
                    sources: message.sourceSnapshot.filter { $0.fingerprint != "pending" },
                    evidence: message.evidence, onViewEvidence: onViewEvidence) { quote in
                        appendDiscussion(quote, message: message)
                    }
                HStack(spacing: 12) {
                    Button("Copy", systemImage: "doc.on.doc") { PlatformClipboard.copyText(answer) }
                    Button("Save as note", systemImage: "square.and.pencil") { saveNote(message, sessionID: sessionID) }
                    Menu {
                        Button("Quote answer and follow up") { appendDiscussion(answer, message: message) }
                    } label: { Image(systemName: "ellipsis") }.menuStyle(.borderlessButton).fixedSize()
                }
                .buttonStyle(.borderless)
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.vertical, 2)
                if message.origin == .localOutline {
                    Label("Local outline", systemImage: "leaf").font(.caption).foregroundStyle(.secondary)
                }
            }
            ForEach(message.evidence) { evidence in
                ResearchEvidenceRow(evidence: evidence, onView: onViewEvidence)
            }
            if !message.operationResults.isEmpty {
                DisclosureGroup("Source coverage and actions") {
                    ForEach(Array(message.operationResults.enumerated()), id: \.offset) { _, result in
                        Text(result).font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
                    }
                }.font(.caption)
            }
            ResearchContextSummaryView(message: message)
            if message.status != .accepted && message.status != .running {
                Label(statusTitle(message.status), systemImage: message.status == .failed ? "exclamationmark.circle" : "pause.circle")
                    .font(.caption).foregroundStyle(.secondary)
                if let error = message.errorMessage { Text(LocalizedStringKey(error)).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
                Button("Add this input to draft") {
                    mutateDraft { current in
                        if !message.input.text.isEmpty {
                            current.text += (current.text.isEmpty ? "" : "\n\n") + message.input.text
                        }
                        current.blocks += message.input.blocks.map { block in
                            var copied = block
                            copied.id = UUID()
                            return copied
                        }
                    }
                }
                    .font(.caption).buttonStyle(.borderless).disabled(running)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func composer(_ session: ResearchSession) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if !composerEditing.ownsEditor {
                HStack {
                    Text("This input is being edited in another window.").font(.caption).foregroundStyle(.secondary)
                    Spacer(minLength: 4)
                    Button("Edit here") { _ = composerEditing.takeOver() }.controlSize(.small)
                }
            }
            if let error = composerEditing.error {
                HStack {
                    Text(verbatim: error).font(.caption).foregroundStyle(.orange)
                    Button("Retry save") { _ = composerEditing.retrySave() }.controlSize(.small)
                }
            }
            let conflicts = store.composerConflicts.filter { $0.sessionID == session.id && !$0.isResolved }
            if !conflicts.isEmpty {
                Menu("Recover input", systemImage: "arrow.uturn.backward") {
                    ForEach(conflicts) { record in
                        Button { _ = composerEditing.restoreConflict(record.id) } label: {
                            Text(verbatim: String(record.text.prefix(80)))
                        }
                    }
                }.disabled(!composerEditing.ownsEditor).controlSize(.small)
            }
            if !store.saveFailures.isEmpty || !store.loadWarnings.isEmpty
                || runtime.jobs[session.id] != nil || runtime.errors[session.id] != nil {
                // Short status messages use only their natural height. Long
                // provider errors and expanded source details remain readable
                // in a bounded area without pushing the conversation away.
                ViewThatFits(in: .vertical) {
                    composerStatus(session).fixedSize(horizontal: false, vertical: true)
                    ScrollView(.vertical) {
                        composerStatus(session).fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxHeight: 120, alignment: .top)
                .id(session.id)
            }
            VStack(alignment: .leading, spacing: 6) {
                if !draft.blocks.isEmpty {
                    ScrollView {
                        LazyVStack(spacing: 6) {
                            ForEach(Array(draft.blocks.enumerated()), id: \.element.id) { index, block in inputBlock(block, index: index) }
                        }
                    }
                    .frame(maxHeight: compact ? 115 : 155)
                    .padding(.horizontal, 6)
                    .padding(.top, 6)
                }
                ResearchComposerLayout(text: draft.text, maximumHeight: compact ? 132 : 164) {
                    ResearchTextEditor(text: composerTextBinding(sessionID: session.id),
                        isEditable: composerEditing.ownsEditor,
                        placeholder: L10n.string("Ask a question, or leave empty for an outline…"),
                        onSubmit: { send() }, onPasteImage: importImage,
                        commands: composerCommands, identity: session.id,
                        composerEditing: composerEditing)
                        .id(session.id)
                }
                .frame(maxWidth: .infinity)
                composerActions(session)
                    .padding(.horizontal, 10)
                    .padding(.bottom, 9)
            }
            .padding(.top, 3)
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.primary.opacity(0.12)))
            if imagesNeedConfirmation {
                Label("Image support is unconfirmed or unavailable. Attachments will stay in your draft.", systemImage: "photo.badge.exclamationmark")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .padding(.bottom, 12)
    }

    private func composerStatus(_ session: ResearchSession) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if !store.saveFailures.isEmpty || !store.loadWarnings.isEmpty {
                HStack(alignment: .top) {
                    Label("Some research content needs attention.", systemImage: "exclamationmark.triangle")
                    Spacer()
                    Button("Retry save") { store.retryFailedSaves() }
                }.font(.caption).foregroundStyle(.orange)
            }
            if let progress = runtime.jobs[session.id] { progressView(progress, sessionID: session.id) }
            if let error = runtime.errors[session.id] {
                Text(LocalizedStringKey(error)).font(.caption).foregroundStyle(.red).textSelection(.enabled)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func composerActions(_ session: ResearchSession) -> some View {
        VStack(spacing: 9) {
            HStack(spacing: 10) {
                Menu {
                    Button("Add selected passage", systemImage: "text.quote", action: onAddSelection).disabled(currentFileID == nil)
                    Button("Capture PDF region", systemImage: "viewfinder", action: onCaptureRegion).disabled(currentFileID == nil)
                    Divider()
                    Button("Choose image…", systemImage: "photo", action: chooseImage)
                    Button("Paste image", systemImage: "doc.on.clipboard", action: pasteImage)
                } label: { Label("Add", systemImage: "plus") }
                .menuStyle(.borderlessButton)
                .font(.caption)
                .fixedSize()
                Spacer(minLength: 0)
                Toggle("Allow highlights", isOn: Binding(get: { runtime.sessionAllowsAnnotations(session.id) },
                    set: { runtime.setAllowsAnnotations($0, sessionID: session.id) }))
                    .toggleStyle(.checkbox).font(.caption).disabled(running || mainStore == nil)
                    .help("Only the explicit main PDF can receive highlights.")
            }
            HStack(spacing: 8) {
                Text("⌘ Return to send").font(.caption2).foregroundStyle(.tertiary)
                Spacer(minLength: 0)
                if imagesNeedConfirmation {
                    Button("Send text only") { send(textOnly: true) }
                        .buttonStyle(.borderless).font(.caption).disabled(!composerEditing.ownsEditor || running)
                }
                Button(action: { send() }) {
                    if draft.isEmpty {
                        Label(LocalizedStringKey(runtime.cloudAvailable ? "Create outline" : "Local outline"), systemImage: "arrow.up")
                            .font(.caption.weight(.medium))
                    } else {
                        Image(systemName: "arrow.up").font(.body.weight(.semibold)).frame(width: 16, height: 18)
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .clipShape(RoundedRectangle(cornerRadius: 7))
                .help(LocalizedStringKey(draft.isEmpty ? (runtime.cloudAvailable ? "Create outline" : "Local outline") : "Send"))
                .accessibilityLabel(LocalizedStringKey(draft.isEmpty ? (runtime.cloudAvailable ? "Create outline" : "Local outline") : "Send"))
                .disabled(!composerEditing.ownsEditor || running || imagesNeedConfirmation || (sourceIDs.isEmpty && draft.attachmentIDs.isEmpty))
            }
        }
    }

    private func progressView(_ progress: ResearchRequestProgress, sessionID: UUID) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                ProgressView().controlSize(.small)
                Text(progress.phase).font(.caption).lineLimit(2)
                Spacer(minLength: 0)
                Button("Cancel") { runtime.cancel(sessionID: sessionID) }.controlSize(.small)
            }
            TimelineView(.periodic(from: progress.startedAt, by: 1)) { context in
                Text("\(progress.preparedSources)/\(progress.totalSources) sources · \(Int(context.date.timeIntervalSince(progress.startedAt)))s · \(progress.providerTurns) turns")
                    .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
            }
            if !progress.skippedSources.isEmpty {
                DisclosureGroup("Skipped sources: \(progress.skippedSources.count)", isExpanded: Binding(
                    get: { expandedProgressRequestID == progress.requestID },
                    set: { expandedProgressRequestID = $0 ? progress.requestID : nil }
                )) {
                    ForEach(Array(progress.skippedSources.enumerated()), id: \.offset) { _, reason in Text(reason).font(.caption) }
                }.font(.caption)
            }
        }
    }

    private func inputBlock(_ block: ResearchInputBlock, index: Int) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .top, spacing: 6) {
                if let attachmentID = block.attachmentID ?? block.evidence?.attachmentID,
                   let attachment = store.attachments.first(where: { $0.id == attachmentID }),
                   let url = store.attachmentURL(id: attachmentID), let image = LocalImageDecoding.stillImage(at: url) {
                    Button { attachmentPreview = attachment } label: {
                        Image(decorative: image, scale: 1).resizable().scaledToFit().frame(width: 52, height: 42).clipShape(RoundedRectangle(cornerRadius: 4))
                    }.buttonStyle(.plain).accessibilityLabel("Preview image")
                } else {
                    Image(systemName: block.kind.isDiscussionBackground ? "quote.bubble" : "text.quote").foregroundStyle(.secondary)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(block.evidence?.source?.displayName ?? kindTitle(block.kind)).font(.caption.weight(.medium)).lineLimit(1)
                    if !block.text.isEmpty { Text(block.text).font(.caption).foregroundStyle(.secondary).lineLimit(2) }
                    if block.kind.isDiscussionBackground { Text("Discussion background").font(.caption2).foregroundStyle(.tertiary) }
                }
                Spacer(minLength: 0)
                Menu {
                    Button("Move up") { moveBlock(index, by: -1) }.disabled(index == 0)
                    Button("Move down") { moveBlock(index, by: 1) }.disabled(index == draft.blocks.count - 1)
                    if let evidence = block.evidence, evidence.source != nil {
                        Button("View source") { onViewEvidence(evidence) }
                    }
                    Button("Remove", role: .destructive) { mutateDraft { $0.blocks.removeAll { $0.id == block.id } } }
                } label: { Image(systemName: "ellipsis") }.menuStyle(.borderlessButton).fixedSize()
            }
            TextField("Add a note about this item…", text: Binding(
                get: { draft.blocks.first(where: { $0.id == block.id })?.explanation ?? "" },
                set: { text in mutateDraft { value in if let index = value.blocks.firstIndex(where: { $0.id == block.id }) { value.blocks[index].explanation = text } } }
            )).textFieldStyle(.plain).font(.caption)
        }
        .padding(8).background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 7))
    }

    private func sentInputBlock(_ block: ResearchInputBlock) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(block.evidence?.source?.displayName ?? kindTitle(block.kind)).font(.caption.weight(.semibold))
            if let id = block.attachmentID ?? block.evidence?.attachmentID,
               let attachment = store.attachments.first(where: { $0.id == id }),
               let url = store.attachmentURL(id: id), let image = LocalImageDecoding.stillImage(at: url) {
                Button { attachmentPreview = attachment } label: {
                    Image(decorative: image, scale: 1).resizable().scaledToFit().frame(maxHeight: 130)
                }.buttonStyle(.plain).accessibilityLabel("Preview image")
            }
            if !block.text.isEmpty { Text(block.text).font(.caption).textSelection(.enabled) }
            if !block.explanation.isEmpty { Text(block.explanation).font(.caption).italic().textSelection(.enabled) }
            if let evidence = block.evidence, evidence.source != nil {
                Button("View source") { onViewEvidence(evidence) }.buttonStyle(.borderless).font(.caption)
            }
            if block.kind.isDiscussionBackground { Text("Discussion background").font(.caption2).foregroundStyle(.tertiary) }
        }.frame(maxWidth: .infinity, alignment: .leading).padding(8)
            .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 6))
    }

    private func mutateSession(_ mutation: (inout ResearchSession) -> Void) {
        guard var value = session else { return }
        mutation(&value)
        store.updateSession(value)
    }
    private func mutateDraft(_ mutation: (inout ResearchDraft) -> Void) {
        guard let sessionID else { return }
        var value = draft
        mutation(&value)
        store.saveDraft(value, sessionID: sessionID)
    }
    private func setFile(_ fileID: UUID, included: Bool) {
        mutateSession { value in
            value.sourceSelection.fileIDs.removeAll { $0 == fileID }
            if included { value.sourceSelection.fileIDs.append(fileID) }
        }
    }
    private func moveBlock(_ index: Int, by delta: Int) {
        mutateDraft { value in
            let destination = index + delta
            guard value.blocks.indices.contains(index), value.blocks.indices.contains(destination) else { return }
            value.blocks.swapAt(index, destination)
        }
    }
    private func createSession() {
        guard composerEditing.prepareForTransition(), composerEditing.release() else { return }
        sessionID = store.createSession(title: L10n.string("New research"), sourceSelection: ResearchSourceSelection(fileIDs: currentFileID.map { [$0] } ?? []))
    }
    private func send(textOnly: Bool = false) {
        guard let sessionID, !running, textOnly || !imagesNeedConfirmation,
              composerEditing.sessionID == sessionID, composerEditing.ownsEditor,
              composerEditing.prepareForTransition() else { return }
        runtime.send(sessionID: sessionID, library: library, mainStore: mainStore, viewID: viewID, textOnly: textOnly)
    }

    private func bindComposer() {
        guard let sessionID else { return }
        let commands = composerCommands
        _ = composerEditing.bind(sessionID: sessionID, prepareNativeInput: {
            commands.finishEditing(identity: sessionID)
        })
    }

    private func selectSession(_ id: UUID) {
        guard composerEditing.prepareForTransition(), composerEditing.release() else { return }
        sessionID = id
    }

    private func composerTextBinding(sessionID: UUID) -> Binding<String> {
        Binding(get: {
            composerEditing.sessionID == sessionID ? composerEditing.text : store.session(id: sessionID)?.draft.text ?? ""
        }, set: { text in
            guard composerEditing.sessionID == sessionID else { return }
            _ = composerEditing.acceptNativeText(text)
        })
    }
    private func appendDiscussion(_ text: String, message: ResearchMessage) {
        let evidence = ResearchEvidence(source: nil, kind: .discussion, excerpt: text, messageID: message.id)
        mutateDraft { $0.blocks.append(ResearchInputBlock(kind: .discussion, text: text, evidence: evidence)) }
    }
    private func saveNote(_ message: ResearchMessage, sessionID: UUID) {
        guard let answer = message.answer else { return }
        let title = String((message.question.isEmpty ? L10n.string("Research note") : message.question).prefix(100))
        let provenance = ResearchNoteProvenance(origin: message.origin, sessionID: sessionID, messageID: message.id, evidence: message.evidence)
        let id = store.createNote(title: title, body: answer, provenance: [provenance], attachmentIDs: message.input.attachmentIDs)
        (workspaceOpenWindow ?? openWindow)(id: "research-note", value: id)
    }
    private func chooseImage() {
        guard imageImportRequest == nil, let sessionID, store.session(id: sessionID) != nil else { return }
        imageImportRequest = ResearchImageImportRequest(sessionID: sessionID)
        showingImageImporter = true
    }
    private func pasteImage() {
        guard let image = ResearchNativeTextView.image(from: .general) else {
            localError = L10n.string("The clipboard does not contain an image.")
            return
        }
        importImage(image.data, image.name)
    }
    private func importImage(_ data: Data, _ name: String) {
        guard let sessionID else { return }
        importImage(data, name, sessionID: sessionID)
    }
    private func importImage(_ data: Data, _ name: String, sessionID: UUID) {
        do { try ResearchImagePipeline.importImage(data: data, displayName: name, sessionID: sessionID, store: store) }
        catch { localError = error.localizedDescription }
    }
    private func importImageURL(_ url: URL, sessionID: UUID) {
        do {
            try ResearchImageImportRequest(sessionID: sessionID).importURL(url, store: store)
        } catch { localError = error.localizedDescription }
    }
    private func receiveDrop(_ providers: [NSItemProvider]) -> Bool {
        guard let sessionID else { return false }
        guard providers.count <= ResearchInputLimits.maximumImages else {
            localError = ResearchStoreError.invalidAttachment.localizedDescription
            return false
        }
        for provider in providers {
            if provider.canLoadObject(ofClass: NSURL.self) {
                provider.loadObject(ofClass: NSURL.self) { item, _ in
                    if let url = item as? URL { Task { @MainActor in importImageURL(url, sessionID: sessionID) } }
                }
            } else if let type = provider.registeredTypeIdentifiers.first(where: { UTType($0)?.conforms(to: .image) == true }) {
                provider.loadDataRepresentation(forTypeIdentifier: type) { data, _ in
                    if let data { Task { @MainActor in importImage(data, provider.suggestedName ?? L10n.string("Dropped image"), sessionID: sessionID) } }
                }
            }
        }
        return true
    }
    private func kindTitle(_ kind: ResearchSourceKind) -> String {
        switch kind {
        case .pdfText: return L10n.string("PDF passage")
        case .annotation: return L10n.string("Annotation")
        case .discussion: return L10n.string("Conversation quote")
        case .note: return L10n.string("Note quote")
        case .image: return L10n.string("Image")
        case .file: return L10n.string("File")
        case .group: return L10n.string("Group")
        }
    }
    private func statusTitle(_ status: ResearchRequestStatus) -> String {
        switch status {
        case .running: return L10n.string("Running")
        case .accepted: return L10n.string("Accepted")
        case .failed: return L10n.string("Failed — input kept")
        case .cancelled: return L10n.string("Canceled — input kept")
        case .interrupted: return L10n.string("Interrupted — resume explicitly")
        }
    }
}

struct ResearchEvidenceRow: View {
    let evidence: ResearchEvidence
    var onView: (ResearchEvidence) -> Void
    var body: some View {
        Button { onView(evidence) } label: {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 5) {
                    Image(systemName: evidence.kind == .image ? "photo" : "doc.text.magnifyingglass")
                    Text(evidence.source?.displayName ?? L10n.string("Image evidence")).lineLimit(1)
                    if let anchor = evidence.anchor { Text("p. \(anchor.pageIndex + 1)").monospacedDigit() }
                    Spacer(minLength: 0)
                    Image(systemName: "arrow.up.right").font(.caption2)
                }.font(.caption.weight(.medium))
                if !evidence.excerpt.isEmpty { Text(evidence.excerpt).font(.caption).foregroundStyle(.secondary).lineLimit(3) }
                if let source = evidence.source {
                    Text(source.fileID.uuidString.prefix(8)).font(.caption2.monospaced()).foregroundStyle(.tertiary)
                }
            }.frame(maxWidth: .infinity, alignment: .leading).padding(8)
                .background(Color.accentColor.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
        }.buttonStyle(.plain).accessibilityLabel("View evidence")
    }
}

struct ResearchAttachmentPreview: View {
    let attachment: ResearchAttachment
    @ObservedObject var store: ResearchStore
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Text(attachment.displayName).font(.headline)
                Spacer()
                Button("Done") { dismiss() }
            }
            if let url = store.attachmentURL(id: attachment.id), let image = LocalImageDecoding.stillImage(at: url) {
                Image(decorative: image, scale: 1).resizable().scaledToFit().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else { ContentUnavailableView("Image unavailable", systemImage: "photo.badge.exclamationmark") }
            Text("\(attachment.pixelWidth ?? 0) × \(attachment.pixelHeight ?? 0) · \(ByteCountFormatter.string(fromByteCount: Int64(attachment.byteCount), countStyle: .file))")
                .font(.caption).foregroundStyle(.secondary)
        }.padding(20).frame(minWidth: 420, idealWidth: 700, minHeight: 300, idealHeight: 550)
    }
}

/// Measure only the draft at its final available width. No deferred height state
/// feeds back into the conversation scroll view, and the native editor still
/// owns scrolling, marked text, image paste and Undo after reaching the cap.
private struct ResearchComposerLayout: Layout {
    let text: String
    let maximumHeight: CGFloat
    private let minimumHeight: CGFloat = 64

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let proposedWidth = proposal.width.flatMap { $0.isFinite ? $0 : nil } ?? 300
        let width = max(1, proposedWidth)
        let storage = NSTextStorage(string: text.isEmpty ? " " : text,
                                    attributes: [.font: NSFont.systemFont(ofSize: NSFont.systemFontSize)])
        let manager = NSLayoutManager()
        // Match ResearchTextEditor's 8-point insets and default line padding.
        // Reserve the legacy scroller width so an always-visible scrollbar
        // cannot make a last line overflow before the height cap is reached.
        let scrollerWidth = NSScroller.scrollerWidth(for: .regular, scrollerStyle: NSScroller.preferredScrollerStyle)
        let container = NSTextContainer(size: NSSize(width: max(1, width - 16 - scrollerWidth),
                                                     height: .greatestFiniteMagnitude))
        manager.addTextContainer(container)
        storage.addLayoutManager(manager)
        manager.ensureLayout(for: container)
        let usedHeight = manager.usedRect(for: container).height
        let trailingLineHeight = text.hasSuffix("\n") ? manager.defaultLineHeight(for: .systemFont(ofSize: NSFont.systemFontSize)) : 0
        let height = min(maximumHeight, max(minimumHeight, ceil(usedHeight + trailingLineHeight + 16)))
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for subview in subviews {
            subview.place(at: bounds.origin, anchor: .topLeading,
                          proposal: ProposedViewSize(width: bounds.width, height: bounds.height))
        }
    }
}
