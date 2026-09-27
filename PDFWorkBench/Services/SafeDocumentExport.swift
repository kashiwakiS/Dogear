import Foundation

enum SafeDocumentExportError: LocalizedError {
    case originalDestination

    var errorDescription: String? {
        "Choose a different file name. The original PDF is not overwritten by default."
    }
}

/// Keep destination validation ahead of every write. SwiftUI fileExporter writes
/// before its completion callback supplies the destination, so that callback
/// cannot enforce the PDF original-file prohibition.
enum SafeDocumentExport {
    static func isSameFile(_ first: URL, _ second: URL) -> Bool {
        if first.resolvingSymlinksInPath().standardizedFileURL.path ==
            second.resolvingSymlinksInPath().standardizedFileURL.path { return true }
        // Also reject hard links and case aliases of an existing original.
        let firstID = try? first.resourceValues(forKeys: [.fileResourceIdentifierKey]).fileResourceIdentifier
        let secondID = try? second.resourceValues(forKeys: [.fileResourceIdentifierKey]).fileResourceIdentifier
        if let firstID = firstID as? NSObject, let secondID = secondID as? NSObject {
            return firstID.isEqual(secondID)
        }
        return false
    }

    static func write(data: Data, to destination: URL, protecting original: URL?) throws {
        let access = destination.startAccessingSecurityScopedResource()
        let originalAccess = original?.startAccessingSecurityScopedResource() == true
        defer {
            if access { destination.stopAccessingSecurityScopedResource() }
            if originalAccess { original?.stopAccessingSecurityScopedResource() }
        }
        if let original, isSameFile(destination, original) {
            throw SafeDocumentExportError.originalDestination
        }
        try data.write(to: destination, options: .atomic)
    }
}
