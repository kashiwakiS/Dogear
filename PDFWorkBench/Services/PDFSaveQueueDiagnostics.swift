import CryptoKit
import Foundation

/// Actual serial writes, path aliases and recovery journals in disposable files.
/// The legacy records preserve the existing Codable payload; no alternate queue
/// implementation or platform file-service substitute is involved.
@MainActor
enum PDFSaveQueueDiagnostics {
    static func run() async -> (checks: Int, failures: [String]) {
        var checks = 0
        var failures: [String] = []
        func check(_ condition: Bool, _ message: String) {
            checks += 1
            if !condition { failures.append(message) }
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("DogearSaveQueue-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let actual = root.appendingPathComponent("actual")
            let alias = root.appendingPathComponent("alias")
            try FileManager.default.createDirectory(at: actual, withIntermediateDirectories: true)
            try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: actual)
            check(try sameFilesystemIdentity(alias, actual), "The queue fixture did not create a real directory alias.")
            await exerciseMissingParents(alias: alias, actual: actual,
                journal: root.appendingPathComponent("new-journals"), check: check)
            try await exerciseLegacyJournals(alias: alias, actual: actual,
                journal: root.appendingPathComponent("legacy-journals"), check: check)
            try await exerciseCleanupFailures(alias: alias, actual: actual,
                journal: root.appendingPathComponent("cleanup-failures"), check: check)
            try await exerciseUnavailableLatestJournal(alias: alias, actual: actual,
                journal: root.appendingPathComponent("unavailable-latest"), check: check)

            let canonicalRoot = root.resolvingSymlinksInPath().standardizedFileURL
            if root.standardizedFileURL.path != canonicalRoot.path {
                // On a physical iPad this covers its actual /private/var and
                // /var spelling, in addition to the explicit symlink fixture.
                check(try sameFilesystemIdentity(root, canonicalRoot),
                      "The native raw/canonical queue roots do not address one directory.")
                await exerciseMissingParents(alias: root, actual: canonicalRoot,
                    journal: root.appendingPathComponent("native-journals"), check: check)
            }
        } catch { check(false, "Save queue fixture failed: \(error.localizedDescription)") }
        return (checks, failures)
    }

    private static func exerciseMissingParents(alias: URL, actual: URL, journal: URL,
                                               check: (Bool, String) -> Void) async {
        do {
            let blockedParent = actual.appendingPathComponent("blocked")
            try Data("Obstruct the destination parent".utf8).write(to: blockedParent)
            let rawDestination = alias.appendingPathComponent("blocked/deeper/copy.pdf")
            let canonicalDestination = actual.appendingPathComponent("blocked/deeper/copy.pdf")
            let copies = try PDFWorkingCopyStore(directoryURL: actual.appendingPathComponent("fixture-copies"))
            let queue = PDFSaveQueue(recoveryDirectoryURL: journal, workingCopyStore: copies)
            let oldBytes = Data("older pending bytes".utf8)
            let newestBytes = Data("newest pending bytes".utf8)
            check(isFailure(await write(oldBytes, to: rawDestination, queue: queue)),
                  "A blocked alias destination reported a successful save.")
            check(isFailure(await write(newestBytes, to: canonicalDestination, queue: queue)),
                  "A blocked canonical destination reported a successful save.")
            check(queue.pendingDestinations.count == 1
                    && queue.pendingData(for: rawDestination) == newestBytes
                    && queue.pendingData(for: canonicalDestination) == newestBytes,
                  "Raw/canonical failed saves retained separate identities or older snapshots.")
            check(!queue.hasUnrecoverablePendingWrites
                    && queue.failureDescription(for: rawDestination) != nil,
                  "The newest alias failure lost its durable journal/error state.")
            let reloaded = PDFSaveQueue(recoveryDirectoryURL: journal, workingCopyStore: copies)
            check(reloaded.pendingDestinations.count == 1
                    && reloaded.pendingData(for: rawDestination) == newestBytes
                    && reloaded.pendingData(for: canonicalDestination) == newestBytes,
                  "A reconstructed queue could not recover the newest bytes through both path spellings.")

            // The queue itself now creates the missing hierarchy. This changes
            // full-path URL resolution on the affected physical iOS filesystem.
            try FileManager.default.removeItem(at: blockedParent)
            let retried = await retry(to: rawDestination, queue: reloaded)
            check(isSuccess(retried), "Explicit alias retry did not create the missing destination parents.")
            check((try? Data(contentsOf: rawDestination)) == newestBytes
                    && (try? Data(contentsOf: canonicalDestination)) == newestBytes,
                  "Alias retry wrote different or older bytes to the physical destination.")
            let journals = try FileManager.default.contentsOfDirectory(at: journal, includingPropertiesForKeys: nil)
            check(reloaded.pendingDestinations.isEmpty && journals.isEmpty,
                  "Parent creation changed queue identity or left a journal: raw \(rawDestination.path), resolved \(rawDestination.resolvingSymlinksInPath().path), journals \(journals.map(\.lastPathComponent)), pending \(reloaded.pendingDestinations.map(\.path)).")
            let final = PDFSaveQueue(recoveryDirectoryURL: journal, workingCopyStore: copies)
            check(final.pendingDestinations.isEmpty && final.pendingData(for: rawDestination) == nil
                    && final.pendingData(for: canonicalDestination) == nil,
                  "A successful alias retry resurrected edits when the queue was reconstructed.")
        } catch { check(false, "Missing-parent queue fixture failed: \(error.localizedDescription)") }
    }

