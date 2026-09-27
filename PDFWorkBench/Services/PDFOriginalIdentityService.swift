import CryptoKit
import Foundation

nonisolated enum LibraryWorkflowError: LocalizedError, Equatable {
    case fileUnavailable
    case notRegularFile
    case changedWhileReading
    case recordChanged
    case alreadyInLibrary
    case contentMismatch
    case baselineUnavailable
    case persistenceFailed
    case unknownFile
    case invalidGroup
    case invalidName
    case groupNameExists
    case unsafeWorkingCopy
    case destinationExists

    var errorDescription: String? {
        switch self {
        case .fileUnavailable: return "The file could not be read. Choose an available PDF and try again."
        case .notRegularFile: return "Choose a regular PDF file."
        case .changedWhileReading: return "The file changed during verification. Choose it again before continuing."
        case .recordChanged: return "The Library entry changed during this operation. Try again."
        case .alreadyInLibrary: return "This file already belongs to another Library entry. Open that entry instead."
        case .contentMismatch: return "The selected file has different contents. Import it as a new file; the existing entry and edits will be kept."
        case .baselineUnavailable: return "The original file has no verified SHA-256. Import the selected PDF as a new file; the existing entry and edits will be kept."
        case .persistenceFailed: return "The Library change could not be saved. The previous entry has been kept."
        case .unknownFile: return "One of the selected Library files is no longer available."
        case .invalidGroup: return "Choose an available, unarchived Group."
        case .invalidName: return "Enter a Group name."
        case .groupNameExists: return "A Group with this name already exists."
        case .unsafeWorkingCopy: return "This working-copy reference cannot be managed safely. The file has been kept."
        case .destinationExists: return "Choose a new file name. Existing files are not replaced by this export."
        }
    }
}

/// File-system observations bind a streamed digest to the bytes read. They are
/// not a content-equivalence heuristic and are not persisted as the baseline.
nonisolated struct PDFFileReadStamp: Equatable, Sendable {
    let canonicalPath: String
    let size: Int64
    let modifiedAt: Date
    let createdAt: Date?
    let fileNumber: UInt64?
    let fileSystemNumber: UInt64?
}

nonisolated struct PDFOriginalFingerprint: Equatable, Sendable {
    let sha256: String
    let stamp: PDFFileReadStamp
    var byteCount: Int64 { stamp.size }
}

/// Foundation/CryptoKit boundary shared by native front ends. File bytes never
/// cross MainActor and memory use is bounded independently of document size.
nonisolated enum PDFOriginalIdentityService {
    static func fingerprint(at url: URL) async throws -> PDFOriginalFingerprint {
        let worker = Task.detached(priority: .utility) { try readFingerprint(at: url) }
        return try await withTaskCancellationHandler {
            let value = try await worker.value
            try Task.checkCancellation()
            return value
        } onCancel: {
            worker.cancel()
        }
    }

    static func isSHA256(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy {
            (48...57).contains($0) || (97...102).contains($0)
        }
    }

    static func currentStamp(at url: URL) throws -> PDFFileReadStamp {
        guard url.isFileURL else { throw LibraryWorkflowError.notRegularFile }
        let canonicalURL = url.resolvingSymlinksInPath().standardizedFileURL
        let attributes = try FileManager.default.attributesOfItem(atPath: canonicalURL.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              let size = (attributes[.size] as? NSNumber)?.int64Value,
              let modifiedAt = attributes[.modificationDate] as? Date else {
            throw LibraryWorkflowError.notRegularFile
        }
        return PDFFileReadStamp(canonicalPath: canonicalURL.path, size: size,
            modifiedAt: modifiedAt, createdAt: attributes[.creationDate] as? Date,
            fileNumber: (attributes[.systemFileNumber] as? NSNumber)?.uint64Value,
            fileSystemNumber: (attributes[.systemNumber] as? NSNumber)?.uint64Value)
    }

    static func validate(_ fingerprint: PDFOriginalFingerprint, at url: URL) throws {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        guard try currentStamp(at: url) == fingerprint.stamp else {
            throw LibraryWorkflowError.changedWhileReading
        }
    }

    private static func readFingerprint(at url: URL) throws -> PDFOriginalFingerprint {
        try Task.checkCancellation()
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        let before = try currentStamp(at: url)
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hash = SHA256()
        var count: Int64 = 0
        while true {
            try Task.checkCancellation()
            guard let chunk = try handle.read(upToCount: 1_048_576), !chunk.isEmpty else { break }
            count += Int64(chunk.count)
            hash.update(data: chunk)
        }
        try Task.checkCancellation()
        guard try currentStamp(at: url) == before, count == before.size else {
            throw LibraryWorkflowError.changedWhileReading
        }
        return PDFOriginalFingerprint(
            sha256: hash.finalize().map { String(format: "%02x", $0) }.joined(), stamp: before)
    }
}

nonisolated enum LibraryRelinkDisposition: String, Codable, Sendable {
    case sameContent, differentContent, baselineUnavailable
}

/// Produced by LibraryStore, revalidated after asynchronous/UI preparation, then
/// committed inside the document coordinator's synchronous binding transaction.
nonisolated struct LibraryRelinkPlan: Sendable {
    let fileID: UUID
    let originalURL: URL
    let candidateURL: URL
    let disposition: LibraryRelinkDisposition
    let originalSHA256: String?
    let candidateSHA256: String
    let workingCopyURL: URL?

    let expectedCanonicalPath: String
    let expectedWorkingCopyPath: String?
    let expectedBookmark: Data?
    let candidateFingerprint: PDFOriginalFingerprint
    let candidateBookmark: Data
}
