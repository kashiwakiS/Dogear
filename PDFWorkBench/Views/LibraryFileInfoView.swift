import SwiftUI
import UniformTypeIdentifiers

/// The sheet keeps an explicit file ID; changing the reader cannot retarget it.
struct LibraryFileInfoView: View {
    @ObservedObject var library: LibraryStore
    let fileID: UUID
    let onExport: (LibraryFile) -> Void
    let onReveal: (URL) -> Void
    let onOpenNew: (URL) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var tags = ""
    @State private var choosingOriginal = false
    @State private var isBusy = false
    @State private var error: String?
    @State private var resultMessage: String?
    @State private var differentFile: URL?
    @State private var showDifferentFile = false
    @State private var access: ScopedLibraryFileAccess?
    @State private var relinkTask: Task<Void, Never>?

    private var file: LibraryFile? { library.allFiles.first { $0.id == fileID } }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("File Info").font(.title2.weight(.semibold))
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            if let file {
                Form {
                    Section {
                        LabeledContent("Name", value: file.displayName)
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Original location").foregroundStyle(.secondary)
                            Text(file.path).font(.caption).textSelection(.enabled)
                            HStack {
                                Button("Reveal Original") { onReveal(library.resolvedURL(for: file)) }
                                Button("Locate Original…") { choosingOriginal = true }.disabled(isBusy)
                            }
                        }
                        LabeledContent("Reading position", value: String(file.lastPageIndex + 1))
                    }
                    Section("Organization") {
                        LabeledContent("Groups", value: library.groups(containing: file).map(\.localizedName).joined(separator: ", "))
                        TextField("Tags, comma separated", text: $tags)
                        Button("Save Tags") {
                            do {
                                try library.updateTags(tags.split(separator: ",").map(String.init), for: [fileID])
                                tags = self.file?.tagsText ?? tags
                                error = nil
                            } catch { self.error = error.localizedDescription }
                        }.disabled(tags == file.tagsText)
                        Text("App-only labels. PDF metadata is not edited.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Section("Working copy") {
                        if let url = library.openingWorkingCopyURL(for: file) {
                            Text("Your edits are kept in a working copy.")
                            Text(url.path).font(.caption).textSelection(.enabled)
                            HStack {
                                Button("Save Copy As…") { onExport(file) }
                                Button("Reveal") { onReveal(url) }
                            }
                        } else { Text("No working copy; the original is unchanged.") }
                    }
                }.formStyle(.grouped)
            } else { Text("This file is no longer in the Library.") }
            if isBusy {
                HStack {
                    ProgressView().controlSize(.small)
                    Text("Checking original content…")
                    Spacer()
                    Button("Cancel") { relinkTask?.cancel() }
                }
            }
            if let resultMessage { Text(resultMessage).font(.callout).foregroundStyle(.secondary) }
            if let error {
                Text(L10n.string(String.LocalizationValue(error)))
                    .font(.callout).foregroundStyle(.red).textSelection(.enabled)
            }
        }
        .padding(20).frame(minWidth: 480, idealWidth: 540, minHeight: 480)
        .onAppear { tags = file?.tagsText ?? "" }
        .onDisappear { relinkTask?.cancel(); access = nil }
        .fileImporter(isPresented: $choosingOriginal, allowedContentTypes: [.pdf]) { result in
            switch result {
            case .success(let url): locate(url)
            case .failure(let error): self.error = error.localizedDescription
            }
        }
        .alert("This is not a verified copy of the original", isPresented: $showDifferentFile) {
            Button("Import as New File") {
                importDifferentFile()
            }
            Button("Cancel", role: .cancel) { differentFile = nil; access = nil }
        } message: {
            Text("The SHA-256 differs, or the original has no saved fingerprint. Import this PDF separately. The old file, working copy and research records will be kept.")
        }
    }

    private func importDifferentFile() {
        guard let candidate = differentFile else { return }
        defer { differentFile = nil; access = nil }
        // An externally replaced original can occupy the old path. A new file
        // must get a different location before it can receive a new Library ID.
        if library.file(for: candidate)?.id == fileID {
            guard let target = SafeFileExportPicker.chooseDestination(
                suggestedName: candidate.deletingPathExtension().lastPathComponent + "-new.pdf", contentType: .pdf) else { return }
            let targetAccess = ScopedLibraryFileAccess(url: target)
            defer { withExtendedLifetime(targetAccess) {} }
            do {
                guard library.file(for: target) == nil,
                      !SafeDocumentExport.isSameFile(candidate, target) else { throw LibraryWorkflowError.alreadyInLibrary }
                try FileManager.default.copyItem(at: candidate, to: target)
                onOpenNew(target)
            } catch { self.error = error.localizedDescription }
        } else { onOpenNew(candidate) }
    }

    private func locate(_ url: URL) {
        relinkTask?.cancel()
        access = ScopedLibraryFileAccess(url: url)
        isBusy = true; error = nil; resultMessage = nil
        relinkTask = Task { @MainActor in
            defer { isBusy = false }
            do {
                let plan = try await library.prepareRelink(fileID: fileID, to: url)
                try Task.checkCancellation()
                guard plan.disposition == .sameContent else {
                    differentFile = url; showDifferentFile = true; return
                }
                let checked = try await library.revalidateRelink(plan)
                try Task.checkCancellation()
                // The coordinator performs its remaining checks before the Library commit.
                try DocumentAccessCoordinator.shared.relocateOriginal(
                    fileID: fileID, from: checked.originalURL, to: checked.candidateURL,
                    updateLibrary: { _ = try library.commitRelink(checked) })
                resultMessage = L10n.string("Original file reconnected.")
                access = nil
            } catch is CancellationError { access = nil }
            catch { self.error = error.localizedDescription; access = nil }
        }
    }
}