    private static func exerciseLegacyJournals(alias: URL, actual: URL, journal: URL,
                                               check: (Bool, String) -> Void) async throws {
        let rawDestination = alias.appendingPathComponent("legacy/copy.pdf")
        let canonicalDestination = actual.appendingPathComponent("legacy/copy.pdf")
        let copies = try PDFWorkingCopyStore(directoryURL: actual.appendingPathComponent("fixture-copies"))
        let oldBytes = Data("older legacy journal".utf8)
        let newestBytes = Data("newest legacy journal".utf8)
        let oldJournal = try legacyJournal(data: oldBytes, destination: rawDestination,
            namePath: rawDestination.path, directory: journal, modifiedAt: Date(timeIntervalSince1970: 1_000))
        let newJournal = try legacyJournal(data: newestBytes, destination: canonicalDestination,
            namePath: canonicalDestination.path, directory: journal, modifiedAt: Date(timeIntervalSince1970: 2_000))
        check(oldJournal.lastPathComponent != newJournal.lastPathComponent,
              "The legacy fixture did not create two original path-hash journal names.")
        let queue = PDFSaveQueue(recoveryDirectoryURL: journal, workingCopyStore: copies)
        check(queue.pendingDestinations.count == 1
                && queue.pendingData(for: rawDestination) == newestBytes
                && queue.pendingData(for: canonicalDestination) == newestBytes
                && !queue.hasUnrecoverablePendingWrites,
              "Legacy alias journals did not recover one newest durable snapshot.")
        check(!FileManager.default.fileExists(atPath: canonicalDestination.path),
              "Loading legacy journals automatically wrote an unconfirmed destination.")
        check(isSuccess(await retry(to: rawDestination, queue: queue)),
              "Explicit retry could not save a legacy journal through its alternate path.")
        check((try? Data(contentsOf: canonicalDestination)) == newestBytes,
              "Legacy alias retry did not preserve the most recently journaled bytes.")
        let remaining = try FileManager.default.contentsOfDirectory(at: journal, includingPropertiesForKeys: nil)
        check(queue.pendingDestinations.isEmpty && remaining.isEmpty,
              "Legacy retry cleaned only the new hash and retained loaded journal URLs: \(remaining.map(\.lastPathComponent)).")
        check(PDFSaveQueue(recoveryDirectoryURL: journal, workingCopyStore: copies).pendingDestinations.isEmpty,
              "A successful legacy retry recovered abandoned older bytes after reconstruction.")

        let discardJournal = journal.appendingPathComponent("explicit-discard")
        _ = try legacyJournal(data: oldBytes, destination: rawDestination,
            namePath: rawDestination.path, directory: discardJournal, modifiedAt: Date(timeIntervalSince1970: 3_000))
        _ = try legacyJournal(data: newestBytes, destination: canonicalDestination,
            namePath: canonicalDestination.path, directory: discardJournal, modifiedAt: Date(timeIntervalSince1970: 4_000))
        let discard = PDFSaveQueue(recoveryDirectoryURL: discardJournal, workingCopyStore: copies)
        check(discard.pendingData(for: rawDestination) == newestBytes,
              "The explicit legacy discard fixture did not first recover the newest bytes.")
        try discard.discardPendingData(for: rawDestination)
        let discardedFiles = try FileManager.default.contentsOfDirectory(at: discardJournal, includingPropertiesForKeys: nil)
        check(discard.pendingDestinations.isEmpty && discardedFiles.isEmpty
                && PDFSaveQueue(recoveryDirectoryURL: discardJournal, workingCopyStore: copies).pendingDestinations.isEmpty,
              "Explicit alias discard retained a legacy journal or in-memory pending bytes.")
        check((try? Data(contentsOf: canonicalDestination)) == newestBytes,
              "Discarding recovery bytes unexpectedly deleted or changed the saved destination.")
    }

