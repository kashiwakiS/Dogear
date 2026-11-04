import Foundation

/// Derived source and retrieval artifacts share the legacy app-private root.
/// Resolving this path does not create a model directory or load a model.
nonisolated enum AIRetrievalCachePaths {
    static var root: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PDFWorkBench/EvidenceRAG", isDirectory: true)
    }
}
