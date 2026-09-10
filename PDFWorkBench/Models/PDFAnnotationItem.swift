import Foundation
import PDFKit

enum ReaderFindScope: String, CaseIterable, Identifiable {
    case documentText
    case annotations

    var id: String { rawValue }

    var displayTitle: String {
        switch self {
        case .documentText:
            return L10n.string("Document Text")
        case .annotations:
            return L10n.string("Annotations")
        }
    }
}

struct ReaderFindRequest: Equatable {
    let id: Int
    let scope: ReaderFindScope
}

enum AnnotationOriginFilter: String, CaseIterable, Identifiable {
    case all
    case manual
    case ai

    var id: String { rawValue }

    var displayTitle: String {
        switch self {
        case .all:
            return L10n.string("All Sources")
        case .manual:
            return L10n.string("Manual")
        case .ai:
            return L10n.string("AI")
        }
    }
}

enum AnnotationKindFilter: String, CaseIterable, Identifiable {
    case all
    case highlights
    case notes

    var id: String { rawValue }

    var displayTitle: String {
        switch self {
        case .all:
            return L10n.string("All Types")
        case .highlights:
            return L10n.string("Highlights")
        case .notes:
            return L10n.string("Notes")
        }
    }
}

struct PDFHighlightRequest: Equatable {
    let id: Int
    let trigger: FeedbackTrigger
}

struct PDFAnnotationItem: Identifiable, Equatable {
    enum Kind: String {
        case highlight = "Highlight"
        case note = "Note"

        var displayTitle: String {
            switch self {
            case .highlight: return L10n.string("Highlight")
            case .note: return L10n.string("Note")
            }
        }
    }

    enum Origin: Equatable {
        case manual
        case dogearAI(category: AIHighlightCategory?, groupID: UUID)
    }

    let id: String
    let pageIndex: Int
    let annotationIndex: Int
    let kind: Kind
    let text: String
    let note: String
    let origin: Origin

    var isAIGenerated: Bool {
        if case .dogearAI = origin { return true }
        return false
    }

    var aiCategory: AIHighlightCategory? {
        guard case .dogearAI(let category, _) = origin else { return nil }
        return category
    }

    var aiGroupID: UUID? {
        guard case .dogearAI(_, let groupID) = origin else { return nil }
        return groupID
    }

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

        return L10n.string("\(kind.displayTitle) on page \(pageNumber)")
    }

    static func id(pageIndex: Int, annotationIndex: Int, annotation: PDFAnnotation) -> String {
        if let uniqueName = annotation.value(forAnnotationKey: .name) as? String,
           !uniqueName.isEmpty {
            return "nm:\(uniqueName)"
        }
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

struct AIHighlightRailMarker: Identifiable, Equatable {
    let id: String
    let annotationID: PDFAnnotationItem.ID
    let pageIndex: Int
    let relativePagePosition: CGFloat
    let level: Int
    let title: String

    var pageNumber: Int {
        pageIndex + 1
    }
}
