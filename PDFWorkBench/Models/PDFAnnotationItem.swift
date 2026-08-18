import Foundation
import PDFKit

struct PDFAnnotationItem: Identifiable, Equatable {
    enum Kind: String {
        case highlight = "Highlight"
        case note = "Note"
    }

    let id: String
    let pageIndex: Int
    let annotationIndex: Int
    let kind: Kind
    let text: String
    let note: String

    var pageNumber: Int {
        pageIndex + 1
    }

    var searchableText: String {
        "\(text) \(note)"
    }

    var displayText: String {
        if !text.isEmpty {
            return text
        }

        if !note.isEmpty {
            return note
        }

        return "\(kind.rawValue) on page \(pageNumber)"
    }

    static func id(pageIndex: Int, annotationIndex: Int, annotation: PDFAnnotation) -> String {
        let bounds = annotation.bounds
        let type = annotation.type ?? "Unknown"
        return [
            "\(pageIndex)",
            "\(annotationIndex)",
            type,
            String(format: "%.2f", bounds.origin.x),
            String(format: "%.2f", bounds.origin.y),
            String(format: "%.2f", bounds.size.width),
            String(format: "%.2f", bounds.size.height)
        ].joined(separator: ":")
    }
}

struct PDFSearchResult: Identifiable, Equatable {
    let id: String
    let pageIndex: Int
    let resultIndex: Int
    let selection: PDFSelection
    let snippet: String

    var pageNumber: Int {
        pageIndex + 1
    }

    static func == (lhs: PDFSearchResult, rhs: PDFSearchResult) -> Bool {
        lhs.id == rhs.id
    }
}
