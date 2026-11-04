#if os(iOS)
import SwiftUI

struct IPadDocumentWorkspace: View {
    @ObservedObject var workspace: IPadGroupWorkspace
    @ObservedObject var services: IPadApplicationServices
    @ObservedObject var library: LibraryStore
    @ObservedObject private var exporter: IPadDocumentExportPresenter
    @ObservedObject private var feedback: OperationFeedbackCenter
    @ObservedObject private var noteRecovery: IPadInlineNoteDraftRecovery
    @ObservedObject private var highlightRecovery: IPadHighlightDraftRecovery
    @ObservedObject private var researchPresentation: IPadResearchPresentation
    let windowSize: CGSize
    let isPresentationActive: Bool
    @State private var prepareResearchSwitch: (() -> Bool)?
    @State private var researchPreparationToken: UUID?
    @State private var evidenceError: String?
    @State private var pendingExportAction: (() -> Void)?
    @State private var confirmsDraftDiscard = false
    @State private var draftDiscardPermit: IPadInlineNoteDraftRecovery.DiscardPermit?
    @State private var confirmsHighlightDraftDiscard = false
    @State private var highlightDiscardPermit: IPadHighlightDraftRecovery.DiscardPermit?
    init(workspace: IPadGroupWorkspace, services: IPadApplicationServices, library: LibraryStore,
         windowSize: CGSize = .zero, isPresentationActive: Bool = true) {
        self.workspace = workspace; self.services = services; self.library = library
        self.isPresentationActive = isPresentationActive
        self.windowSize = windowSize; researchPresentation = workspace.researchPresentation
        exporter = workspace.export; feedback = workspace.feedback
        noteRecovery = workspace.noteDraftRecovery
        highlightRecovery = workspace.highlightDraftRecovery
    }
    var body: some View {
        VStack(spacing: 0) {
            if let error = noteRecovery.lastError {
                IPadAnnotationDraftRecoveryNotice(message: error,
                    canRestore: workspace.highlightEditingSession == nil,
                    canDiscard: workspace.inlineNoteSession == nil && noteRecovery.candidates.count <= 1,
                    candidates: noteRecovery.candidates, onSelect: { candidate in
                        guard isPresentationActive, workspace.state.isActive, !workspace.state.isClosed,
                              workspace.highlightEditingSession == nil else { return }
                        if noteRecovery.selectCandidate(candidate) { workspace.restoreInlineNoteIfNeeded() }
                    },
                    onRetry: { workspace.restoreInlineNoteIfNeeded() }, onDiscard: {
                            guard workspace.state.isActive, !workspace.state.isClosed,
                                  let permit = noteRecovery.captureDiscardPermit() else { return }
                            draftDiscardPermit = permit; confirmsDraftDiscard = true
                    }).accessibilityIdentifier("ipad.note.recovery.error")
            }
            if let error = highlightRecovery.lastError {
                IPadAnnotationDraftRecoveryNotice(message: error,
                    canRestore: workspace.inlineNoteSession == nil,
                    canDiscard: workspace.highlightEditingSession == nil && highlightRecovery.candidates.count <= 1,
                    candidates: highlightRecovery.candidates, onSelect: { candidate in
                        guard isPresentationActive, workspace.state.isActive, !workspace.state.isClosed,
                              workspace.inlineNoteSession == nil else { return }
                        if highlightRecovery.selectCandidate(candidate) { workspace.restoreHighlightIfNeeded() }
                    },
                    onRetry: { workspace.restoreHighlightIfNeeded() }, onDiscard: {
                        guard workspace.state.isActive, !workspace.state.isClosed,
                              let permit = highlightRecovery.captureDiscardPermit() else { return }
                        highlightDiscardPermit = permit; confirmsHighlightDraftDiscard = true
                    }).accessibilityIdentifier("ipad.highlight.recovery.error")
            }
            HStack(spacing: 0) {
                IPadResearchWorkspacePanes(showsResearch: workspace.showsResearch,
                    presentation: researchPresentation, windowSize: windowSize,
                    isPresentationActive: isPresentationActive) { readerVisible in
                    IPadReaderView(workspace: workspace, store: workspace.document, library: library,
                        isPresentationActive: readerVisible && isPresentationActive,
                        onInteraction: { services.commands.userDidInteract(viewID: workspace.state.id) })
                } research: {
                  IPadResearchView(library: library, documentStore: workspace.document,
                    storage: services.research, runtime: services.runtime,
                    groupID: workspace.state.groupID, viewID: workspace.state.id,
                    isPresentationActive: isPresentationActive && workspace.showsResearch,
                    onInteraction: { services.commands.userDidInteract(viewID: workspace.state.id) },
                    onShowEvidence: showEvidence, onExport: { request in
                        exporter.export(request) { result in
                            if case .failure(let error) = result { evidenceError = error.localizedDescription }
                        }
                    }, onPreparePresentationChange: registerResearchPreparation)
                }
                Divider()
                workspaceRail
            }
            if let message = feedback.currentFeedback {
                Text(verbatim: message.message).font(.caption).foregroundStyle(message.kind == .error ? .red : .secondary)
                    .padding(8).frame(maxWidth: .infinity).background(.regularMaterial)
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            if isPresentationActive { IPadResearchCommands.register(workspace: workspace, library: library, commands: services.commands) }
        }
        .onChange(of: isPresentationActive) { _, active in
            if active { IPadResearchCommands.register(workspace: workspace, library: library, commands: services.commands) }
        }
        .onDisappear {
            workspace.cancelEvidencePreview(); confirmsDraftDiscard = false; draftDiscardPermit = nil
            confirmsHighlightDraftDiscard = false; highlightDiscardPermit = nil
            if let token = researchPreparationToken { workspace.unregisterResearchPresentationPreparation(token) }
            researchPreparationToken = nil; prepareResearchSwitch = nil
        }
        .onChange(of: workspace.document.document.map(ObjectIdentifier.init)) { _, _ in
            confirmsDraftDiscard = false; draftDiscardPermit = nil
            confirmsHighlightDraftDiscard = false; highlightDiscardPermit = nil
        }
        .sheet(item: Binding(get: { exporter.ticket }, set: { if $0 == nil, let ticket = exporter.ticket { exporter.finish(ticket.id, result: .success(nil)) } })) { ticket in
            IPadExportPicker(ticket: ticket, presenter: exporter)
        }
        .sheet(item: $workspace.reference) { preview in
            IPadReferenceReader(preview: preview, onInteraction: {
                services.commands.userDidInteract(viewID: workspace.state.id)
            }, onClose: { workspace.cancelEvidencePreview() }).id(preview.id)
        }
        .sheet(item: Binding(get: { workspace.document.pendingExportOptions }, set: { workspace.document.pendingExportOptions = $0 }), onDismiss: {
            let action = pendingExportAction; pendingExportAction = nil; action?()
        }) { request in
            IPadExportOptionsView(request: request) { result in
                if let result { pendingExportAction = { request.onConfirm(result) } }
                workspace.document.pendingExportOptions = nil
            }
        }
        .alert("Evidence unavailable", isPresented: Binding(get: { evidenceError != nil }, set: { if !$0 { evidenceError = nil } })) { Button("OK") { evidenceError = nil } } message: { Text(verbatim: evidenceError ?? "") }
        .confirmationDialog("Discard saved note draft?", isPresented: $confirmsDraftDiscard, titleVisibility: .visible) {
            Button("Discard saved draft", role: .destructive) {
                guard workspace.state.isActive, !workspace.state.isClosed,
                      let permit = draftDiscardPermit else { return }
                _ = noteRecovery.discardSavedDraft(using: permit); draftDiscardPermit = nil
            }
            Button("Keep draft", role: .cancel) { draftDiscardPermit = nil }
        } message: { Text("This removes the unfinished editor text. Saved PDF annotations are kept.") }
        .confirmationDialog("Discard saved highlight draft?", isPresented: $confirmsHighlightDraftDiscard, titleVisibility: .visible) {
            Button("Discard saved draft", role: .destructive) {
                guard workspace.state.isActive, !workspace.state.isClosed,
                      let permit = highlightDiscardPermit else { return }
                _ = highlightRecovery.discardSavedDraft(using: permit); highlightDiscardPermit = nil
            }
            Button("Keep draft", role: .cancel) { highlightDiscardPermit = nil }
        } message: { Text("This removes the unfinished editor text. Saved PDF annotations are kept.") }
    }
    private var workspaceRail: some View {
        VStack(spacing: 4) {
            railButton("Reader", icon: "doc.text", selected: !workspace.showsResearch,
                identifier: "ipad.workspace.reader") { switchWorkspace(toResearch: false) }
            railButton("Research", icon: "text.bubble", selected: workspace.showsResearch,
                identifier: "ipad.workspace.research") { switchWorkspace(toResearch: true) }
            if workspace.showsResearch {
                let width = researchPresentation.resolvedWidth(windowSize: windowSize)
                railButton(width == .sidebar ? "Full width" : "Sidebar",
                    icon: width == .sidebar ? "arrow.up.left.and.arrow.down.right" : "sidebar.right",
                    selected: false, identifier: "ipad.workspace.research.width") {
                    guard isPresentationActive, workspace.state.isActive, !workspace.state.isClosed else { return }
                    services.commands.userDidInteract(viewID: workspace.state.id)
                    researchPresentation.toggleWidth(windowSize: windowSize)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.top, 4).frame(width: 52)
        .background(Color(uiColor: .secondarySystemBackground))
        .accessibilityIdentifier("ipad.workspace.rail")
    }

    private func railButton(_ title: LocalizedStringKey, icon: String, selected: Bool,
                            identifier: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 2) {
                Image(systemName: icon).font(.system(size: 18))
                Text(title).font(.system(size: 9)).lineLimit(1)
            }
            .frame(width: 44, height: 44)
            .foregroundStyle(selected ? Color.accentColor : .secondary)
            .background(selected ? Color.accentColor.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain).accessibilityLabel(title).accessibilityIdentifier(identifier)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func switchWorkspace(toResearch: Bool) {
        guard isPresentationActive, workspace.state.isActive, !workspace.state.isClosed,
              workspace.showsResearch != toResearch else { return }
        if toResearch {
            guard workspace.inlineNoteSession?.finishIME() != false, workspace.flushHighlight() else { return }
        } else {
            guard let prepareResearchSwitch, prepareResearchSwitch() else { return }
        }
        services.commands.userDidInteract(viewID: workspace.state.id)
        if toResearch { researchPresentation.recordResearchOpened() }
        workspace.showsResearch = toResearch
    }

    private func registerResearchPreparation(_ prepare: @escaping () -> Bool) {
        if let token = researchPreparationToken { workspace.unregisterResearchPresentationPreparation(token) }
        prepareResearchSwitch = prepare
        researchPreparationToken = workspace.registerResearchPresentationPreparation(prepare)
    }
    private func showEvidence(_ evidence: ResearchEvidence) {
        services.commands.userDidInteract(viewID: workspace.state.id)
        evidenceError = nil
        workspace.beginEvidencePreview(resolve: {
            try await ResearchEvidenceResolver.resolve(evidence, library: library)
        }, title: evidence.source?.displayName ?? L10n.string("Evidence"),
            onError: { evidenceError = $0 })
    }
}

private struct IPadAnnotationDraftRecoveryNotice: View {
    let message: String
    let canRestore: Bool
    let canDiscard: Bool
    let candidates: [AnnotationDraftCandidate]
    let onSelect: (AnnotationDraftCandidate) -> Void
    let onRetry: () -> Void
    let onDiscard: () -> Void
    var body: some View {
        HStack {
            Text(verbatim: message).font(.caption).foregroundStyle(.red)
            Button("Retry", action: onRetry).frame(minWidth: 44, minHeight: 44).disabled(!canRestore)
            if !candidates.isEmpty {
                Menu("Review drafts") {
                    ForEach(candidates) { candidate in
                        Button { onSelect(candidate) } label: {
                            Text(verbatim: candidate.text.map { String($0.prefix(100)) } ?? candidate.url.lastPathComponent)
                            if let page = candidate.pageIndex { Text("Page \(page + 1)") }
                            if let date = candidate.updatedAt { Text(date, style: .date) }
                        }
                    }
                }.frame(minHeight: 44).disabled(!canRestore)
            }
            if canDiscard {
                Button("Discard saved draft", role: .destructive, action: onDiscard).frame(minWidth: 44, minHeight: 44)
            }
        }.padding(.horizontal, 10)
    }
}

/// Keep the evidence navigation command stable through parent updates. Scrolling
/// a detached preview is user takeover just as scrolling the editing reader is.
private struct IPadReferenceReader: View {
    let preview: IPadReferencePreview
    let onInteraction: () -> Void
    let onClose: () -> Void
    @State private var navigation: PDFReaderUIKitNavigation
    init(preview: IPadReferencePreview, onInteraction: @escaping () -> Void, onClose: @escaping () -> Void) {
        self.preview = preview; self.onInteraction = onInteraction; self.onClose = onClose
        _navigation = State(initialValue: .init(document: preview.document, pageIndex: preview.pageIndex, bounds: preview.bounds))
    }
    var body: some View {
        NavigationStack {
            PDFReaderUIKitView(document: preview.document, navigation: navigation, onUserInteraction: onInteraction)
                .navigationTitle(preview.title).navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { onInteraction(); onClose() } } }
        }
    }
}

#endif
