#if os(iOS)
import SwiftUI
import UniformTypeIdentifiers

struct IPadWorkspaceView: View {
    @ObservedObject var services: IPadApplicationServices
    @ObservedObject var library: LibraryStore
    @ObservedObject var session: IPadWorkspaceSession
    let isPresentationActive: Bool
    @ObservedObject private var importer: LibraryImportController
    @State private var showsImport = false
    @State private var importGroupID: UUID?
    @State private var importWorkspace: IPadGroupWorkspace?
    @State private var importingFolder = false
    @State private var showsSettings = false
    @State private var groupName = ""
    @State private var showsCreateGroup = false
    @State private var editingGroup: LibraryGroup?
    @State private var deletingGroup: LibraryGroup?
    @State private var editingFile: IPadLibraryFileEditRequest?
    @State private var showsLibrary = false
    @State private var addingLibraryGroupID: UUID?
    @State private var localLibraryVisibility: NavigationSplitViewVisibility = .all
    private let suppliedLibraryVisibility: Binding<NavigationSplitViewVisibility>?
    private var libraryVisibility: Binding<NavigationSplitViewVisibility> {
        suppliedLibraryVisibility ?? $localLibraryVisibility
    }
    @State private var compactColumn: NavigationSplitViewColumn = .sidebar
    @State private var localError: String?
    @State private var windowSize: CGSize = .zero
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    init(services: IPadApplicationServices, library: LibraryStore, session: IPadWorkspaceSession,
         isPresentationActive: Bool = true, libraryVisibility: Binding<NavigationSplitViewVisibility>? = nil) {
        self.services = services; self.library = library; self.session = session
        self.isPresentationActive = isPresentationActive
        suppliedLibraryVisibility = libraryVisibility
        importer = session.importer
    }
    var body: some View {
        NavigationSplitView(columnVisibility: libraryVisibility, preferredCompactColumn: $compactColumn) {
            IPadLibrarySidebar(library: library, session: session,
                onCreateGroup: { userDidInteract(); groupName = ""; showsCreateGroup = true },
                onRenameGroup: { userDidInteract(); groupName = $0.name; editingGroup = $0 },
                onDeleteGroup: { userDidInteract(); deletingGroup = $0 },
                onEditFile: { file in
                    guard session.acceptsUserActions, !session.workspace.state.isClosed,
                          session.workspace.export.ticket == nil,
                          session.workspace.document.pendingExportOptions == nil else { return }
                    userDidInteract()
                    editingFile = IPadLibraryFileEditRequest(file: file, session: session)
                },
                onImport: beginImport,
                onAddFromLibrary: { userDidInteract(); addingLibraryGroupID = session.groupID; showsLibrary = true },
                onSettings: { userDidInteract(); showsSettings = true },
                onShowDetail: {
                    compactColumn = .detail
                    if horizontalSizeClass == .compact { libraryVisibility.wrappedValue = .detailOnly }
                },
                onInteraction: userDidInteract)
                .navigationSplitViewColumnWidth(min: 240, ideal: 300, max: 400)
        } detail: {
            IPadDocumentWorkspace(workspace: session.workspace, services: services, library: library,
                windowSize: windowSize, isPresentationActive: isPresentationActive)
                .id(session.workspace.state.id)
                .toolbar(.hidden, for: .navigationBar)
        }
        .navigationSplitViewStyle(.balanced)
        .background(IPadWorkspaceWindowGeometry { windowSize = $0 })
        .onChange(of: libraryVisibility.wrappedValue) { _, visibility in
            compactColumn = visibility == .detailOnly ? .detail : .sidebar
            if isPresentationActive { userDidInteract() }
        }
        .onChange(of: scenePhase) { _, phase in if phase != .active { session.flushReadingState() } }
        .fileImporter(isPresented: $showsImport, allowedContentTypes: importingFolder ? [.folder] : [.pdf], allowsMultipleSelection: true) { result in
            let target = importGroupID, owner = importWorkspace
            let capturedSession = session
            importGroupID = nil; importWorkspace = nil
            guard capturedSession.acceptsUserActions, let target, let owner,
                  library.group(withID: target) != nil, !owner.state.isClosed,
                  owner.export.ticket == nil, owner.document.pendingExportOptions == nil else { return }
            do {
                let urls = try result.get()
                importer.start(urls: urls, library: library, groupID: target, sessionID: capturedSession.id,
                    assignToGroup: true, mayContinue: { [weak capturedSession, weak owner] in
                        guard let owner else { return false }
                        return capturedSession?.acceptsUserActions == true && library.group(withID: target) != nil
                            && !owner.state.isClosed && owner.export.ticket == nil
                            && owner.document.pendingExportOptions == nil
                    }, onOpen: { [weak capturedSession] file, groupID in
                        guard let capturedSession, capturedSession.acceptsUserActions else { return }
                        if groupID == target, capturedSession.groupID == target { capturedSession.open(file, in: target) }
                    })
            } catch {
                if (error as NSError).code != NSUserCancelledError { localError = error.localizedDescription }
            }
        }
        .safeAreaInset(edge: .bottom) {
            ForEach(session.workspacesNeedingDraftRecovery, id: \.state.id) { retained in
                HStack {
                    Text("A removed group still has an unsaved draft.").font(.caption)
                    Button("Recover Draft") { _ = session.recoverDraftWorkspace(id: retained.state.id) }
                        .frame(minHeight: 44)
                }.padding(.horizontal, 8).background(.regularMaterial)
            }
            if importer.isVisible {
                HStack {
                    if importer.isRunning { ProgressView(); Text("Importing \(importer.completed) / \(importer.total)"); Button("Cancel") { importer.cancel() } }
                    else { Text("Imported \(importer.completed) · skipped \(importer.skipped) · errors \(importer.failures.count)"); Button("Done") { importer.dismiss() } }
                }.font(.caption).padding().background(.regularMaterial)
            }
        }
        .sheet(isPresented: $showsSettings) { IPadAISettingsView(configurationStore: services.configuration, languageStore: services.language) }
        .sheet(item: $editingFile) { request in
            IPadLibraryFileEditor(request: request, library: library, session: session).id(request.id)
        }
        .sheet(isPresented: $showsLibrary) {
            NavigationStack { List(library.allFiles) { file in
                Button(file.displayName) {
                    if let target = addingLibraryGroupID, library.group(withID: target) != nil { library.addFile(file.id, to: target) }
                }
            }.navigationTitle("Add from Library").toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { showsLibrary = false } } } }
        }
        .alert("New Group", isPresented: $showsCreateGroup) {
            TextField("Name", text: $groupName)
            Button("Create") { if let group = library.createGroup(named: groupName) { session.selectGroup(group.id) } }
            Button("Cancel", role: .cancel) {}
        }
        .alert("Rename Group", isPresented: Binding(get: { editingGroup != nil }, set: { if !$0 { editingGroup = nil } })) {
            TextField("Name", text: $groupName)
            Button("Save") { if let group = editingGroup { _ = library.renameGroup(group, to: groupName) }; editingGroup = nil }
            Button("Cancel", role: .cancel) { editingGroup = nil }
        }
        .alert("Delete Group?", isPresented: Binding(get: { deletingGroup != nil }, set: { if !$0 { deletingGroup = nil } })) {
            Button("Delete Group", role: .destructive) { if let group = deletingGroup { _ = library.deleteGroup(group); if session.groupID == group.id { session.selectGroup(LibraryGroup.ungroupedID) } }; deletingGroup = nil }
            Button("Cancel", role: .cancel) { deletingGroup = nil }
        } message: { Text("PDF files and research notes are kept. Group membership is removed.") }
        .alert("Import Error", isPresented: Binding(get: { localError != nil }, set: { if !$0 { localError = nil } })) { Button("OK") { localError = nil } } message: { Text(verbatim: localError ?? "") }
        .onOpenURL { url in
            if isPresentationActive && url.isFileURL { session.importURLs([url], groupID: session.groupID) }
        }
    }
    private func userDidInteract() { services.commands.userDidInteract(viewID: session.workspace.state.id) }
    private func beginImport(folder: Bool) {
        let owner = session.workspace
        guard session.acceptsUserActions, !importer.isRunning,
              owner.export.ticket == nil, owner.document.pendingExportOptions == nil else { return }
        userDidInteract(); importGroupID = session.groupID; importWorkspace = owner
        importingFolder = folder; showsImport = true
    }
}

