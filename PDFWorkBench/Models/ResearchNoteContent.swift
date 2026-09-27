import Foundation

/// The content a research-result editor or renderer consumes, independently of
/// its window. New formats can add a case and an explicit persistence adapter.
/// This is deliberately not a second stored body or a new on-disk schema.
nonisolated enum ResearchNoteContent: Equatable, Sendable {
    case markdown(String)
}

extension ResearchNote {
    var content: ResearchNoteContent {
        get { .markdown(body) }
        set {
            switch newValue {
            case .markdown(let markdown): body = markdown
            }
        }
    }
}

extension ResearchNoteRevision {
    var content: ResearchNoteContent { .markdown(body) }
}

extension ResearchNoteSuggestion {
    var content: ResearchNoteContent { .markdown(body) }
}
