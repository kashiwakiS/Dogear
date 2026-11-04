import Foundation

/// Exercises the actual shared factory and BM25 backend on either native SDK.
nonisolated enum AILexicalPlatformDiagnostics {
    static func run() async -> (checks: Int, failures: [String]) {
        var checks = 0
        var failures: [String] = []
        func check(_ value: Bool, _ message: String) {
            checks += 1
            if !value { failures.append(message) }
        }

        let suite = "Dogear-LexicalPlatform-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(AIRetrievalMode.scheme2EvidenceRAG.rawValue, forKey: AIRetrievalMode.defaultsKey)
        defaults.set(String(repeating: "a", count: 64), forKey: AIRetrievalSelection.packageDefaultsKey)
        #if os(macOS)
        check((try? AIRetrievalSelection.capture(from: defaults).mode) == .scheme2EvidenceRAG,
              "Mac retrieval selection stopped preserving the configured Dense mode.")
        check(AILocalEmbeddingModels.root == AIRetrievalCachePaths.root,
              "Mac model/cache root changed during shared path extraction.")
        #else
        check((try? AIRetrievalSelection.capture(from: defaults).mode) == .scheme1Lexical,
              "iPad inherited an unsupported Dense selection.")
        #endif
        check(AIRetrievalCachePaths.root == FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PDFWorkBench/EvidenceRAG", isDirectory: true),
              "The derived retrieval cache no longer uses the legacy EvidenceRAG path.")

        do {
            let firstID = UUID()
            let secondID = UUID()
            let emptyID = UUID()
            let sources = [
                source(firstID, name: "First", text: "Orchard evidence explains apple farming. Soil supports apple roots."),
                source(secondID, name: "Second", text: "Orchard evidence explains apple harvest. Picking apples is seasonal."),
                source(emptyID, name: "Image only", text: "")
            ]
            let registry = try AISegmentRegistry(sources: sources)
            let backend = AIInMemoryBM25IndexBackend()
            let prepared = try await AIEvidenceRetrievalFactory.makeSources(
                selection: .lexical, registry: registry, lexicalBackend: backend
            )
            check(prepared.coverage.requestedCount == 3 && prepared.coverage.preparedFileIDs == [firstID, secondID],
                  "Shared preparation lost ordered multi-file identities or coverage.")
            check(prepared.coverage.skipped.map(\.fileID) == [emptyID],
                  "An image-only source was not reported as skipped.")
            let request = AISegmentSearchRequest(query: "orchard apple evidence", topK: 4)
            let results = try await prepared.retriever.search(request)
            check(Set(results.map { $0.id.document }) == [1, 2],
                  "Multi-file BM25 omitted a selected text source.")
            check(results.allSatisfy { registry.record(for: $0.id) != nil },
                  "BM25 returned an evidence ID outside the fixed source registry.")
            let scoped = try await prepared.retriever.search(AISegmentSearchRequest(
                query: "apple", scope: AISegmentScope(documentNumbers: [2]), topK: 4
            ))
            check(!scoped.isEmpty && scoped.allSatisfy { $0.id.document == 2 },
                  "The shared source retriever ignored document scope.")
            let reordered = try AISegmentRegistry(sources: [sources[1], sources[0]])
            let reorderedPrepared = try await AIEvidenceRetrievalFactory.makeSources(
                selection: .lexical, registry: reordered, lexicalBackend: backend
            )
            check(reorderedPrepared.coverage.preparedFileIDs == [secondID, firstID],
                  "Reordered request ordinals changed file identity.")
            let reorderedResults = try await reorderedPrepared.retriever.search(request)
            check(reorderedResults.allSatisfy { reordered.record(for: $0.id) != nil },
                  "Reordered BM25 returned stale document ordinals.")

            let single = try AISegmentRegistry(snapshot: sources[0].snapshot)
            let emptySingle = try AISegmentRegistry(snapshot: sources[2].snapshot)
            let emptyMultiple = try AISegmentRegistry(sources: [sources[2]])
            for (name, value) in [("single", single), ("empty single", emptySingle), ("empty multiple", emptyMultiple)] {
                let shared = try await AIEvidenceRetrievalFactory.makeSources(
                    selection: .lexical, registry: value, lexicalBackend: backend
                )
                let actual = try await shared.retriever.search(request)
                if value.records.isEmpty {
                    check(actual.isEmpty, "Shared \(name) preparation fabricated evidence.")
                } else {
                    check(!actual.isEmpty, "Shared \(name) preparation lost extractable text.")
                }
                #if os(macOS)
                let explicit = try await AIEvidenceRetrievalFactory.makeSources(
                    selection: .lexical, registry: value, sharedEmbedder: nil, lexicalBackend: backend
                )
                let explicitResults = try await explicit.retriever.search(request)
                check(actual == explicitResults && shared.coverage == explicit.coverage,
                      "Mac explicit nil embedder changed shared \(name) preparation.")
                #endif
            }

            #if os(macOS)
            let explicit = try await AIEvidenceRetrievalFactory.makeSources(
                selection: .lexical, registry: registry, sharedEmbedder: nil, lexicalBackend: backend
            )
            let explicitResults = try await explicit.retriever.search(request)
            check(results == explicitResults && prepared.coverage == explicit.coverage,
                  "Mac explicit nil embedder diverged from shared multi-file preparation.")
            #else
            let unusedCache = FileManager.default.temporaryDirectory
                .appendingPathComponent("Dogear-UnsupportedDense-\(UUID().uuidString)")
            do {
                _ = try await AIEvidenceRetrievalFactory.makeSources(
                    selection: AIRetrievalSelection(mode: .scheme2EvidenceRAG, packageID: nil),
                    registry: emptySingle, cacheRoot: unusedCache, lexicalBackend: backend
                )
                check(false, "iPad accepted an explicit Dense request.")
            } catch {
                check(error as? AIRetrievalError == .invalidSelection,
                      "iPad did not reject Dense before model/cache preparation.")
            }
            check(!FileManager.default.fileExists(atPath: unusedCache.path),
                  "An unsupported iPad Dense request created a model/cache directory.")
            do {
                _ = try AIMultiSourceEvidenceRetriever(sources: [], mode: .scheme2EvidenceRAG, registry: emptySingle)
                check(false, "The iPad multi-source adapter accepted Dense mode.")
            } catch {
                check(error as? AIRetrievalError == .invalidSelection,
                      "The iPad Dense adapter returned an unexpected error.")
            }
            #endif

            do {
                _ = try await AIEvidenceRetrievalFactory.makeSources(
                    selection: .lexical, registry: registry, lexicalBackend: backend,
                    lexicalPreparationBudget: .zero
                )
                check(false, "Shared lexical preparation ignored its time budget.")
            } catch {
                check(error as? AIRetrievalError == .preparationTimedOut,
                      "Shared lexical preparation changed its time-budget error.")
            }
            let cancelled = Task {
                withUnsafeCurrentTask { $0?.cancel() }
                return try await AIEvidenceRetrievalFactory.makeSources(
                    selection: .lexical, registry: registry, lexicalBackend: backend
                )
            }
            do {
                _ = try await cancelled.value
                check(false, "Cancelled lexical preparation published an index.")
            } catch {
                check(error is CancellationError, "Lexical cancellation changed into another error.")
            }
        } catch {
            check(false, "Shared lexical platform fixture failed: \(error)")
        }
        return (checks, failures)
    }

    private static func source(_ id: UUID, name: String, text: String) -> AIWorkflowSourceSnapshot {
        AIWorkflowSourceSnapshot(fileID: id, displayName: name, snapshot: AIHighlightTextSnapshot(
            fingerprint: "snapshot-\(id)",
            pages: [AITextPageSnapshot(pageNumber: 1, text: text, fingerprint: "page-\(id)")]
        ))
    }
}