@MainActor
struct IPadLibraryFileEditRequest: Identifiable {
    let id = UUID()
    let file: LibraryFile
    let sessionID: UUID
    let groupID: UUID
    let workspace: IPadGroupWorkspace

    init(file: LibraryFile, session: IPadWorkspaceSession) {
        self.file = file
        sessionID = session.id
        groupID = session.groupID
        workspace = session.workspace
    }
}

@MainActor
struct IPadLibraryFileEditor: View {
    let request: IPadLibraryFileEditRequest
    @ObservedObject var library: LibraryStore
    @ObservedObject var session: IPadWorkspaceSession
    @ObservedObject private var workspaceState: GroupWorkspaceState
    @ObservedObject private var exportPresenter: IPadDocumentExportPresenter
    @ObservedObject private var document: PDFDocumentStore
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var tags: String
    @State private var isPresented = false
    @State private var choosingOriginal = false
    @State private var isBusy = false
    @State private var error: String?
    @State private var resultMessage: String?
    @State private var locateTicket: UUID?
    @State private var relinkTask: Task<Void, Never>?

    init(request: IPadLibraryFileEditRequest, library: LibraryStore, session: IPadWorkspaceSession) {
        self.request = request; self.library = library; self.session = session
        workspaceState = request.workspace.state
        exportPresenter = request.workspace.export
        document = request.workspace.document
        _name = State(initialValue: request.file.displayName)
        _tags = State(initialValue: request.file.tagsText)
    }

