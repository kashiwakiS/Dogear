import Foundation

/// Frozen production scoring contract. Index data does not depend on these
/// values, so later parameter changes do not require retokenizing postings.
nonisolated struct AIBM25Parameters: Codable, Equatable, Sendable {
    static let frozen = AIBM25Parameters()
    static let configurationIdentity = "bm25-window-v1-rsj-log1p-k1-1.2-b-0.75-unique-query-terms"

    let k1: Double
    let b: Double

    private init() {
        k1 = 1.2
        b = 0.75
    }
}

nonisolated struct AIBM25Posting: Codable, Equatable, Sendable {
    let segmentID: AISegmentID
    let termFrequency: Int
}

nonisolated struct AIBM25TermStatistics: Codable, Equatable, Sendable {
    let documentFrequency: Int
    let collectionFrequency: Int
}

/// Text-free lexical values suitable for either an in-memory backend or a
/// persistent postings backend. In BM25 terminology each segment is a document.
nonisolated struct AIBM25IndexData: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 1

    let schemaVersion: Int
    let tokenizerVersion: String
    let segmentLengths: [AISegmentID: Int]
    let termStatistics: [String: AIBM25TermStatistics]
    let postings: [String: [AIBM25Posting]]
    let totalSegmentLength: Int

    var segmentCount: Int { segmentLengths.count }
    var averageSegmentLength: Double {
        guard segmentCount > 0 else { return 0 }
        return Double(totalSegmentLength) / Double(segmentCount)
    }
}

/// Mutable construction boundary. Replacing an existing stable ID is an
/// update, not an additional corpus entry; `build` always emits sorted postings.
nonisolated struct AIBM25IndexBuilder: Sendable {
    let tokenizer: AILexicalTokenizer
    private var termFrequenciesBySegment: [AISegmentID: [String: Int]] = [:]

    init(tokenizer: AILexicalTokenizer = AILexicalTokenizer()) {
        self.tokenizer = tokenizer
    }

    var segmentCount: Int { termFrequenciesBySegment.count }

    mutating func upsert(id: AISegmentID, text: String) {
        termFrequenciesBySegment[id] = Self.termFrequencies(tokenizer.tokens(text))
    }

    mutating func upsert(_ record: AISegmentRecord) {
        upsert(id: record.id, text: record.text)
    }

    @discardableResult
    mutating func remove(id: AISegmentID) -> Bool {
        termFrequenciesBySegment.removeValue(forKey: id) != nil
    }

    mutating func rebuild(records: [AISegmentRecord]) {
        termFrequenciesBySegment.removeAll(keepingCapacity: true)
        for record in records.sorted(by: { $0.id < $1.id }) {
            upsert(record)
        }
    }

    /// Rebuilds transactionally while allowing long source preparation to
    /// cooperate with task cancellation. The receiver keeps its previous
    /// complete contents if cancellation or another check error is raised.
    mutating func rebuildCheckingCancellation(
        records: [AISegmentRecord],
        checkCancellation: () throws -> Void = { try Task.checkCancellation() }
    ) throws {
        try checkCancellation()
        var replacement = AIBM25IndexBuilder(tokenizer: tokenizer)
        for record in records.sorted(by: { $0.id < $1.id }) {
            try checkCancellation()
            replacement.upsert(record)
        }
        try checkCancellation()
        termFrequenciesBySegment = replacement.termFrequenciesBySegment
    }

    mutating func rebuild(segments: [(id: AISegmentID, text: String)]) {
        termFrequenciesBySegment.removeAll(keepingCapacity: true)
        for segment in segments.sorted(by: { $0.id < $1.id }) {
            upsert(id: segment.id, text: segment.text)
        }
    }

    /// Tuple-based counterpart used by index importers and diagnostics.
    mutating func rebuildCheckingCancellation(
        segments: [(id: AISegmentID, text: String)],
        checkCancellation: () throws -> Void = { try Task.checkCancellation() }
    ) throws {
        try checkCancellation()
        var replacement = AIBM25IndexBuilder(tokenizer: tokenizer)
        for segment in segments.sorted(by: { $0.id < $1.id }) {
            try checkCancellation()
            replacement.upsert(id: segment.id, text: segment.text)
        }
        try checkCancellation()
        termFrequenciesBySegment = replacement.termFrequenciesBySegment
    }

    func build() -> AIBM25IndexData {
        var segmentLengths: [AISegmentID: Int] = [:]
        var postings: [String: [AIBM25Posting]] = [:]
        var collectionFrequencies: [String: Int] = [:]

        for id in termFrequenciesBySegment.keys.sorted() {
            let frequencies = termFrequenciesBySegment[id, default: [:]]
            segmentLengths[id] = frequencies.values.reduce(0, +)
            for term in frequencies.keys.sorted() {
                let frequency = frequencies[term, default: 0]
                postings[term, default: []].append(
                    AIBM25Posting(segmentID: id, termFrequency: frequency)
                )
                collectionFrequencies[term, default: 0] += frequency
            }
        }
        let statistics = Dictionary(uniqueKeysWithValues: postings.map { term, values in
            (term, AIBM25TermStatistics(
                documentFrequency: values.count,
                collectionFrequency: collectionFrequencies[term, default: 0]
            ))
        })
        return AIBM25IndexData(
            schemaVersion: AIBM25IndexData.currentSchemaVersion,
            tokenizerVersion: tokenizer.version,
            segmentLengths: segmentLengths,
            termStatistics: statistics,
            postings: postings,
            totalSegmentLength: segmentLengths.values.reduce(0, +)
        )
    }

    private static func termFrequencies(_ tokens: [String]) -> [String: Int] {
        tokens.reduce(into: [:]) { $0[$1, default: 0] += 1 }
    }
}

