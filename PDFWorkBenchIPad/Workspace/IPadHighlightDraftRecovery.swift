#if os(iOS)
import Combine
import CryptoKit
import Foundation
import PDFKit
import UIKit

/// App-private unfinished values, never an alternate annotation database. A
/// recovered editor must still pass the shared Store's native writer checks.
@MainActor
final class IPadHighlightDraftRecovery: ObservableObject {
    struct ColorValue: Codable, Equatable {
        let red: Double, green: Double, blue: Double, alpha: Double
        init(_ color: UIColor) throws {
            var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
            guard color.getRed(&r, green: &g, blue: &b, alpha: &a) else { throw RecoveryError.malformed }
            red = Double(r); green = Double(g); blue = Double(b); alpha = Double(a)
            guard isValid else { throw RecoveryError.malformed }
        }
        var isValid: Bool { [red, green, blue, alpha].allSatisfy { $0.isFinite && (0...1).contains($0) } }
        var color: UIColor { UIColor(red: CGFloat(red), green: CGFloat(green), blue: CGFloat(blue), alpha: CGFloat(alpha)) }
        func matches(_ color: UIColor) -> Bool {
            guard let other = try? Self(color) else { return false }
            // PDFKit serializes color components as PDF numbers. This tolerance
            // admits numeric roundtrip noise, not a different picker color.
            return zip([red, green, blue, alpha], [other.red, other.green, other.blue, other.alpha])
                .allSatisfy { abs($0.0 - $0.1) <= 0.000001 }
        }
    }
    struct Values: Codable {
        let comment: String
        let color: ColorValue
        init(_ values: IPadHighlightEditingSession.Values) throws {
            comment = values.comment; color = try ColorValue(values.color)
        }
        var editValues: IPadHighlightEditingSession.Values { .init(comment: comment, color: color.color) }
        func matches(_ annotation: PDFAnnotation) -> Bool {
            (annotation.contents ?? "") == comment && color.matches(annotation.color)
        }
    }
    struct Record: Codable, AnnotationDraftRecord {
        var recoveryText: String { values.comment }
        var schema = 1
        let draftID: UUID
        let fileID: UUID
        let pageIndex: Int
        let pageText: String?
        let sourceDigest: String?
        let pageDigest: String?
        let pageBounds: CGRect
        let rotation: Int
        let annotationName: String?
        let annotationBounds: CGRect
        let points: [CGPoint]?
        let quote: String
        let baseline: Values
        var values: Values
        var pendingSave = false
        var pendingUndo = false
        var completed = false
        var updatedAt = Date()
    }
    enum RecoveryError: LocalizedError {
        case identityChanged, malformed, occupied
        var errorDescription: String? {
            switch self {
            case .identityChanged: "The saved highlight draft does not match this page or annotation. The draft has been kept."
            case .malformed: "The saved highlight draft could not be read. The draft has been kept."
            case .occupied: "Multiple unfinished drafts exist. Choose a draft to review; all other drafts will be kept."
            }
        }
    }
    struct DiscardPermit {
        fileprivate let document: PDFDocument
        fileprivate let fileID: UUID
        fileprivate let url: URL
        fileprivate let digest: SHA256.Digest
    }

    @Published private(set) var lastError: String?
    @Published private(set) var candidates: [AnnotationDraftCandidate] = []
    private let directory: URL
    private let workspaceID: UUID
    private let feedback: OperationFeedbackCenter
    private weak var store: PDFDocumentStore?
    private weak var session: IPadHighlightEditingSession?
    private var fileID: UUID?
    private var record: Record?
    private var recordURL: URL?
    private var defaultURL: URL { directory.appendingPathComponent("\(workspaceID.uuidString)-\(fileID?.uuidString ?? "unbound").json") }
    private var valuesObservation: AnyCancellable?
    private var completionObservation: AnyCancellable?
    private var saveObservation: AnyCancellable?
    private weak var awaitingSavedDocument: PDFDocument?
    private var awaitingSavedDraftID: UUID?
    private weak var validatedUndoDocument: PDFDocument?
    private weak var validatedUndoAnnotation: PDFAnnotation?
    private var validatedUndoDraftID: UUID?
    private var preparedUndoDraftID: UUID?

