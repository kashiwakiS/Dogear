import AppKit
import SwiftUI

private enum ResearchLibrarySelection: Hashable {
    case session(UUID), note(UUID)
}

private struct ResearchLibrarySource: Identifiable {
    var id: UUID
    var name: String
}

struct ResearchLibraryView: View {
    @ObservedObject private var languageStore = AppLanguageStore.shared
    @ObservedObject var store: ResearchStore
    @ObservedObject var runtime: ResearchRuntime
    @ObservedObject var library: LibraryStore
    var onOpenSession: (UUID) -> Void
    var onViewEvidence: (ResearchEvidence) -> Void
    @Environment(\.openWindow) private var openWindow
    @State private var searchText = ""
    @State private var filterFileID: UUID?
    @State private var selection: ResearchLibrarySelection?
    @State private var selectedSessionID: UUID?
    @State private var viewID = UUID()
    @State private var pendingDelete: ResearchLibrarySelection?
    @State private var renaming: ResearchLibrarySelection?
    @State private var renameText = ""
    @State private var error: String?
    @State private var showingStorage = false
    @State private var confirmCleanup = false

    init(store: ResearchStore? = nil, runtime: ResearchRuntime? = nil, library: LibraryStore,
         onOpenSession: @escaping (UUID) -> Void,
         onViewEvidence: @escaping (ResearchEvidence) -> Void = { _ in }) {
        self.store = store ?? .shared; self.runtime = runtime ?? .shared; self.library = library
        self.onOpenSession = onOpenSession; self.onViewEvidence = onViewEvidence
    }

