import Foundation
import PDFKit

struct ResolvedResearchEvidence {
    let document: PDFDocument
    let pageIndex: Int
    let rect: CGRect?
    let revalidated: Bool
}

@MainActor
enum ResearchEvidenceResolver {
    static func resolve(_ evidence: ResearchEvidence, library: LibraryStore) async throws -> ResolvedResearchEvidence {
        guard let source = evidence.source, evidence.anchor != nil,
              let file = library.allFiles.first(where: { $0.id == source.fileID }) else {
            throw DocumentAccessError.snapshotUnavailable
        }
        let read = try DocumentAccessCoordinator.shared.readSnapshot(fileID: file.id,
            originalURL: library.resolvedURL(for: file), workingCopyURL: file.workingCopyURL)
        return try await resolve(evidence, read: read)
    }

    /// Injected detached snapshots keep identity/version/geometry validation
    /// independently testable without opening a Library editor or user file.
    static func resolve(_ evidence: ResearchEvidence, read: PDFSourceReadSnapshot) async throws -> ResolvedResearchEvidence {
        guard let source = evidence.source, let anchor = evidence.anchor,
              read.fileID == source.fileID, anchor.pageIndex >= 0, anchor.pageIndex < read.document.pageCount,
              let page = read.document.page(at: anchor.pageIndex) else {
            throw DocumentAccessError.snapshotUnavailable
        }
        let components = [anchor.x, anchor.y, anchor.width, anchor.height]
        let hasGeometry = components.contains { $0 != nil }
        var rect: CGRect?
        if hasGeometry {
            guard let x = anchor.x, let y = anchor.y, let width = anchor.width, let height = anchor.height,
                  [x, y, width, height].allSatisfy(\.isFinite), width > 0, height > 0 else {
                throw ResearchRuntimeError.sourceChanged(source.displayName)
            }
            let candidate = CGRect(x: x, y: y, width: width, height: height)
            guard !candidate.isInfinite, page.bounds(for: .cropBox).contains(candidate) else {
                throw ResearchRuntimeError.sourceChanged(source.displayName)
            }
            rect = candidate
        } else if evidence.kind == .image {
            throw ResearchRuntimeError.sourceChanged(source.displayName)
        }
        let revalidated = read.contentVersion != source.fingerprint
        if revalidated {
            // Annotation-only changes may leave this precise text passage valid.
            // Image/annotation anchors cannot be recovered from matching text.
            guard evidence.kind == .pdfText, let expected = anchor.pageFingerprint else {
                throw ResearchRuntimeError.sourceChanged(source.displayName)
            }
            let current = try await NativePDFTextSnapshotBuilder(document: read.document).makeTextSnapshotCooperatively()
            try Task.checkCancellation()
            guard let snapshot = current.pages.first(where: { $0.pageNumber == anchor.pageIndex + 1 }),
                  snapshot.fingerprint == expected, !evidence.excerpt.isEmpty else {
                throw ResearchRuntimeError.sourceChanged(source.displayName)
            }
            // A page may retain identical text while its drawing geometry changes.
            // Only a unique exact excerpt can establish a new position; never reuse
            // old rectangle coordinates merely because the page contains the text.
            let text = snapshot.text as NSString
            let match = text.range(of: evidence.excerpt)
            guard match.location != NSNotFound else { throw ResearchRuntimeError.sourceChanged(source.displayName) }
            let tail = NSRange(location: NSMaxRange(match), length: text.length - NSMaxRange(match))
            guard text.range(of: evidence.excerpt, range: tail).location == NSNotFound,
                  let selection = page.selection(for: match),
                  selection.string == evidence.excerpt else {
                throw ResearchRuntimeError.sourceChanged(source.displayName)
            }
            let currentRect = selection.bounds(for: page).intersection(page.bounds(for: .cropBox))
            guard !currentRect.isNull, !currentRect.isEmpty else { throw ResearchRuntimeError.sourceChanged(source.displayName) }
            rect = currentRect
        }
        try Task.checkCancellation()
        return ResolvedResearchEvidence(document: read.document, pageIndex: anchor.pageIndex, rect: rect, revalidated: revalidated)
    }
}