    init(workspaceID: UUID, store: PDFDocumentStore, feedback: OperationFeedbackCenter, directoryURL: URL? = nil) {
        directory = directoryURL ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PDFWorkBench/HighlightDrafts", isDirectory: true)
        self.workspaceID = workspaceID; self.store = store; self.feedback = feedback
        saveObservation = store.$hasUnsavedChanges.combineLatest(store.$workingCopySaveError).sink { [weak self] dirty, error in
            guard let self, let native = self.awaitingSavedDocument, self.store?.document === native,
                  !dirty, error == nil, self.record?.draftID == self.awaitingSavedDraftID else { return }
            if self.finishRecord() { self.awaitingSavedDocument = nil; self.awaitingSavedDraftID = nil }
        }
    }

    var hasUnresolvedRecord: Bool { session == nil && (record?.completed == false || lastError != nil) }

    /// Bind only after a successful native open and shared Library identity bind.
    func bind(fileID: UUID) {
        if self.fileID != fileID {
            record = nil; recordURL = nil; lastError = nil; candidates = []
            awaitingSavedDocument = nil; awaitingSavedDraftID = nil
            validatedUndoDocument = nil; validatedUndoAnnotation = nil; preparedUndoDraftID = nil
            validatedUndoDraftID = nil
        }
        self.fileID = fileID
    }

    func track(_ session: IPadHighlightEditingSession?) {
        valuesObservation = nil; completionObservation = nil; self.session = session
        guard let session else {
            revealRemainingRecordIfIdle()
            return
        }
        session.beforeSave = { [weak self, weak session] in
            guard let self, let session, self.session === session, !session.isFinished else { return false }
            return self.checkpoint(session, values: session.values, pendingSave: true)
        }
        session.beforeDiscard = { [weak self, weak session] in
            guard let self, let session, self.session === session, !session.isFinished else { return false }
            guard self.record == nil || self.record?.draftID == session.id else {
                session.error = RecoveryError.occupied.localizedDescription; return false
            }
            let finished = self.finishRecord()
            if !finished { session.error = self.lastError }
            return finished
        }
        valuesObservation = session.$values.sink { [weak self, weak session] values in
            guard let self, let session, !session.isFinished else { return }
            _ = self.checkpoint(session, values: values)
        }
        completionObservation = session.$completion.compactMap { $0 }.sink { [weak self, weak session] completion in
            guard let self, let session, completion == .saved,
                  self.store?.document === session.draft.document, self.record?.draftID == session.id,
                  self.record?.fileID == self.fileID else { return }
            self.validatedUndoDocument = session.draft.document
            self.validatedUndoAnnotation = session.draft.annotation
            self.validatedUndoDraftID = session.id
            self.finishAppliedRecord(in: session.draft.document)
        }
    }

    @discardableResult
    func flush() -> Bool {
        guard let session, !session.isFinished else { return true }
        guard session.finishIME() else {
            report(L10n.string("Finish composing the comment before leaving the editor.")); return false
        }
        return checkpoint(session, values: session.values)
    }

    @discardableResult
    func prepareDocumentUndo(in document: PDFDocument) -> Bool {
        preparedUndoDraftID = nil
        guard store?.document === document, store?.canUndoDocumentChange == true else { return false }
        // A later draft can target the same native highlight without having
        // committed. Its write-ahead record cannot borrow an older Save's proof.
        guard validatedUndoDocument === document, var record, record.fileID == fileID,
              validatedUndoDraftID == record.draftID,
              record.pendingSave, !record.completed else { return true }
        record.pendingUndo = true
        do { try write(record); self.record = record; preparedUndoDraftID = record.draftID; return true }
        catch { report(error.localizedDescription); return false }
    }

