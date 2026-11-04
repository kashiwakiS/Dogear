import AppKit
import SwiftUI

struct ResearchNoteEditorView: View {
    @ObservedObject private var languageStore = AppLanguageStore.shared
    let noteID: UUID
    @ObservedObject var store: ResearchStore
    var onViewEvidence: (ResearchEvidence) -> Void
    var onQuote: ((ResearchInputBlock) -> Void)?
    @Environment(\.openWindow) private var openWindow
    @State private var editorID = UUID()
    @State private var ownsEditor = true
    @State private var showSources = true
    @State private var showHistory = false
    @State private var preview = false
    @State private var error: String?
    @State private var suggestionToApply: ResearchNoteSuggestion?

    init(noteID: UUID, store: ResearchStore? = nil,
         onViewEvidence: @escaping (ResearchEvidence) -> Void = { _ in },
         onQuote: ((ResearchInputBlock) -> Void)? = nil) {
        self.noteID = noteID; self.store = store ?? .shared
        self.onViewEvidence = onViewEvidence; self.onQuote = onQuote
    }

    private var note: ResearchNote? { store.note(id: noteID) }
    private var saveFailed: Bool { store.saveFailures["notes/\(noteID.uuidString)"] != nil }

    var body: some View {
        Group {
            if let note {
                VStack(spacing: 0) {
                    titleBar(note)
                    Divider()
                    if !ownsEditor {
                        HStack {
                            Label("This note is already open in another editor.", systemImage: "macwindow.on.rectangle")
                            Button("Show editor") { ResearchNoteWindowRegistry.focus(noteID: noteID) }
                        }.font(.caption).padding(10)
                    }
                    if !note.suggestions.isEmpty { suggestions(note) }
                    if preview {
                        ScrollView {
                            contentPreview(note.content, provenance: note.provenance, onQuote: quote)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(12)
                        }
                    } else {
                        contentEditor(note)
                    }
                    if showSources && !note.provenance.flatMap(\.evidence).isEmpty {
                        Divider()
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 6) {
                                Text("Sources").font(.caption.weight(.semibold))
                                ForEach(uniqueEvidence(note)) { evidence in ResearchEvidenceRow(evidence: evidence, onView: onViewEvidence) }
                            }.padding(12)
                        }.frame(maxHeight: 200)
                    }
                    Divider()
                    HStack {
                        if saveFailed {
                            Label("Not saved — your edits are kept in memory", systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                            Button("Retry save") { store.retryFailedSaves() }
                        } else { Label("Saved locally", systemImage: "checkmark.circle").foregroundStyle(.secondary) }
                        Spacer()
                        Text("Revision \(note.revision)").foregroundStyle(.secondary)
                        if note.verificationInvalidated {
                            Image(systemName: "pencil.circle").help("Edited content does not inherit the original AI verification.")
                        }
                    }.font(.caption).padding(10)
                }
            } else {
                ContentUnavailableView("Note unavailable", systemImage: "note.text", description: Text("This note may have been deleted."))
            }
        }
        .frame(minWidth: 440, minHeight: 360)
        .navigationTitle(Text(verbatim: note?.title ?? L10n.string("Research Note")))
        .background(ResearchNoteWindowReader { window in
            if ownsEditor { ResearchNoteWindowRegistry.register(window, noteID: noteID, editorID: editorID) }
            else { ResearchNoteWindowRegistry.focus(noteID: noteID) }
        })
        .onAppear {
            ownsEditor = store.claimNoteEditor(noteID: noteID, editorID: editorID) == editorID
            if !ownsEditor { ResearchNoteWindowRegistry.focus(noteID: noteID) }
        }
        .onDisappear {
            store.releaseNoteEditor(noteID: noteID, editorID: editorID)
            ResearchNoteWindowRegistry.remove(noteID: noteID, editorID: editorID)
        }
        .sheet(isPresented: $showHistory) { history.environment(\.locale, languageStore.locale) }
        .alert("Research note", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("OK") { error = nil }
        } message: { Text(LocalizedStringKey(error ?? "")) }
        .confirmationDialog("Apply this suggested version?", isPresented: Binding(
            get: { suggestionToApply != nil }, set: { if !$0 { suggestionToApply = nil } }
        ), titleVisibility: .visible) {
            Button("Apply suggestion") {
                if let suggestion = suggestionToApply {
                    do { try store.applySuggestion(id: suggestion.id, noteID: noteID) }
                    catch { self.error = error.localizedDescription }
                }
                suggestionToApply = nil
            }
        } message: { Text("The current note is retained in revision history.") }
    }

    private func titleBar(_ note: ResearchNote) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField("Note title", text: Binding(get: { self.note?.title ?? "" }, set: { title in edit { $0.title = title } }))
                .textFieldStyle(.plain).font(.title2.weight(.semibold)).disabled(!ownsEditor)
            HStack {
                Picker("View", selection: $preview) {
                    Text("Edit").tag(false)
                    Text("Preview").tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .accessibilityLabel(Text("View"))
                .frame(width: 160)
                .fixedSize(horizontal: true, vertical: true)
                Spacer()
                Toggle(isOn: $showSources) { Image(systemName: "doc.text.magnifyingglass") }
                    .toggleStyle(.button).help("Show sources")
                Button { showHistory = true } label: { Image(systemName: "clock.arrow.circlepath") }
                    .help("Revision history")
                Button { exportNote() } label: { Label("Export", systemImage: "square.and.arrow.up") }
            }.controlSize(.small)
        }.padding(16)
    }

    private func suggestions(_ note: ResearchNote) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(note.suggestions) { suggestion in
                DisclosureGroup {
                    ScrollView {
                        contentPreview(suggestion.content, provenance: suggestion.provenance)
                    }.frame(maxHeight: 220)
                    HStack {
                        if suggestion.baseRevision != note.revision {
                            Text("The note changed since this suggestion. Create a new suggestion for the latest revision.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Apply suggestion") { suggestionToApply = suggestion }
                            .disabled(!ownsEditor || suggestion.baseRevision != note.revision)
                    }
                } label: { Label("Suggested revision", systemImage: "pencil.and.outline") }
            }
        }.padding(12).background(Color.accentColor.opacity(0.05))
    }

    private var history: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Revision history").font(.headline)
                Spacer()
                Button("Done") { showHistory = false }
            }
            if let note, !note.revisions.isEmpty {
                List(note.revisions.reversed()) { revision in
                    DisclosureGroup {
                        contentPreview(revision.content, provenance: revision.provenance,
                            onQuote: { text in quote(text, revision: revision.number) })
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Revision \(revision.number) · \(revision.title)")
                            Text(revision.createdAt, style: .date).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            } else {
                ContentUnavailableView("No earlier revisions", systemImage: "clock.arrow.circlepath")
            }
        }.padding(20).frame(width: 580, height: 450)
    }

    @ViewBuilder
    private func contentEditor(_ note: ResearchNote) -> some View {
        switch note.content {
        case .markdown:
            ResearchTextEditor(
                text: Binding(
                    get: {
                        switch self.note?.content ?? note.content {
                        case .markdown(let markdown): return markdown
                        }
                    },
                    set: { markdown in edit { $0.content = .markdown(markdown) } }
                ),
                isEditable: ownsEditor,
                placeholder: L10n.string("Write your research note in Markdown…"),
                onQuote: quote,
                onEditingBoundary: { store.endNoteEditBurst(noteID: noteID) }
            )
            .id(noteID)
        }
    }

    private func contentPreview(
        _ content: ResearchNoteContent,
        provenance: [ResearchNoteProvenance],
        onQuote: ((String) -> Void)? = nil
    ) -> some View {
        ResearchNoteContentPreview(
            content: content,
            sources: citationSources(for: provenance),
            evidence: uniqueEvidence(provenance),
            onViewEvidence: onViewEvidence,
            onQuote: onQuote
        )
    }

    private func citationSources(for provenance: [ResearchNoteProvenance]) -> [ResearchSourceSnapshot] {
        ResearchNoteEvidenceContext(provenance: provenance, store: store).sources
    }

    private func edit(_ mutation: (inout ResearchNote) -> Void) {
        guard ownsEditor, var note else { return }
        mutation(&note)
        _ = store.updateNote(note, coalescingEdits: true)
    }
    private func uniqueEvidence(_ note: ResearchNote) -> [ResearchEvidence] {
        uniqueEvidence(note.provenance)
    }
    private func uniqueEvidence(_ provenance: [ResearchNoteProvenance]) -> [ResearchEvidence] {
        ResearchNoteEvidenceContext(provenance: provenance, store: store).evidence
    }
    private func quote(_ text: String) { quote(text, revision: note?.revision ?? 1) }
    private func quote(_ text: String, revision: Int) {
        let evidence = ResearchEvidence(source: nil, kind: .note, excerpt: text, noteID: noteID, noteRevision: revision)
        let block = ResearchInputBlock(kind: .note, text: text, evidence: evidence)
        if let onQuote { onQuote(block) }
        else {
            let id = store.createSession(title: note?.title ?? L10n.string("Research note"),
                sourceSelection: ResearchSourceSelection(fileIDs: Array(note?.relatedFileIDs ?? [])))
            store.saveDraft(ResearchDraft(blocks: [block]), sessionID: id)
            openWindow(id: "research-session", value: id)
        }
    }
    private func exportNote() {
        do { try ResearchExportUI.exportNote(id: noteID, store: store) }
        catch { self.error = error.localizedDescription }
    }
}

