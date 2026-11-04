import CryptoKit
import Darwin
import Foundation

nonisolated enum SafeDocumentExportError: LocalizedError {
    case originalDestination
    case destinationExists
    case destinationChanged

    var errorDescription: String? {
        switch self {
        case .originalDestination:
            "Choose a different file name. The original PDF is not overwritten by default."
        case .destinationExists, .destinationChanged:
            "The existing exported file will be replaced. The original PDF cannot be selected."
        }
    }
}

/// Keep destination validation ahead of every write. SwiftUI fileExporter writes
/// before its completion callback supplies the destination, so that callback
/// cannot enforce the PDF original-file prohibition.
nonisolated enum SafeDocumentExport {
    struct ReplacementAuthorization: Equatable, Sendable {
        fileprivate let path: String
        fileprivate let fileIdentity: String
        fileprivate let fingerprint: String
    }

    enum ExistingFilePolicy: Sendable {
        /// Desktop's native save panel already obtains replacement consent.
        case replace
        case forbidReplacement
        case replaceConfirmed(ReplacementAuthorization)
    }

    static func isSameFile(_ first: URL, _ second: URL) -> Bool {
        let firstResolved = first.resolvingSymlinksInPath().standardizedFileURL
        let secondResolved = second.resolvingSymlinksInPath().standardizedFileURL
        if firstResolved.path == secondResolved.path { return true }
        // URL resource values can retain an earlier inode in the same run-loop
        // turn. A Files target may have become an original hard link meanwhile.
        // Read current filesystem identity before consulting provider identifiers.
        let firstAttributes = try? FileManager.default.attributesOfItem(atPath: firstResolved.path)
        let secondAttributes = try? FileManager.default.attributesOfItem(atPath: secondResolved.path)
        if let firstDevice = firstAttributes?[.systemNumber] as? NSNumber,
           let secondDevice = secondAttributes?[.systemNumber] as? NSNumber,
           let firstInode = firstAttributes?[.systemFileNumber] as? NSNumber,
           let secondInode = secondAttributes?[.systemFileNumber] as? NSNumber,
           firstDevice == secondDevice, firstInode == secondInode { return true }
        // Keep logical provider/case alias protection, but never trust values
        // captured before the final write boundary.
        var freshFirst = first
        var freshSecond = second
        freshFirst.removeAllCachedResourceValues()
        freshSecond.removeAllCachedResourceValues()
        let firstID = try? freshFirst.resourceValues(forKeys: [.fileResourceIdentifierKey]).fileResourceIdentifier
        let secondID = try? freshSecond.resourceValues(forKeys: [.fileResourceIdentifierKey]).fileResourceIdentifier
        if let firstID = firstID as? NSObject, let secondID = secondID as? NSObject {
            return firstID.isEqual(secondID)
        }
        return false
    }

    /// Capture both identity and bytes: replacing A with an identical B still
    /// requires new consent, as does editing A while its confirmation is open.
    static func replacementAuthorization(for destination: URL) throws -> ReplacementAuthorization {
        let resolved = destination.resolvingSymlinksInPath().standardizedFileURL
        let before = try FileManager.default.attributesOfItem(atPath: resolved.path)
        guard before[.type] as? FileAttributeType == .typeRegular,
              let device = before[.systemNumber] as? NSNumber,
              let inode = before[.systemFileNumber] as? NSNumber else {
            throw SafeDocumentExportError.destinationChanged
        }
        let data = try Data(contentsOf: destination)
        let after = try FileManager.default.attributesOfItem(atPath: resolved.path)
        guard before[.systemNumber] as? NSNumber == after[.systemNumber] as? NSNumber,
              before[.systemFileNumber] as? NSNumber == after[.systemFileNumber] as? NSNumber,
              before[.modificationDate] as? Date == after[.modificationDate] as? Date,
              before[.size] as? NSNumber == after[.size] as? NSNumber else {
            throw SafeDocumentExportError.destinationChanged
        }
        return .init(path: resolved.path, fileIdentity: "\(device):\(inode)",
                     fingerprint: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined())
    }

    static func write(data: Data, to destination: URL, protecting original: URL?,
                      existingFilePolicy: ExistingFilePolicy = .replace) throws {
        guard destination.isFileURL else { throw CocoaError(.fileWriteUnsupportedScheme) }
        let access = destination.startAccessingSecurityScopedResource()
        let originalAccess = original?.startAccessingSecurityScopedResource() == true
        defer {
            if access { destination.stopAccessingSecurityScopedResource() }
            if originalAccess { original?.stopAccessingSecurityScopedResource() }
        }
        if let original, isSameFile(destination, original) {
            throw SafeDocumentExportError.originalDestination
        }
        switch existingFilePolicy {
        case .replace:
            try data.write(to: destination, options: .atomic)
        case .forbidReplacement:
            try createAtomically(data: data, at: destination)
        case .replaceConfirmed(let authorization):
            // Files providers and participating writers serialize changes through
            // this native coordinator. Revalidate inside its access window.
            // An unrelated process bypassing coordination has no filesystem CAS.
            let coordinator = NSFileCoordinator(filePresenter: nil)
            var coordinationError: NSError?
            var writeResult: Result<Void, Error>?
            coordinator.coordinate(writingItemAt: destination, options: .forReplacing,
                                   error: &coordinationError) { coordinatedURL in
                writeResult = Result {
                    if let original, isSameFile(coordinatedURL, original) {
                        throw SafeDocumentExportError.originalDestination
                    }
                    guard (try? replacementAuthorization(for: coordinatedURL)) == authorization else {
                        throw SafeDocumentExportError.destinationChanged
                    }
                    try data.write(to: coordinatedURL, options: .atomic)
                }
            }
            if let writeResult { try writeResult.get() }
            else if let coordinationError { throw coordinationError }
            else { throw CocoaError(.fileWriteUnknown) }
        }
    }

    private static func createAtomically(data: Data, at destination: URL) throws {
        // Complete the bytes beside the destination before an exclusive rename.
        // A target appearing during serialization can never be overwritten.
        var template = destination.deletingLastPathComponent()
            .appendingPathComponent(".Dogear-export-XXXXXX").path.utf8CString
        let descriptor = template.withUnsafeMutableBufferPointer { buffer in
            mkstemp(buffer.baseAddress!)
        }
        guard descriptor != -1 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        let stagingURL = template.withUnsafeBufferPointer { buffer in
            URL(fileURLWithPath: String(cString: buffer.baseAddress!))
        }
        _ = close(descriptor)
        defer { try? FileManager.default.removeItem(at: stagingURL) }
        // mkstemp gives this operation exclusive ownership before cleanup is
        // installed; a staging-name collision never deletes somebody else's file.
        try data.write(to: stagingURL, options: .atomic)
        let result: Int32 = stagingURL.withUnsafeFileSystemRepresentation { source in
            destination.withUnsafeFileSystemRepresentation { target in
                guard let source, let target else { return EINVAL }
                return renamex_np(source, target, UInt32(RENAME_EXCL)) == 0 ? 0 : errno
            }
        }
        if result == EEXIST { throw SafeDocumentExportError.destinationExists }
        if result != 0 { throw NSError(domain: NSPOSIXErrorDomain, code: Int(result)) }
    }
}
