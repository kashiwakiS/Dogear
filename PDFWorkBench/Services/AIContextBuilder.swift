import Foundation
import PDFKit

protocol AIContextBuilding {
    @MainActor
    func documentContext(from store: PDFDocumentStore) async throws -> AIContextPackage

    @MainActor
    func selectionContext(from store: PDFDocumentStore) throws -> AIContextPackage
}

struct AIContextBuilder: AIContextBuilding {
    @MainActor
    func documentContext(from store: PDFDocumentStore) async throws -> AIContextPackage {
        guard let document = store.document else {
            throw AIContextError.noDocument
        }

        try Task.checkCancellation()
        guard let data = document.dataRepresentation() else {
            throw AIContextError.cannotPreparePDF
        }

        return AIContextPackage(
            title: store.selectedDocumentName,
            text: "",
            pageNumbers: (0..<document.pageCount).map { $0 + 1 },
            file: AIFileAttachment(
                filename: store.selectedDocumentName,
                data: data,
                pageCount: document.pageCount
            )
        )
    }

    @MainActor
    func selectionContext(from store: PDFDocumentStore) throws -> AIContextPackage {
        guard let selection = store.currentTextSelection, !selection.isEmpty else {
            throw AIContextError.noSelection
        }

        return AIContextPackage(
            title: store.selectedDocumentName,
            text: selection.text,
            pageNumbers: selection.pageNumbers
        )
    }
}

enum AIContextError: LocalizedError {
    case noDocument
    case noSelection
    case cannotPreparePDF

    var errorDescription: String? {
        switch self {
        case .noDocument:
            return "Open a PDF first."
        case .noSelection:
            return "Select text in the PDF first."
        case .cannotPreparePDF:
            return "The complete PDF could not be prepared for upload."
        }
    }
}
