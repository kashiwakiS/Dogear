import Foundation
import PDFKit

@MainActor
enum AnnotationExtractor {
    private static let dogearHighlightTextKey = PDFAnnotationKey(rawValue: "/DogearText")

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
                    ? annotationHighlightText(annotation, on: page)
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
        let normalizedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedText.isEmpty else { return false }
        return annotation.setValue(normalizedText, forAnnotationKey: dogearHighlightTextKey)
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

    private static func annotationHighlightText(
        _ annotation: PDFAnnotation,
        on page: PDFPage
    ) -> String {
        if let storedText = annotation.value(forAnnotationKey: dogearHighlightTextKey) as? String {
            let normalizedText = storedText.trimmingCharacters(in: .whitespacesAndNewlines)
            if !normalizedText.isEmpty {
                return normalizedText
            }
        }

        let quadrilateralText = annotationQuadrilateralText(annotation, on: page)
        if !quadrilateralText.isEmpty {
            return quadrilateralText
        }

        return page.selection(for: annotation.bounds)?
            .string?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    private static func annotationQuadrilateralText(
        _ annotation: PDFAnnotation,
        on page: PDFPage
    ) -> String {
        guard let points = annotation.quadrilateralPoints,
              points.count >= 4
        else {
            return ""
        }

        let lines: [String] = stride(from: 0, through: points.count - 4, by: 4).compactMap { index in
            let quadPoints = points[index..<(index + 4)].map(\.pointValue)
            let xCoordinates = quadPoints.map(\.x)
            let yCoordinates = quadPoints.map(\.y)
            guard let minX = xCoordinates.min(),
                  let maxX = xCoordinates.max(),
                  let minY = yCoordinates.min(),
                  let maxY = yCoordinates.max()
            else {
                return nil
            }

            let quadBounds = NSRect(
                x: annotation.bounds.minX + minX,
                y: annotation.bounds.minY + minY,
                width: maxX - minX,
                height: maxY - minY
            )
            return page.selection(for: quadBounds)?
                .string?
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }

        return lines.filter { !$0.isEmpty }.joined(separator: "\n")
    }
}

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
            annotation.shouldDisplay = shouldDisplay
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
            state.annotation.shouldDisplay = state.shouldDisplay
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
