import CoreML
import Foundation

nonisolated struct AIEmbeddingManifest: Codable, Sendable {
    let schema: Int
    let model: String
    let revision: String
    let dimensions: Int
    let maximumTokens: Int
    let tokenizer: String
    let pooling: String
    let precision: String
    let queryPrefix: String
    let files: [String: String]

    func validate() throws {
        guard schema == 1, model == "BAAI/bge-small-en-v1.5",
              revision == "5c38ec7c405ec4b44b94cc5a9bb96e735b38267a",
              dimensions == 384, maximumTokens == 512,
              tokenizer == AIBertWordPieceTokenizer.version, pooling == "cls-l2", precision == "float16",
              queryPrefix == "Represent this sentence for searching relevant passages: ",
              files["vocab.txt"] != nil, files.keys.contains(where: { $0.hasPrefix("embedding.mlmodelc/") }),
              files.count < 100 else { throw AIRetrievalError.invalidModel }
    }
}

/// No downloader in the app. Users explicitly import a developer-converted package.
/// Content hashes detect corruption; they are not a publisher signature.
actor AILocalEmbeddingModels {
    static let shared = AILocalEmbeddingModels()
    nonisolated static var root: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PDFWorkBench/EvidenceRAG", isDirectory: true)
    }

    nonisolated static func packageURL(_ id: String) throws -> URL {
        guard id.count == 64, id.allSatisfy({ $0.isHexDigit && !$0.isUppercase }) else {
            throw AIRetrievalError.invalidSelection
        }
        return root.appendingPathComponent("Models/\(id)", isDirectory: true)
    }

    func install(from source: URL) async throws -> String {
        let (manifest, id) = try Self.validatePackage(at: source)
        let destination = try Self.packageURL(id)
        let manager = FileManager.default
        let parent = destination.deletingLastPathComponent()
        try manager.createDirectory(at: parent, withIntermediateDirectories: true,
                                    attributes: [.posixPermissions: 0o700])
        if manager.fileExists(atPath: destination.path) {
            _ = try Self.validatePackage(at: destination, expectedID: id)
            return id
        }
        let temporary = parent.appendingPathComponent("import-\(UUID().uuidString)")
        defer { if manager.fileExists(atPath: temporary.path) { try? manager.removeItem(at: temporary) } }
        try Self.copyPackage(from: source, manifest: manifest, to: temporary)
        // Validate the copied bytes too: a source can change during import.
        _ = try Self.validatePackage(at: temporary, expectedID: id)
        let smokeModel = try AICoreMLEmbedder(packageURL: temporary, packageID: id)
        _ = try await smokeModel.embedQuery("document evidence")
        try Self.restrictPermissions(at: temporary)
        try Task.checkCancellation()
        if manager.fileExists(atPath: destination.path) {
            _ = try Self.validatePackage(at: destination, expectedID: id)
        } else {
            try manager.moveItem(at: temporary, to: destination)
        }
        return id
    }

    /// Copy only verified assets. Finder may add .DS_Store while the user browses
    /// a package; that metadata is neither model input nor part of its identity.
    nonisolated static func copyPackage(from source: URL, manifest: AIEmbeddingManifest, to destination: URL) throws {
        let manager = FileManager.default
        try manager.createDirectory(at: destination, withIntermediateDirectories: false,
                                    attributes: [.posixPermissions: 0o700])
        for path in ["manifest.json"] + manifest.files.keys.sorted() {
            try Task.checkCancellation()
            let target = destination.appendingPathComponent(path)
            try manager.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true,
                                        attributes: [.posixPermissions: 0o700])
            try manager.copyItem(at: source.appendingPathComponent(path), to: target)
        }
    }

    private nonisolated static func restrictPermissions(at root: URL) throws {
        let manager = FileManager.default
        try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
        if let entries = manager.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey]) {
            for case let url as URL in entries {
                let directory = try url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true
                try manager.setAttributes([.posixPermissions: directory ? 0o700 : 0o600], ofItemAtPath: url.path)
            }
        }
    }

    nonisolated static func validatePackage(at root: URL, expectedID: String? = nil) throws -> (AIEmbeddingManifest, String) {
        let manager = FileManager.default
        guard manager.fileExists(atPath: root.path) else { throw AIRetrievalError.modelMissing }
        guard try root.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else {
            throw AIRetrievalError.invalidModel
        }
        let manifestURL = root.appendingPathComponent("manifest.json")
        let size = try manifestURL.resourceValues(forKeys: [.fileSizeKey, .isSymbolicLinkKey])
        guard size.isSymbolicLink != true, (size.fileSize ?? Int.max) < 100_000 else {
            throw AIRetrievalError.invalidModel
        }
        let data = try Data(contentsOf: manifestURL)
        let id = AIRetrievalHash.data(data)
        if let expectedID, id != expectedID { throw AIRetrievalError.invalidModel }
        let manifest = try JSONDecoder().decode(AIEmbeddingManifest.self, from: data)
        try manifest.validate()
        var actualFiles = Set<String>()
        var total = 0
        guard let entries = manager.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]) else {
            throw AIRetrievalError.invalidModel
        }
        for case let url as URL in entries {
            try Task.checkCancellation()
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
            guard values.isSymbolicLink != true else { throw AIRetrievalError.invalidModel }
            guard values.isRegularFile == true else { continue }
            if url.lastPathComponent == ".DS_Store" { continue }
            let relative = String(url.path.dropFirst(root.path.count + 1))
            if relative == "manifest.json" { continue }
            total += values.fileSize ?? 0
            guard total <= 300_000_000, let hash = manifest.files[relative],
                  hash.count == 64, try AIRetrievalHash.file(url) == hash else { throw AIRetrievalError.invalidModel }
            actualFiles.insert(relative)
        }
        guard actualFiles == Set(manifest.files.keys) else { throw AIRetrievalError.invalidModel }
        return (manifest, id)
    }
}

