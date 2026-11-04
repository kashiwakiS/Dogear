#if os(iOS)
import Foundation

/// A text export is deliberately a single Markdown document. Stored image
/// attachments remain in Research; their identities replace package-only links
/// so the exported file has no dangling relative image references.
@MainActor
enum IPadResearchTextExport {
    static func session(id: UUID, storage: ResearchStore,
                        protectedOriginalURL: URL?) throws -> DocumentExportRequest {
        guard let session = storage.session(id: id) else { throw ResearchStoreError.missingRecord }
        return request(markdown: try storage.sessionMarkdown(id: id),
            attachmentIDs: session.attachmentIDs, storage: storage,
            suggestedName: "research.md", protectedOriginalURL: protectedOriginalURL)
    }

    static func note(id: UUID, storage: ResearchStore) throws -> DocumentExportRequest {
        guard let note = storage.note(id: id) else { throw ResearchStoreError.missingRecord }
        let ids = note.attachmentIDs.union(note.provenance.flatMap(\.evidence).compactMap(\.attachmentID))
        return request(markdown: try storage.noteMarkdown(id: id),
            attachmentIDs: ids, storage: storage,
            suggestedName: "research-note.md", protectedOriginalURL: nil)
    }

    private static func request(markdown: String, attachmentIDs: Set<UUID>, storage: ResearchStore,
                                suggestedName: String, protectedOriginalURL: URL?) -> DocumentExportRequest {
        var text = markdown
        for attachment in storage.attachments where attachmentIDs.contains(attachment.id) {
            let label = attachment.displayName.replacingOccurrences(of: "]", with: "\\]")
            let reference = "![\(label)](attachments/\(attachment.filename))"
            let description = "Image attachment: \(attachment.displayName) (\(attachment.id.uuidString))."
            text = text.replacingOccurrences(of: reference, with: description)
        }
        if !attachmentIDs.isEmpty {
            text += "\n" + L10n.string("This text export omits image files. The original attachments remain saved in Dogear.") + "\n"
        }
        return DocumentExportRequest(data: Data(text.utf8), suggestedName: suggestedName,
            contentType: DocumentExportRequest.markdownContentType, protectedOriginalURL: protectedOriginalURL)
    }
}
#endif