    func didUndoDocument(in document: PDFDocument) {
        defer { preparedUndoDraftID = nil }
        guard store?.document === document, validatedUndoDocument === document, let annotation = validatedUndoAnnotation,
              let record, record.draftID == preparedUndoDraftID, record.fileID == fileID,
              validatedUndoDraftID == record.draftID,
              record.pendingUndo, let page = annotation.page, page.document === document,
              page.annotations.contains(where: { $0 === annotation }), matches(annotation, record: record, values: record.baseline) else { return }
        if finishRecord() { awaitingSavedDocument = nil; awaitingSavedDraftID = nil }
    }

    func restore() -> IPadHighlightEditingSession? {
        guard session == nil, let fileID, let store, store.canEditDocument, let document = store.document,
              store.captureWritePermit(requestID: UUID())?.fileID == fileID else { return nil }
        validatedUndoDocument = nil; validatedUndoAnnotation = nil; preparedUndoDraftID = nil
        validatedUndoDraftID = nil
        do {
            if record == nil { try loadRecord(for: fileID) }
            guard let record, record.fileID == fileID else { return nil }
            guard record.schema == 1 else { throw RecoveryError.malformed }
            if record.completed { _ = finishRecord(); return nil }
            guard valid(record), sourceStillMatches(record) else { throw RecoveryError.identityChanged }
            if record.pendingSave {
                // Page organization can move an accepted annotation before its
                // write completes. This branch only recognizes an already
                // applied edit; it never restores values or mutates the PDF.
                // Check all content-matching pages so a duplicate cannot turn
                // a first match into false proof of the saved draft's identity.
                var applied: [PDFAnnotation] = []
                for index in 0..<document.pageCount {
                    guard let page = document.page(at: index), try matchesPageContent(page, record: record) else { continue }
                    applied.append(contentsOf: page.annotations.filter { matches($0, record: record, values: record.values) })
                }
                guard applied.count <= 1 else { throw RecoveryError.identityChanged }
                if applied.count == 1, let annotation = applied.first {
                    validatedUndoDocument = document; validatedUndoAnnotation = annotation
                    validatedUndoDraftID = record.draftID
                    lastError = nil
                    finishAppliedRecord(in: document); return nil
                }
            }
            guard let page = document.page(at: record.pageIndex), page.rotation == record.rotation,
                  try matchesPageContent(page, record: record) else { throw RecoveryError.identityChanged }
            let candidates = page.annotations.filter { matches($0, record: record, values: record.baseline) }
            guard candidates.count == 1, let annotation = candidates.first else { throw RecoveryError.identityChanged }
            if record.pendingUndo { finishAppliedRecord(in: document); return nil }
            let draft = HighlightEditDraft(document: document, annotation: annotation, quote: record.quote,
                color: annotation.color, comment: annotation.contents ?? "")
            let editor = IPadHighlightEditingSession(draft: draft, id: record.draftID)
            editor.values = record.values.editValues; lastError = nil
            return editor
        } catch { report(error.localizedDescription); return nil }
    }

