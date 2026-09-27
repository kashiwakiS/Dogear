import Foundation
import CoreGraphics
import PDFKit

/// Command snapshots need the latest viewport, but pixels scrolled are not UI
/// state. A stable, non-observed reference avoids invalidating the whole reader.
@MainActor
final class PDFReadingPositionCache {
    private weak var document: PDFDocument?
    private var latest: PDFNavigationTarget?

    func update(_ position: PDFNavigationTarget, for document: PDFDocument) {
        self.document = document
        latest = position
    }

    func position(for document: PDFDocument?) -> PDFNavigationTarget? {
        guard let document, self.document === document else { return nil }
        return latest
    }
}

enum DocumentOutlineSource: String, Equatable {
    case pdfBookmark
    case detectedHeading
}

struct PDFNavigationTarget: Equatable {
    let pageIndex: Int
    let point: CGPoint?
    let relativePagePosition: CGFloat?
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