    private static func exerciseCleanupFailures(alias: URL, actual: URL, journal: URL,
                                                 check: (Bool, String) -> Void) async throws {
        let manager = FileManager.default
        let secondAlias = alias.deletingLastPathComponent().appendingPathComponent("cleanup-second-alias")
        let thirdAlias = alias.deletingLastPathComponent().appendingPathComponent("cleanup-third-alias")
        try manager.createSymbolicLink(at: secondAlias, withDestinationURL: actual)
        try manager.createSymbolicLink(at: thirdAlias, withDestinationURL: actual)
        let canonicalRoot = actual.resolvingSymlinksInPath().standardizedFileURL
        let copies = try PDFWorkingCopyStore(directoryURL: actual.appendingPathComponent("fixture-copies"))
        let oldBytes = Data("cleanup disk A0".utf8)
        let latestBytes = Data("cleanup latest A1".utf8)
        let destination = canonicalRoot.appendingPathComponent("cleanup-retry/copy.pdf")
        let rawDestination = alias.appendingPathComponent("cleanup-retry/copy.pdf")
        let secondDestination = secondAlias.appendingPathComponent("cleanup-retry/copy.pdf")
        try manager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try oldBytes.write(to: destination)
        let retryJournals = journal.appendingPathComponent("retry")
        let staleA = try legacyJournal(data: oldBytes, destination: rawDestination, namePath: rawDestination.path,
            directory: retryJournals, modifiedAt: Date(timeIntervalSince1970: 1_000))
        let staleB = try legacyJournal(data: oldBytes, destination: secondDestination, namePath: secondDestination.path,
            directory: retryJournals, modifiedAt: Date(timeIntervalSince1970: 1_500))
        let newest = try legacyJournal(data: latestBytes, destination: destination, namePath: destination.path,
            directory: retryJournals, modifiedAt: Date(timeIntervalSince1970: 2_000))
        let retryJournalAlias = journal.appendingPathComponent("retry-journal-alias")
        try manager.createSymbolicLink(at: retryJournalAlias, withDestinationURL: retryJournals)
        let stale = [staleA, staleB].sorted { $0.path < $1.path }
        let fault = JournalFailureFileManager(failedRemovalURL: stale[1], canonicalizesDirectoryListings: true)
        let loadedJournalURLs = try fault.contentsOfDirectory(at: retryJournalAlias, includingPropertiesForKeys: nil)
        let expectedJournalPaths = Set([staleA, staleB, newest].map(\.libraryComparablePath))
        let loadedJournalPaths = Set(loadedJournalURLs.map(\.libraryComparablePath))
        let listedJournalsExist = loadedJournalURLs.allSatisfy { manager.fileExists(atPath: $0.path) }
        check(loadedJournalPaths == expectedJournalPaths && listedJournalsExist,
              "Canonical journal listing did not expose the actual three records through its directory alias: \(loadedJournalURLs.map(\.path)).")
        let queue = PDFSaveQueue(fileManager: fault, recoveryDirectoryURL: retryJournalAlias, workingCopyStore: copies)
        let sameJournalDirectory = try sameFilesystemIdentity(retryJournalAlias, retryJournals)
        let loadedBytes = queue.pendingData(for: destination)
        let loadedText = loadedBytes.map { String(decoding: $0, as: UTF8.self) } ?? "nil"
        check(queue.pendingData(for: destination) == latestBytes && sameJournalDirectory,
              "Cleanup failure fixture did not load latest A1 through an actual journal-directory alias: journals \(loadedJournalURLs.map(\.path)), pending \(queue.pendingDestinations.map(\.path)), data \(loadedText).")
        check(isFailure(await retry(to: destination, queue: queue)),
              "A real stale-journal removal failure reported a successful save.")
        check((try? Data(contentsOf: destination)) == latestBytes && queue.pendingData(for: destination) == latestBytes
                && !queue.hasUnrecoverablePendingWrites && queue.failureDescription(for: destination) != nil,
              "Cleanup failure lost the committed/pending durable A1 or its retryable error.")
        let removedIdentities = fault.removalPaths.map { URL(fileURLWithPath: $0).libraryComparablePath }
        check(!manager.fileExists(atPath: stale[0].path) && manager.fileExists(atPath: stale[1].path)
                && manager.fileExists(atPath: newest.path) && !removedIdentities.contains(newest.libraryComparablePath),
              "Partial cleanup deleted latest A1 before all stale journals: removed \(fault.removalPaths).")
        let restored = PDFSaveQueue(fileManager: fault, recoveryDirectoryURL: retryJournalAlias, workingCopyStore: copies)
        check(restored.pendingData(for: destination) == latestBytes && !restored.hasUnrecoverablePendingWrites,
              "Restart after partial cleanup resurrected A0 over committed A1.")
        fault.failsRemoval = false
        check(isSuccess(await retry(to: destination, queue: restored)),
              "Repairing journal removal did not allow explicit A1 retry.")
        let retryRemaining = try manager.contentsOfDirectory(at: retryJournals, includingPropertiesForKeys: nil)
        check((try? Data(contentsOf: destination)) == latestBytes && retryRemaining.isEmpty
                && restored.pendingDestinations.isEmpty
                && PDFSaveQueue(recoveryDirectoryURL: retryJournals, workingCopyStore: copies).pendingDestinations.isEmpty,
              "Successful cleanup retry left stale journals or resurrected pending data.")

        let discardDestination = canonicalRoot.appendingPathComponent("cleanup-discard/copy.pdf")
        let rawDiscard = alias.appendingPathComponent("cleanup-discard/copy.pdf")
        let secondDiscard = secondAlias.appendingPathComponent("cleanup-discard/copy.pdf")
        let thirdDiscard = thirdAlias.appendingPathComponent("cleanup-discard/copy.pdf")
        try manager.createDirectory(at: discardDestination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try oldBytes.write(to: discardDestination)
        let discardJournals = journal.appendingPathComponent("discard")
        let discardStaleA = try legacyJournal(data: oldBytes, destination: secondDiscard, namePath: secondDiscard.path,
            directory: discardJournals, modifiedAt: Date(timeIntervalSince1970: 1_000))
        let discardStaleB = try legacyJournal(data: oldBytes, destination: thirdDiscard, namePath: thirdDiscard.path,
            directory: discardJournals, modifiedAt: Date(timeIntervalSince1970: 1_500))
        let discardLatest = try legacyJournal(data: latestBytes, destination: rawDiscard, namePath: rawDiscard.path,
            directory: discardJournals, modifiedAt: Date(timeIntervalSince1970: 2_000))
        let discardStale = [discardStaleA, discardStaleB].sorted { $0.path < $1.path }
        let discardFault = JournalFailureFileManager(failedRemovalURL: discardStale[1])
        let discard = PDFSaveQueue(fileManager: discardFault, recoveryDirectoryURL: discardJournals, workingCopyStore: copies)
        check(!manager.fileExists(atPath: journalURL(namePath: discardDestination.path, directory: discardJournals).path)
                && discard.pendingData(for: discardDestination) == latestBytes,
              "Discard failure fixture requires a latest loaded legacy journal and no current-hash journal.")
        do {
            try discard.discardPendingData(for: discardDestination)
            check(false, "A real partial discard failure was reported as success.")
        } catch { check(true, "") }
        check(!manager.fileExists(atPath: discardStale[0].path) && manager.fileExists(atPath: discardStale[1].path)
                && manager.fileExists(atPath: discardLatest.path) && !discardFault.removalPaths.contains(discardLatest.path)
                && discard.pendingData(for: discardDestination) == latestBytes && !discard.hasUnrecoverablePendingWrites,
              "Partial discard lost its actual latest legacy journal or pending A1: removed \(discardFault.removalPaths).")
        let restoredDiscard = PDFSaveQueue(fileManager: discardFault, recoveryDirectoryURL: discardJournals,
                                          workingCopyStore: copies)
        check(restoredDiscard.pendingData(for: discardDestination) == latestBytes
                && (try? Data(contentsOf: discardDestination)) == oldBytes,
              "Restart after failed discard recovered A0 or changed existing disk bytes.")
        discardFault.failsRemoval = false
        try restoredDiscard.discardPendingData(for: discardDestination)
        let discardRemaining = try manager.contentsOfDirectory(at: discardJournals, includingPropertiesForKeys: nil)
        check(discardRemaining.isEmpty && restoredDiscard.pendingDestinations.isEmpty
                && (try? Data(contentsOf: discardDestination)) == oldBytes
                && PDFSaveQueue(recoveryDirectoryURL: discardJournals, workingCopyStore: copies).pendingDestinations.isEmpty,
              "Repaired explicit discard failed to clear every journal or changed disk bytes.")
    }

    private static func exerciseUnavailableLatestJournal(alias: URL, actual: URL, journal: URL,
                                                          check: (Bool, String) -> Void) async throws {
        let manager = FileManager.default
        let copies = try PDFWorkingCopyStore(directoryURL: actual.appendingPathComponent("fixture-copies"))
        let oldBytes = Data("unavailable journal disk A0".utf8)
        let latestBytes = Data("unavailable journal memory A1".utf8)
        for failCreation in [true, false] {
            let label = failCreation ? "directory creation" : "atomic journal write"
            let component = failCreation ? "unavailable-create" : "unavailable-write"
            let destination = actual.resolvingSymlinksInPath().appendingPathComponent(component + "/copy.pdf")
            let rawDestination = alias.appendingPathComponent(component + "/copy.pdf")
            try manager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try oldBytes.write(to: destination)
            let journals = journal.appendingPathComponent(component)
            let oldJournal = try legacyJournal(data: oldBytes, destination: rawDestination, namePath: rawDestination.path,
                directory: journals, modifiedAt: Date(timeIntervalSince1970: 1_000))
            let currentJournal = journalURL(namePath: destination.path, directory: journals)
            let fault = JournalFailureFileManager(failedRemovalURL: oldJournal,
                failedCreationDirectoryURL: failCreation ? journals : nil)
            let queue = PDFSaveQueue(fileManager: fault, recoveryDirectoryURL: journals, workingCopyStore: copies)
            if !failCreation {
                // Real Data.atomic failure: the new hash is a directory, while
                // the old A0 legacy journal remains readable beside it.
                try manager.createDirectory(at: currentJournal, withIntermediateDirectories: false)
            }
            check(queue.pendingData(for: destination) == oldBytes && oldJournal != currentJournal,
                  "Combined \(label)/removal fixture did not establish an older durable A0 journal.")
            check(isFailure(await write(latestBytes, to: destination, queue: queue)),
                  "Unavailable latest journal (\(label)) reported a successful A1 save.")
            check((try? Data(contentsOf: destination)) == oldBytes && queue.pendingData(for: destination) == latestBytes
                    && queue.hasUnrecoverablePendingWrites && queue.failureDescription(for: destination) != nil,
                  "Combined \(label)/old-removal fault wrote A1 prematurely or claimed its memory was durable.")
            check(fault.removalPaths.isEmpty && manager.fileExists(atPath: oldJournal.path)
                    && (!failCreation || fault.creationFailureCount > 0),
                  "Unavailable latest journal (\(label)) attempted unsafe stale-journal deletion: \(fault.removalPaths).")
            let reloaded = PDFSaveQueue(recoveryDirectoryURL: journals, workingCopyStore: copies)
            check(reloaded.pendingData(for: destination) == oldBytes && (try? Data(contentsOf: destination)) == oldBytes,
                  "Restart after unavailable latest journal would recover stale A0 over a newly written A1 disk.")
            if !failCreation { try manager.removeItem(at: currentJournal) }
            fault.failsCreation = false
            fault.failsRemoval = false
            check(isSuccess(await retry(to: destination, queue: queue)),
                  "Repairing \(label)/removal did not preserve and retry live latest A1 memory.")
            let remaining = try manager.contentsOfDirectory(at: journals, includingPropertiesForKeys: nil)
            check((try? Data(contentsOf: destination)) == latestBytes && remaining.isEmpty
                    && queue.pendingDestinations.isEmpty
                    && PDFSaveQueue(recoveryDirectoryURL: journals, workingCopyStore: copies).pendingDestinations.isEmpty,
                  "Repair after unavailable latest journal (\(label)) left old recovery or lost latest A1.")
        }
    }

    // Identical to the existing durable record shape, including compatibility
    // with journals from before the optional journaled field was written.
    private struct LegacyRecord: Encodable {
        let id = UUID()
        let data: Data
        let destinationURL: URL
        let error: String? = nil
        let journaled: Bool? = nil
    }
    private static func legacyJournal(data: Data, destination: URL, namePath: String,
                                      directory: URL, modifiedAt: Date) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = journalURL(namePath: namePath, directory: directory)
        try JSONEncoder().encode(LegacyRecord(data: data, destinationURL: destination)).write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.modificationDate: modifiedAt], ofItemAtPath: file.path)
        return file
    }
    private static func journalURL(namePath: String, directory: URL) -> URL {
        let digest = SHA256.hash(data: Data(namePath.utf8)).map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent(digest + ".json")
    }
    private static func sameFilesystemIdentity(_ first: URL, _ second: URL) throws -> Bool {
        let firstValues = try FileManager.default.attributesOfItem(atPath: first.resolvingSymlinksInPath().path)
        let secondValues = try FileManager.default.attributesOfItem(atPath: second.resolvingSymlinksInPath().path)
        guard let firstDevice = firstValues[.systemNumber] as? NSNumber,
              let secondDevice = secondValues[.systemNumber] as? NSNumber,
              let firstInode = firstValues[.systemFileNumber] as? NSNumber,
              let secondInode = secondValues[.systemFileNumber] as? NSNumber else { return false }
        return firstDevice == secondDevice && firstInode == secondInode
    }
    private static func write(_ data: Data, to url: URL, queue: PDFSaveQueue) async -> Result<URL, Error> {
        await withCheckedContinuation { continuation in
            queue.enqueue(data: data, to: url) { continuation.resume(returning: $0) }
        }
    }
    private static func retry(to url: URL, queue: PDFSaveQueue) async -> Result<URL, Error> {
        await withCheckedContinuation { continuation in
            if !queue.retry(to: url, completion: { continuation.resume(returning: $0) }) {
                continuation.resume(returning: .failure(CocoaError(.fileNoSuchFile)))
            }
        }
    }
    private static func isSuccess(_ result: Result<URL, Error>) -> Bool {
        if case .success = result { return true }; return false
    }
    private static func isFailure(_ result: Result<URL, Error>) -> Bool {
        if case .failure = result { return true }; return false
    }
}

