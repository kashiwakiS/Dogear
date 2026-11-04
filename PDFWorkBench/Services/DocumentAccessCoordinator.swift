import CryptoKit
import Foundation
import PDFKit

struct PDFDocumentWritePermit: Equatable, Sendable {
    let requestID: UUID
    let fileID: UUID?
    let originalPath: String
    let editSessionID: UUID
    let contentVersion: String
}

enum DocumentAccessError: LocalizedError {
    case editorUnavailable
    case sourceChanged
    case snapshotUnavailable
    case workingCopyMissing
    case discardFailed
    case relinkConflict
    case pendingSaveFailed

    var errorDescription: String? {
        switch self {
        case .editorUnavailable: return "The original PDF editing session is no longer available."
        case .sourceChanged: return "The PDF changed after this request started. Run the request again before adding annotations."
        case .snapshotUnavailable: return "Could not read the latest PDF source."
        case .workingCopyMissing: return "The recorded working copy is missing. Locate or explicitly discard it before using this source."
        case .discardFailed: return "Could not discard the working copy. Original PDF was not changed."
        case .relinkConflict: return "This PDF has another active editing session. Close that session before locating the original."
        case .pendingSaveFailed: return "Save the working copy successfully before locating its original. Your edits have been retained."
        }
    }
}

struct PDFSourceReadSnapshot {
    let fileID: UUID?
    let originalURL: URL
    let contentVersion: String
    let document: PDFDocument
}

/// Detached PDF state plus a cheap retrieval-cache revision. The revision is
/// a SHA-256 of the exact source bytes for a stable on-disk document. A dirty
/// in-memory editor also includes its coordinator mutation generation, so an
/// unsaved edit can never reuse an older text snapshot merely because the last
/// written working-copy bytes are unchanged.
struct PDFSourceRetrievalCandidate {
    let fileID: UUID?
    let originalURL: URL
    let sourceByteFingerprint: String
    let fastRevision: String?
    let document: PDFDocument
}

/// All PDFKit access remains on the main actor. Background research receives an
/// independent read snapshot; it never acquires an editor or creates a working copy.
@MainActor
final class DocumentAccessCoordinator {
    static let shared = DocumentAccessCoordinator()

    final class Entry {
        weak var owner: (any PDFDocumentEditingOwner)?
        var originalURL: URL
        var fileID: UUID?
        var document: PDFDocument
        var workingCopyURL: URL?
        var dirty = false
        var saveError: String?
        var generation = UUID()
        var hasPreparedData = true

        init(owner: any PDFDocumentEditingOwner, originalURL: URL, document: PDFDocument, workingCopyURL: URL?) {
            self.owner = owner
            self.originalURL = originalURL
            self.document = document
            self.workingCopyURL = workingCopyURL
        }
    }

    private var entries: [String: Entry] = [:]
    private var pathsByFileID: [UUID: String] = [:]
    private let saveQueue: PDFSaveQueue

    init(saveQueue: PDFSaveQueue? = nil) { self.saveQueue = saveQueue ?? .shared }

    struct WorkingCopyStatus {
        let isOpen: Bool
        let hasUnsavedChanges: Bool
        let saveError: String?
        let workingCopyURL: URL?
    }

    var protectedWorkingCopyURLs: Set<URL> {
        Set(entries.values.filter { $0.owner != nil || $0.dirty }.compactMap(\.workingCopyURL))
            .union(saveQueue.pendingDestinations)
    }

    func workingCopyStatus(for originalURL: URL) -> WorkingCopyStatus? {
        guard let entry = entries[originalURL.libraryComparablePath] else { return nil }
        return WorkingCopyStatus(isOpen: entry.owner != nil, hasUnsavedChanges: entry.dirty,
            saveError: entry.saveError, workingCopyURL: entry.workingCopyURL)
    }

