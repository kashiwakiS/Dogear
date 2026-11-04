import CryptoKit
import Foundation

// Immutable configuration; FileManager is only used through its thread-safe
// URL/file APIs. Front ends own pickers and document-writer coordination.
nonisolated struct PDFWorkingCopyStore: @unchecked Sendable {
    enum StoreError: Error {
        case missingApplicationSupportDirectory
    }

    let fileManager: FileManager
    let directoryURL: URL

    init(
        fileManager: FileManager = .default,
        directoryURL: URL? = nil
    ) throws {
        self.fileManager = fileManager

        if let directoryURL {
            self.directoryURL = directoryURL
            return
        }

        guard let applicationSupportURL = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else {
            throw StoreError.missingApplicationSupportDirectory
        }

        self.directoryURL = applicationSupportURL
            .appendingPathComponent("PDFWorkBench", isDirectory: true)
            .appendingPathComponent("WorkingCopies", isDirectory: true)
    }

    func workingCopyURL(forOriginalURL originalURL: URL) -> URL {
        let comparablePath = originalURL.resolvingSymlinksInPath().standardizedFileURL.path
        let digest = SHA256.hash(data: Data(comparablePath.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
            .prefix(16)
        let baseName = originalURL
            .deletingPathExtension()
            .lastPathComponent
            .replacingOccurrences(of: "/", with: "-")

        return directoryURL
            .appendingPathComponent("\(baseName)-\(digest).pdf", isDirectory: false)
    }

    /// App updates can relocate the sandbox while preserving its contents.
    /// Only the app-owned support directory is portable; external copies must
    /// retain their explicit location and missing-file recovery behavior.
    func relocatedManagedCopyURL(for recordedURL: URL) -> URL? {
        guard let candidate = portableManagedCopyURL(for: recordedURL),
              let attributes = try? fileManager.attributesOfItem(atPath: candidate.path),
              attributes[.type] as? FileAttributeType == .typeRegular else { return nil }
        return candidate
    }

    /// A decoded recovery journal can own a first edit whose copy does not yet
    /// exist. Rebase its destination without inventing bytes or creating files.
    /// Library keeps this missing-copy reference so opening still requires the
    /// actual retained journal or disk PDF, never a fallback to the original.
    func portableManagedCopyURL(for recordedURL: URL) -> URL? {
        guard recordedURL.isFileURL,
              !fileManager.fileExists(atPath: recordedURL.path) else { return nil }
        let hash = recordedURL.deletingPathExtension().lastPathComponent.split(separator: "-").last ?? ""
        guard recordedURL.pathExtension.lowercased() == "pdf", hash.count == 16,
              hash.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else { return nil }
        let suffix = ["Library", "Application Support", "PDFWorkBench", "WorkingCopies"]
        guard Array(directoryURL.standardizedFileURL.pathComponents.suffix(4)) == suffix,
              Array(recordedURL.deletingLastPathComponent().standardizedFileURL.pathComponents.suffix(4)) == suffix else {
            return nil
        }
        let candidate = directoryURL.appendingPathComponent(recordedURL.lastPathComponent)
        if let attributes = try? fileManager.attributesOfItem(atPath: candidate.path),
           attributes[.type] as? FileAttributeType != .typeRegular { return nil }
        return candidate
    }

}
