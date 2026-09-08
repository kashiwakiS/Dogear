import Combine
import Foundation

@MainActor
final class AIReadingStore: ObservableObject {
    @Published private(set) var errorMessage: String?
    @Published private(set) var capturedSelection: AIContextPackage?
    @Published var questionText = ""

    private let contextBuilder: AIContextBuilding
    private var documentIdentity: String?

    convenience init() {
        self.init(contextBuilder: AIContextBuilder())
    }

    init(contextBuilder: AIContextBuilding) {
        self.contextBuilder = contextBuilder
    }

    func contextForCurrentQuestion(from store: PDFDocumentStore) -> AIContextPackage? {
        if let capturedSelection {
            return capturedSelection
        }
        guard store.currentTextSelection != nil else { return nil }
        do {
            let context = try contextBuilder.selectionContext(from: store)
            capturedSelection = context
            errorMessage = nil
            return context
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }

    func useNewSelection(from store: PDFDocumentStore) {
        do {
            capturedSelection = try contextBuilder.selectionContext(from: store)
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func useAnnotationSelection(
        _ text: String,
        documentName: String,
        pageNumber: Int
    ) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        capturedSelection = AIContextPackage(
            title: documentName,
            text: trimmed,
            pageNumbers: [pageNumber]
        )
        errorMessage = nil
    }

    func documentDidChange(to identity: String?) {
        guard documentIdentity != identity else { return }
        documentIdentity = identity
        capturedSelection = nil
        questionText = ""
        errorMessage = nil
    }
}