    private var sessions: [ResearchSession] {
        store.sessions.filter { session in
            let groupMembers = session.sourceSelection.groupID.map { library.files(in: $0).map(\.id) } ?? []
            return (filterFileID.map { session.relatedFileIDs.union(groupMembers).contains($0) } ?? true)
                && (searchText.isEmpty || session.title.localizedCaseInsensitiveContains(searchText)
                    || session.messages.contains { $0.question.localizedCaseInsensitiveContains(searchText) })
        }.sorted { $0.updatedAt > $1.updatedAt }
    }
    private var sourceOptions: [ResearchLibrarySource] {
        var names = Dictionary(uniqueKeysWithValues: library.allFiles.map { ($0.id, $0.displayName) })
        let historical = store.sessions.flatMap { $0.messages.flatMap(\.sourceSnapshot) }
            + store.notes.flatMap { $0.provenance.flatMap { $0.evidence.compactMap(\.source) } }
        for source in historical where names[source.fileID] == nil { names[source.fileID] = source.displayName }
        return names.map { ResearchLibrarySource(id: $0.key, name: $0.value) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
    private var notes: [ResearchNote] {
        store.notes.filter { note in
            (filterFileID.map { note.relatedFileIDs.contains($0) } ?? true)
                && (searchText.isEmpty || note.title.localizedCaseInsensitiveContains(searchText)
                    || note.body.localizedCaseInsensitiveContains(searchText))
        }.sorted { $0.updatedAt > $1.updatedAt }
    }

    var body: some View {
        NavigationSplitView {
            VStack(spacing: 0) {
                Picker("Source", selection: $filterFileID) {
                    Text("All sources").tag(nil as UUID?)
                    ForEach(sourceOptions) { source in Text(source.name + " · " + source.id.uuidString.prefix(8)).tag(Optional(source.id)) }
                }.padding(12)
                List(selection: $selection) {
                    Section("Sessions") {
                        ForEach(sessions) { session in
                            sessionRow(session).tag(ResearchLibrarySelection.session(session.id))
                                .contextMenu {
                                    Button("Open session") { onOpenSession(session.id) }
                                    Button("Rename…") { rename(.session(session.id), title: session.title) }
                                    Button("Export Markdown…") { export(.session(session.id)) }
                                    Divider()
                                    Button("Delete session…", role: .destructive) { pendingDelete = .session(session.id) }
                                }
                        }
                    }
                    Section("Notes") {
                        ForEach(notes) { note in
                            noteRow(note).tag(ResearchLibrarySelection.note(note.id))
                                .contextMenu {
                                    Button("Open note") { openWindow(id: "research-note", value: note.id) }
                                    Button("Rename…") { rename(.note(note.id), title: note.title) }
                                    Button("Export Markdown…") { export(.note(note.id)) }
                                    Divider()
                                    Button("Delete note…", role: .destructive) { pendingDelete = .note(note.id) }
                                }
                        }
                    }
                }
                .searchable(text: $searchText, prompt: "Find research")
                .overlay {
                    if sessions.isEmpty && notes.isEmpty && (!searchText.isEmpty || filterFileID != nil) {
                        ContentUnavailableView.search(text: searchText)
                    }
                }
                Divider()
                HStack {
                    Text("\(store.sessions.count) sessions · \(store.notes.count) notes").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button { showingStorage = true } label: { Image(systemName: "internaldrive") }
                        .buttonStyle(.borderless).help("Research storage")
                }.padding(10)
            }.navigationSplitViewColumnWidth(min: 230, ideal: 280, max: 360)
        } detail: {
            VStack(spacing: 0) {
                if !store.saveFailures.isEmpty || !store.loadWarnings.isEmpty {
                    HStack {
                        Label("Some research content needs attention.", systemImage: "exclamationmark.triangle")
                        Spacer()
                        Button("Details") { showingStorage = true }
                        Button("Retry save") { store.retryFailedSaves() }
                    }.font(.caption).padding(12).background(Color.orange.opacity(0.08))
                }
                detail
            }
        }
        .navigationTitle(Text(verbatim: L10n.string("Research")))
        .toolbar {
            ToolbarItemGroup {
                Button("New session", systemImage: "plus.bubble") { createSession() }
                Button("New note", systemImage: "square.and.pencil") { createNote() }
            }
        }
        .onChange(of: selection) { _, value in
            if case .session(let id) = value { selectedSessionID = id }
        }
        .onChange(of: selectedSessionID) { _, value in
            if let value { selection = .session(value) }
        }
        .confirmationDialog("Delete this research item?", isPresented: Binding(
            get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }
        ), titleVisibility: .visible) {
            Button("Delete", role: .destructive) { deletePending() }
        } message: {
            Text("This deletes the selected research item. Source PDFs, PDF annotations, and other research items are kept.")
        }
        .sheet(isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            VStack(alignment: .leading, spacing: 16) {
                Text("Rename research item").font(.headline)
                TextField("Title", text: $renameText).textFieldStyle(.roundedBorder).onSubmit(commitRename)
                HStack {
                    Spacer()
                    Button("Cancel") { renaming = nil }
                    Button("Save", action: commitRename).keyboardShortcut(.defaultAction)
                        .disabled(renameText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }.padding(20).frame(width: 400)
                .environment(\.locale, languageStore.locale)
        }
        .sheet(isPresented: $showingStorage) { storageDetails.environment(\.locale, languageStore.locale) }
        .alert("Research", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("OK") { error = nil }
        } message: { Text(LocalizedStringKey(error ?? "")) }
    }

    @ViewBuilder private var detail: some View {
        switch selection {
        case .session(let id):
            if store.session(id: id) != nil {
                ResearchPanelView(store: store, runtime: runtime, library: library, sessionID: $selectedSessionID,
                    currentFileID: nil, mainStore: nil, viewID: viewID, compact: false,
                    onAddSelection: {}, onCaptureRegion: {}, onViewEvidence: onViewEvidence,
                    onShowLibrary: {}, onToggleWide: { onOpenSession(id) })
                    .id(id)
            } else { emptyDetail }
        case .note(let id):
            if let note = store.note(id: id) {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text(note.title).font(.title2.weight(.semibold))
                        Spacer()
                        Button("Edit note") { openWindow(id: "research-note", value: id) }.buttonStyle(.borderedProminent)
                        Menu {
                            Button("Rename…") { rename(.note(id), title: note.title) }
                            Button("Export Markdown…") { export(.note(id)) }
                            Button("Delete note…", role: .destructive) { pendingDelete = .note(id) }
                        } label: { Image(systemName: "ellipsis") }
                    }
                    ScrollView {
                        VStack(alignment: .leading, spacing: 12) {
                            ResearchSelectableText(text: note.body, onQuote: { quote in quoteNote(quote, note: note) })
                            ForEach(uniqueEvidence(note)) { evidence in ResearchEvidenceRow(evidence: evidence, onView: onViewEvidence) }
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }
                }.padding(20)
            } else { emptyDetail }
        case nil: emptyDetail
        }
    }

    private var emptyDetail: some View {
        ContentUnavailableView {
            Label("Your research, together", systemImage: "books.vertical")
        } description: {
            Text("Sessions and independent notes remain available after closing your PDFs.")
        } actions: {
            HStack {
                Button("New session", action: createSession)
                Button("New note", action: createNote)
            }
        }
    }

    private func sessionRow(_ session: ResearchSession) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "text.bubble").foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 3) {
                Text(session.title).lineLimit(2)
                Text(session.updatedAt, style: .date).font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            if runtime.jobs[session.id] != nil { ProgressView().controlSize(.mini) }
            else if !session.draft.isEmpty { Image(systemName: "pencil.tip").font(.caption).foregroundStyle(.secondary).help("Unsent draft") }
        }.padding(.vertical, 3)
    }

    private func noteRow(_ note: ResearchNote) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "note.text").foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 3) {
                Text(note.title).lineLimit(2)
                Text(note.updatedAt, style: .date).font(.caption).foregroundStyle(.secondary)
            }
        }.padding(.vertical, 3)
    }

    private var storageDetails: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Research storage").font(.headline)
                Spacer()
                Button("Done") { showingStorage = false }
            }
            Text("Images: \(store.attachments.count) · \(ByteCountFormatter.string(fromByteCount: Int64(store.attachments.reduce(0) { $0 + $1.byteCount }), countStyle: .file))")
            Text("Attachments used by sessions, drafts, notes, and note revisions are kept. Cleanup only removes unreferenced images.")
                .font(.caption).foregroundStyle(.secondary)
            Button("Remove unused attachments…") { confirmCleanup = true }
                .disabled(!store.loadWarnings.isEmpty || !store.saveFailures.isEmpty)
            if !store.saveFailures.isEmpty {
                Text("Unsaved items").font(.subheadline.weight(.semibold))
                ForEach(store.saveFailures.keys.sorted(), id: \.self) { key in
                    Text("\(key): \(store.saveFailures[key] ?? "")").font(.caption).textSelection(.enabled)
                }
                Button("Retry save") { store.retryFailedSaves() }
            }
            if !store.loadWarnings.isEmpty {
                Text("Items needing recovery").font(.subheadline.weight(.semibold))
                ScrollView {
                    ForEach(Array(store.loadWarnings.enumerated()), id: \.offset) { _, warning in
                        Text(warning).font(.caption).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(20).frame(width: 500, height: 360)
        .confirmationDialog("Remove unused images?", isPresented: $confirmCleanup, titleVisibility: .visible) {
            Button("Remove unused images", role: .destructive) {
                do { _ = try store.removeUnreferencedAttachments() }
                catch { self.error = error.localizedDescription }
            }
        } message: { Text("This cannot be undone. Images referenced by research content are kept.") }
    }

    private func createSession() {
        let id = store.createSession(title: L10n.string("New research"), sourceSelection: ResearchSourceSelection(fileIDs: filterFileID.map { [$0] } ?? []))
        selectedSessionID = id
        selection = .session(id)
    }
    private func createNote() {
        let id = store.createNote(title: L10n.string("New note"), body: "")
        selection = .note(id)
        openWindow(id: "research-note", value: id)
    }
    private func rename(_ item: ResearchLibrarySelection, title: String) { renameText = title; renaming = item }
    private func commitRename() {
        let title = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, let renaming else { return }
        switch renaming {
        case .session(let id):
            if var session = store.session(id: id) { session.title = title; store.updateSession(session) }
        case .note(let id):
            if var note = store.note(id: id) { note.title = title; store.updateNote(note) }
        }
        self.renaming = nil
    }
    private func deletePending() {
        guard let item = pendingDelete else { return }
        let deleted: Bool
        switch item {
        case .session(let id): runtime.cancel(sessionID: id); deleted = store.deleteSession(id: id)
        case .note(let id): deleted = store.deleteNote(id: id)
        }
        if deleted && selection == item { selection = nil; selectedSessionID = nil }
        if !deleted { error = ResearchStoreError.storageUnavailable.localizedDescription }
        pendingDelete = nil
    }
    private func export(_ item: ResearchLibrarySelection) {
        do {
            switch item {
            case .session(let id): try ResearchExportUI.exportSession(id: id, store: store)
            case .note(let id): try ResearchExportUI.exportNote(id: id, store: store)
            }
        } catch { self.error = error.localizedDescription }
    }
    private func uniqueEvidence(_ note: ResearchNote) -> [ResearchEvidence] {
        var seen = Set<UUID>()
        return note.provenance.flatMap(\.evidence).filter { seen.insert($0.id).inserted }
    }
    private func quoteNote(_ quote: String, note: ResearchNote) {
        let evidence = ResearchEvidence(source: nil, kind: .note, excerpt: quote, noteID: note.id, noteRevision: note.revision)
        let id = store.createSession(title: note.title, sourceSelection: ResearchSourceSelection(fileIDs: Array(note.relatedFileIDs)))
        store.saveDraft(ResearchDraft(blocks: [ResearchInputBlock(kind: .note, text: quote, evidence: evidence)]), sessionID: id)
        selectedSessionID = id
        selection = .session(id)
    }
}

@MainActor
enum ResearchExportUI {
    static func exportSession(id: UUID, store: ResearchStore) throws {
        guard let session = store.session(id: id), let destination = destination(title: session.title) else { return }
        try store.exportSession(id: id, to: destination)
    }
    static func exportNote(id: UUID, store: ResearchStore) throws {
        guard let note = store.note(id: id), let destination = destination(title: note.title) else { return }
        try store.exportNote(id: id, to: destination)
    }
    private static func destination(title: String) -> URL? {
        let panel = NSSavePanel()
        panel.title = L10n.string("Export research folder")
        panel.message = L10n.string("A new folder will contain research.md and any image attachments.")
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = String(title.map { "/:\\".contains($0) ? "-" : $0 }.prefix(100))
        panel.prompt = L10n.string("Export")
        guard panel.runModal() == .OK else { return nil }
        return panel.url
    }
}
