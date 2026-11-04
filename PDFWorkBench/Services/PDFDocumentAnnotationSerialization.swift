import Foundation
import PDFKit

/// Reader-only visibility must never leak into saved standard annotations.
/// This real serialization path preserves linked notes and quiet-link values.
extension PDFDocument {
    typealias NoteDisplayState = (annotation: PDFAnnotation, shouldDisplay: Bool)

    @discardableResult
    func setNoteAnnotationsShouldDisplay(_ shouldDisplay: Bool) -> [NoteDisplayState] {
        var states: [NoteDisplayState] = []
        var visited: Set<ObjectIdentifier> = []

        func update(_ annotation: PDFAnnotation) {
            let identifier = ObjectIdentifier(annotation)
            guard visited.insert(identifier).inserted else { return }
            states.append((annotation, annotation.shouldDisplay))
            if annotation.shouldDisplay != shouldDisplay {
                annotation.shouldDisplay = shouldDisplay
            }
        }

        for pageIndex in 0..<pageCount {
            guard let page = page(at: pageIndex) else {
                continue
            }

            for annotation in page.annotations {
                if annotation.type == "FreeText"
                    || annotation.type == "Text"
                    || annotation.type == "Popup" {
                    update(annotation)
                }
                if let popup = annotation.popup {
                    update(popup)
                }
            }
        }

        return states
    }

    func restoreNoteAnnotationDisplayStates(_ states: [NoteDisplayState]) {
        for state in states {
            if state.annotation.shouldDisplay != state.shouldDisplay {
                state.annotation.shouldDisplay = state.shouldDisplay
            }
        }
    }

    @MainActor
    func dataRepresentationWithNoteAnnotationsDisplayed() -> Data? {
        let states = setNoteAnnotationsShouldDisplay(true)
        defer {
            restoreNoteAnnotationDisplayStates(states)
        }

        return QuietLinkDisplayRegistry.shared
            .dataRepresentationPreservingOriginalLinkAppearance(for: self)
    }
}
