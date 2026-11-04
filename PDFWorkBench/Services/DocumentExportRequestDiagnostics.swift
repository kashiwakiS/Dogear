import Foundation
import UniformTypeIdentifiers

nonisolated struct DocumentExportRequestDiagnosticReport {
    let checkCount: Int
    let failures: [String]
}

/// Real shared payload/writer with disposable files; no application or picker
/// stubs and no user document access.
@MainActor
enum DocumentExportRequestDiagnostics {
    static func run() -> DocumentExportRequestDiagnosticReport {
        var checks = 0
        var failures: [String] = []
        func check(_ condition: @autoclosure () -> Bool, _ message: String) {
            checks += 1
            if !condition() { failures.append(message) }
        }
        do {
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent("DogearSharedExport-\(UUID())")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }
            let original = root.appendingPathComponent("original.pdf")
            let replacement = root.appendingPathComponent("replacement.pdf")
            let originalBytes = Data("original bytes".utf8)
            let replacementBytes = Data("replacement bytes".utf8)
            try originalBytes.write(to: original)
            try replacementBytes.write(to: replacement)

            var liveBytes = Data("captured annotation copy".utf8)
            var liveOriginal = original
            let request = DocumentExportRequest(data: liveBytes, suggestedName: "annotated.pdf",
                contentType: .pdf, protectedOriginalURL: liveOriginal)
            liveBytes.append(Data(" later edit".utf8))
            liveOriginal = replacement
            check(request.data == Data("captured annotation copy".utf8)
                && request.data != liveBytes && request.protectedOriginalURL == original
                && request.protectedOriginalURL != liveOriginal,
                "A later edit/document switch changed the prepared bytes or protected original.")
            check(request.suggestedName == "annotated.pdf" && request.contentType == .pdf,
                "The PDF payload lost its filename or destination type.")

            let symlink = root.appendingPathComponent("original-link.pdf")
            let hardlink = root.appendingPathComponent("original-hardlink.pdf")
            try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: original)
            try FileManager.default.linkItem(at: original, to: hardlink)
            for destination in [original, symlink, hardlink] {
                do {
                    try request.write(to: destination)
                    check(false, "The prepared PDF export overwrote an original or alias.")
                } catch SafeDocumentExportError.originalDestination { check(true, "") }
            }
            check((try? Data(contentsOf: original)) == originalBytes
                && (try? Data(contentsOf: replacement)) == replacementBytes,
                "A rejected delayed export changed its old or new original.")

            let changingAlias = root.appendingPathComponent("changing-alias.pdf")
            try replacementBytes.write(to: changingAlias)
            _ = try changingAlias.resourceValues(forKeys: [.fileResourceIdentifierKey])
            check(!SafeDocumentExport.isSameFile(changingAlias, original),
                "The changing-alias fixture started as the original.")
            try FileManager.default.removeItem(at: changingAlias)
            try FileManager.default.linkItem(at: original, to: changingAlias)
            let aliasAttributes = try FileManager.default.attributesOfItem(atPath: changingAlias.path)
            let originalAttributes = try FileManager.default.attributesOfItem(atPath: original.path)
            check(aliasAttributes[.systemNumber] as? NSNumber == originalAttributes[.systemNumber] as? NSNumber
                && aliasAttributes[.systemFileNumber] as? NSNumber == originalAttributes[.systemFileNumber] as? NSNumber
                && aliasAttributes[.systemFileNumber] != nil,
                "The changing-alias fixture did not create an actual original hard link.")
            check(SafeDocumentExport.isSameFile(changingAlias, original),
                "Original protection used a cached identity after the target became a hard link.")
            for policy in [SafeDocumentExport.ExistingFilePolicy.replace, .forbidReplacement,
                           .replaceConfirmed(try SafeDocumentExport.replacementAuthorization(for: changingAlias))] {
                do {
                    try request.write(to: changingAlias, existingFilePolicy: policy)
                    check(false, "A write policy accepted a target changed into an original hard link.")
                } catch SafeDocumentExportError.originalDestination { check(true, "") }
            }
            check((try? Data(contentsOf: changingAlias)) == originalBytes && (try? Data(contentsOf: original)) == originalBytes,
                "A changing hard-link refusal altered original or alias bytes.")

