import CryptoKit
import Foundation

/// Frozen rank-fusion parameters shared by production retrieval and diagnostics.
/// Weight bit patterns are part of the identity so the hash is
/// independent of locale-specific decimal formatting.
nonisolated struct AIRetrievalFusionConfiguration: Equatable, Sendable {
    static let frozen = AIRetrievalFusionConfiguration(
        denseWeight: 1.0,
        lexicalWeight: 0.0,
        rrfK: 60,
        candidatePoolMin: 24,
        candidatePoolMultiplier: 3,
        candidatePoolCap: 100
    )

    let denseWeight: Double
    let lexicalWeight: Double
    let rrfK: Int
    let candidatePoolMin: Int
    let candidatePoolMultiplier: Int
    let candidatePoolCap: Int

    init(
        denseWeight: Double,
        lexicalWeight: Double,
        rrfK: Int = 60,
        candidatePoolMin: Int = 24,
        candidatePoolMultiplier: Int = 3,
        candidatePoolCap: Int = 100
    ) {
        precondition(denseWeight.isFinite && denseWeight >= 0, "Dense RRF weight must be finite and nonnegative.")
        precondition(lexicalWeight.isFinite && lexicalWeight >= 0, "Lexical RRF weight must be finite and nonnegative.")
        precondition(denseWeight > 0 || lexicalWeight > 0, "At least one RRF channel must have positive weight.")
        precondition(rrfK > 0, "RRF constant must be positive.")
        precondition(candidatePoolMin > 0, "Candidate-pool minimum must be positive.")
        precondition(candidatePoolMultiplier > 0, "Candidate-pool multiplier must be positive.")
        precondition(candidatePoolCap >= candidatePoolMin, "Candidate-pool cap must include the minimum.")
        self.denseWeight = denseWeight
        self.lexicalWeight = lexicalWeight
        self.rrfK = rrfK
        self.candidatePoolMin = candidatePoolMin
        self.candidatePoolMultiplier = candidatePoolMultiplier
        self.candidatePoolCap = candidatePoolCap
    }

    func candidatePoolSize(forResultLimit resultLimit: Int) -> Int {
        let boundedLimit = min(candidatePoolCap, max(1, resultLimit))
        let (scaled, overflow) = boundedLimit.multipliedReportingOverflow(by: candidatePoolMultiplier)
        return min(candidatePoolCap, max(candidatePoolMin, overflow ? candidatePoolCap : scaled))
    }

    var canonicalIdentity: String {
        [
            "dogear.weighted-rrf.v1",
            "dense=\(Self.canonicalBits(denseWeight))",
            "lexical=\(Self.canonicalBits(lexicalWeight))",
            "rrf-k=\(rrfK)",
            "pool-min=\(candidatePoolMin)",
            "pool-multiplier=\(candidatePoolMultiplier)",
            "pool-cap=\(candidatePoolCap)"
        ].joined(separator: "|")
    }

    var canonicalHash: String {
        SHA256.hash(data: Data(canonicalIdentity.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private static func canonicalBits(_ value: Double) -> String {
        // Normalize signed zero because both values have identical fusion
        // semantics but otherwise have distinct IEEE-754 representations.
        let bits = (value == 0 ? 0.0 : value).bitPattern
        let encoded = String(bits, radix: 16, uppercase: false)
        return String(repeating: "0", count: max(0, 16 - encoded.count)) + encoded
    }
}

/// Internal evidence retained for diagnostics without changing the public
/// `AISegmentSearchResult` contract.
nonisolated struct AIRetrievalFusionDiagnosticCandidate: Equatable, Sendable {
    let id: AISegmentID
    let lexicalRank: Int?
    let denseRank: Int?
    let finalScore: Double
}

nonisolated enum AIRetrievalFusion {
    static func fuse(
        lexical: [AISegmentID],
        dense: [AISegmentID],
        configuration: AIRetrievalFusionConfiguration = .frozen
    ) -> [AISegmentSearchResult] {
        diagnosticCandidates(lexical: lexical, dense: dense, configuration: configuration)
            .map { AISegmentSearchResult(id: $0.id, score: $0.finalScore) }
    }

    /// Raw lexical and cosine scores are intentionally ignored. Only each
    /// channel's stable, deduplicated rank contributes to weighted RRF.
    static func fuse(
        lexical: [AISegmentSearchResult],
        dense: [AISegmentSearchResult],
        configuration: AIRetrievalFusionConfiguration = .frozen
    ) -> [AISegmentSearchResult] {
        fuse(
            lexical: lexical.map(\.id),
            dense: dense.map(\.id),
            configuration: configuration
        )
    }

    static func diagnosticCandidates(
        lexical: [AISegmentID],
        dense: [AISegmentID],
        configuration: AIRetrievalFusionConfiguration = .frozen
    ) -> [AIRetrievalFusionDiagnosticCandidate] {
        let lexicalRanks = uniqueRanks(lexical)
        let denseRanks = uniqueRanks(dense)

        var candidateIDs = Set<AISegmentID>()
        if configuration.lexicalWeight > 0 {
            candidateIDs.formUnion(lexicalRanks.keys)
        }
        if configuration.denseWeight > 0 {
            candidateIDs.formUnion(denseRanks.keys)
        }

        return candidateIDs.map { id in
            let lexicalRank = lexicalRanks[id]
            let denseRank = denseRanks[id]
            var score = 0.0
            if configuration.denseWeight > 0, let denseRank {
                score += configuration.denseWeight / Double(configuration.rrfK + denseRank)
            }
            if configuration.lexicalWeight > 0, let lexicalRank {
                score += configuration.lexicalWeight / Double(configuration.rrfK + lexicalRank)
            }
            return AIRetrievalFusionDiagnosticCandidate(
                id: id,
                lexicalRank: lexicalRank,
                denseRank: denseRank,
                finalScore: score
            )
        }
        .sorted {
            if $0.finalScore == $1.finalScore { return $0.id < $1.id }
            return $0.finalScore > $1.finalScore
        }
    }

    private static func uniqueRanks(_ ids: [AISegmentID]) -> [AISegmentID: Int] {
        var ranks: [AISegmentID: Int] = [:]
        ranks.reserveCapacity(ids.count)
        for id in ids where ranks[id] == nil {
            // Ranks are one-based after per-channel deduplication. Repeated IDs
            // therefore cannot consume a rank or change another candidate.
            ranks[id] = ranks.count + 1
        }
        return ranks
    }
}