    @discardableResult
    private func checkpoint(_ session: IPadHighlightEditingSession, values: IPadHighlightEditingSession.Values,
                            pendingSave: Bool = false) -> Bool {
        guard let fileID, let store, store.document === session.draft.document,
              store.captureWritePermit(requestID: session.id)?.fileID == fileID,
              let page = session.draft.annotation.page, page.document === session.draft.document else {
            session.error = RecoveryError.identityChanged.localizedDescription; return false
        }
        guard pendingSave || values != .init(comment: session.draft.comment, color: session.draft.color) || record != nil else { return true }
        do {
            // Recheck disk before the first edit too: a writer may have become
            // active after an earlier read-only restore attempt was declined.
            if record == nil { try loadRecord(for: fileID) }
            if let record, !record.completed, record.draftID != session.id { throw RecoveryError.occupied }
            let previous = record?.draftID == session.id ? record : nil
            if let previous, pendingSave, !sourceStillMatches(previous) { throw RecoveryError.identityChanged }
            let pageIndex = session.draft.document.index(for: page)
            guard pageIndex != NSNotFound else { throw RecoveryError.identityChanged }
            let digest: String?
            if let previous { digest = previous.pageDigest } else { digest = try? pageFingerprint(page) }
            var next = Record(draftID: session.id, fileID: fileID, pageIndex: previous?.pageIndex ?? pageIndex,
                pageText: previous?.pageText ?? page.string, sourceDigest: previous?.sourceDigest ?? (try? originalDigest()),
                pageDigest: digest, pageBounds: previous?.pageBounds ?? page.bounds(for: .cropBox),
                rotation: previous?.rotation ?? page.rotation,
                annotationName: session.draft.annotation.value(forAnnotationKey: .name) as? String,
                annotationBounds: session.baselineBounds, points: session.baselinePoints, quote: session.draft.quote,
                baseline: try Values(.init(comment: session.draft.comment, color: session.draft.color)), values: try Values(values))
            next.pendingSave = pendingSave
            guard valid(next) else { throw RecoveryError.malformed }
            try write(next); record = next; lastError = nil; session.error = nil
            return true
        } catch { session.error = error.localizedDescription; report(error.localizedDescription); return false }
    }

    private func valid(_ record: Record) -> Bool {
        record.schema == 1 && record.pageIndex >= 0 && (record.pageDigest?.isEmpty != true)
            && finiteRect(record.pageBounds) && finiteRect(record.annotationBounds)
            && (record.points?.allSatisfy { $0.x.isFinite && $0.y.isFinite } ?? true)
            && record.baseline.color.isValid && record.values.color.isValid
    }
    private func finiteRect(_ rect: CGRect) -> Bool {
        [rect.origin.x, rect.origin.y, rect.width, rect.height].allSatisfy(\.isFinite) && rect.width > 0 && rect.height > 0
    }
    private func matches(_ annotation: PDFAnnotation, record: Record, values: Values) -> Bool {
        annotation.type == "Highlight" && annotation.bounds == record.annotationBounds
            && annotation.quadrilateralPoints?.map({ PDFPlatformStyle.point(from: $0) }) == record.points
            && (record.annotationName == nil || (annotation.value(forAnnotationKey: .name) as? String) == record.annotationName)
            && values.matches(annotation)
    }
    private func matchesPageContent(_ page: PDFPage, record: Record) throws -> Bool {
        guard let digest = record.pageDigest, page.string == record.pageText,
              page.bounds(for: .cropBox) == record.pageBounds else { return false }
        return try pageFingerprint(page) == digest
    }

    private func loadRecord(for fileID: UUID) throws {
        let entries = try AnnotationDraftFiles.scan(Record.self, directory: directory, fileID: fileID)
        candidates = entries.map(\.candidate)
        guard entries.count <= 1 else { throw RecoveryError.occupied }
        guard let entry = entries.first else { candidates = []; return }
        recordURL = entry.candidate.url
        guard let value = entry.record, value.schema == 1 else { throw RecoveryError.malformed }
        record = value; candidates = []
    }

    private func revealRemainingRecordIfIdle() {
        guard session == nil, record == nil, let fileID else { return }
        do {
            try loadRecord(for: fileID)
            if record != nil { report(L10n.string("Another unfinished draft is available. Retry to review it.")) }
        } catch { report(error.localizedDescription) }
    }

    func selectCandidate(_ candidate: AnnotationDraftCandidate) -> Bool {
        guard session == nil, candidate.fileID == fileID,
              candidates.contains(where: { $0.id == candidate.id }), AnnotationDraftFiles.unchanged(candidate) else {
            report(L10n.string("The highlight draft changed. Retry recovery before choosing it.")); return false
        }
        recordURL = candidate.url
        record = try? JSONDecoder().decode(Record.self, from: Data(contentsOf: candidate.url))
        candidates = []
        if record == nil { report(RecoveryError.malformed.localizedDescription); return false }
        lastError = nil; return true
    }

