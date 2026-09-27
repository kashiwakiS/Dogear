import Foundation

nonisolated enum AIRetrievalFusionDiagnostics {
    struct Report: Sendable {
        let checks: Int
        let failures: [String]
    }

    static func run() -> Report {
        var checks = 0
        var failures: [String] = []
        func check(_ condition: Bool, _ message: String) {
            checks += 1
            if !condition { failures.append(message) }
        }
        func approximatelyEqual(_ lhs: Double, _ rhs: Double) -> Bool {
            abs(lhs - rhs) < 0.000_000_000_001
        }

        let frozen = AIRetrievalFusionConfiguration.frozen
        check(
            frozen.denseWeight == 1.0 && frozen.lexicalWeight == 0.0
                && frozen.rrfK == 60 && frozen.candidatePoolMin == 24
                && frozen.candidatePoolMultiplier == 3 && frozen.candidatePoolCap == 100,
            "The frozen weighted-RRF parameters changed."
        )
        check(
            frozen.candidatePoolSize(forResultLimit: 0) == 24
                && frozen.candidatePoolSize(forResultLimit: 8) == 24
                && frozen.candidatePoolSize(forResultLimit: 9) == 27
                && frozen.candidatePoolSize(forResultLimit: 100) == 100
                && frozen.candidatePoolSize(forResultLimit: .max) == 100,
            "Candidate-pool bounds or overflow handling changed."
        )
        check(
            frozen.canonicalIdentity
                == "dogear.weighted-rrf.v1|dense=3ff0000000000000|lexical=0000000000000000|rrf-k=60|pool-min=24|pool-multiplier=3|pool-cap=100",
            "The canonical weighted-RRF identity changed."
        )
        check(
            frozen.canonicalHash == "ea4643ad74df1c912f28ea67a88108448e47b1b3acdb1a718419f4b071a4ebe1"
                && frozen.canonicalHash == AIRetrievalFusionConfiguration.frozen.canonicalHash,
            "The weighted-RRF configuration hash is not stable SHA-256."
        )

        let a = AISegmentID(document: 1, page: 1, block: 1, sentence: 1)
        let b = AISegmentID(document: 1, page: 1, block: 1, sentence: 2)
        let c = AISegmentID(document: 1, page: 1, block: 1, sentence: 3)
        let d = AISegmentID(document: 1, page: 2, block: 1, sentence: 1)
        let blended = AIRetrievalFusionConfiguration(denseWeight: 0.70, lexicalWeight: 0.30)

        let detailed = AIRetrievalFusion.diagnosticCandidates(
            lexical: [a, b, c],
            dense: [b, d, a],
            configuration: blended
        )
        let byID = Dictionary(uniqueKeysWithValues: detailed.map { ($0.id, $0) })
        check(
            byID[a]?.lexicalRank == 1 && byID[a]?.denseRank == 3
                && approximatelyEqual(byID[a]?.finalScore ?? -.infinity, 0.30 / 61.0 + 0.70 / 63.0),
            "Weighted RRF did not use one-based ranks for both channels."
        )
        check(
            byID[b]?.lexicalRank == 2 && byID[b]?.denseRank == 1
                && approximatelyEqual(byID[b]?.finalScore ?? -.infinity, 0.30 / 62.0 + 0.70 / 61.0),
            "Weighted RRF formula changed for a shared candidate."
        )
        check(detailed.map(\.id) == [b, a, d, c], "Weighted RRF produced an unexpected order.")

        let duplicate = AIRetrievalFusion.diagnosticCandidates(
            lexical: [a, a, b, a],
            dense: [],
            configuration: blended
        )
        check(
            duplicate.map(\.id) == [a, b]
                && duplicate.map(\.lexicalRank) == [1, 2]
                && approximatelyEqual(duplicate[1].finalScore, 0.30 / 62.0),
            "A duplicate stable ID consumed rank or appeared more than once."
        )

        let denseOnlyInput = AIRetrievalFusion.fuse(
            lexical: [],
            dense: [c, b, a],
            configuration: blended
        )
        check(
            denseOnlyInput.map(\.id) == [c, b, a]
                && approximatelyEqual(denseOnlyInput[0].score, 0.70 / 61.0),
            "A single dense channel did not preserve its ranking."
        )
        let lexicalOnlyInput = AIRetrievalFusion.fuse(
            lexical: [a, c, b],
            dense: [],
            configuration: blended
        )
        check(
            lexicalOnlyInput.map(\.id) == [a, c, b]
                && approximatelyEqual(lexicalOnlyInput[0].score, 0.30 / 61.0),
            "A single lexical channel did not preserve its ranking."
        )

        let denseBoundaryResults = AIRetrievalFusion.fuse(
            lexical: [a, b],
            dense: [c, b],
            configuration: frozen
        )
        check(
            denseBoundaryResults.map(\.id) == [c, b]
                && approximatelyEqual(denseBoundaryResults[0].score, 1.0 / 61.0),
            "The frozen 1/0 configuration did not reproduce dense ranking."
        )
        check(
            AIRetrievalFusion.fuse(lexical: [a, b], dense: [], configuration: frozen).isEmpty,
            "The zero-weight frozen lexical channel contributed candidates."
        )
        let lexicalBoundary = AIRetrievalFusionConfiguration(denseWeight: 0, lexicalWeight: 1)
        let lexicalBoundaryResults = AIRetrievalFusion.fuse(
            lexical: [a, b],
            dense: [c, b],
            configuration: lexicalBoundary
        )
        check(
            lexicalBoundaryResults.map(\.id) == [a, b]
                && approximatelyEqual(lexicalBoundaryResults[0].score, 1.0 / 61.0),
            "The 0/1 boundary did not reproduce lexical ranking."
        )

        let tieConfiguration = AIRetrievalFusionConfiguration(denseWeight: 0.5, lexicalWeight: 0.5)
        let tied = AIRetrievalFusion.fuse(
            lexical: [b, a],
            dense: [a, b],
            configuration: tieConfiguration
        )
        check(
            tied.map(\.id) == [a, b] && approximatelyEqual(tied[0].score, tied[1].score),
            "Equal fusion scores did not use AISegmentID as the tie-break."
        )

        let rawScoresIgnored = AIRetrievalFusion.fuse(
            lexical: [AISegmentSearchResult(id: a, score: -1_000), AISegmentSearchResult(id: b, score: 1_000)],
            dense: [AISegmentSearchResult(id: b, score: -.infinity), AISegmentSearchResult(id: a, score: .infinity)],
            configuration: tieConfiguration
        )
        check(rawScoresIgnored == tied, "Fusion mixed lexical or cosine raw scores into RRF.")

        let baseline = AIRetrievalFusion.fuse(
            lexical: [a, b, a, c],
            dense: [b, d, a, d],
            configuration: blended
        )
        check(
            (0..<20).allSatisfy { _ in
                AIRetrievalFusion.fuse(
                    lexical: [a, b, a, c],
                    dense: [b, d, a, d],
                    configuration: blended
                ) == baseline
            },
            "Repeated fusion changed configuration, scores, or ordering."
        )

        return Report(checks: checks, failures: failures)
    }
}
