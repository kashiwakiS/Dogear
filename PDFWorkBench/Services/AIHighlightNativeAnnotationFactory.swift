import Foundation
import PDFKit

nonisolated struct AIHighlightNativeAnnotationStyle: Equatable, Sendable {
    let color = PDFColorComponents(
        red: 0.30,
        green: 0.78,
        blue: 0.88,
        alpha: 1.0
    )
}

@MainActor
struct AIHighlightNativeAnnotationFactory {
    let style: AIHighlightNativeAnnotationStyle

    init() {
        style = AIHighlightNativeAnnotationStyle()
    }

    init(style: AIHighlightNativeAnnotationStyle) {
        self.style = style
    }

    func makeAnnotation(
        anchor: ResolvedAIHighlightAnchor,
        staged: StagedAIHighlight,
        groupID: UUID,
        id: UUID = UUID(),
        modificationDate: Date = Date()
    ) throws -> PDFAnnotation {
        let candidate = staged.candidate
        guard staged.sourceKind == .nativeText,
              candidate.candidateID == anchor.candidateID,
              candidate.segmentIDs == anchor.segmentIDs,
              staged.pageNumber == anchor.pageNumber
        else {
            throw AIHighlightNativeAnnotationError.mismatchedAnchor(
                candidate.candidateID
            )
        }

        let bounds = anchor.annotationBounds.cgRect
        guard bounds.width > 0,
              bounds.height > 0,
              !bounds.isNull,
              !bounds.isInfinite,
              !anchor.quadrilateralPoints.isEmpty,
              anchor.quadrilateralPoints.count.isMultiple(of: 4)
        else {
            throw AIHighlightNativeAnnotationError.invalidGeometry(
                candidate.candidateID
            )
        }

        let annotation = PDFAnnotation(
            bounds: bounds,
            forType: .highlight,
            withProperties: nil
        )
        annotation.color = PDFPlatformStyle.color(style.color)
        annotation.quadrilateralPoints = anchor.quadrilateralPoints.map {
            PDFPlatformStyle.pointValue($0.cgPoint)
        }
        annotation.shouldDisplay = true
        annotation.shouldPrint = true

        if let note = candidate.note?.trimmingCharacters(in: .whitespacesAndNewlines),
           !note.isEmpty {
            annotation.contents = note
        }

        try AIAnnotationProvenance.assignMetadata(
            to: annotation,
            uniqueName: AIAnnotationProvenance.makeUniqueName(
                groupID: groupID,
                id: id
            ),
            category: candidate.category,
            groupID: groupID,
            modificationDate: modificationDate
        )
        return annotation
    }
}