actor AICoreMLEmbedder {
    let manifest: AIEmbeddingManifest
    let tokenizer: AIBertWordPieceTokenizer
    private let model: MLModel

    init(packageURL: URL, packageID: String) throws {
        let (manifest, _) = try AILocalEmbeddingModels.validatePackage(at: packageURL, expectedID: packageID)
        self.manifest = manifest
        tokenizer = try AIBertWordPieceTokenizer(vocabulary: String(contentsOf: packageURL.appendingPathComponent("vocab.txt"), encoding: .utf8))
        let configuration = MLModelConfiguration()
        // Explicit CPU baseline first; device/ANE tuning needs separate measurements.
        configuration.computeUnits = .cpuOnly
        model = try MLModel(contentsOf: packageURL.appendingPathComponent("embedding.mlmodelc"), configuration: configuration)
    }

    func embedQuery(_ text: String) throws -> [Float] {
        try embed(tokens: tokenizer.tokens(manifest.queryPrefix + text))
    }

    func embed(tokens: [Int32]) throws -> [Float] {
        try Task.checkCancellation()
        guard tokens.count + 2 <= manifest.maximumTokens else { throw AIRetrievalError.inputTooLong }
        let values: [Int32] = [101] + tokens + [102]
        let ids = try MLMultiArray(shape: [1, NSNumber(value: values.count)], dataType: .int32)
        let mask = try MLMultiArray(shape: [1, NSNumber(value: values.count)], dataType: .int32)
        for index in values.indices { ids[index] = NSNumber(value: values[index]); mask[index] = 1 }
        let input = try MLDictionaryFeatureProvider(dictionary: ["input_ids": ids, "attention_mask": mask])
        let output = try model.prediction(from: input)
        try Task.checkCancellation()
        guard let array = output.featureValue(for: "embedding")?.multiArrayValue,
              array.count == manifest.dimensions else { throw AIRetrievalError.invalidVector }
        let vector = (0..<array.count).map { array[$0].floatValue }
        guard vector.allSatisfy(\.isFinite) else { throw AIRetrievalError.invalidVector }
        let norm = sqrt(vector.reduce(0) { $0 + $1 * $1 })
        guard norm.isFinite, norm > 0.0001 else { throw AIRetrievalError.invalidVector }
        return vector.map { $0 / norm }
    }
}