/// A renderer has no editor ownership or window lifecycle. Multiple previews
/// can show one note while its existing store continues to own edits/revisions.
struct ResearchNoteContentPreview: View {
    let content: ResearchNoteContent
    var sources: [ResearchSourceSnapshot] = []
    var evidence: [ResearchEvidence] = []
    var onViewEvidence: ((ResearchEvidence) -> Void)? = nil
    var onQuote: ((String) -> Void)? = nil

    var body: some View {
        switch content {
        case .markdown(let markdown):
            ResearchSelectableText(text: markdown, sources: sources, evidence: evidence,
                onViewEvidence: onViewEvidence, onQuote: onQuote)
        }
    }
}

@MainActor
private enum ResearchNoteWindowRegistry {
    private final class Entry {
        weak var window: NSWindow?
        let editorID: UUID
        init(window: NSWindow, editorID: UUID) { self.window = window; self.editorID = editorID }
    }
    private static var windows: [UUID: Entry] = [:]
    static func register(_ window: NSWindow, noteID: UUID, editorID: UUID) { windows[noteID] = Entry(window: window, editorID: editorID) }
    static func focus(noteID: UUID) { windows[noteID]?.window?.makeKeyAndOrderFront(nil) }
    static func remove(noteID: UUID, editorID: UUID) { if windows[noteID]?.editorID == editorID { windows[noteID] = nil } }
}

private struct ResearchNoteWindowReader: NSViewRepresentable {
    let onWindow: (NSWindow) -> Void
    func makeNSView(context: Context) -> WindowView {
        let view = WindowView()
        view.onWindow = onWindow
        return view
    }
    func updateNSView(_ nsView: WindowView, context: Context) { nsView.onWindow = onWindow }
    final class WindowView: NSView {
        var onWindow: ((NSWindow) -> Void)?
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window else { return }
            DispatchQueue.main.async { [weak self, weak window] in if let window { self?.onWindow?(window) } }
        }
    }
}
