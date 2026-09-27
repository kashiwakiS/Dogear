import Foundation

nonisolated enum AIBM25Diagnostics {
    struct Report {
        let checks: Int
        let failures: [String]
    }

    static func run() -> Report {
        var checks = 0
        var failures: [String] = []
        func check(_ condition: @autoclosure () -> Bool, _ message: String) {
            checks += 1
            if !condition() { failures.append(message) }
        }
        func close(_ lhs: Double, _ rhs: Double, tolerance: Double = 1e-12) -> Bool {
            abs(lhs - rhs) <= tolerance
        }
        func id(_ document: Int, _ page: Int = 1, _ sentence: Int = 1) -> AISegmentID {
            AISegmentID(document: document, page: page, block: 1, sentence: sentence)
        }
        func prepared(_ segments: [(AISegmentID, String)]) throws -> AIBM25PreparedIndex {
            var builder = AIBM25IndexBuilder()
            builder.rebuild(segments: segments.map { (id: $0.0, text: $0.1) })
            return try AIBM25PreparedIndex(data: builder.build())
        }

        let tokenizer = AILexicalTokenizer()
        check(tokenizer.version == AILexicalTokenizer.currentVersion, "Tokenizer profile version drifted.")
        check(tokenizer.tokens("ＦｌａｓｈＡｔｔｅｎｔｉｏｎ CAFÉ") == ["flashattention", "cafe"],
              "NFKC, width, case or diacritic normalization is unstable.")
        check(tokenizer.tokens("A100-SXM4 v2.1 C++ C# fp16/bf16 2024")
            == ["a100-sxm4", "v2.1", "c++", "c#", "fp16/bf16", "2024"],
              "Technical connectors or numeric identifiers were not preserved.")
        check(tokenizer.tokens("cat, a; concatenate") == ["cat", "a", "concatenate"],
              "Punctuation did not form strict token boundaries.")
        check(tokenizer.tokens("O(n²)") == ["o", "n2"], "Compatibility normalization lost scientific notation.")
        check(tokenizer.tokens("注意力机制 显存占用") == ["注", "意", "力", "机", "制", "显", "存", "占", "用"],
              "The deterministic CJK unit-token baseline changed.")
        check(tokenizer.tokens("  … — !!! ").isEmpty, "Whitespace or punctuation produced lexical tokens.")

        let expectedIDF = log(1 + (Double(10 - 2) + 0.5) / (Double(2) + 0.5))
        check(close(AIBM25PreparedIndex.inverseDocumentFrequency(documentCount: 10, documentFrequency: 2), expectedIDF),
              "BM25 IDF no longer uses the frozen log1p Robertson formula.")
        check(AIBM25PreparedIndex.inverseDocumentFrequency(documentCount: 0, documentFrequency: 0) == 0,
              "Empty-corpus IDF is not explicit.")
        let one = AIBM25PreparedIndex.termContribution(termFrequency: 1, documentLength: 10,
            averageDocumentLength: 10, inverseDocumentFrequency: 1)
        let two = AIBM25PreparedIndex.termContribution(termFrequency: 2, documentLength: 10,
            averageDocumentLength: 10, inverseDocumentFrequency: 1)
        check(two > one && two < one * 2, "BM25 term frequency is not saturating.")
        let short = AIBM25PreparedIndex.termContribution(termFrequency: 1, documentLength: 5,
            averageDocumentLength: 20, inverseDocumentFrequency: 1)
        let long = AIBM25PreparedIndex.termContribution(termFrequency: 1, documentLength: 80,
            averageDocumentLength: 20, inverseDocumentFrequency: 1)
        check(short > long, "BM25 length normalization did not favor the shorter equal-TF segment.")
        check(AIBM25Parameters.frozen.k1 == 1.2 && AIBM25Parameters.frozen.b == 0.75,
              "Frozen BM25 parameters changed.")

        do {
            let boundary = try prepared([(id(1), "concatenate only"), (id(2), "a standalone token")])
            check(boundary.search(AISegmentSearchRequest(query: "cat")).isEmpty,
                  "A query token matched an arbitrary substring.")
            check(boundary.search(AISegmentSearchRequest(query: "a")).map(\.id) == [id(2)],
                  "A single-character token escaped strict boundaries.")

            let technical = try prepared([
                (id(1), "A100-SXM4 uses C++ and version v2.1 in 2024."),
                (id(2), "A100 SXM4 uses another language in 2023.")
            ])
            for query in ["A100-SXM4", "C++", "v2.1", "2024"] {
                check(technical.search(AISegmentSearchRequest(query: query)).first?.id == id(1),
                      "Technical query \(query) did not retain its exact token.")
            }
            let chinese = try prepared([(id(1), "该方法显著降低显存占用。"), (id(2), "该方法提高训练速度。")])
            check(chinese.search(AISegmentSearchRequest(query: "显存占用")).first?.id == id(1),
                  "Chinese lexical retrieval did not use the shared CJK tokenizer.")

            let frequency = try prepared([(id(1), "signal signal signal"), (id(2), "signal")])
            let frequencyResults = frequency.search(AISegmentSearchRequest(query: "signal", topK: 2))
            check(frequencyResults.map(\.id) == [id(1), id(2)], "Higher TF did not rank first.")
            check((frequencyResults.first?.score ?? 0) < (frequencyResults.last?.score ?? 0) * 3,
                  "Repeated TF grew linearly instead of saturating.")

            let filler = Array(repeating: "filler", count: 80).joined(separator: " ")
            let lengths = try prepared([(id(1), "target"), (id(2), "target \(filler)")])
            check(lengths.search(AISegmentSearchRequest(query: "target", topK: 2)).map(\.id) == [id(1), id(2)],
                  "Segment length normalization changed ordering.")
            check(lengths.search(AISegmentSearchRequest(query: "target target target"))
                == lengths.search(AISegmentSearchRequest(query: "target")),
                  "Repeated query terms changed the frozen unique-term semantics.")
            check(lengths.search(AISegmentSearchRequest(query: "… !!!")).isEmpty,
                  "An empty normalized query returned results.")
            let empty = try prepared([])
            check(empty.search(AISegmentSearchRequest(query: "target")).isEmpty,
                  "An empty index returned results.")

            let tied = try prepared([(id(2), "same"), (id(1), "same")])
            check(tied.search(AISegmentSearchRequest(query: "same", topK: 2)).map(\.id) == [id(1), id(2)],
                  "Equal BM25 scores did not use stable segment-ID ordering.")
            check(tied.search(AISegmentSearchRequest(query: "same", topK: 2))
                == tied.search(AISegmentSearchRequest(query: "same", topK: 2)),
                  "An immutable prepared index changed on reuse.")

            let scoped = try prepared([
                (id(1, 1), "target"),
                (id(1, 2), "target target filler"),
                (id(2, 1), "unrelated filler filler filler")
            ])
            let allStats = scoped.scopedStatistics(query: "target")
            let pageStats = scoped.scopedStatistics(query: "target", scope: AISegmentScope(pageRange: 2...2))
            check(allStats.segmentCount == 3 && allStats.documentFrequency["target"] == 2,
                  "Whole-corpus segment statistics are incorrect.")
            check(pageStats.segmentCount == 1 && pageStats.totalSegmentLength == 3
                && pageStats.averageSegmentLength == 3 && pageStats.documentFrequency["target"] == 1,
                  "Page scope did not recompute N, average length and df.")
            let documentScope = AISegmentScope(documentNumbers: [2])
            check(scoped.search(AISegmentSearchRequest(query: "target", scope: documentScope)).isEmpty,
                  "Document scope leaked postings or full-corpus statistics.")
            let blockScope = AISegmentScope(blockIDs: [id(1, 2)])
            check(scoped.search(AISegmentSearchRequest(query: "target", scope: blockScope)).map(\.id) == [id(1, 2)],
                  "Block scope returned an unauthorized segment.")
        } catch {
            check(false, "Prepared-index diagnostics failed: \(error)")
        }

        do {
            var incremental = AIBM25IndexBuilder()
            incremental.upsert(id: id(2), text: "beta beta")
            incremental.upsert(id: id(1), text: "alpha")
            check(incremental.segmentCount == 2, "Index add did not track stable IDs.")
            incremental.upsert(id: id(1), text: "gamma")
            let updated = try AIBM25PreparedIndex(data: incremental.build())
            check(updated.search(AISegmentSearchRequest(query: "alpha")).isEmpty
                && updated.search(AISegmentSearchRequest(query: "gamma")).map(\.id) == [id(1)],
                  "Index update retained stale terms or duplicated a stable ID.")
            check(incremental.remove(id: id(2)) && !incremental.remove(id: id(2)),
                  "Index remove did not report its deterministic state change.")
            let removed = try AIBM25PreparedIndex(data: incremental.build())
            check(removed.search(AISegmentSearchRequest(query: "beta")).isEmpty,
                  "Removed postings remained queryable.")

            incremental.upsert(id: id(2), text: "beta beta")
            var rebuilt = AIBM25IndexBuilder()
            rebuilt.rebuild(segments: [(id: id(1), text: "gamma"), (id: id(2), text: "beta beta")])
            check(incremental.build() == rebuilt.build(),
                  "Incremental add/update/remove and deterministic rebuild diverged.")
            let first = try AIBM25PreparedIndex(data: incremental.build())
            let second = try AIBM25PreparedIndex(data: rebuilt.build())
            check(first.search(AISegmentSearchRequest(query: "beta gamma", topK: 2))
                == second.search(AISegmentSearchRequest(query: "beta gamma", topK: 2)),
                  "Rebuilt index changed ranking semantics.")

            let completeBeforeCancellation = incremental.build()
            var cancellationChecks = 0
            do {
                try incremental.rebuildCheckingCancellation(
                    segments: [(id: id(1), text: "replacement"), (id: id(2), text: "replacement")],
                    checkCancellation: {
                        cancellationChecks += 1
                        if cancellationChecks == 3 { throw CancellationError() }
                    }
                )
                check(false, "A cancelled index rebuild completed.")
            } catch is CancellationError {
                check(incremental.build() == completeBeforeCancellation,
                      "A cancelled index rebuild exposed partial contents.")
            } catch {
                check(false, "Cancelled rebuild returned the wrong error: \(error)")
            }
            var checkedRebuild = AIBM25IndexBuilder()
            try checkedRebuild.rebuildCheckingCancellation(
                segments: [(id: id(1), text: "gamma"), (id: id(2), text: "beta beta")]
            )
            check(checkedRebuild.build() == rebuilt.build(),
                  "Cancellation-safe rebuild changed complete index semantics.")
        } catch {
            check(false, "Builder lifecycle diagnostics failed: \(error)")
        }

        do {
            var builder = AIBM25IndexBuilder()
            builder.upsert(id: id(1), text: "token")
            let data = builder.build()
            let staleTokenizer = AILexicalTokenizer(version: "fixture-old-tokenizer")
            _ = try AIBM25PreparedIndex(data: data, tokenizer: staleTokenizer)
            check(false, "A mismatched tokenizer profile reused index data.")
        } catch AIBM25IndexError.incompatibleTokenizer {
            check(true, "Tokenizer mismatch was rejected.")
        } catch {
            check(false, "Tokenizer mismatch returned the wrong error: \(error)")
        }

        return Report(checks: checks, failures: failures)
    }
}
