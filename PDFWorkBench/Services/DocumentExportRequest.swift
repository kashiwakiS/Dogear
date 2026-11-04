import Foundation
import UniformTypeIdentifiers

/// Prepared bytes and their protected original travel together across a
/// platform destination picker. A later document switch cannot redirect either.
nonisolated struct DocumentExportRequest: Sendable {
    let data: Data
    let suggestedName: String
    let contentType: UTType
    let protectedOriginalURL: URL?

    /// Preserve the existing extension-based Markdown type on older supported
    /// SDKs; the native UTType.markdown constant requires much newer systems.
    static var markdownContentType: UTType {
        UTType(filenameExtension: "md") ?? .plainText
    }

    func write(to destination: URL,
               existingFilePolicy: SafeDocumentExport.ExistingFilePolicy = .replace) throws {
        try SafeDocumentExport.write(data: data, to: destination, protecting: protectedOriginalURL,
                                     existingFilePolicy: existingFilePolicy)
    }
}
