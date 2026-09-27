import Foundation

/// A confirmation authorizes one captured set of edits, not whatever happens to
/// occupy the same working-copy path when a different window finishes editing.
@MainActor
struct WorkingCopyDiscardRequest {
    let fileID: UUID
    let originalURL: URL
    let workingCopyURL: URL
    let contentVersion: String

    init(file: LibraryFile, originalURL: URL, workingCopyURL: URL,
         coordinator: DocumentAccessCoordinator? = nil) throws {
        let coordinator = coordinator ?? .shared
        self.fileID = file.id
        self.originalURL = originalURL
        self.workingCopyURL = workingCopyURL
        self.contentVersion = try coordinator.readSnapshot(fileID: file.id, originalURL: originalURL,
            workingCopyURL: workingCopyURL).contentVersion
    }

    func discard(library: LibraryStore, coordinator: DocumentAccessCoordinator? = nil) throws {
        let coordinator = coordinator ?? .shared
        guard let file = library.allFiles.first(where: { $0.id == fileID }),
              library.resolvedURL(for: file).libraryComparablePath == originalURL.libraryComparablePath,
              (coordinator.workingCopyStatus(for: originalURL)?.workingCopyURL ?? library.openingWorkingCopyURL(for: file))?.standardizedFileURL
                == workingCopyURL.standardizedFileURL else { throw DocumentAccessError.sourceChanged }
        let current = try coordinator.readSnapshot(fileID: fileID, originalURL: originalURL, workingCopyURL: workingCopyURL)
        guard current.contentVersion == contentVersion else { throw DocumentAccessError.sourceChanged }
        try coordinator.discardWorkingCopy(originalURL: originalURL, workingCopyURL: workingCopyURL, fileID: fileID)
        library.updateWorkingCopyURL(nil, for: file)
    }
}