            let pdfCopy = root.appendingPathComponent("copy.pdf")
            try Data("previous copy".utf8).write(to: pdfCopy)
            try request.write(to: pdfCopy)
            check((try? Data(contentsOf: pdfCopy)) == request.data,
                "A valid destination did not receive exactly the captured PDF bytes.")

            let exclusiveCopy = root.appendingPathComponent("exclusive.pdf")
            try request.write(to: exclusiveCopy, existingFilePolicy: .forbidReplacement)
            check((try? Data(contentsOf: exclusiveCopy)) == request.data,
                "An exclusive export did not atomically install its prepared bytes.")
            let unconfirmedBytes = Data("appeared before export committed".utf8)
            try unconfirmedBytes.write(to: exclusiveCopy, options: .atomic)
            do {
                try request.write(to: exclusiveCopy, existingFilePolicy: .forbidReplacement)
                check(false, "An exclusive export replaced a newly existing destination.")
            } catch SafeDocumentExportError.destinationExists { check(true, "") }
            check((try? Data(contentsOf: exclusiveCopy)) == unconfirmedBytes,
                "A refused exclusive export changed the unconfirmed file.")
            let confirmation = try SafeDocumentExport.replacementAuthorization(for: exclusiveCopy)
            let changedBytes = Data("changed while replacement confirmation was open".utf8)
            try changedBytes.write(to: exclusiveCopy, options: .atomic)
            do {
                try request.write(to: exclusiveCopy, existingFilePolicy: .replaceConfirmed(confirmation))
                check(false, "An old confirmation replaced a different destination revision.")
            } catch SafeDocumentExportError.destinationChanged { check(true, "") }
            check((try? Data(contentsOf: exclusiveCopy)) == changedBytes,
                "A stale replacement confirmation changed the newer file.")
            let freshConfirmation = try SafeDocumentExport.replacementAuthorization(for: exclusiveCopy)
            try request.write(to: exclusiveCopy, existingFilePolicy: .replaceConfirmed(freshConfirmation))
            check((try? Data(contentsOf: exclusiveCopy)) == request.data,
                "An unchanged, explicitly confirmed target could not be replaced.")
            check((try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil))?
                .contains(where: { $0.lastPathComponent.hasPrefix(".Dogear-export-") }) == false,
                "Atomic export left a staging file after success or collision refusal.")

            let markdown = DocumentExportRequest(data: Data("# Notes\n\n中文 😀".utf8),
                suggestedName: "notes.md", contentType: DocumentExportRequest.markdownContentType, protectedOriginalURL: original)
            check(markdown.contentType == (UTType(filenameExtension: "md") ?? .plainText)
                && markdown.suggestedName == "notes.md",
                "The Markdown payload lost its destination type or filename.")
            do {
                try markdown.write(to: original)
                check(false, "The Markdown export bypassed original protection.")
            } catch SafeDocumentExportError.originalDestination { check(true, "") }
            let markdownCopy = root.appendingPathComponent("notes.md")
            try markdown.write(to: markdownCopy)
            check((try? Data(contentsOf: markdownCopy)) == markdown.data,
                "A valid Markdown destination lost UTF-8 content.")

            let failedDestination = root.appendingPathComponent("missing/copy.pdf")
            do {
                try request.write(to: failedDestination)
                check(false, "An export to a missing directory reported success.")
            } catch {
                check(!FileManager.default.fileExists(atPath: failedDestination.path),
                    "A failed export left a partial destination.")
            }
            check((try? Data(contentsOf: original)) == originalBytes
                && (try? Data(contentsOf: replacement)) == replacementBytes,
                "Copy export or failure changed an original PDF.")

            let generated = DocumentExportRequest(data: Data("generated content".utf8),
                suggestedName: "generated.md", contentType: DocumentExportRequest.markdownContentType, protectedOriginalURL: nil)
            let generatedCopy = root.appendingPathComponent("generated.md")
            try generated.write(to: generatedCopy)
            check((try? Data(contentsOf: generatedCopy)) == generated.data,
                "An export without an original could not create its requested destination.")
        } catch { failures.append("Export fixture: \(error.localizedDescription)") }
        return .init(checkCount: checks, failures: failures)
    }
}
