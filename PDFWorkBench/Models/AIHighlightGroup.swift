import Foundation

nonisolated enum AIHighlightGroupRequestKind: String, Codable, Sendable {
    case overview
    case question
    case recovered
}

nonisolated struct AIHighlightGroup: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    var requestKind: AIHighlightGroupRequestKind
    var title: String?
    var question: String?
    var providerName: String
    var modelName: String
    var promptVersion: String
    var annotationUniqueNames: [String]
    let createdAt: Date

    init(
        id: UUID = UUID(),
        requestKind: AIHighlightGroupRequestKind,
        title: String? = nil,
        question: String? = nil,
        providerName: String,
        modelName: String,
        promptVersion: String,
        annotationUniqueNames: [String] = [],
        createdAt: Date = Date()
    ) {
        self.id = id
        self.requestKind = requestKind
        self.title = AIHighlightGroupTitle.normalized(title)
        self.question = question
        self.providerName = providerName
        self.modelName = modelName
        self.promptVersion = promptVersion
        self.annotationUniqueNames = annotationUniqueNames
        self.createdAt = createdAt
    }

    @MainActor var displayTitle: String {
        if let title = AIHighlightGroupTitle.normalized(title) {
            return title
        }
        switch requestKind {
        case .overview:
            return L10n.string("Document Overview")
        case .question:
            let trimmed = question?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return trimmed.isEmpty
                ? L10n.string("Question Highlights")
                : trimmed
        case .recovered:
            return L10n.string("Recovered AI Highlights")
        }
    }
}

nonisolated enum AIHighlightGroupTitle {
    static let maximumLength = 60

    static func normalized(_ value: String?) -> String? {
        guard let value else { return nil }
        let collapsed = value
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        guard !collapsed.isEmpty else { return nil }
        return String(collapsed.prefix(maximumLength))
    }
}

nonisolated struct AIHighlightDocumentGroupState: Codable, Equatable, Sendable {
    let documentID: UUID
    var groups: [AIHighlightGroup]
    var visibleGroupIDs: Set<UUID>
}

nonisolated struct AIHighlightGroupPersistenceState: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 1

    var schemaVersion = Self.currentSchemaVersion
    var documents: [AIHighlightDocumentGroupState] = []
}
