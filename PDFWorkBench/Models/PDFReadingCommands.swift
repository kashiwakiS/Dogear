import Foundation
import PDFKit

/// Reader presentation values independent of the native PDFView wrapper.
enum PDFReadingDisplayStyle: String, CaseIterable, Identifiable {
    case singlePage
    case continuous
    case twoUp

    var id: String {
        rawValue
    }

    var title: String {
        switch self {
        case .singlePage:
            return "Single"
        case .continuous:
            return "Continuous"
        case .twoUp:
            return "Two-Up"
        }
    }

    var systemImage: String {
        switch self {
        case .singlePage:
            return "doc"
        case .continuous:
            return "doc.text"
        case .twoUp:
            return "square.split.2x1"
        }
    }

    var pdfDisplayMode: PDFDisplayMode {
        switch self {
        case .singlePage:
            return .singlePage
        case .continuous:
            return .singlePageContinuous
        case .twoUp:
            return .twoUpContinuous
        }
    }

    var displaysAsBook: Bool {
        // PDFKit's book layout shows the first page as a cover and can leave
        // the final page stranded outside the scrollable document in
        // continuous two-up mode. Keep normal page pairing (1-2, 3-4, ...).
        false
    }
}

enum PDFPageNumberInput {
    static func pageIndex(_ text: String, pageCount: Int) -> Int? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.allSatisfy({ $0.isNumber }),
              let number = Int(trimmed), number > 0, number <= pageCount else { return nil }
        return number - 1
    }
}

struct PDFZoomCommand: Equatable {
    let id: Int
    let action: PDFZoomAction
}

enum PDFZoomAction: Equatable {
    case zoomIn
    case zoomOut
    case actualSize
    case fitWidth
    case fitPage
    /// A percentage (125 means 125%), bounded to the native reader's range.
    case custom(Double)
}
