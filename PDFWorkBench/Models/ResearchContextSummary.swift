import Foundation

nonisolated enum ResearchHistoryOmission: String, Codable, Sendable {
    case roundLimit, characterLimit, localOutline
}

nonisolated struct ResearchSourceOmission: Codable, Equatable, Sendable, Identifiable {
    var fileID: UUID
    var reason: String
    var id: UUID { fileID }
}

/// A small request-time receipt, not a second copy of the prompt or provider transcript.
nonisolated struct ResearchContextSummary: Codable, Equatable, Sendable {
    var historyMessageIDs: [UUID]
    var availableHistoryRounds: Int
    var historyCharacters: Int
    var historyOmission: ResearchHistoryOmission?
    var imageCount: Int
    var excludedImageCount: Int
    var isLocalOutline: Bool
    /// Nil until native source preparation finishes; an empty array means none were prepared.
    var preparedFileIDs: [UUID]? = nil
    /// Nil until the workflow reports retrieval preparation. Prepared is not the same as cited.
    var retrievalFileIDs: [UUID]? = nil
    var skippedSources: [ResearchSourceOmission] = []

    var omittedHistoryRounds: Int { max(0, availableHistoryRounds - historyMessageIDs.count) }

    static func capture(session: ResearchSession, history: [ResearchHistoryRound],
                        imageCount: Int, excludedImageCount: Int, isLocalOutline: Bool) -> Self {
        let available = session.messages.filter { $0.status == .accepted && !($0.answer ?? "").isEmpty }.count
        let included = isLocalOutline ? [] : history
        let omission: ResearchHistoryOmission?
        if isLocalOutline { omission = .localOutline }
        else if included.count < available {
            omission = included.count >= ResearchInputLimits.maximumHistoryRounds ? .roundLimit : .characterLimit
        } else { omission = nil }
        return Self(historyMessageIDs: included.map(\.messageID), availableHistoryRounds: available,
            historyCharacters: included.reduce(0) { $0 + $1.question.count + $1.answer.count },
            historyOmission: omission, imageCount: imageCount, excludedImageCount: excludedImageCount,
            isLocalOutline: isLocalOutline)
    }
}
