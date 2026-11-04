import Foundation

/// Prepared bytes cross this boundary; a presenter never re-reads a live PDF.
/// Cancellation is a successful nil result. Each workspace owns its presenter.
@MainActor
protocol DocumentExportPresenting: AnyObject {
    func export(_ request: DocumentExportRequest,
                completion: @escaping @MainActor (Result<URL?, Error>) -> Void)
}

@MainActor
func defaultDocumentExportPresenter() -> (any DocumentExportPresenting)? {
#if os(macOS)
    MacDocumentExportPresenter()
#else
    nil
#endif
}
