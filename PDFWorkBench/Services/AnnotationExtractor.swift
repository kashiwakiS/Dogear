import Foundation
import PDFKit

@MainActor
enum AnnotationExtractor {
    static func annotationItems(in document: PDFDocument) -> [PDFAnnotationItem] {
        var items: [PDFAnnotationItem] = []

        for pageIndex in 0..<document.pageCount {
            guard let page = document.page(at: pageIndex) else {
                continue
            }

            for (annotationIndex, annotation) in page.annotations.enumerated() {
                guard let kind = kind(for: annotation) else {
                    continue
                }

                let storedContents = annotation.contents?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let text = kind == .highlight
                    ? PDFHighlightText.text(of: annotation, on: page)
                    : ""
                let note = kind == .note || kind == .highlight ? storedContents : ""
                let classification = AIAnnotationProvenance.classify(annotation)
                let metadata = AIAnnotationProvenance.embeddedMetadata(of: annotation)

                items.append(
                    PDFAnnotationItem(
                        id: PDFAnnotationItem.id(
                            pageIndex: pageIndex,
                            annotationIndex: annotationIndex,
                            annotation: annotation
                        ),
                        pageIndex: pageIndex,
                        annotationIndex: annotationIndex,
                        kind: kind,
                        text: text,
                        note: note,
                        origin: classification.isAI
                            ? .dogearAI(
                                category: metadata?.category,
                                groupID: AIAnnotationProvenance.displayGroupID(
                                    of: annotation
                                ) ?? AIAnnotationProvenance.legacyGroupID
                            )
                            : .manual
                    )
                )
            }
        }

        return items
    }

    static func annotation(matching item: PDFAnnotationItem, in document: PDFDocument) -> PDFAnnotation? {
        guard let page = document.page(at: item.pageIndex) else {
            return nil
        }

        return page.annotations.enumerated().first { annotationIndex, annotation in
            PDFAnnotationItem.id(
                pageIndex: item.pageIndex,
                annotationIndex: annotationIndex,
                annotation: annotation
            ) == item.id
        }?.element
    }

    @discardableResult
    static func storeExactHighlightText(_ text: String, in annotation: PDFAnnotation) -> Bool {
        PDFHighlightText.storeExactText(text, in: annotation)
    }

    private static func kind(for annotation: PDFAnnotation) -> PDFAnnotationItem.Kind? {
        switch annotation.type {
        case "Highlight":
            return .highlight
        case "Text", "FreeText":
            return .note
        default:
            return nil
        }
    }

}