    /// The caller verifies the original's exact SHA-256 and validates the
    /// candidate again in updateLibrary. Durable Library commit happens before
    /// this no-throw in-memory handoff; failure leaves the editor/path unchanged.
    func relocateOriginal(fileID: UUID, from oldURL: URL, to newURL: URL,
                          updateLibrary: () throws -> Void) throws {
        let oldPath = oldURL.libraryComparablePath
        let newPath = newURL.libraryComparablePath
        if let registeredPath = pathsByFileID[fileID], registeredPath != oldPath {
            throw DocumentAccessError.sourceChanged
        }
        let entry = entries[oldPath]
        if let entry, let boundID = entry.fileID, boundID != fileID {
            throw DocumentAccessError.relinkConflict
        }
        if oldPath != newPath, let destination = entries[newPath],
           destination.owner != nil || destination.dirty {
            throw DocumentAccessError.relinkConflict
        }
        entry?.owner?.retryWorkingCopySave()
        saveQueue.waitUntilDrained()
        if saveQueue.pendingData(for: oldURL) != nil { throw DocumentAccessError.pendingSaveFailed }
        if let entry, entry.dirty {
            guard entry.hasPreparedData, let workingCopy = entry.workingCopyURL,
                  saveQueue.pendingData(for: workingCopy) == nil,
                  FileManager.default.fileExists(atPath: workingCopy.path) else {
                throw DocumentAccessError.pendingSaveFailed
            }
        }
        try updateLibrary()
        if let entry {
            entries.removeValue(forKey: oldPath)
            entry.originalURL = newURL
            entry.fileID = fileID
            entry.dirty = false
            entry.saveError = nil
            entry.generation = UUID()
            entries[newPath] = entry
        }
        pathsByFileID[fileID] = newPath
        entry?.owner?.adoptRelocatedOriginal(newURL, fileID: fileID)
        if let entry { entry.owner?.synchronizeSaveState(from: entry) }
    }

    /// Call after PDFSaveQueue.waitUntilDrained() at app termination. Queue
    /// state is authoritative even if main-actor completion callbacks are pending.
    var hasUnrecoverableChanges: Bool {
        saveQueue.hasUnrecoverablePendingWrites || entries.values.contains { $0.dirty && !$0.hasPreparedData }
    }

    func retryPendingSaves() {
        let retainedDestinations = Set(entries.values.compactMap(\.workingCopyURL))
        for destination in saveQueue.pendingDestinations where !retainedDestinations.contains(destination) {
            // These bytes already carried explicit write authorization. Retry is
            // invoked by the user's Retry action, never automatically at launch.
            saveQueue.retry(to: destination) { _ in }
        }
        for entry in Array(entries.values) where entry.dirty {
            if let owner = entry.owner {
                owner.retryWorkingCopySave()
            } else {
                guard let destination = entry.workingCopyURL ?? (try? PDFWorkingCopyStore())?.workingCopyURL(forOriginalURL: entry.originalURL),
                      let data = entry.document.dataRepresentationWithAIAnnotationsDisplayed() else {
                    entry.hasPreparedData = false
                    continue
                }
                let generation = noteMutation(for: entry.originalURL, document: entry.document, workingCopyURL: destination)
                entry.hasPreparedData = true
                saveQueue.enqueue(data: data, to: destination) { [self] result in
                    finishSave(for: entry.originalURL, generation: generation, result: result)
                }
            }
        }
    }

    func notePreparedData(for url: URL) { entries[url.libraryComparablePath]?.hasPreparedData = true }

    @discardableResult
    func activateExistingEditor(for url: URL, excluding store: (any PDFDocumentEditingOwner)? = nil) -> Bool {
        guard let owner = entries[url.libraryComparablePath]?.owner, owner !== store else { return false }
        owner.activateEditor()
        return true
    }

    /// A security-scoped bookmark may follow a Finder move before the active
    /// editor has a new path. Check stable identity before opening a new store.
    @discardableResult
    func activateExistingEditor(fileID: UUID, excluding store: (any PDFDocumentEditingOwner)? = nil) -> Bool {
        guard let path = pathsByFileID[fileID], let owner = entries[path]?.owner,
              owner !== store else { return false }
        owner.activateEditor()
        return true
    }

    func retainedEntry(for url: URL) -> Entry? {
        guard let entry = entries[url.libraryComparablePath], entry.owner != nil || entry.dirty else { return nil }
        return entry
    }

    func register(_ store: any PDFDocumentEditingOwner, url: URL, document: PDFDocument, workingCopyURL: URL?) {
        let path = url.libraryComparablePath
        if let entry = retainedEntry(for: url) {
            precondition(entry.owner == nil || entry.owner === store)
            entry.owner = store
            entry.document = document
            entry.workingCopyURL = workingCopyURL
        } else {
            entries[path] = Entry(owner: store, originalURL: url, document: document, workingCopyURL: workingCopyURL)
        }
    }

