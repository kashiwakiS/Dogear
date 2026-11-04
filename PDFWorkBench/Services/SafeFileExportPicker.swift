#if os(macOS)
import AppKit
import UniformTypeIdentifiers

/// A narrow macOS adapter: returns the authorized destination before any bytes
/// are written. PDF callers must then use SafeDocumentExport's original guard.
@MainActor
enum SafeFileExportPicker {
    static func chooseDestination(for request: DocumentExportRequest) -> URL? {
        chooseDestination(suggestedName: request.suggestedName, contentType: request.contentType)
    }

    static func chooseDestination(suggestedName: String, contentType: UTType) -> URL? {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [contentType]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = suggestedName
        return panel.runModal() == .OK ? panel.url : nil
    }
}

/// Retains the desktop's synchronous picker and validates before writing.
@MainActor
final class MacDocumentExportPresenter: DocumentExportPresenting {
    func export(_ request: DocumentExportRequest,
                completion: @escaping @MainActor (Result<URL?, Error>) -> Void) {
        guard let destination = SafeFileExportPicker.chooseDestination(for: request) else {
            completion(.success(nil))
            return
        }
        do {
            try request.write(to: destination)
            completion(.success(destination))
        } catch {
            completion(.failure(error))
        }
    }
}
#endif
