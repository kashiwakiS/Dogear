import Foundation

/// The coordinator owns PDF state; the native editor owns activation,
/// authorized retries, explicit discard/reopen and presentation of save state.
/// Class identity and weak lifetime remain part of the single-writer contract.
@MainActor
protocol PDFDocumentEditingOwner: AnyObject {
    func activateEditor()
    func retryWorkingCopySave()
    func adoptRelocatedOriginal(_ url: URL, fileID: UUID)
    func synchronizeSaveState(from entry: DocumentAccessCoordinator.Entry)
    func discardCurrentWorkingCopyAndReopenOriginal() -> Bool
    @discardableResult func bindLibraryFile(_ fileID: UUID) -> Bool
}