    func bind(fileID: UUID, to store: any PDFDocumentEditingOwner, url: URL) -> Bool {
        let path = url.libraryComparablePath
        if let existingPath = pathsByFileID[fileID], existingPath != path,
           let existing = entries[existingPath], existing.owner != nil || existing.dirty {
            existing.owner?.activateEditor()
            return false
        }
        guard let entry = entries[path], entry.owner === store else { return false }
        entry.fileID = fileID
        pathsByFileID[fileID] = path
        return true
    }

    func owns(_ store: any PDFDocumentEditingOwner, url: URL) -> Bool {
        entries[url.libraryComparablePath]?.owner === store
    }

    func release(_ store: any PDFDocumentEditingOwner, url: URL) {
        let path = url.libraryComparablePath
        guard let entry = entries[path], entry.owner === store else { return }
        entry.owner = nil
        if !entry.dirty { entries.removeValue(forKey: path) }
    }

    /// Called only after explicit user confirmation by the discard command.
    func discardRetainedState(for url: URL, owner: any PDFDocumentEditingOwner) {
        guard owns(owner, url: url) else { return }
        entries.removeValue(forKey: url.libraryComparablePath)
    }

    /// Call only after explicit discard confirmation, including from another
    /// window's Library. The editing owner must reopen so its next save cannot
    /// resurrect the discarded PDF; closed owners also retain recoverable bytes.
    func discardWorkingCopy(originalURL: URL, workingCopyURL: URL, fileID: UUID? = nil) throws {
        let path = originalURL.libraryComparablePath
        // A bookmark may have followed a Finder move while the active writer
        // still owns the previous path. Do not bypass that owner and delete its
        // copy as if it were closed: its next save could resurrect the edits.
        // Exact-content Locate Original coordinates this handoff first.
        if let fileID, let registeredPath = pathsByFileID[fileID], registeredPath != path,
           let registered = entries[registeredPath], registered.owner != nil || registered.dirty {
            throw DocumentAccessError.sourceChanged
        }
        if let owner = entries[path]?.owner {
            let boundFileID = entries[path]?.fileID ?? fileID
            guard owner.discardCurrentWorkingCopyAndReopenOriginal() else { throw DocumentAccessError.discardFailed }
            if let boundFileID { owner.bindLibraryFile(boundFileID) }
            return
        }
        let destination = entries[path]?.workingCopyURL ?? workingCopyURL
        guard destination.libraryComparablePath != path else { throw DocumentAccessError.discardFailed }
        saveQueue.waitUntilDrained()
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        try saveQueue.discardPendingData(for: destination)
        entries.removeValue(forKey: path)
    }

    func exportData(fileID: UUID? = nil, originalURL: URL, workingCopyURL: URL?) throws -> Data {
        let snapshot = try readSnapshot(fileID: fileID, originalURL: originalURL, workingCopyURL: workingCopyURL)
        guard let data = snapshot.document.dataRepresentationWithAIAnnotationsDisplayed() else {
            throw DocumentAccessError.snapshotUnavailable
        }
        return data
    }

    func noteMutation(for url: URL, document: PDFDocument, workingCopyURL: URL?) -> UUID {
        guard let entry = entries[url.libraryComparablePath] else { return UUID() }
        entry.document = document
        entry.workingCopyURL = workingCopyURL
        entry.dirty = true
        entry.hasPreparedData = false
        entry.saveError = nil
        entry.generation = UUID()
        return entry.generation
    }

    func finishSave(for url: URL, generation: UUID, result: Result<URL, Error>) {
        let path = url.libraryComparablePath
        guard let entry = entries[path], entry.generation == generation else { return }
        switch result {
        case .success:
            entry.dirty = false
            entry.saveError = nil
        case .failure(let error):
            entry.dirty = true
            entry.saveError = error.localizedDescription
        }
        entry.owner?.synchronizeSaveState(from: entry)
        if entry.owner == nil && !entry.dirty { entries.removeValue(forKey: path) }
    }

    func sourceVersion(for originalURL: URL, document: PDFDocument, workingCopyURL: URL?) -> String {
        let data: Data?
        if let workingCopyURL {
            data = saveQueue.pendingData(for: workingCopyURL) ?? (try? Data(contentsOf: workingCopyURL))
        } else {
            data = try? Data(contentsOf: originalURL)
        }
        let fileDigest = data.map(Self.sha256) ?? "unavailable"
        return Self.contentVersion(of: document) + ":" + fileDigest
    }

