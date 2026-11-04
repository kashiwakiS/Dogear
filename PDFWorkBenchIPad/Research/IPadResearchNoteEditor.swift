#if os(iOS)
import SwiftUI

@MainActor
struct IPadResearchNoteEditor: View {
    @ObservedObject var storage: ResearchStore
    let noteID: UUID
    let onShowEvidence: (ResearchEvidence) -> Void
    let onExport: (DocumentExportRequest) -> Void
    var onDiscussNote: (ResearchNote) -> Void = { _ in }
    @Environment(\.dismiss) private var dismiss
    @State private var editorID = UUID()
    @State private var ownsEditor = false
    @State private var showsPreview = false
    @State private var showsHistory = false
    @State private var pendingHistoryEvidence: ResearchEvidence?
    @State private var localError: String?
    @StateObject private var textCommands = IPadResearchTextEditingCommands()

    private var note: ResearchNote? { storage.note(id: noteID) }

    var body: some View {
        NavigationStack {
            if let note {
                VStack(alignment: .leading, spacing: 12) {
                    IPadResearchNativeTextEditor(text: binding(\.title), commands: textCommands,
                        identity: noteID,
                        isEditable: ownsEditor, isTitle: true,
                        onEditingBoundary: { storage.endNoteEditBurst(noteID: noteID) })
                        .frame(height: 52)
                    if note.verificationInvalidated {
                        Label("Edited after verification", systemImage: "pencil")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if !storage.saveFailures.isEmpty {
                        HStack {
                            Text("Some research content needs attention.")
                            Button("Retry save") { storage.retryFailedSaves() }
                        }.font(.caption).foregroundStyle(.orange)
                    }
                    if showsPreview {
                        ScrollView {
                            let context = ResearchNoteEvidenceContext(provenance: note.provenance, store: storage)
                            IPadResearchAnswer(markdown: note.body,
                                sources: context.sources, evidence: context.evidence, onShowEvidence: onShowEvidence)
                            ForEach(context.evidence) { evidence in
                                Button { onShowEvidence(evidence) } label: {
                                    Text(verbatim: evidence.source?.displayName ?? evidence.excerpt)
                                        .font(.caption).frame(maxWidth: .infinity, alignment: .leading)
                                }
                            }
                        }
                    } else {
                        IPadResearchNativeTextEditor(text: binding(\.body), commands: textCommands,
                            identity: noteID,
                            isEditable: ownsEditor,
                            onEditingBoundary: { storage.endNoteEditBurst(noteID: noteID) })
                            .id(noteID)
                    }
                    if !note.suggestions.isEmpty {
                        DisclosureGroup("Revision suggestions") {
                            ForEach(note.suggestions) { suggestion in
                                VStack(alignment: .leading) {
                                    Text(verbatim: suggestion.body).font(.caption).lineLimit(5)
                                    Button("Apply suggestion") {
                                        do { try storage.applySuggestion(id: suggestion.id, noteID: noteID) }
                                        catch { localError = error.localizedDescription }
                                    }.disabled(!ownsEditor || textCommands.hasMarkedText || suggestion.baseRevision != note.revision)
                                }
                            }
                        }
                    }
                    Button("Discuss note", systemImage: "text.bubble") {
                        guard textCommands.commitMarkedTextAndEndEditing(identity: noteID),
                              let current = storage.note(id: noteID) else { return }
                        storage.endNoteEditBurst(noteID: noteID)
                        onDiscussNote(current)
                        dismiss()
                    }
                    if !note.attachmentIDs.isEmpty || note.provenance.flatMap(\.evidence).contains(where: { $0.attachmentID != nil }) {
                        Text("Markdown export includes text and source references. Image files stay in Dogear.")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                    if !ownsEditor {
                        Text("This note is being edited in another view.").font(.caption).foregroundStyle(.secondary)
                    }
                }
                .padding()
                .navigationTitle("Research note")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button(showsPreview ? "Edit" : "Preview") {
                            guard textCommands.commitMarkedTextAndEndEditing(identity: noteID) else { return }
                            storage.endNoteEditBurst(noteID: noteID)
                            showsPreview.toggle()
                        }
                    }
                    ToolbarItemGroup(placement: .topBarTrailing) {
                        Button("Undo", systemImage: "arrow.uturn.backward") { textCommands.undo() }
                            .disabled(!ownsEditor || showsPreview || !textCommands.canUndo)
                            .accessibilityIdentifier("ipad.research.note.undo")
                        Button("Redo", systemImage: "arrow.uturn.forward") { textCommands.redo() }
                            .disabled(!ownsEditor || showsPreview || !textCommands.canRedo)
                            .accessibilityIdentifier("ipad.research.note.redo")
                        Button("Revision history", systemImage: "clock.arrow.circlepath") {
                            guard textCommands.commitMarkedTextAndEndEditing(identity: noteID) else { return }
                            storage.endNoteEditBurst(noteID: noteID)
                            showsHistory = true
                        }
                        .accessibilityIdentifier("ipad.research.note.history")
                        Button("Export text", systemImage: "square.and.arrow.up", action: exportNote)
                        Button("Done") {
                            guard textCommands.commitMarkedTextAndEndEditing(identity: noteID) else { return }
                            dismiss()
                        }
                    }
                }
            } else {
                ContentUnavailableView("Research note", systemImage: "doc.text",
                    description: Text("The research item could not be found."))
            }
        }
        .onAppear { ownsEditor = storage.claimNoteEditor(noteID: noteID, editorID: editorID) == editorID }
        .onDisappear {
            _ = textCommands.commitMarkedTextAndEndEditing(identity: noteID)
            ownsEditor = false
            storage.releaseNoteEditor(noteID: noteID, editorID: editorID)
        }
        .sheet(isPresented: $showsHistory, onDismiss: {
            guard let evidence = pendingHistoryEvidence else { return }
            pendingHistoryEvidence = nil
            onShowEvidence(evidence)
        }) { history }
        .alert("Research", isPresented: Binding(get: { localError != nil },
            set: { if !$0 { localError = nil } })) {
            Button("OK") { localError = nil }
        } message: { Text(verbatim: localError ?? "") }
    }

    private var history: some View {
        NavigationStack {
            if let note, !note.revisions.isEmpty {
                List(note.revisions.reversed()) { revision in
                    DisclosureGroup {
                        let context = ResearchNoteEvidenceContext(provenance: revision.provenance, store: storage)
                        IPadResearchAnswer(markdown: revision.body, sources: context.sources,
                            evidence: context.evidence, onShowEvidence: { evidence in
                                pendingHistoryEvidence = evidence
                                showsHistory = false
                            })
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Revision \(revision.number) · \(revision.title)")
                            Text(revision.createdAt, style: .date).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            } else {
                ContentUnavailableView("No earlier revisions", systemImage: "clock.arrow.circlepath")
            }
        }
        .navigationTitle("Revision history")
        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { showsHistory = false } } }
    }

    private func binding(_ keyPath: WritableKeyPath<ResearchNote, String>) -> Binding<String> {
        Binding(get: { note?[keyPath: keyPath] ?? "" }, set: { value in
            guard ownsEditor, var note = storage.note(id: noteID), note[keyPath: keyPath] != value else { return }
            note[keyPath: keyPath] = value
            _ = storage.updateNote(note, coalescingEdits: true)
        })
    }

    private func exportNote() {
        guard textCommands.commitMarkedTextAndEndEditing(identity: noteID) else { return }
        guard let note else { return }
        do {
            onExport(try IPadResearchTextExport.note(id: note.id, storage: storage))
        } catch { localError = error.localizedDescription }
    }
}
#endif
