import Foundation

/// Durable research records contain user content, never provider continuation or credentials.
nonisolated struct ResearchSourceSnapshot: Codable, Equatable, Hashable, Sendable, Identifiable {
    var fileID: UUID
    var displayName: String
    var fingerprint: String
    var id: UUID { fileID }
}

nonisolated struct ResearchSourceSelection: Codable, Equatable, Sendable {
    var fileIDs: [UUID] = []
    var groupID: UUID? = nil

    func expandedFileIDs(groupMembers: [UUID]) -> [UUID] {
        var seen = Set<UUID>()
        return ((groupID == nil ? [] : groupMembers) + fileIDs).filter { seen.insert($0).inserted }
    }
}

/// Coordinates are PDF page coordinates, never window or screen coordinates.
nonisolated struct ResearchPageAnchor: Codable, Equatable, Hashable, Sendable {
    var pageIndex: Int
    var x: Double? = nil
    var y: Double? = nil
    var width: Double? = nil
    var height: Double? = nil
    var pageFingerprint: String? = nil
}

nonisolated enum ResearchSourceKind: String, Codable, CaseIterable, Sendable {
    case pdfText, annotation, discussion, note, image, file, group

    var isDiscussionBackground: Bool { self == .discussion || self == .note }
}

nonisolated struct ResearchEvidence: Codable, Equatable, Sendable, Identifiable {
    var id: UUID = UUID()
    var source: ResearchSourceSnapshot?
    var kind: ResearchSourceKind = .pdfText
    var anchor: ResearchPageAnchor? = nil
    var excerpt: String
    var annotationID: String? = nil
    var messageID: UUID? = nil
    var noteID: UUID? = nil
    var noteRevision: Int? = nil
    var attachmentID: UUID? = nil
}

nonisolated struct ResearchInputBlock: Codable, Equatable, Sendable, Identifiable {
    var id: UUID = UUID()
    var kind: ResearchSourceKind
    var text: String = ""
    var explanation: String = ""
    var evidence: ResearchEvidence? = nil
    var fileID: UUID? = nil
    var groupID: UUID? = nil
    var attachmentID: UUID? = nil
}

nonisolated struct ResearchDraft: Codable, Equatable, Sendable {
    var text: String = ""
    var blocks: [ResearchInputBlock] = []
    var isEmpty: Bool { text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && blocks.isEmpty }
    var attachmentIDs: Set<UUID> {
        Set(blocks.flatMap { [$0.attachmentID, $0.evidence?.attachmentID].compactMap { $0 } })
    }
}

nonisolated enum ResearchRequestStatus: String, Codable, CaseIterable, Sendable {
    case running, accepted, failed, cancelled, interrupted
}

nonisolated enum ResearchContentOrigin: String, Codable, Sendable {
    case verifiedAI, localOutline, user
}

nonisolated struct ResearchMessage: Codable, Equatable, Sendable, Identifiable {
    var id: UUID = UUID()
    var requestID: UUID = UUID()
    var question: String
    var input: ResearchDraft = ResearchDraft()
    var sourceSnapshot: [ResearchSourceSnapshot] = []
    var answer: String? = nil
    var evidence: [ResearchEvidence] = []
    var status: ResearchRequestStatus = .running
    var origin: ResearchContentOrigin = .user
    var errorMessage: String? = nil
    var operationResults: [String] = []
    /// Nil for legacy records; never reconstruct a past request from today's session/Group.
    var contextSummary: ResearchContextSummary? = nil
    var createdAt: Date = Date()
    var completedAt: Date? = nil
}

nonisolated struct ResearchSession: Codable, Equatable, Sendable, Identifiable {
    static let currentSchemaVersion = 1
    var schemaVersion: Int = currentSchemaVersion
    var id: UUID = UUID()
    var title: String
    var sourceSelection: ResearchSourceSelection = ResearchSourceSelection()
    var draft: ResearchDraft = ResearchDraft()
    var messages: [ResearchMessage] = []
    var createdAt: Date = Date()
    var updatedAt: Date = Date()

    var activeRequestID: UUID? { messages.first { $0.status == .running }?.requestID }
    var relatedFileIDs: Set<UUID> {
        Set(sourceSelection.fileIDs + messages.flatMap { $0.sourceSnapshot.map(\.fileID) }
            + messages.flatMap { $0.evidence.compactMap { $0.source?.fileID } }
            + draft.blocks.compactMap { $0.evidence?.source?.fileID ?? $0.fileID })
    }
    var attachmentIDs: Set<UUID> {
        messages.reduce(into: draft.attachmentIDs) { result, message in
            result.formUnion(message.input.attachmentIDs)
            result.formUnion(message.evidence.compactMap(\.attachmentID))
        }
    }
}