    func readSnapshot(fileID: UUID? = nil, originalURL: URL, workingCopyURL: URL? = nil) throws -> PDFSourceReadSnapshot {
        let candidate = try retrievalCandidate(
            fileID: fileID,
            originalURL: originalURL,
            workingCopyURL: workingCopyURL
        )
        return PDFSourceReadSnapshot(
            fileID: candidate.fileID,
            originalURL: candidate.originalURL,
            contentVersion: retrievalContentVersion(for: candidate),
            document: candidate.document
        )
    }

    /// Captures a detached source without asking PDFKit to extract every page's
    /// text. Callers may first consult the derived source cache using
    /// `fastRevision`; a cache miss can then build the semantic text snapshot.
    func retrievalCandidate(
        fileID: UUID? = nil,
        originalURL: URL,
        workingCopyURL: URL? = nil
    ) throws -> PDFSourceRetrievalCandidate {
        let path = fileID.flatMap { pathsByFileID[$0] } ?? originalURL.libraryComparablePath
        let resolvedOriginalURL = entries[path]?.originalURL ??
            (path == originalURL.libraryComparablePath ? originalURL : URL(fileURLWithPath: path))
        var scopedURLs: [URL] = []
        defer { scopedURLs.forEach { $0.stopAccessingSecurityScopedResource() } }
        let detached: PDFDocument
        let sourceBytes: Data?
        let dirtyGeneration: UUID?
        if let entry = entries[path], entry.owner != nil || entry.dirty {
            let effectiveWorkingCopyURL = entry.workingCopyURL
            if let effectiveWorkingCopyURL {
                sourceBytes = saveQueue.pendingData(for: effectiveWorkingCopyURL)
                    ?? (try? Data(contentsOf: effectiveWorkingCopyURL))
            } else {
                sourceBytes = try? Data(contentsOf: resolvedOriginalURL)
            }
            dirtyGeneration = entry.dirty ? entry.generation : nil
            guard let data = entry.document.dataRepresentationWithAIAnnotationsDisplayed(),
                  let snapshot = PDFDocument(data: data) else {
                throw DocumentAccessError.snapshotUnavailable
            }
            detached = snapshot
        } else {
            let candidate = workingCopyURL ?? (try? PDFWorkingCopyStore())?.workingCopyURL(forOriginalURL: resolvedOriginalURL)
            if let workingCopyURL, !FileManager.default.fileExists(atPath: workingCopyURL.path),
               saveQueue.pendingData(for: workingCopyURL) == nil { throw DocumentAccessError.workingCopyMissing }
            let readURL = candidate.flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil } ?? resolvedOriginalURL
            if readURL.startAccessingSecurityScopedResource() { scopedURLs.append(readURL) }
            let pending = candidate.flatMap { saveQueue.pendingData(for: $0) }
            sourceBytes = pending ?? (try? Data(contentsOf: readURL))
            guard let loaded = sourceBytes.flatMap(PDFDocument.init(data:)) ?? PDFDocument(url: readURL),
                  let data = loaded.dataRepresentationWithAIAnnotationsDisplayed(),
                  let snapshot = PDFDocument(data: data) else { throw DocumentAccessError.snapshotUnavailable }
            detached = snapshot
            dirtyGeneration = nil
        }
        let byteFingerprint = sourceBytes.map(Self.sha256) ?? "unavailable"
        let revision: String?
        if byteFingerprint == "unavailable" {
            revision = nil
        } else if let dirtyGeneration {
            revision = Self.sha256(Data("dogear-live-source-v1|\(dirtyGeneration.uuidString)|\(byteFingerprint)".utf8))
        } else {
            revision = Self.sha256(Data("dogear-byte-source-v1|\(byteFingerprint)".utf8))
        }
        return PDFSourceRetrievalCandidate(
            fileID: fileID,
            originalURL: resolvedOriginalURL,
            sourceByteFingerprint: byteFingerprint,
            fastRevision: revision,
            document: detached
        )
    }

    func retrievalContentVersion(for candidate: PDFSourceRetrievalCandidate) -> String {
        Self.contentVersion(of: candidate.document) + ":" + candidate.sourceByteFingerprint
    }

    /// A semantic fingerprint, not PDF serialization bytes (which may contain
    /// changing metadata). Local AI visibility flags are deliberately excluded.
    static func contentVersion(of document: PDFDocument) -> String {
        PDFDocumentContentVersion.value(of: document)
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
