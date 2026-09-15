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
    nonisolated private struct PendingSave: Codable, Sendable {
        let id: UUID
        let data: Data
        let destinationURL: URL
        var error: String?
        var journaled: Bool? = false
    }
    private var pending: [String: PendingSave] = [:]

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
        stateLock.lock()
        defer { stateLock.unlock() }
        return pending[destinationURL.resolvingSymlinksInPath().standardizedFileURL.path]?.data
    }

    func failureDescription(for destinationURL: URL) -> String? {
        stateLock.lock()
        defer { stateLock.unlock() }
        return pending[destinationURL.resolvingSymlinksInPath().standardizedFileURL.path]?.error
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
        // Forgetting memory first could report a successful discard while a
        // surviving journal silently restores those edits at the next launch.
        try removeRecoveryData(for: destinationURL)
        stateLock.lock()
        pending.removeValue(forKey: destinationURL.resolvingSymlinksInPath().standardizedFileURL.path)
        stateLock.unlock()
    }

    init(fileManager: FileManager = .default, recoveryDirectoryURL: URL? = nil) {
        self.fileManager = fileManager
        self.recoveryDirectoryURL = recoveryDirectoryURL ?? fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("PDFWorkBench/PendingPDFWrites", isDirectory: true)
        if let directory = self.recoveryDirectoryURL,
           let files = try? fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
            for file in files where file.pathExtension == "json" {
                guard let data = try? Data(contentsOf: file),
                      var item = try? JSONDecoder().decode(PendingSave.self, from: data) else { continue }
                item.error = "A previous save was interrupted. The latest edits are available for recovery."
                item.journaled = true
                pending[item.destinationURL.resolvingSymlinksInPath().standardizedFileURL.path] = item
            }
        }
    }

    private func recoveryURL(for destinationURL: URL) -> URL? {
        let digest = SHA256.hash(data: Data(destinationURL.resolvingSymlinksInPath().standardizedFileURL.path.utf8))
            .map { String(format: "%02x", $0) }.joined()
        return recoveryDirectoryURL?.appendingPathComponent(digest + ".json")
    }

    private func removeRecoveryData(for destinationURL: URL) throws {
        guard let recoveryURL = recoveryURL(for: destinationURL) else { return }
        do {
            try fileManager.removeItem(at: recoveryURL)
        } catch {
            let cocoaError = error as NSError
            guard cocoaError.domain == NSCocoaErrorDomain, cocoaError.code == NSFileNoSuchFileError else { throw error }
        }
    }

    func enqueue(
        data: Data,
        to destinationURL: URL,
        completion: @escaping @MainActor (Result<URL, Error>) -> Void
    ) {
        let identifier = UUID()
        let path = destinationURL.resolvingSymlinksInPath().standardizedFileURL.path
        stateLock.lock()
        pending[path] = PendingSave(id: identifier, data: data, destinationURL: destinationURL)
        stateLock.unlock()
        group.enter()
        queue.async { [self, group] in
            let result: Result<URL, Error>

            // Keep recovery separate from the target directory: a read-only or
            // missing destination must not be the only home of unsaved bytes.
            if let recoveryURL = recoveryURL(for: destinationURL) {
                do {
                    try fileManager.createDirectory(at: recoveryURL.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
                    let recovery = PendingSave(id: identifier, data: data, destinationURL: destinationURL)
                    try JSONEncoder().encode(recovery).write(to: recoveryURL, options: .atomic)
                    try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: recoveryURL.path)
                    stateLock.lock()
                    if pending[path]?.id == identifier { pending[path]?.journaled = true }
                    stateLock.unlock()
                } catch {
                    // Destination save can still succeed when recovery storage is
                    // unavailable. On failure the newest bytes remain in memory.
                }
            }
            do {
                try fileManager.createDirectory(
                    at: destinationURL.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try data.write(to: destinationURL, options: [.atomic])
                try removeRecoveryData(for: destinationURL)
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
}
