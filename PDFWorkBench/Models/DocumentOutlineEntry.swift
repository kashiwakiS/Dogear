import Foundation
import CoreGraphics

enum DocumentOutlineSource: String, Equatable {
    case pdfBookmark
    case detectedHeading
}

struct PDFNavigationTarget: Equatable {
    let pageIndex: Int
    let point: CGPoint?
}

struct DocumentOutlineEntry: Identifiable, Equatable {
    let id: String
    let title: String
    let level: Int
    let target: PDFNavigationTarget
    let source: DocumentOutlineSource

    var pageNumber: Int {
        target.pageIndex + 1
    }
}

struct PDFOutlineNavigationRequest: Equatable {
    let id: Int
    let target: PDFNavigationTarget
}