    private func write(_ record: Record) throws {
        let url = recordURL ?? defaultURL
        try AnnotationDraftFiles.write(record, to: url); recordURL = url
    }

    private func originalDigest() throws -> String {
        guard let url = store?.selectedPDFURL else { throw RecoveryError.identityChanged }
        let access = ScopedLibraryFileAccess(url: url)
        return try withExtendedLifetime(access) {
            hex(SHA256.hash(data: try Data(contentsOf: url, options: .mappedIfSafe)))
        }
    }
    private func sourceStillMatches(_ record: Record) -> Bool {
        guard let expected = record.sourceDigest, let current = try? originalDigest() else { return true }
        return expected == current
    }
    private func pageFingerprint(_ page: PDFPage) throws -> String {
        guard let reference = page.pageRef else { throw RecoveryError.identityChanged }
        let crop = page.bounds(for: .cropBox)
        guard finiteRect(crop) else { throw RecoveryError.identityChanged }
        let scale = 256 / max(crop.width, crop.height)
        let width = max(1, Int((crop.width * scale).rounded())), height = max(1, Int((crop.height * scale).rounded()))
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue), let bytes = context.data else {
            throw RecoveryError.identityChanged
        }
        let rect = CGRect(x: 0, y: 0, width: width, height: height)
        context.setFillColor(gray: 1, alpha: 1); context.fill(rect)
        context.concatenate(reference.getDrawingTransform(.cropBox, rect: rect, rotate: 0, preserveAspectRatio: true))
        context.drawPDFPage(reference)
        return hex(SHA256.hash(data: Data(bytes: bytes, count: width * height * 4)))
    }
    private func hex(_ digest: SHA256.Digest) -> String { digest.map { String(format: "%02x", $0) }.joined() }

    private func finishAppliedRecord(in document: PDFDocument) {
        guard let record else { return }
        guard store?.hasUnsavedChanges == false, store?.workingCopySaveError == nil else {
            awaitingSavedDocument = document; awaitingSavedDraftID = record.draftID; return
        }
        _ = finishRecord()
    }

    func captureDiscardPermit() -> DiscardPermit? {
        guard session == nil, let fileID, let document = store?.document else { return nil }
        guard candidates.count <= 1 else { return nil }
        let url = recordURL ?? defaultURL
        guard let data = try? Data(contentsOf: url) else { return nil }
        return .init(document: document, fileID: fileID, url: url, digest: SHA256.hash(data: data))
    }
    @discardableResult
    func discardSavedDraft(using permit: DiscardPermit) -> Bool {
        guard session == nil, store?.document === permit.document, fileID == permit.fileID,
              (recordURL ?? defaultURL) == permit.url, let data = try? Data(contentsOf: permit.url),
              SHA256.hash(data: data) == permit.digest else {
            report(L10n.string("The highlight draft changed. Open its discard confirmation again.")); return false
        }
        if record != nil { return finishRecord() }
        do {
            try FileManager.default.removeItem(at: permit.url); recordURL = nil; candidates = []; lastError = nil
            revealRemainingRecordIfIdle()
            return true
        }
        catch { report(error.localizedDescription); return false }
    }

    @discardableResult
    private func finishRecord() -> Bool {
        guard let record, let url = recordURL else { return true }
        do {
            let result = try AnnotationDraftFiles.complete(record, at: url)
            self.record = result.record
            if let error = result.cleanupError { report(error) }
            else {
                self.record = nil; recordURL = nil; lastError = nil; candidates = []
                revealRemainingRecordIfIdle()
            }
            return true
        } catch { report(error.localizedDescription); return false }
    }
    private func report(_ message: String) {
        lastError = L10n.string(.init(stringLiteral: message)); feedback.post(lastError ?? message, kind: .error)
    }
}
#endif