    private var file: LibraryFile? { library.allFiles.first { $0.id == request.file.id } }
    private var contextIsCurrent: Bool {
        isPresented && session.acceptsUserActions && session.id == request.sessionID
            && session.groupID == request.groupID && session.workspace === request.workspace
            && workspaceState.groupID == request.groupID && workspaceState.isActive && !workspaceState.isClosed
            && library.group(withID: request.groupID) != nil && file != nil
            && exportPresenter.ticket == nil && document.pendingExportOptions == nil
    }

    var body: some View {
        let pickerTicket = locateTicket
        return NavigationStack {
            Form {
                if let file {
                    Section("Organization") {
                        TextField("Display Name", text: $name)
                        TextField("Tags", text: $tags)
                    }.disabled(isBusy || !contextIsCurrent)
                    Section("Original location") {
                        Text(verbatim: file.canonicalPath).font(.caption).textSelection(.enabled)
                        Button("Locate Original…", action: beginLocate)
                            .disabled(isBusy || !contextIsCurrent)
                    }
                    Section("Working copy") {
                        if let copy = library.openingWorkingCopyURL(for: file) ?? file.workingCopyURL {
                            Text(verbatim: copy.path).font(.caption).textSelection(.enabled)
                            if FileManager.default.fileExists(atPath: copy.path) {
                                Text("Your edits are kept in a working copy.")
                            } else {
                                Text("Working copy is missing").foregroundStyle(.orange)
                            }
                        } else {
                            Text("No working copy; the original is unchanged.")
                        }
                        Button("Retry Failed Saves") {
                            guard contextIsCurrent, !isBusy else { return }
                            DocumentAccessCoordinator.shared.retryPendingSaves()
                        }.disabled(isBusy || !contextIsCurrent)
                    }
                } else {
                    Text("This file is no longer in the Library.")
                }
                if isBusy {
                    HStack {
                        ProgressView()
                        Text("Checking original content…")
                        Spacer()
                        Button("Cancel") { cancelLocate() }
                    }
                }
                if let resultMessage { Text(verbatim: resultMessage).foregroundStyle(.secondary) }
                if let error {
                    Text(verbatim: L10n.string(String.LocalizationValue(error)))
                        .foregroundStyle(.red).textSelection(.enabled)
                }
            }
            .navigationTitle("File Details")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { isPresented = false; cancelLocate(); dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        guard contextIsCurrent, !isBusy, var current = file else { return }
                        current.displayName = name; current.tagsText = tags
                        library.update(current)
                        isPresented = false; cancelLocate(); dismiss()
                    }.disabled(isBusy || !contextIsCurrent)
                }
            }
        }
        .onAppear { isPresented = true }
        .onDisappear { isPresented = false; cancelLocate() }
        .onChange(of: session.groupID) { _, _ in if !contextIsCurrent { cancelLocate() } }
        .onChange(of: ObjectIdentifier(session.workspace)) { _, _ in if !contextIsCurrent { cancelLocate() } }
        .onChange(of: workspaceState.isActive) { _, active in if !active { cancelLocate() } }
        .onChange(of: file?.id) { _, id in if id == nil { cancelLocate() } }
        .onChange(of: exportPresenter.ticket?.id) { _, id in if id != nil { cancelLocate() } }
        .onChange(of: document.pendingExportOptions?.id) { _, id in if id != nil { cancelLocate() } }
        .fileImporter(isPresented: $choosingOriginal, allowedContentTypes: [.pdf], allowsMultipleSelection: false,
            onCompletion: { completeLocate($0, ticket: pickerTicket) },
            onCancellation: {
                guard let pickerTicket else { return }
                cancelLocate(ticket: pickerTicket)
            })
    }

    private func beginLocate() {
        guard contextIsCurrent else { return }
        cancelLocate()
        error = nil; resultMessage = nil
        locateTicket = UUID()
        choosingOriginal = true
    }

    private func completeLocate(_ result: Result<[URL], Error>, ticket: UUID?) {
        guard let ticket, locateTicket == ticket, contextIsCurrent, !isBusy else { return }
        do {
            guard let url = try result.get().first else { cancelLocate(ticket: ticket); return }
            let access = ScopedLibraryFileAccess(url: url)
            isBusy = true
            relinkTask = Task { @MainActor in
                defer {
                    // Cancellation can outlive the view while the hash worker
                    // finishes. Keep the native lease until this task returns.
                    withExtendedLifetime(access) {}
                    if locateTicket == ticket {
                        isBusy = false; relinkTask = nil; locateTicket = nil
                    }
                }
                do {
                    try validateLocate(ticket)
                    let plan = try await library.prepareRelink(fileID: request.file.id, to: url)
                    try validateLocate(ticket)
                    switch plan.disposition {
                    case .differentContent: throw LibraryWorkflowError.contentMismatch
                    case .baselineUnavailable: throw LibraryWorkflowError.baselineUnavailable
                    case .sameContent: break
                    }
                    let checked = try await library.revalidateRelink(plan)
                    try validateLocate(ticket)
                    try DocumentAccessCoordinator.shared.relocateOriginal(
                        fileID: request.file.id, from: checked.originalURL, to: checked.candidateURL,
                        updateLibrary: {
                            try validateLocate(ticket)
                            _ = try library.commitRelink(checked)
                        })
                    resultMessage = L10n.string("Original file reconnected.")
                } catch is CancellationError {
                    // An expired presentation has no authority to report or commit.
                } catch {
                    if locateTicket == ticket, contextIsCurrent { self.error = error.localizedDescription }
                }
            }
        } catch {
            if (error as NSError).code != NSUserCancelledError { self.error = error.localizedDescription }
            cancelLocate(ticket: ticket)
        }
    }

    private func validateLocate(_ ticket: UUID) throws {
        try Task.checkCancellation()
        guard locateTicket == ticket, contextIsCurrent else { throw CancellationError() }
    }

    private func cancelLocate(ticket: UUID? = nil) {
        if let ticket, locateTicket != ticket { return }
        locateTicket = nil
        relinkTask?.cancel(); relinkTask = nil
        isBusy = false; choosingOriginal = false
    }
}
#endif