/// Injects failures at the actual filesystem endpoints; writes, recovery
/// decoding, pending state and retry/discard behavior remain the real queue.
/// Configuration is immutable; fault flags and traces are protected by faultLock.
nonisolated private final class JournalFailureFileManager: FileManager {
    private let failedRemovalURL: URL
    private let failedCreationDirectoryURL: URL?
    private let canonicalizesDirectoryListings: Bool
    private let faultLock = NSLock()
    private var shouldFailRemoval = true
    private var shouldFailCreation = true
    private var removedPaths: [String] = []
    private var creationFailures = 0

    init(failedRemovalURL: URL, failedCreationDirectoryURL: URL? = nil,
         canonicalizesDirectoryListings: Bool = false) {
        self.failedRemovalURL = failedRemovalURL
        self.failedCreationDirectoryURL = failedCreationDirectoryURL
        self.canonicalizesDirectoryListings = canonicalizesDirectoryListings
        super.init()
    }
    var failsRemoval: Bool {
        get { faultLock.lock(); defer { faultLock.unlock() }; return shouldFailRemoval }
        set { faultLock.lock(); shouldFailRemoval = newValue; faultLock.unlock() }
    }
    var failsCreation: Bool {
        get { faultLock.lock(); defer { faultLock.unlock() }; return shouldFailCreation }
        set { faultLock.lock(); shouldFailCreation = newValue; faultLock.unlock() }
    }
    var removalPaths: [String] {
        faultLock.lock(); defer { faultLock.unlock() }; return removedPaths
    }
    var creationFailureCount: Int {
        faultLock.lock(); defer { faultLock.unlock() }; return creationFailures
    }
    override func contentsOfDirectory(at url: URL, includingPropertiesForKeys keys: [URLResourceKey]?,
                                     options mask: FileManager.DirectoryEnumerationOptions = []) throws -> [URL] {
        // Foundation's URL enumerator does not traverse a leaf symlink. This
        // adapter models a provider listing canonical URLs for the actual
        // directory while the writer still uses its alias URL.
        let directory = canonicalizesDirectoryListings ? url.resolvingSymlinksInPath().standardizedFileURL : url
        let files = try super.contentsOfDirectory(at: directory, includingPropertiesForKeys: keys, options: mask)
        return canonicalizesDirectoryListings ? files.map { $0.resolvingSymlinksInPath().standardizedFileURL } : files
    }
    override func removeItem(at url: URL) throws {
        faultLock.lock(); removedPaths.append(url.path); faultLock.unlock()
        if failsRemoval && Self.comparablePath(for: url) == Self.comparablePath(for: failedRemovalURL) {
            throw CocoaError(.fileWriteNoPermission)
        }
        try super.removeItem(at: url)
    }
    override func createDirectory(at url: URL, withIntermediateDirectories createIntermediates: Bool,
                                  attributes: [FileAttributeKey: Any]? = nil) throws {
        if failsCreation, let failedCreationDirectoryURL,
           Self.comparablePath(for: url) == Self.comparablePath(for: failedCreationDirectoryURL) {
            faultLock.lock(); creationFailures += 1; faultLock.unlock()
            throw CocoaError(.fileWriteNoPermission)
        }
        try super.createDirectory(at: url, withIntermediateDirectories: createIntermediates, attributes: attributes)
    }
    nonisolated private static func comparablePath(for url: URL) -> String {
        url.resolvingSymlinksInPath().standardizedFileURL.path
    }
}