nonisolated struct ResearchNoteProvenance: Codable, Equatable, Sendable {
    var origin: ResearchContentOrigin = .user
    var sessionID: UUID? = nil
    var messageID: UUID? = nil
    var evidence: [ResearchEvidence] = []
}

nonisolated struct ResearchNoteRevision: Codable, Equatable, Sendable, Identifiable {
    var id: UUID = UUID()
    var number: Int
    var title: String
    var body: String
    var provenance: [ResearchNoteProvenance]
    var attachmentIDs: Set<UUID>
    var verificationInvalidated: Bool
    var createdAt: Date = Date()
}

nonisolated struct ResearchNoteSuggestion: Codable, Equatable, Sendable, Identifiable {
    var id: UUID = UUID()
    var baseRevision: Int
    var body: String
    var provenance: [ResearchNoteProvenance] = []
    var attachmentIDs: Set<UUID> = []
    var createdAt: Date = Date()
}

nonisolated struct ResearchNote: Codable, Equatable, Sendable, Identifiable {
    static let currentSchemaVersion = 1
    var schemaVersion: Int = currentSchemaVersion
    var id: UUID = UUID()
    var title: String
    var body: String
    var provenance: [ResearchNoteProvenance] = []
    var attachmentIDs: Set<UUID> = []
    var revision: Int = 1
    var revisions: [ResearchNoteRevision] = []
    var suggestions: [ResearchNoteSuggestion] = []
    var verificationInvalidated: Bool = false
    var createdAt: Date = Date()
    var updatedAt: Date = Date()

    var relatedFileIDs: Set<UUID> {
        Set(provenance.flatMap { $0.evidence.compactMap { $0.source?.fileID } })
    }
    var allAttachmentIDs: Set<UUID> {
        var result = attachmentIDs
        result.formUnion(provenance.flatMap { $0.evidence.compactMap(\.attachmentID) })
        for revision in revisions {
            result.formUnion(revision.attachmentIDs)
            result.formUnion(revision.provenance.flatMap { $0.evidence.compactMap(\.attachmentID) })
        }
        for suggestion in suggestions {
            result.formUnion(suggestion.attachmentIDs)
            result.formUnion(suggestion.provenance.flatMap { $0.evidence.compactMap(\.attachmentID) })
        }
        return result
    }
}

nonisolated struct ResearchAttachment: Codable, Equatable, Sendable, Identifiable {
    var id: UUID = UUID()
    var displayName: String
    var mimeType: String
    var fileExtension: String
    var byteCount: Int
    var pixelWidth: Int? = nil
    var pixelHeight: Int? = nil
    var createdAt: Date = Date()
    var filename: String { "\(id.uuidString).\(fileExtension)" }
}

nonisolated enum ResearchInputLimits {
    static let maximumHistoryRounds = 6
    static let maximumHistoryCharacters = 12_000
    static let maximumImages = 4
    static let maximumImportedImageBytes = 20 * 1_024 * 1_024
    static let maximumImageDimension = 2_048
    static let maximumProcessedImageBytes = 4 * 1_024 * 1_024
    static let maximumRequestImageBytes = 12 * 1_024 * 1_024
}

nonisolated struct ResearchHistoryRound: Equatable, Sendable {
    var messageID: UUID
    var question: String
    var answer: String
    /// History is explicitly discussion background; evidence must be re-read for new claims.
    var kind: ResearchSourceKind { .discussion }
}

nonisolated enum ResearchHistorySelection {
    static func select(
        from session: ResearchSession,
        maximumRounds: Int = ResearchInputLimits.maximumHistoryRounds,
        maximumCharacters: Int = ResearchInputLimits.maximumHistoryCharacters
    ) -> [ResearchHistoryRound] {
        var selected: [ResearchHistoryRound] = []
        var characters = 0
        for message in session.messages.reversed() where message.status == .accepted {
            guard selected.count < max(0, maximumRounds) else { break }
            guard let answer = message.answer, !answer.isEmpty else { continue }
            let size = message.question.count + answer.count
            // Preserve a contiguous tail of full rounds instead of silently cutting a round.
            guard size <= max(0, maximumCharacters) - characters else { break }
            selected.append(ResearchHistoryRound(messageID: message.id, question: message.question, answer: answer))
            characters += size
        }
        return selected.reversed()
    }
}
