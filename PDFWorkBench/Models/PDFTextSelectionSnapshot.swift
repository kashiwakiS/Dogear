import CoreGraphics
import Foundation

/// Value-only reading context; PDFKit selection ownership remains on MainActor.
nonisolated struct PDFTextSelectionSnapshot: Equatable, Sendable {
    let text: String
    let pageNumbers: [Int]
    var passages: [PDFSelectedPassage] = []

    var isEmpty: Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

nonisolated struct PDFSelectedPassage: Equatable, Sendable {
    let pageNumber: Int
    let text: String
    let bounds: CGRect
}
