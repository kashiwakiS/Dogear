import SwiftUI
import UniformTypeIdentifiers

struct WorkingCopiesView: View {
    @ObservedObject var library: LibraryStore
    let onOpen: (LibraryFile) -> Void
    let onReveal: (URL) -> Void
    @State private var items: [WorkingCopyInventoryItem] = []
    @State private var isLoading = false
    @State private var error: String?
    @State private var pendingDiscard: WorkingCopyInventoryItem?
    @State private var confirmDiscard = false
    @State private var discardRequest: WorkingCopyDiscardRequest?
    @State private var search = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Working Copies").font(.title2.weight(.semibold))
                Spacer()
                if isLoading { ProgressView().controlSize(.small) }
                Button("Refresh") { Task { await reload() } }.disabled(isLoading)
                Button("Retry Failed Saves") {
                    DocumentAccessCoordinator.shared.retryPendingSaves()
                    Task { await reload() }
                }
            }
            Text("Edits stay here until you explicitly discard them. Exporting a copy keeps your working copy.")
                .font(.callout).foregroundStyle(.secondary)
            TextField("Find a file", text: $search).textFieldStyle(.roundedBorder)
            List(filteredItems) { item in
                VStack(alignment: .leading, spacing: 7) {
                    HStack {
                        Text(item.displayNames.first ?? item.url.lastPathComponent).font(.headline)
                        Spacer()
                        if let bytes = item.sizeBytes {
                            Text(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))
                                .foregroundStyle(.secondary)
                        }
                    }
                    Text(status(for: item)).font(.caption).foregroundStyle(.secondary)
                    if let modified = item.modifiedAt { Text(modified, style: .date).font(.caption) }
                    HStack {
                        if let file = associatedFile(item) {
                            Button("Open") { onOpen(file) }.disabled(item.status == .unsafeReference)
                            Button("Save Copy As…") { export(item, recovering: false) }
                                .disabled(item.status == .missing || item.status == .unsafeReference)
                            if item.fileIDs.count == 1 {
                                Button("Discard…", role: .destructive) {
                                    do {
                                        discardRequest = try WorkingCopyDiscardRequest(file: file,
                                            originalURL: library.resolvedURL(for: file), workingCopyURL: item.url)
                                        pendingDiscard = item; confirmDiscard = true
                                    } catch { self.error = error.localizedDescription }
                                }.disabled(item.status == .missing || item.status == .unsafeReference)
                            }
                        } else if item.status == .unassociated {
                            Button("Save Copy As…") { export(item, recovering: false) }
                            Button("Recover to File…") { export(item, recovering: true) }
                        }
                        Button("Reveal") { onReveal(item.url) }.disabled(item.status == .missing)
                    }.buttonStyle(.borderless)
                }.padding(.vertical, 6)
            }
            if filteredItems.isEmpty, !isLoading { Text("No working copies found.").foregroundStyle(.secondary) }
            if let error {
                Text(L10n.string(String.LocalizationValue(error))).foregroundStyle(.red).textSelection(.enabled)
            }
        }
        .padding(20).frame(minWidth: 600, minHeight: 420)
        .task { await reload() }
        .alert("Discard all changes?", isPresented: $confirmDiscard) {
            Button("Discard Changes", role: .destructive) { discard() }
            Button("Cancel", role: .cancel) { pendingDiscard = nil }
        } message: {
            Text("This deletes the selected working copy and its edits. The original PDF is not changed. If the original is missing, export your work first.")
        }
    }

    private var filteredItems: [WorkingCopyInventoryItem] {
        items.filter { search.isEmpty || ($0.displayNames + [$0.url.lastPathComponent])
            .contains { $0.localizedCaseInsensitiveContains(search) } }
    }

    private func associatedFile(_ item: WorkingCopyInventoryItem) -> LibraryFile? {
        library.allFiles.first { item.fileIDs.contains($0.id) }
    }

    private func status(for item: WorkingCopyInventoryItem) -> String {
        if let file = associatedFile(item),
           let state = DocumentAccessCoordinator.shared.workingCopyStatus(for: library.resolvedURL(for: file)) {
            if let error = state.saveError {
                return L10n.string("Save failed") + ": " + L10n.string(String.LocalizationValue(error))
            }
            if state.hasUnsavedChanges { return L10n.string("Saving working copy…") }
        }
        switch item.status {
        case .missing: return L10n.string("Working copy is missing")
        case .unassociated: return L10n.string("Not associated with Library · kept for recovery")
        case .protected: return L10n.string("In use or waiting to save")
        case .unsafeReference: return L10n.string("Unavailable storage reference")
        case .available:
            return item.missingOriginalFileIDs.isEmpty ? L10n.string("Saved working copy")
                : L10n.string("Original is missing · working copy is available")
        }
    }

    private func reload() async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let store = try PDFWorkingCopyStore()
            let originals = Dictionary(uniqueKeysWithValues: library.allFiles.map { ($0.id, library.resolvedURL(for: $0)) })
            items = try await WorkingCopyInventoryService.scan(directoryURL: store.directoryURL,
                files: library.allFiles, originalURLs: originals,
                protectedURLs: DocumentAccessCoordinator.shared.protectedWorkingCopyURLs)
            error = nil
        } catch is CancellationError {} catch { self.error = error.localizedDescription }
    }

    private func export(_ item: WorkingCopyInventoryItem, recovering: Bool) {
        guard let target = SafeFileExportPicker.chooseDestination(
            suggestedName: associatedFile(item)?.displayName ?? "Recovered.pdf", contentType: .pdf) else { return }
        let targetAccess = ScopedLibraryFileAccess(url: target)
        Task { @MainActor in
            defer { withExtendedLifetime(targetAccess) {} }
            do {
                let currentAssociation = library.allFiles.first { library.openingWorkingCopyURL(for: $0)?.libraryComparablePath == item.url.libraryComparablePath }
                if let file = currentAssociation ?? associatedFile(item) {
                    let original = library.resolvedURL(for: file)
                    let data = try DocumentAccessCoordinator.shared.exportData(fileID: file.id,
                        originalURL: original, workingCopyURL: file.workingCopyURL)
                    try SafeDocumentExport.write(data: data, to: target, protecting: original)
                } else {
                    guard !DocumentAccessCoordinator.shared.protectedWorkingCopyURLs.contains(where: {
                        $0.libraryComparablePath == item.url.libraryComparablePath
                    }) else { throw LibraryWorkflowError.unsafeWorkingCopy }
                    try await WorkingCopyInventoryService.exportUnassociatedCopy(item, to: target)
                }
                if recovering {
                    let file = library.upsertOpenedURL(target)
                    onOpen(file)
                }
                error = nil
            } catch { self.error = error.localizedDescription }
        }
    }

    private func discard() {
        defer { pendingDiscard = nil; discardRequest = nil }
        do {
            try discardRequest?.discard(library: library)
            error = nil
            Task { await reload() }
        } catch { self.error = error.localizedDescription }
    }
}