nonisolated struct AIEmbeddingIndexCache: Codable, Sendable {
    let key: String
    let ids: [[AISegmentID]]
    let vectors: [[Float]]

    static func key(registry: AISegmentRegistry, packageID: String, chunks: [AIEmbeddingChunk]) throws -> String {
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        let chunkHash = AIRetrievalHash.data(try encoder.encode(chunks))
        return AIRetrievalHash.data(Data("index-v1|whole-adjacent-3-254|\(registry.snapshotFingerprint)|\(registry.segmenterVersion)|\(packageID)|\(chunkHash)".utf8))
    }

    func isValid(key expected: String, chunks: [AIEmbeddingChunk], dimensions: Int) -> Bool {
        key == expected && ids == chunks.map(\.ids) && vectors.count == chunks.count
            && vectors.allSatisfy { vector in
                vector.count == dimensions && vector.allSatisfy(\.isFinite)
                    && abs(vector.reduce(0) { $0 + $1 * $1 } - 1) < 0.01
            }
    }
}

nonisolated enum AIEvidenceRetrievalFactory {
    static func make(
        selection: AIRetrievalSelection,
        registry: AISegmentRegistry,
        progress: (@Sendable (Int, Int) async -> Void)? = nil,
        indexed: (@Sendable (Int, Bool, Double) async -> Void)? = nil,
        packageURL: URL? = nil,
        cacheRoot: URL? = nil
    ) async throws -> any AIEvidenceRetrieving {
        guard selection.mode == .scheme2EvidenceRAG else { return AILexicalEvidenceRetriever(registry: registry) }
        let started = Date()
        guard let packageID = selection.packageID else { throw AIRetrievalError.modelMissing }
        await progress?(0, 0)
        try Task.checkCancellation()
        let embedder = try AICoreMLEmbedder(packageURL: packageURL ?? AILocalEmbeddingModels.packageURL(packageID), packageID: packageID)
        let chunks = try AIEmbeddingChunk.make(registry: registry, tokenizer: embedder.tokenizer)
        let key = try AIEmbeddingIndexCache.key(registry: registry, packageID: packageID, chunks: chunks)
        let root = cacheRoot ?? AILocalEmbeddingModels.root.appendingPathComponent("Indexes", isDirectory: true)
        let url = root.appendingPathComponent("\(key).json")
        let manager = FileManager.default
        var vectors: [[Float]] = []
        var cacheHit = false
        if let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isSymbolicLinkKey]),
           values.isSymbolicLink != true, (values.fileSize ?? Int.max) < 200_000_000,
           let data = try? Data(contentsOf: url),
           let cached = try? JSONDecoder().decode(AIEmbeddingIndexCache.self, from: data),
           cached.isValid(key: key, chunks: chunks, dimensions: 384) {
            vectors = cached.vectors
            cacheHit = true
            await progress?(chunks.count, chunks.count)
        } else {
            await progress?(0, chunks.count)
            for (index, chunk) in chunks.enumerated() {
                try Task.checkCancellation()
                vectors.append(try await embedder.embed(tokens: chunk.tokens))
                await progress?(index + 1, chunks.count)
            }
            try Task.checkCancellation()
            let cache = AIEmbeddingIndexCache(key: key, ids: chunks.map(\.ids), vectors: vectors)
            try manager.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let data = try JSONEncoder().encode(cache)
            // Complete cache only; write with restrictive mode before atomic rename.
            let temp = root.appendingPathComponent("\(UUID().uuidString).partial")
            defer { try? manager.removeItem(at: temp) }
            guard manager.createFile(atPath: temp.path, contents: data, attributes: [.posixPermissions: 0o600]) else {
                throw CocoaError(.fileWriteUnknown)
            }
            try Task.checkCancellation()
            if manager.fileExists(atPath: url.path) {
                guard try url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else {
                    throw AIRetrievalError.invalidModel
                }
                _ = try manager.replaceItemAt(url, withItemAt: temp)
            } else {
                try manager.moveItem(at: temp, to: url)
            }
        }
        await indexed?(chunks.count, cacheHit, Date().timeIntervalSince(started))
        return AIHybridEvidenceRetriever(registry: registry, embedder: embedder, chunks: chunks, vectors: vectors)
    }
}
