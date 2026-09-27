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

}
