import Foundation
import PDFKit

/// Quoted source text is independent of an annotation's comment. Exact Dogear
/// quotes take priority; ordinary PDF highlights read their native geometry.
@MainActor
enum PDFHighlightText {
    private static let exactTextKey = PDFAnnotationKey(rawValue: "/DogearText")

    @discardableResult
    static func storeExactText(_ text: String, in annotation: PDFAnnotation) -> Bool {
        let normalizedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedText.isEmpty else { return false }
        return annotation.setValue(normalizedText, forAnnotationKey: exactTextKey)
    }

    static func text(of annotation: PDFAnnotation, on page: PDFPage) -> String {
        if let storedText = annotation.value(forAnnotationKey: exactTextKey) as? String {
            let normalizedText = storedText.trimmingCharacters(in: .whitespacesAndNewlines)
            if !normalizedText.isEmpty {
                return normalizedText
            }
        }

        let quadrilateralText = quadrilateralText(of: annotation, on: page)
        if !quadrilateralText.isEmpty {
            return quadrilateralText
        }

        return page.selection(for: annotation.bounds)?
            .string?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    private static func quadrilateralText(of annotation: PDFAnnotation, on page: PDFPage) -> String {
        guard let points = annotation.quadrilateralPoints,
              points.count >= 4 else { return "" }

        let lines: [String] = stride(from: 0, through: points.count - 4, by: 4).compactMap { index in
            let quadPoints = points[index..<(index + 4)].map { PDFPlatformStyle.point(from: $0) }
            let xCoordinates = quadPoints.map(\.x)
            let yCoordinates = quadPoints.map(\.y)
            guard let minX = xCoordinates.min(),
                  let maxX = xCoordinates.max(),
                  let minY = yCoordinates.min(),
                  let maxY = yCoordinates.max() else { return nil }

            // PDFKit's quad coordinates are relative to annotation.bounds.
            // Preserve the PDF's quad order rather than sorting page geometry.
            let quadBounds = CGRect(
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
