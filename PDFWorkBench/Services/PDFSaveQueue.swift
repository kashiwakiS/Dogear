import CryptoKit
import Foundation

// Mutable recovery state is protected by stateLock; file writes are serialized.
nonisolated final class PDFSaveQueue: @unchecked Sendable {
    static let shared = PDFSaveQueue()

    private let fileManager: FileManager
    private let queue = DispatchQueue(label: "com.pdfworkbench.pdf-save-queue", qos: .utility)
    private let group = DispatchGroup()
    private let stateLock = NSLock()
    private let recoveryDirectoryURL: URL?
    private let workingCopyStore: PDFWorkingCopyStore?
    nonisolated private struct PendingSave: Codable, Sendable {
        let id: UUID
        let data: Data
        var destinationURL: URL
        var error: String?
        var journaled: Bool? = false
    }
    private var pending: [String: PendingSave] = [:]
    // Keep the actual journal names loaded from disk. Older releases hashed a
    // path before its missing parents existed, so its later canonical spelling
    // may differ even though it still addresses the same destination.
    private var journalURLsByPath: [String: Set<URL>] = [:]
    private var latestJournalURLByPath: [String: URL] = [:]

    var hasUnrecoverablePendingWrites: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return pending.values.contains { $0.journaled != true }
    }

    var pendingDestinations: [URL] {
        stateLock.lock()
        defer { stateLock.unlock() }
        return pending.values.map(\.destinationURL)
    }

    /// Failed bytes survive the window/store that initiated the write. A retry
    /// always uses the newest snapshot; an older completion cannot clear it.
    func pendingData(for destinationURL: URL) -> Data? {
        let path = destinationPath(for: destinationURL)
        stateLock.lock()
        defer { stateLock.unlock() }
        return pending[path]?.data
    }

    func failureDescription(for destinationURL: URL) -> String? {
        let path = destinationPath(for: destinationURL)
        stateLock.lock()
        defer { stateLock.unlock() }
        return pending[path]?.error
    }

    @discardableResult
    func retry(to destinationURL: URL, completion: @escaping @MainActor (Result<URL, Error>) -> Void) -> Bool {
        guard let data = pendingData(for: destinationURL) else { return false }
        enqueue(data: data, to: destinationURL, completion: completion)
        return true
    }

    /// Only the explicitly confirmed discard path may abandon pending bytes.
    func discardPendingData(for destinationURL: URL) throws {
        waitUntilDrained()
        let path = destinationPath(for: destinationURL)
        // Forgetting memory first could report a successful discard while a
        // surviving journal silently restores those edits at the next launch.
        try removeRecoveryData(forPath: path)
        stateLock.lock()
        pending.removeValue(forKey: path)
        stateLock.unlock()
    }

    init(fileManager: FileManager = .default, recoveryDirectoryURL: URL? = nil,
         workingCopyStore: PDFWorkingCopyStore? = nil) {
        self.fileManager = fileManager
        self.recoveryDirectoryURL = recoveryDirectoryURL ?? fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("PDFWorkBench/PendingPDFWrites", isDirectory: true)
        self.workingCopyStore = workingCopyStore ?? self.recoveryDirectoryURL.flatMap {
            try? PDFWorkingCopyStore(fileManager: fileManager,
                directoryURL: $0.deletingLastPathComponent().appendingPathComponent("WorkingCopies", isDirectory: true))
        }
        if let directory = self.recoveryDirectoryURL,
           let files = try? fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
            // A legacy path alias may have left more than one journal for the
            // same destination. Retain all names for cleanup and recover the
            // most recently written snapshot rather than directory-list order.
            var journals: [(url: URL, date: Date)] = []
            for file in files where file.pathExtension == "json" {
                let attributes: [FileAttributeKey: Any]? = try? fileManager.attributesOfItem(atPath: file.path)
                let modificationDate: Date? = attributes?[FileAttributeKey.modificationDate] as? Date
                let date: Date = modificationDate ?? Date.distantPast
                journals.append((url: file, date: date))
            }
            journals.sort { first, second in
                if first.date == second.date { return first.url.path < second.url.path }
                return first.date < second.date
            }
            for journal in journals {
                let file = journal.url
                guard let data = try? Data(contentsOf: file),
                      var item = try? JSONDecoder().decode(PendingSave.self, from: data) else { continue }
                // Only decoded, app-owned working-copy recovery is portable.
                // Original/external overwrite destinations retain their exact
                // authorization. This mapping never creates or writes a file.
                if let destination = self.workingCopyStore?.portableManagedCopyURL(for: item.destinationURL) {
                    item.destinationURL = destination
                }
                item.error = "A previous save was interrupted. The latest edits are available for recovery."
                item.journaled = true
                let path = destinationPath(for: item.destinationURL)
                pending[path] = item
                journalURLsByPath[path, default: []].insert(file)
                latestJournalURLByPath[path] = file
            }
        }
    }

    /// Resolve an existing ancestor first, then append the missing suffix. On
    /// iOS a full nonexistent/blocked path can retain /private/var while that
    /// same path resolves to /var after the save creates its directories.
    private func destinationPath(for destinationURL: URL) -> String {
        var ancestor = destinationURL.standardizedFileURL
        var suffix: [String] = []
        while !fileManager.fileExists(atPath: ancestor.path) {
            let parent = ancestor.deletingLastPathComponent()
            guard parent.path != ancestor.path else { break }
            suffix.append(ancestor.lastPathComponent)
            ancestor = parent
        }
        var resolved = ancestor.resolvingSymlinksInPath().standardizedFileURL
        for component in suffix.reversed() { resolved.appendPathComponent(component) }
        return resolved.standardizedFileURL.path
    }

    private func recoveryURL(forPath path: String) -> URL? {
        let digest = SHA256.hash(data: Data(path.utf8))
            .map { String(format: "%02x", $0) }.joined()
        return recoveryDirectoryURL?.appendingPathComponent(digest + ".json")
    }

    private func removeRecoveryData(forPath path: String) throws {
        stateLock.lock()
        var urls = journalURLsByPath[path] ?? []
        let latest = latestJournalURLByPath[path]
        stateLock.unlock()
        if let current = recoveryURL(forPath: path) { urls.insert(current) }
        // An earlier deletion may fail after other stale names are removed.
        // Keep the latest actual journal until every older name is gone, so
        // restarting can never resurrect an older snapshot over current disk.
        // A loaded URL and this writer's recovery URL can spell one journal
        // differently (/private/var, /var or a directory alias). Deduplicate
        // canonical identities before excluding the actual latest journal.
        var urlsByIdentity: [String: URL] = [:]
        for url in urls.sorted(by: { $0.path < $1.path }) {
            urlsByIdentity[destinationPath(for: url)] = url
        }
        if let latest { urlsByIdentity.removeValue(forKey: destinationPath(for: latest)) }
        var orderedURLs: [URL] = urlsByIdentity.keys.sorted().compactMap { urlsByIdentity[$0] }
        if let latest { orderedURLs.append(latest) }
        for url in orderedURLs {
            do {
                try fileManager.removeItem(at: url)
            } catch {
                let cocoaError = error as NSError
                guard cocoaError.domain == NSCocoaErrorDomain, cocoaError.code == NSFileNoSuchFileError else { throw error }
            }
        }
        stateLock.lock()
        journalURLsByPath.removeValue(forKey: path)
        latestJournalURLByPath.removeValue(forKey: path)
        stateLock.unlock()
    }

    func enqueue(
        data: Data,
        to destinationURL: URL,
        completion: @escaping @MainActor (Result<URL, Error>) -> Void
    ) {
        let identifier = UUID()
        let path = destinationPath(for: destinationURL)
        stateLock.lock()
        pending[path] = PendingSave(id: identifier, data: data, destinationURL: destinationURL)
        stateLock.unlock()
        group.enter()
        queue.async { [self, group] in
            let result: Result<URL, Error>
            stateLock.lock()
            let hasOlderJournals = !(journalURLsByPath[path]?.isEmpty ?? true)
            stateLock.unlock()
            var wroteLatestJournal = false
            var recoveryError: Error?

            // Keep recovery separate from the target directory: a read-only or
            // missing destination must not be the only home of unsaved bytes.
            if let recoveryURL = recoveryURL(forPath: path) {
                do {
                    try fileManager.createDirectory(at: recoveryURL.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
                    let recovery = PendingSave(id: identifier, data: data, destinationURL: destinationURL)
                    try JSONEncoder().encode(recovery).write(to: recoveryURL, options: .atomic)
                    wroteLatestJournal = true
                    stateLock.lock()
                    journalURLsByPath[path, default: []].insert(recoveryURL)
                    latestJournalURLByPath[path] = recoveryURL
                    stateLock.unlock()
                    try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: recoveryURL.path)
                    stateLock.lock()
                    if pending[path]?.id == identifier { pending[path]?.journaled = true }
                    stateLock.unlock()
                } catch {
                    // Destination save can still succeed when recovery storage is
                    // unavailable and no stale journal can resurrect older data.
                    recoveryError = error
                }
            }
            do {
                // Without a fresh durable snapshot, failed stale-journal cleanup
                // could restore A0 over a newly written A1 at the next launch.
                // Leave the old disk/journals intact and retain A1 as explicitly
                // non-durable pending memory until recovery storage is repaired.
                if hasOlderJournals && !wroteLatestJournal {
                    throw recoveryError ?? CocoaError(.fileWriteUnknown)
                }
                try fileManager.createDirectory(
                    at: destinationURL.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try data.write(to: destinationURL, options: [.atomic])
                try removeRecoveryData(forPath: path)
                result = .success(destinationURL)
            } catch {
                result = .failure(error)
            }

            stateLock.lock()
            if pending[path]?.id == identifier {
                switch result {
                case .success: pending.removeValue(forKey: path)
                case .failure(let error): pending[path]?.error = error.localizedDescription
                }
            }
            stateLock.unlock()
            group.leave()
            Task { @MainActor in
                completion(result)
            }
        }
    }

    func waitUntilDrained() {
        group.wait()
    }

    /// Mobile lifecycle adapters must not block the main actor while a serial
    /// writer drains. Recovery bytes remain owned by this queue on cancellation.
    func drain() async {
        await withCheckedContinuation { continuation in
            group.notify(queue: .global(qos: .utility)) { continuation.resume() }
        }
    }
}
