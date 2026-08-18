import Foundation
import PDFKit

/// Keeps PDF link appearance changes strictly scoped to the on-screen reader.
///
/// PDFKit serializes `shouldDisplay`, so every original value must be restored
/// before a document is saved or exported and after its last reader closes.
@MainActor
final class QuietLinkDisplayRegistry {
    static let shared = QuietLinkDisplayRegistry()

    private let documentStates = NSMapTable<PDFDocument, DocumentState>.weakToStrongObjects()

    private init() {}

    func beginDisplaying(_ document: PDFDocument) {
        if let state = documentStates.object(forKey: document) {
            state.activeReaderCount += 1
            return
        }

        let state = DocumentState(document: document)
        state.activeReaderCount = 1
        state.hideNativeLinks()
        documentStates.setObject(state, forKey: document)
    }

    func endDisplaying(_ document: PDFDocument) {
        guard let state = documentStates.object(forKey: document) else {
            return
        }

        state.activeReaderCount = max(0, state.activeReaderCount - 1)
        guard state.activeReaderCount == 0 else {
            return
        }

        state.restoreOriginalValues()
        documentStates.removeObject(forKey: document)
    }

    func dataRepresentationPreservingOriginalLinkAppearance(for document: PDFDocument) -> Data? {
        guard let state = documentStates.object(forKey: document) else {
            return document.dataRepresentation()
        }

        state.restoreOriginalValues()
        defer {
            state.hideNativeLinks()
        }

        return document.dataRepresentation()
    }

    private final class DocumentState {
        typealias LinkDisplayState = (annotation: PDFAnnotation, shouldDisplay: Bool)

        var activeReaderCount = 0
        private let linkDisplayStates: [LinkDisplayState]

        init(document: PDFDocument) {
            var states: [LinkDisplayState] = []

            for pageIndex in 0..<document.pageCount {
                guard let page = document.page(at: pageIndex) else {
                    continue
                }

                for annotation in page.annotations where annotation.type == "Link" {
                    states.append((annotation, annotation.shouldDisplay))
                }
            }

            linkDisplayStates = states
        }

        func hideNativeLinks() {
            for state in linkDisplayStates {
                state.annotation.shouldDisplay = false
            }
        }

        func restoreOriginalValues() {
            for state in linkDisplayStates {
                state.annotation.shouldDisplay = state.shouldDisplay
            }
        }
    }
}
