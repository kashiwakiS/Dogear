import Foundation
import PDFKit
import SQLite3

nonisolated enum AIRetrievalSourceSnapshotCacheDiagnostics {
    static func run() async -> (checks: Int, failures: [String]) {
        var checks = 0
        var failures: [String] = []
        func check(_ condition: @autoclosure () -> Bool, _ message: String) {
            checks += 1
            if !condition() { failures.append(message) }
        }

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("DogearSourceSnapshotCache-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let databaseURL = root.appendingPathComponent("source.sqlite3")
        let cache = AIRetrievalSourceSnapshotCache(databaseURL: databaseURL)
        let fileID = UUID()
        let snapshot = AIHighlightTextSnapshot(
            fingerprint: "semantic-text-v1",
            pages: [AITextPageSnapshot(
                pageNumber: 1,
                text: "First finding. Supporting detail.",
                fingerprint: "page-text-v1"
            )]
        )
        let records = AISegmenter().segments(from: snapshot, documentNumber: 1)
        let first = AIRetrievalSourceSnapshotCacheEntry(
            fastRevision: "bytes-v1",
            contentVersion: "broad-version-with-annotation-a",
            snapshot: snapshot,
            snapshotProfile: AINativeTextSnapshotProfile.current,
            segmenterVersion: AISegmenter.currentVersion,
            records: records
        )

        let initializationURL = root
            .appendingPathComponent("initialization-retry", isDirectory: true)
            .appendingPathComponent("source.sqlite3")
        let failedInitialization = AIRetrievalSourceSnapshotCache(
            databaseURL: initializationURL,
            diagnosticInitializationFailure: true
        )
        await failedInitialization.store(fileID: fileID, entry: first)
        await failedInitialization.closeForDiagnostics()
        check(
            ["", "-journal", "-wal", "-shm"].allSatisfy {
                !FileManager.default.fileExists(atPath: initializationURL.path + $0)
            },
            "A failed first source-cache initialization left an unclaimable database or sidecar."
        )
        let initializationRetry = AIRetrievalSourceSnapshotCache(databaseURL: initializationURL)
        await initializationRetry.store(fileID: fileID, entry: first)
        let initializationRetryEntry = await initializationRetry.exact(
            fileID: fileID,
            fastRevision: "bytes-v1",
            segmenterVersion: AISegmenter.currentVersion
        )
        check(
            initializationRetryEntry?.records == records,
            "Source cache initialization could not retry after its first-open failure."
        )
        await initializationRetry.closeForDiagnostics()

        await cache.store(fileID: fileID, entry: first)
        let firstGenerationCount = await cache.generationCount()
        check(firstGenerationCount == 1, "Source cache did not publish one atomic generation.")

        let exact = await cache.exact(
            fileID: fileID,
            fastRevision: "bytes-v1",
            segmenterVersion: AISegmenter.currentVersion
        )
        check(exact?.snapshot == snapshot && exact?.records == records,
              "An unchanged byte revision did not reuse its extracted text and sentence records.")
        let databaseAttributes = try? FileManager.default.attributesOfItem(
            atPath: databaseURL.path
        )
        let directoryAttributes = try? FileManager.default.attributesOfItem(
            atPath: root.path
        )
        let databaseMode = databaseAttributes?[.posixPermissions] as? NSNumber
        let directoryMode = directoryAttributes?[.posixPermissions] as? NSNumber
        let excluded = try? root.resourceValues(forKeys: [.isExcludedFromBackupKey])
            .isExcludedFromBackup
        check(databaseMode?.intValue == 0o600 && directoryMode?.intValue == 0o700,
              "Source snapshot cache permissions were not owner-only.")
        check(excluded == true, "Source snapshot cache directory was not excluded from backup.")

        let semantic = await cache.semantic(
            fileID: fileID,
            snapshotFingerprint: snapshot.fingerprint,
            segmenterVersion: AISegmenter.currentVersion
        )
        check(semantic?.contentVersion == first.contentVersion,
              "The annotation-insensitive text identity did not find its source generation.")

        await cache.closeForDiagnostics()
        let reopened = AIRetrievalSourceSnapshotCache(databaseURL: databaseURL)
        let reopenedExact = await reopened.exact(
            fileID: fileID,
            fastRevision: "bytes-v1",
            segmenterVersion: AISegmenter.currentVersion
        )
        check(reopenedExact?.records == records,
              "Restarting the source cache changed or lost an exact generation.")
        await reopened.closeForDiagnostics()

        let annotationOnly = AIRetrievalSourceSnapshotCacheEntry(
            fastRevision: "bytes-v2-annotation-only",
            contentVersion: "broad-version-with-annotation-b",
            snapshot: snapshot,
            snapshotProfile: AINativeTextSnapshotProfile.current,
            segmenterVersion: AISegmenter.currentVersion,
            records: semantic?.records ?? []
        )
        await cache.store(fileID: fileID, entry: annotationOnly)
        let staleExact = await cache.exact(fileID: fileID, fastRevision: "bytes-v1",
                                           segmenterVersion: AISegmenter.currentVersion)
        check(staleExact == nil,
              "Replacing a source left the stale byte revision addressable.")
        let replacementExact = await cache.exact(
            fileID: fileID,
            fastRevision: "bytes-v2-annotation-only",
            segmenterVersion: AISegmenter.currentVersion
        )
        check(replacementExact?.records == records,
              "An annotation-only source replacement rebuilt or lost the sentence records.")
        let wrongSegmenter = await cache.exact(
            fileID: fileID,
            fastRevision: "bytes-v2-annotation-only",
            segmenterVersion: "future-segmenter"
        )
        check(wrongSegmenter == nil,
              "A segmenter version change reused incompatible sentence records.")
        let wrongSnapshotProfile = await cache.exact(
            fileID: fileID,
            fastRevision: "bytes-v2-annotation-only",
            snapshotProfile: "future-native-text-profile",
            segmenterVersion: AISegmenter.currentVersion
        )
        check(wrongSnapshotProfile == nil,
              "A native text extraction/fingerprint profile change reused an old snapshot.")

        do {
            let prepared = try AISegmentRegistry(sources: [AIWorkflowSourceSnapshot(
                fileID: fileID,
                displayName: "cached.pdf",
                snapshot: snapshot,
                version: annotationOnly.contentVersion,
                preparedRecords: records
            )])
            let rebuilt = try AISegmentRegistry(sources: [AIWorkflowSourceSnapshot(
                fileID: fileID,
                displayName: "cached.pdf",
                snapshot: snapshot,
                version: first.contentVersion
            )])
            check(prepared.records == rebuilt.records,
                  "Prepared records changed the canonical sentence registry.")
            check(prepared.indexIdentity == rebuilt.indexIdentity,
                  "Annotation-only broad versions changed the retrieval cache identity.")
        } catch {
            failures.append("Prepared source registry validation failed: \(error.localizedDescription)")
        }

        let changedSnapshot = AIHighlightTextSnapshot(
            fingerprint: "semantic-text-v2-page-deleted",
            pages: [AITextPageSnapshot(
                pageNumber: 1,
                text: "First finding.",
                fingerprint: "page-text-v2"
            )]
        )
        let changedSemantic = await cache.semantic(
            fileID: fileID,
            snapshotFingerprint: changedSnapshot.fingerprint,
            segmenterVersion: AISegmenter.currentVersion
        )
        check(changedSemantic == nil,
              "Changed page text incorrectly reused the previous semantic generation.")

        await cache.clearDerivedCache()
        let clearedCount = await cache.generationCount()
        check(clearedCount == 0,
              "Deleting the derived source cache did not produce a safe empty cache.")

        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let obstruction = root.appendingPathComponent("not-a-directory")
            try Data("blocked".utf8).write(to: obstruction)
            let unavailable = AIRetrievalSourceSnapshotCache(
                databaseURL: obstruction.appendingPathComponent("cache.sqlite3")
            )
            await unavailable.store(fileID: fileID, entry: first)
            let unavailableEntry = await unavailable.exact(
                fileID: fileID,
                fastRevision: "bytes-v1",
                segmenterVersion: AISegmenter.currentVersion
            )
            check(unavailableEntry == nil,
                  "An unavailable source cache did not fall back to a miss.")
        } catch {
            failures.append("Could not construct the unavailable-cache fixture: \(error.localizedDescription)")
        }

        do {
            let corruptionRoot = root.appendingPathComponent("corrupt", isDirectory: true)
            let corruptionURL = corruptionRoot.appendingPathComponent("source.sqlite3")
            let corruption = AIRetrievalSourceSnapshotCache(databaseURL: corruptionURL)
            await corruption.store(fileID: fileID, entry: first)
            await corruption.closeForDiagnostics()
            try executeSQLite(
                at: corruptionURL,
                sql: "UPDATE source_generation SET payload = X'00'"
            )
            let corruptedMiss = await corruption.exact(
                fileID: fileID,
                fastRevision: "bytes-v1",
                segmenterVersion: AISegmenter.currentVersion
            )
            check(corruptedMiss == nil && FileManager.default.fileExists(atPath: corruptionURL.path),
                  "A corrupt source row was returned or caused unproven file deletion.")
            await corruption.store(fileID: fileID, entry: first)
            let repaired = await corruption.exact(
                fileID: fileID,
                fastRevision: "bytes-v1",
                segmenterVersion: AISegmenter.currentVersion
            )
            check(repaired?.records == records,
                  "A later atomic source store did not repair a corrupt derived row.")
            await corruption.closeForDiagnostics()
        } catch {
            failures.append("Could not construct the corrupt-cache fixture: \(error.localizedDescription)")
        }

        do {
            let foreignRoot = root.appendingPathComponent("foreign", isDirectory: true)
            try FileManager.default.createDirectory(at: foreignRoot, withIntermediateDirectories: true)
            let foreignURL = foreignRoot.appendingPathComponent("source.sqlite3")
            try executeSQLite(at: foreignURL, sql: "CREATE TABLE foreign_data(value TEXT)")
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o640],
                ofItemAtPath: foreignURL.path
            )
            let before = try Data(contentsOf: foreignURL)
            let modeBefore = try fileMode(foreignURL)
            let foreign = AIRetrievalSourceSnapshotCache(databaseURL: foreignURL)
            await foreign.store(fileID: fileID, entry: first)
            let foreignEntry = await foreign.exact(
                fileID: fileID,
                fastRevision: "bytes-v1",
                segmenterVersion: AISegmenter.currentVersion
            )
            await foreign.closeForDiagnostics()
            let after = try Data(contentsOf: foreignURL)
            let modeAfter = try fileMode(foreignURL)
            check(foreignEntry == nil && before == after && modeBefore == modeAfter,
                  "A non-empty foreign SQLite database was claimed, modified, or chmodded.")
            let foreignApplicationID = try sqliteScalar(
                at: foreignURL,
                sql: "PRAGMA application_id"
            )
            check(foreignApplicationID == 0,
                  "A foreign database received the Dogear application identity.")
        } catch {
            failures.append("Could not construct the foreign-cache fixture: \(error.localizedDescription)")
        }

        do {
            let emptyRoot = root.appendingPathComponent("foreign-empty", isDirectory: true)
            try FileManager.default.createDirectory(at: emptyRoot, withIntermediateDirectories: true)
            let emptyURL = emptyRoot.appendingPathComponent("source.sqlite3")
            try executeSQLite(at: emptyURL, sql: "VACUUM")
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o640],
                ofItemAtPath: emptyURL.path
            )
            let bytesBefore = try Data(contentsOf: emptyURL)
            let modeBefore = try fileMode(emptyURL)
            let empty = AIRetrievalSourceSnapshotCache(databaseURL: emptyURL)
            await empty.store(fileID: fileID, entry: first)
            let entry = await empty.exact(
                fileID: fileID,
                fastRevision: "bytes-v1",
                segmenterVersion: AISegmenter.currentVersion
            )
            await empty.closeForDiagnostics()
            let bytesAfter = try Data(contentsOf: emptyURL)
            let modeAfter = try fileMode(emptyURL)
            let applicationID = try sqliteScalar(at: emptyURL, sql: "PRAGMA application_id")
            check(
                entry == nil
                    && bytesBefore == bytesAfter
                    && modeBefore == modeAfter
                    && applicationID == 0,
                "An empty foreign SQLite database was claimed, modified, or chmodded."
            )
        } catch {
            failures.append("Could not construct the empty foreign-cache fixture: \(error.localizedDescription)")
        }

        do {
            let linkRoot = root.appendingPathComponent("symlink", isDirectory: true)
            try FileManager.default.createDirectory(at: linkRoot, withIntermediateDirectories: true)
            let target = linkRoot.appendingPathComponent("target")
            let link = linkRoot.appendingPathComponent("source.sqlite3")
            let sentinel = Data("foreign-target".utf8)
            try sentinel.write(to: target)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o640],
                ofItemAtPath: target.path
            )
            let targetMode = try fileMode(target)
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
            let linked = AIRetrievalSourceSnapshotCache(databaseURL: link)
            await linked.store(fileID: fileID, entry: first)
            let linkedEntry = await linked.exact(
                fileID: fileID,
                fastRevision: "bytes-v1",
                segmenterVersion: AISegmenter.currentVersion
            )
            let targetAfterProbe = try Data(contentsOf: target)
            let targetModeAfterProbe = try fileMode(target)
            let linkValues = try link.resourceValues(forKeys: [.isSymbolicLinkKey])
            check(
                linkedEntry == nil
                    && targetAfterProbe == sentinel
                    && targetModeAfterProbe == targetMode
                    && linkValues.isSymbolicLink == true,
                "A source-cache symlink was followed, modified, or chmodded."
            )
        } catch {
            failures.append("Could not construct the symlink-cache fixture: \(error.localizedDescription)")
        }

        do {
            let skippedExtraction = try await exactPreparerSkipsExtraction(
                root: root.appendingPathComponent("preparer", isDirectory: true)
            )
            check(
                skippedExtraction,
                "An exact source-cache hit did not bypass native text extraction/segmentation."
            )
        } catch {
            failures.append("Could not verify the exact source preparer path: \(error.localizedDescription)")
        }

        return (checks, failures)
    }

    @MainActor
    private static func exactPreparerSkipsExtraction(root: URL) async throws -> Bool {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let sourceURL = root.appendingPathComponent("source.pdf")
        let document = PDFDocument()
        document.insert(PDFPage(), at: 0)
        guard document.write(to: sourceURL) else {
            throw CocoaError(.fileWriteUnknown)
        }
        let fileID = UUID()
        let candidate = try DocumentAccessCoordinator.shared.retrievalCandidate(
            fileID: fileID,
            originalURL: sourceURL,
            workingCopyURL: nil
        )
        guard let fastRevision = candidate.fastRevision else {
            throw CocoaError(.fileReadUnknown)
        }
        let cachedSnapshot = AIHighlightTextSnapshot(
            fingerprint: "cached-without-native-extraction",
            pages: [AITextPageSnapshot(
                pageNumber: 1,
                text: "cached sentinel text",
                fingerprint: "cached-page"
            )]
        )
        let cache = AIRetrievalSourceSnapshotCache(
            databaseURL: root.appendingPathComponent("source.sqlite3")
        )
        await cache.store(fileID: fileID, entry: AIRetrievalSourceSnapshotCacheEntry(
            fastRevision: fastRevision,
            contentVersion: "cached-content-version",
            snapshot: cachedSnapshot,
            snapshotProfile: AINativeTextSnapshotProfile.current,
            segmenterVersion: AISegmenter.currentVersion,
            records: []
        ))
        let prepared = try await AIRetrievalSourcePreparer(cache: cache).prepare(
            fileID: fileID,
            originalURL: sourceURL,
            workingCopyURL: nil
        )
        return prepared.cacheDisposition == .exact
            && prepared.snapshot == cachedSnapshot
            && prepared.records.isEmpty
    }

    private static func executeSQLite(at url: URL, sql: String) throws {
        var database: OpaquePointer?
        let opened = sqlite3_open_v2(
            url.path,
            &database,
            SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX,
            nil
        )
        guard opened == SQLITE_OK, let database else {
            if let database { sqlite3_close_v2(database) }
            throw CocoaError(.fileWriteUnknown)
        }
        defer { sqlite3_close_v2(database) }
        guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else {
            throw CocoaError(.fileWriteUnknown)
        }
    }

    private static func sqliteScalar(at url: URL, sql: String) throws -> Int64 {
        var database: OpaquePointer?
        guard sqlite3_open_v2(
            url.path,
            &database,
            SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX,
            nil
        ) == SQLITE_OK, let database else {
            if let database { sqlite3_close_v2(database) }
            throw CocoaError(.fileReadUnknown)
        }
        defer { sqlite3_close_v2(database) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else { throw CocoaError(.fileReadUnknown) }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else {
            throw CocoaError(.fileReadUnknown)
        }
        return sqlite3_column_int64(statement, 0)
    }

    private static func fileMode(_ url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard let permissions = attributes[.posixPermissions] as? NSNumber else {
            throw CocoaError(.fileReadUnknown)
        }
        return permissions.intValue & 0o777
    }
}