nonisolated enum AIBM25IndexError: LocalizedError, Equatable {
    case incompatibleSchema(expected: Int, actual: Int)
    case incompatibleTokenizer(expected: String, actual: String)
    case invalidIndexData

    var errorDescription: String? {
        switch self {
        case .incompatibleSchema(let expected, let actual):
            "The lexical index schema is incompatible (expected \(expected), found \(actual))."
        case .incompatibleTokenizer(let expected, let actual):
            "The lexical tokenizer is incompatible (expected \(expected), found \(actual))."
        case .invalidIndexData:
            "The lexical index contains inconsistent segment or posting statistics."
        }
    }
}

nonisolated struct AIBM25ScopedStatistics: Equatable, Sendable {
    let segmentCount: Int
    let totalSegmentLength: Int
    let averageSegmentLength: Double
    let documentFrequency: [String: Int]
}

/// Immutable, reusable query view. Scope statistics are deliberately recomputed
/// over only the authorized segments for each request.
nonisolated struct AIBM25PreparedIndex: Sendable {
    let data: AIBM25IndexData
    let tokenizer: AILexicalTokenizer
    let parameters: AIBM25Parameters

    init(
        data: AIBM25IndexData,
        tokenizer: AILexicalTokenizer = AILexicalTokenizer(),
        parameters: AIBM25Parameters = .frozen,
        checkCancellation: () throws -> Void = { try Task.checkCancellation() }
    ) throws {
        try checkCancellation()
        guard data.schemaVersion == AIBM25IndexData.currentSchemaVersion else {
            throw AIBM25IndexError.incompatibleSchema(
                expected: AIBM25IndexData.currentSchemaVersion,
                actual: data.schemaVersion
            )
        }
        guard data.tokenizerVersion == tokenizer.version else {
            throw AIBM25IndexError.incompatibleTokenizer(
                expected: tokenizer.version,
                actual: data.tokenizerVersion
            )
        }
        guard try Self.isValid(data, checkCancellation: checkCancellation) else {
            throw AIBM25IndexError.invalidIndexData
        }
        try checkCancellation()
        self.data = data
        self.tokenizer = tokenizer
        self.parameters = parameters
    }

    init(
        records: [AISegmentRecord],
        tokenizer: AILexicalTokenizer = AILexicalTokenizer(),
        parameters: AIBM25Parameters = .frozen
    ) throws {
        var builder = AIBM25IndexBuilder(tokenizer: tokenizer)
        try builder.rebuildCheckingCancellation(records: records)
        try self.init(data: builder.build(), tokenizer: tokenizer, parameters: parameters)
    }

    func search(_ request: AISegmentSearchRequest) -> [AISegmentSearchResult] {
        let terms = queryTerms(request.query)
        guard !terms.isEmpty else { return [] }
        let unrestricted = Self.isUnrestricted(request.scope)
        let scopedSet: Set<AISegmentID>?
        let statistics: AIBM25ScopedStatistics
        if unrestricted {
            scopedSet = nil
            statistics = globalStatistics(terms: terms)
        } else {
            let selected = data.segmentLengths.keys.filter(request.scope.includes)
            guard !selected.isEmpty else { return [] }
            let selectedSet = Set(selected)
            scopedSet = selectedSet
            statistics = scopedStatistics(terms: terms, scopedIDs: selected, scopedSet: selectedSet)
        }
        guard statistics.segmentCount > 0 else { return [] }

        var scores: [AISegmentID: Double] = [:]
        for term in terms {
            let frequency = statistics.documentFrequency[term, default: 0]
            guard frequency > 0 else { continue }
            let idf = Self.inverseDocumentFrequency(
                documentCount: statistics.segmentCount,
                documentFrequency: frequency
            )
            let postings = data.postings[term, default: []]
            if let scopedSet {
                for posting in postings where scopedSet.contains(posting.segmentID) {
                    let contribution = Self.termContribution(
                        termFrequency: posting.termFrequency,
                        documentLength: data.segmentLengths[posting.segmentID, default: 0],
                        averageDocumentLength: statistics.averageSegmentLength,
                        inverseDocumentFrequency: idf,
                        parameters: parameters
                    )
                    scores[posting.segmentID, default: 0] += contribution
                }
            } else {
                for posting in postings {
                    let contribution = Self.termContribution(
                        termFrequency: posting.termFrequency,
                        documentLength: data.segmentLengths[posting.segmentID, default: 0],
                        averageDocumentLength: statistics.averageSegmentLength,
                        inverseDocumentFrequency: idf,
                        parameters: parameters
                    )
                    scores[posting.segmentID, default: 0] += contribution
                }
            }
        }
        let results: [AISegmentSearchResult] = scores.map { entry in
            AISegmentSearchResult(id: entry.key, score: entry.value)
        }
        let rankedResults = results.sorted { lhs, rhs in
            if lhs.score == rhs.score { return lhs.id < rhs.id }
            return lhs.score > rhs.score
        }
        return Array(rankedResults.prefix(min(100, max(1, request.topK))))
    }

    func scopedStatistics(query: String, scope: AISegmentScope = AISegmentScope()) -> AIBM25ScopedStatistics {
        let terms = queryTerms(query)
        if Self.isUnrestricted(scope) {
            return globalStatistics(terms: terms)
        }
        let scopedIDs = data.segmentLengths.keys.filter(scope.includes)
        return scopedStatistics(terms: terms, scopedIDs: scopedIDs, scopedSet: Set(scopedIDs))
    }

    func queryTerms(_ query: String) -> [String] {
        Array(Set(tokenizer.tokens(query))).sorted()
    }

    static func inverseDocumentFrequency(documentCount: Int, documentFrequency: Int) -> Double {
        guard documentCount > 0, documentFrequency >= 0, documentFrequency <= documentCount else { return 0 }
        return log(1 + (Double(documentCount - documentFrequency) + 0.5)
            / (Double(documentFrequency) + 0.5))
    }

    static func termContribution(
        termFrequency: Int,
        documentLength: Int,
        averageDocumentLength: Double,
        inverseDocumentFrequency: Double,
        parameters: AIBM25Parameters = .frozen
    ) -> Double {
        guard termFrequency > 0, documentLength >= 0, averageDocumentLength > 0,
              inverseDocumentFrequency.isFinite, inverseDocumentFrequency >= 0 else { return 0 }
        let tf = Double(termFrequency)
        let lengthRatio = Double(documentLength) / averageDocumentLength
        let denominator = tf + parameters.k1 * (1 - parameters.b + parameters.b * lengthRatio)
        guard denominator > 0 else { return 0 }
        return inverseDocumentFrequency * tf * (parameters.k1 + 1) / denominator
    }

    private func scopedStatistics(
        terms: [String],
        scopedIDs: [AISegmentID],
        scopedSet: Set<AISegmentID>
    ) -> AIBM25ScopedStatistics {
        let totalLength = scopedIDs.reduce(0) { $0 + data.segmentLengths[$1, default: 0] }
        let count = scopedIDs.count
        let average = count > 0 ? Double(totalLength) / Double(count) : 0
        let frequencies = Dictionary(uniqueKeysWithValues: terms.map { term in
            (term, data.postings[term, default: []].reduce(0) {
                $0 + (scopedSet.contains($1.segmentID) ? 1 : 0)
            })
        })
        return AIBM25ScopedStatistics(
            segmentCount: count,
            totalSegmentLength: totalLength,
            averageSegmentLength: average,
            documentFrequency: frequencies
        )
    }

    private func globalStatistics(terms: [String]) -> AIBM25ScopedStatistics {
        AIBM25ScopedStatistics(
            segmentCount: data.segmentCount,
            totalSegmentLength: data.totalSegmentLength,
            averageSegmentLength: data.averageSegmentLength,
            documentFrequency: Dictionary(uniqueKeysWithValues: terms.map { term in
                (term, data.termStatistics[term]?.documentFrequency ?? 0)
            })
        )
    }

    private static func isUnrestricted(_ scope: AISegmentScope) -> Bool {
        scope.pageRange == nil && scope.blockIDs.isEmpty && scope.documentNumbers.isEmpty
    }

    private static func isValid(
        _ data: AIBM25IndexData,
        checkCancellation: () throws -> Void
    ) throws -> Bool {
        try checkCancellation()
        var totalSegmentLength = 0
        var computedLengths: [AISegmentID: Int] = [:]
        computedLengths.reserveCapacity(data.segmentLengths.count)
        for (offset, entry) in data.segmentLengths.enumerated() {
            if offset.isMultiple(of: 64) { try checkCancellation() }
            let (id, length) = entry
            guard length >= 0 else { return false }
            let total = totalSegmentLength.addingReportingOverflow(length)
            guard !total.overflow else { return false }
            totalSegmentLength = total.partialValue
            computedLengths[id] = 0
        }
        guard data.totalSegmentLength == totalSegmentLength,
              data.postings.count == data.termStatistics.count
        else { return false }
        for (offset, term) in data.termStatistics.keys.enumerated() {
            if offset.isMultiple(of: 64) { try checkCancellation() }
            guard data.postings[term] != nil else { return false }
        }
        for (termOffset, entry) in data.postings.enumerated() {
            if termOffset.isMultiple(of: 64) { try checkCancellation() }
            let (term, postings) = entry
            guard !term.isEmpty, let statistics = data.termStatistics[term] else { return false }
            var previousID: AISegmentID?
            var collectionFrequency = 0
            for (postingOffset, posting) in postings.enumerated() {
                if postingOffset.isMultiple(of: 64) { try checkCancellation() }
                guard data.segmentLengths[posting.segmentID] != nil,
                      posting.termFrequency > 0,
                      previousID.map({ $0 < posting.segmentID }) ?? true
                else { return false }
                previousID = posting.segmentID
                let collection = collectionFrequency.addingReportingOverflow(
                    posting.termFrequency
                )
                let segmentLength = computedLengths[posting.segmentID, default: 0]
                    .addingReportingOverflow(posting.termFrequency)
                guard !collection.overflow, !segmentLength.overflow else { return false }
                collectionFrequency = collection.partialValue
                computedLengths[posting.segmentID] = segmentLength.partialValue
            }
            guard statistics.documentFrequency == postings.count,
                  statistics.collectionFrequency == collectionFrequency
            else { return false }
        }
        try checkCancellation()
        return computedLengths == data.segmentLengths
    }
}
