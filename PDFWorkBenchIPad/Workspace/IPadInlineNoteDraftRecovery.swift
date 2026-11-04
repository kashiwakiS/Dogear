#if os(iOS)
import Combine
import CryptoKit
import Foundation
import PDFKit

/// A native editor's unfinished values are a sidecar, never committed PDF data.
/// Restoration uses Library identity and the unchanged page/annotation baseline.
@MainActor
final class IPadInlineNoteDraftRecovery: ObservableObject {
    struct Values: Codable, Equatable {
        var text: String
        var width: Double
        var height: Double
        var fontSize: Double
        var fontColor: PDFColorComponents? = nil
        var fontName: String? = nil
        init(_ value: FreeTextEditValues) {
            text = value.text; width = value.width; height = value.height; fontSize = value.fontSize
            fontColor = value.fontColor
            fontName = value.fontName
        }
        var editValues: FreeTextEditValues {
            .init(text: text, width: width, height: height, fontSize: fontSize, fontColor: fontColor, fontName: fontName)
        }
    }
    /// Exact attributes of a known plain standard note predating a detached draft.
    struct CollisionBaseline: Codable, Equatable {
        let pageIndex: Int
        let bounds: CGRect
        let text: String?
        let fontName: String
        let fontSize: Double
        let fontColor: PDFColorComponents
        let annotationColor: PDFColorComponents?
        var rawColorPresent: Bool? = nil
        var annotationName: String?
        var modificationDate: Date?
    }
    struct Record: Codable, AnnotationDraftRecord {
        var recoveryText: String { values.text }
        var schema = 1
        let draftID: UUID
        let fileID: UUID
        let pageIndex: Int
        let pageText: String?
        let sourceDigest: String?
        let pageDigest: String?
        let pageBounds: CGRect
        let rotation: Int
        let isNew: Bool
        let annotationName: String?
        let originalBounds: CGRect
        let baseline: Values
        var values: Values
        var pendingSave = false
        var pendingUndo = false
        var completed = false
        var updatedAt = Date()
        /// Absent in legacy sidecars; only a detached draft can establish it.
        var baselineSemanticMatchCount: Int? = nil
        var collisionBaselines: [CollisionBaseline]? = nil
    }
    enum RecoveryError: LocalizedError {
        case identityChanged, malformed, occupied
        var errorDescription: String? {
            switch self {
            case .identityChanged: "The saved note draft does not match this page or annotation. The draft has been kept."
            case .malformed: "The saved note draft could not be read. The draft has been kept."
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
    private var defaultURL: URL { directory.appendingPathComponent("\(workspaceID.uuidString)-\(fileID?.uuidString ?? "unbound").json") }
    private var recordURL: URL?
    private var record: Record?
    private var fileID: UUID?
    private weak var store: PDFDocumentStore?
    private weak var session: IPadInlineNoteEditingSession?
    private let feedback: OperationFeedbackCenter
    private var valuesObservation: AnyCancellable?
    private var completionObservation: AnyCancellable?
    private var saveObservation: AnyCancellable?
    private weak var awaitingSavedDocument: PDFDocument?
    private var awaitingSavedDraftID: UUID?
    private weak var validatedUndoDocument: PDFDocument?
    private weak var validatedUndoAnnotation: PDFAnnotation?
    private var validatedUndoDraftID: UUID?
    private var preparedUndoDraftID: UUID?

    init(workspaceID: UUID, store: PDFDocumentStore, feedback: OperationFeedbackCenter,
         directoryURL: URL? = nil) {
        directory = directoryURL ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PDFWorkBench/InlineNoteDrafts", isDirectory: true)
        self.workspaceID = workspaceID
        self.store = store; self.feedback = feedback
        saveObservation = store.$hasUnsavedChanges.combineLatest(store.$workingCopySaveError).sink { [weak self] dirty, error in
            guard let self, let saved = self.awaitingSavedDocument,
                  self.store?.document === saved, !dirty, error == nil else { return }
            guard self.record?.draftID == self.awaitingSavedDraftID else {
                self.awaitingSavedDocument = nil; self.awaitingSavedDraftID = nil; return
            }
            if self.finishRecord() { self.awaitingSavedDocument = nil; self.awaitingSavedDraftID = nil }
        }
    }

    var hasUnresolvedRecord: Bool { session == nil && (record?.completed == false || lastError != nil) }

    var diagnosticState: String {
        [
            "loadedDraft=\(String(describing: record?.draftID)), pendingSave=\(String(describing: record?.pendingSave)), pendingUndo=\(String(describing: record?.pendingUndo)), completed=\(String(describing: record?.completed))",
            "awaitingDraft=\(String(describing: awaitingSavedDraftID)), awaitingCurrentDocument=\(awaitingSavedDocument != nil && awaitingSavedDocument === store?.document)",
            "validatedUndoCurrentDocument=\(validatedUndoDocument != nil && validatedUndoDocument === store?.document), validatedUndoAttached=\(validatedUndoAnnotation?.page != nil), validatedUndoDraft=\(String(describing: validatedUndoDraftID))",
            "trackedSession=\(String(describing: session?.id)), error=\(String(describing: lastError))"
        ].joined(separator: "; ")
    }

    /// Called only after the host binds the successfully opened Library record.
    func bind(fileID: UUID) {
        if self.fileID != fileID {
            record = nil; recordURL = nil; lastError = nil; candidates = []
            awaitingSavedDocument = nil; awaitingSavedDraftID = nil
            validatedUndoDocument = nil; validatedUndoAnnotation = nil; preparedUndoDraftID = nil
            validatedUndoDraftID = nil
        }
        self.fileID = fileID
    }

    func track(_ session: IPadInlineNoteEditingSession?) {
        valuesObservation = nil; completionObservation = nil; self.session = session
        guard let session else {
            revealRemainingRecordIfIdle()
            return
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
        session.beforeSave = { [weak self, weak session] in
            guard let self, let session, self.session === session, !session.isFinished else { return false }
            return self.checkpoint(session, values: session.values, pendingSave: true)
        }
        valuesObservation = session.$values.sink { [weak self, weak session] values in
            guard let self, let session, !session.isFinished else { return }
            self.checkpoint(session, values: values)
        }
        completionObservation = session.$completion.compactMap { $0 }.sink { [weak self, weak session] completion in
            guard let self, let session else { return }
            switch completion {
            case .discarded: break // beforeDiscard already durably recorded it.
            case .saved:
                if var intent = self.record {
                    intent.pendingSave = true; intent.updatedAt = Date()
                    do { try self.write(intent); self.record = intent }
                    catch { self.report(error.localizedDescription) }
                }
                if self.store?.document === session.draft.document,
                   self.record?.fileID == self.fileID, self.record?.draftID == session.id {
                    self.validatedUndoDocument = session.draft.document
                    self.validatedUndoAnnotation = session.draft.annotation
                    self.validatedUndoDraftID = session.id
                }
                self.awaitingSavedDocument = session.draft.document
                self.awaitingSavedDraftID = self.record?.draftID
                if self.store?.hasUnsavedChanges == false, self.store?.workingCopySaveError == nil,
                   self.finishRecord() { self.awaitingSavedDocument = nil; self.awaitingSavedDraftID = nil }
            }
        }
    }

    @discardableResult
    func flush() -> Bool {
        guard let session, !session.isFinished else { return true }
        guard session.finishIME() else {
            report(L10n.string("Finish composing the note before leaving the editor.")); return false
        }
        return checkpoint(session, values: session.values)
    }

    /// Document Undo explicitly revokes an accepted note's pending editor intent.
    /// Native text Undo does not call this method and never changes PDF history.
    func prepareDocumentUndo(in document: PDFDocument) -> Bool {
        preparedUndoDraftID = nil
        guard store?.document === document, store?.canUndoDocumentChange == true else { return false }
        // A mismatched recovery record cannot participate in this document's
        // history. Ordinary Undo remains available without consuming that record.
        guard validatedUndoDocument === document, var record, record.fileID == fileID,
              validatedUndoDraftID == record.draftID,
              record.pendingSave, !record.completed else { return true }
        record.pendingUndo = true
        do { try write(record); self.record = record; preparedUndoDraftID = record.draftID; return true }
        catch { report(error.localizedDescription); return false }
    }

    func didUndoDocument(in document: PDFDocument) {
        defer { preparedUndoDraftID = nil }
        guard store?.document === document, validatedUndoDocument === document,
              let record, record.draftID == preparedUndoDraftID, record.pendingUndo,
              validatedUndoDraftID == record.draftID,
              record.fileID == fileID, matchesOriginalAnnotation(record, in: document) else { return }
        _ = finishRecord(); awaitingSavedDocument = nil; awaitingSavedDraftID = nil
    }

    func restore() -> IPadInlineNoteEditingSession? {
        guard session == nil, let fileID, let store, store.canEditDocument, let document = store.document else { return nil }
        validatedUndoDocument = nil; validatedUndoAnnotation = nil; preparedUndoDraftID = nil
        validatedUndoDraftID = nil
        do {
            if record == nil { try loadRecord(for: fileID) }
            guard let record, record.fileID == fileID else { return nil }
            guard record.schema == 1 else { throw RecoveryError.malformed }
            if record.completed { _ = finishRecord(); return nil }
            guard record.pageIndex >= 0,
                  let page = document.page(at: record.pageIndex),
                  sourceStillMatches(record), let pageDigest = record.pageDigest,
                  try pageFingerprint(page) == pageDigest,
                  page.string == record.pageText, page.bounds(for: .cropBox) == record.pageBounds,
                  page.rotation == record.rotation else { throw RecoveryError.identityChanged }
            if record.isNew, record.pendingUndo {
                guard matchesOriginalAnnotation(record, in: document) else { throw RecoveryError.identityChanged }
                finishAppliedRecord(in: document, store: store, record: record); return nil
            }
            let draft: FreeTextEditDraft
            if record.isNew {
                // A saved draft whose cleanup was interrupted must never create
                // the same annotation again after a successful PDF commit.
                let named = page.annotations.filter { annotation in
                    record.annotationName != nil && (annotation.value(forAnnotationKey: .name) as? String) == record.annotationName
                }
                if !named.isEmpty {
                    guard named.count == 1, let existing = named.first,
                          matchesNewNoteSemantics(existing, record: record, document: document, page: page) else {
                        throw RecoveryError.identityChanged
                    }
                    validatedUndoDocument = document; validatedUndoAnnotation = existing; validatedUndoDraftID = record.draftID
                    finishAppliedRecord(in: document, store: store, record: record); return nil
                }
                // PDFKit can omit a newly created FreeText's /NM. Check for a
                // complete native result even before deciding whether a retained
                // unfinished editor can safely be recreated.
                let matches = page.annotations.filter {
                    matchesNewNoteSemantics($0, record: record, document: document, page: page)
                }
                if !matches.isEmpty {
                    guard record.pendingSave, record.baselineSemanticMatchCount == 0, matches.count == 1,
                          let applied = matches.first, applied.value(forAnnotationKey: .name) == nil else {
                        throw RecoveryError.identityChanged
                    }
                    validatedUndoDocument = document; validatedUndoAnnotation = applied; validatedUndoDraftID = record.draftID
                    finishAppliedRecord(in: document, store: store, record: record); return nil
                }
                // The write-ahead Save intent can outlive a rejected Store
                // mutation. Only an empty known baseline and no plausible
                // native result anywhere in this document permit explicit editing
                // of that uncommitted note. An old unsubmitted sidecar remains
                // compatible only under the same conservative absence check.
                let legacyUnsubmitted = record.baselineSemanticMatchCount == nil && !record.pendingSave
                guard !hasNewNoteCollision(record, in: document, allowingRecordedBaseline: true),
                      record.baselineSemanticMatchCount == 0 || legacyUnsubmitted else {
                    throw RecoveryError.identityChanged
                }
                guard let prepared = store.newFreeTextDraft(page: page, bounds: record.originalBounds) else {
                    throw RecoveryError.identityChanged
                }
                if let name = record.annotationName { _ = prepared.annotation.setValue(name, forAnnotationKey: .name) }
                draft = FreeTextEditDraft(document: document, page: page, annotation: prepared.annotation, isNew: true, id: record.draftID)
            } else {
                if record.pendingSave {
                    let applied = page.annotations.filter { matchesFinalValues($0, record: record, document: document, page: page) }
                    if applied.count == 1 {
                        validatedUndoDocument = document; validatedUndoAnnotation = applied.first; validatedUndoDraftID = record.draftID
                        finishAppliedRecord(in: document, store: store, record: record); return nil
                    }
                }
                let candidates = page.annotations.filter { annotation in
                    matchesBaseline(annotation, record: record, in: document)
                }
                guard candidates.count == 1, let annotation = candidates.first else { throw RecoveryError.identityChanged }
                if record.pendingUndo {
                    finishAppliedRecord(in: document, store: store, record: record); return nil
                }
                draft = FreeTextEditDraft(document: document, page: page, annotation: annotation, id: record.draftID)
            }
            let result = IPadInlineNoteEditingSession(draft: draft)
            result.values = record.values.editValues
            lastError = nil
            return result
        } catch { report(error.localizedDescription); return nil }
    }

    @discardableResult
    private func checkpoint(_ session: IPadInlineNoteEditingSession, values: FreeTextEditValues,
                            pendingSave: Bool = false) -> Bool {
        guard let fileID, let document = store?.document, document === session.draft.document,
              session.draft.page.document === document,
              !session.draft.isNew || session.draft.annotation.page == nil else { return false }
        // The publisher provides the new values before its property is set.
        guard pendingSave || values != session.draft.values || record != nil else { return true }
        let pageIndex = document.index(for: session.draft.page)
        guard pageIndex != NSNotFound else {
            session.error = RecoveryError.identityChanged.localizedDescription
            report(RecoveryError.identityChanged.localizedDescription); return false
        }
        if session.draft.isNew, session.draft.annotation.value(forAnnotationKey: .name) == nil {
            _ = session.draft.annotation.setValue("Dogear.NoteDraft.\(session.id.uuidString)", forAnnotationKey: .name)
        }
        do {
            if record == nil { try loadRecord(for: fileID) }
            if let record, !record.completed, record.draftID != session.id { throw RecoveryError.occupied }
            let previous = record?.draftID == session.id ? record : nil
            if let previous, pendingSave, !sourceStillMatches(previous) { throw RecoveryError.identityChanged }
            var baseline = Values(session.draft.values)
            baseline.fontColor = session.draft.originalFontColor
            baseline.fontName = session.draft.originalFontName
            var next = Record(draftID: session.id, fileID: fileID, pageIndex: pageIndex, pageText: session.draft.page.string,
                sourceDigest: previous?.sourceDigest ?? (try? originalDigest()),
                pageDigest: previous?.pageDigest ?? (try? pageFingerprint(session.draft.page)),
                pageBounds: session.draft.page.bounds(for: .cropBox), rotation: session.draft.page.rotation,
                isNew: session.draft.isNew, annotationName: session.draft.annotation.value(forAnnotationKey: .name) as? String,
                originalBounds: session.draft.originalBounds, baseline: baseline, values: Values(values), pendingSave: pendingSave)
            if session.draft.isNew {
                next.baselineSemanticMatchCount = session.draft.page.annotations.filter {
                    matchesNewNoteSemantics($0, record: next, document: document, page: session.draft.page)
                }.count
                let finalBounds = FreeTextAnnotationEditing.resolvedBounds(values,
                    originalBounds: next.originalBounds, pageBounds: next.pageBounds)
                var baselines: [CollisionBaseline] = []
                for index in 0..<document.pageCount {
                    for annotation in document.page(at: index)?.annotations ?? []
                        where annotation.contents != values.text && annotation.bounds == finalBounds {
                        if let baseline = collisionBaseline(annotation, pageIndex: index) { baselines.append(baseline) }
                    }
                }
                next.collisionBaselines = baselines
            }
            let previousStorageError = lastError
            try write(next); record = next; lastError = nil
            if let previousStorageError, session.error == previousStorageError { session.error = nil }
            return true
        }
        catch { session.error = error.localizedDescription; report(error.localizedDescription); return false }
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

    /// Explicit selection is byte-bound; selecting never discards competing text.
    func selectCandidate(_ candidate: AnnotationDraftCandidate) -> Bool {
        guard session == nil, candidate.fileID == fileID,
              candidates.contains(where: { $0.id == candidate.id }), AnnotationDraftFiles.unchanged(candidate) else {
            report(L10n.string("The note draft changed. Retry recovery before choosing it.")); return false
        }
        recordURL = candidate.url
        record = try? JSONDecoder().decode(Record.self, from: Data(contentsOf: candidate.url))
        candidates = []
        if record == nil { report(RecoveryError.malformed.localizedDescription); return false }
        lastError = nil; return true
    }

    private func write(_ record: Record) throws {
        let url = recordURL ?? defaultURL
        try AnnotationDraftFiles.write(record, to: url)
        recordURL = url
    }

    private func originalDigest() throws -> String {
        guard let url = store?.selectedPDFURL else { throw RecoveryError.identityChanged }
        let access = ScopedLibraryFileAccess(url: url)
        return try withExtendedLifetime(access) {
            SHA256.hash(data: try Data(contentsOf: url, options: .mappedIfSafe)).map { String(format: "%02x", $0) }.joined()
        }
    }

    private func sourceStillMatches(_ record: Record) -> Bool {
        // Original access can be unavailable while the shared Store legitimately
        // edits an existing working copy. Preserve/restore its draft using the
        // exact native page-content and annotation baseline, without requiring
        // that unavailable source. A known changed original is still rejected.
        guard let expected = record.sourceDigest, let current = try? originalDigest() else { return true }
        return expected == current
    }

    private func finishAppliedRecord(in document: PDFDocument, store: PDFDocumentStore, record: Record) {
        guard !store.hasUnsavedChanges, store.workingCopySaveError == nil else {
            // A retained dirty native document is evidence of an accepted edit,
            // not a successful disk write. Its current owner receives shared
            // coordinator save-state publication even across A → B → A.
            awaitingSavedDocument = document; awaitingSavedDraftID = record.draftID
            return
        }
        _ = finishRecord()
    }

    private func matchesOriginalAnnotation(_ record: Record, in document: PDFDocument) -> Bool {
        // Page arrangement can move the accepted annotation away from its
        // original index. Its absence there does not mean Undo removed it.
        if record.isNew {
            if validatedUndoDocument === document, validatedUndoDraftID == record.draftID,
               let annotation = validatedUndoAnnotation {
                // Current-owner Undo knows the exact accepted native object.
                // An unrelated older note sharing its bounds is not that object.
                guard annotation.page == nil else { return false }
                return !(0..<document.pageCount).contains { index in
                    document.page(at: index)?.annotations.contains { $0 === annotation } == true
                }
            }
            guard record.annotationName != nil,
                  record.baselineSemanticMatchCount == 0 else { return false }
            // A page move cannot turn a still-present unnamed note into Undo
            // evidence. Changed styling cannot establish absence either.
            return !hasNewNoteCollision(record, in: document)
        }
        // Older standard FreeText may have no /NM. A similar annotation on a
        // different page cannot prove this accepted edit was undone.
        guard let annotation = validatedUndoAnnotation else { return false }
        return matchesBaseline(annotation, record: record, in: document)
    }

    private func hasNewNoteCollision(_ record: Record, in document: PDFDocument,
                                     allowingRecordedBaseline: Bool = false) -> Bool {
        let finalBounds = FreeTextAnnotationEditing.resolvedBounds(record.values.editValues,
            originalBounds: record.originalBounds, pageBounds: record.pageBounds)
        let baselines = allowingRecordedBaseline ? record.collisionBaselines ?? [] : []
        var candidates: [CollisionBaseline] = []
        for index in 0..<document.pageCount {
            guard let page = document.page(at: index) else { continue }
            for annotation in page.annotations {
                if let name = record.annotationName,
                   (annotation.value(forAnnotationKey: .name) as? String) == name { return true }
                guard annotation.type == "FreeText",
                      annotation.contents == record.values.text || annotation.bounds == finalBounds else { continue }
                // Same text, a complete final result, and the draft's exact name
                // can never be dismissed as an unrelated baseline annotation.
                guard annotation.contents != record.values.text,
                      !matchesNewNoteSemantics(annotation, record: record, document: document, page: page),
                      let baseline = collisionBaseline(annotation, pageIndex: index) else { return true }
                candidates.append(baseline)
            }
        }
        // Reassign only existing complete compatibility edges, consuming each
        // recorded note once. Greedy name/date loss matching is order-dependent.
        var matchedCandidates = [Int?](repeating: nil, count: baselines.count)
        func assign(_ candidate: Int, visited: inout Set<Int>) -> Bool {
            for index in baselines.indices where collisionBaselineMatches(candidates[candidate], recorded: baselines[index]) {
                guard visited.insert(index).inserted else { continue }
                if let previous = matchedCandidates[index], !assign(previous, visited: &visited) { continue }
                matchedCandidates[index] = candidate
                return true
            }
            return false
        }
        for candidate in candidates.indices {
            var visited = Set<Int>()
            guard assign(candidate, visited: &visited) else { return true }
        }
        return false
    }

    private func collisionBaselineMatches(_ current: CollisionBaseline, recorded: CollisionBaseline) -> Bool {
        // PDFKit's observed serialization loss can remove a known /NM. It
        // cannot authorize a new or different nonnil name on a baseline note.
        guard current.annotationName == recorded.annotationName
                || (recorded.annotationName != nil && current.annotationName == nil) else { return false }
        if current.modificationDate != recorded.modificationDate {
            // PDFKit's observed /M serialization drops fractional seconds.
            // Only that directed loss is evidence of an unchanged timestamp.
            guard let recordedDate = recorded.modificationDate, let currentDate = current.modificationDate else { return false }
            let recordedSeconds = recordedDate.timeIntervalSince1970
            let currentSeconds = currentDate.timeIntervalSince1970
            guard recordedSeconds.isFinite, currentSeconds.isFinite,
                  recordedSeconds != floor(recordedSeconds),
                  currentSeconds == floor(recordedSeconds) else { return false }
        }
        var compared = current
        compared.annotationName = recorded.annotationName
        compared.modificationDate = recorded.modificationDate
        return compared == recorded
    }

    private func collisionBaseline(_ annotation: PDFAnnotation, pageIndex: Int) -> CollisionBaseline? {
        guard annotation.type == "FreeText", matchesFactoryStyle(annotation),
              let font = annotation.font, font.pointSize.isFinite, font.pointSize > 0,
              let fontColor = FreeTextAnnotationEditing.textColorComponents(of: annotation.fontColor ?? .black),
              [fontColor.red, fontColor.green, fontColor.blue, fontColor.alpha].allSatisfy(\.isFinite) else { return nil }
        let rawColorPresent = annotation.value(forAnnotationKey: .color) != nil
        let nativeColor: PDFPlatformColor? = annotation.color
        let annotationColor: PDFColorComponents?
        if let nativeColor {
            guard let components = FreeTextAnnotationEditing.textColorComponents(of: nativeColor),
                  [components.red, components.green, components.blue, components.alpha].allSatisfy(\.isFinite) else { return nil }
            annotationColor = components
        } else {
            // A present but unreadable /C is unknown, not an absent color.
            guard !rawColorPresent else { return nil }
            annotationColor = nil
        }
        let rawName = annotation.value(forAnnotationKey: .name)
        guard rawName == nil || rawName is String else { return nil }
        return CollisionBaseline(pageIndex: pageIndex, bounds: annotation.bounds, text: annotation.contents,
            fontName: font.fontName, fontSize: Double(font.pointSize), fontColor: fontColor,
            annotationColor: annotationColor, rawColorPresent: rawColorPresent,
            annotationName: rawName as? String, modificationDate: annotation.modificationDate)
    }

    private func matchesBaseline(_ annotation: PDFAnnotation, record: Record, in document: PDFDocument) -> Bool {
        guard let page = annotation.page, page.document === document else { return false }
        let current = FreeTextEditDraft(document: document, page: page, annotation: annotation)
        let currentValues = Values(current.values)
        // Legacy sidecars did not record a color; their nil baseline is unknown.
        let colorMatches = matchesRecordedColor(record.baseline.fontColor, annotation: annotation)
        return annotation.type == "FreeText" && annotation.bounds == record.originalBounds
            && currentValues.text == record.baseline.text && currentValues.width == record.baseline.width
            && currentValues.height == record.baseline.height && currentValues.fontSize == record.baseline.fontSize
            && (record.baseline.fontName == nil || current.originalFontName == record.baseline.fontName)
            && colorMatches
            && (record.annotationName == nil || (annotation.value(forAnnotationKey: .name) as? String) == record.annotationName)
    }

    private func matchesFinalValues(_ annotation: PDFAnnotation, record: Record, document: PDFDocument, page: PDFPage,
                                    ignoringName: Bool = false) -> Bool {
        return annotation.type == "FreeText" && annotation.contents == record.values.text
            && annotation.bounds == FreeTextAnnotationEditing.resolvedBounds(record.values.editValues,
                originalBounds: record.originalBounds, pageBounds: record.pageBounds)
            && annotation.font?.pointSize == CGFloat(record.values.fontSize)
            && matchesFinalFont(record, annotation: annotation)
            && (record.values.fontColor.map { FreeTextAnnotationEditing.matchesTextColor($0, annotation: annotation) }
                ?? matchesRecordedColor(record.baseline.fontColor, annotation: annotation))
            && (ignoringName || record.annotationName == nil || (annotation.value(forAnnotationKey: .name) as? String) == record.annotationName)
    }

    private func matchesNewNoteSemantics(_ annotation: PDFAnnotation, record: Record,
                                         document: PDFDocument, page: PDFPage) -> Bool {
        // These are the native Factory's fixed defaults, beyond editable values.
        // shouldDisplay is reader-only; PDFKit generates AP and Save timestamps.
        matchesFinalValues(annotation, record: record, document: document, page: page, ignoringName: true)
            && matchesFactoryStyle(annotation)
    }

    private func matchesFactoryStyle(_ annotation: PDFAnnotation) -> Bool {
        annotation.alignment == .left && (annotation.userName ?? "").isEmpty && annotation.shouldPrint
            && (annotation.border?.lineWidth ?? 0) == 0 && (annotation.border?.style ?? .solid) == .solid
            && (annotation.border?.dashPattern?.isEmpty ?? true) && annotation.interiorColor == nil
            && annotation.value(forAnnotationKey: FreeTextAnnotationEditing.richTextKey) == nil
            && annotation.value(forAnnotationKey: PDFAnnotationKey(rawValue: "/Subj")) == nil
            && annotation.popup == nil && annotation.action == nil
            && annotation.value(forAnnotationKey: PDFAnnotationKey(rawValue: "/URI")) == nil
            && annotation.value(forAnnotationKey: PDFAnnotationKey(rawValue: "/A")) == nil
    }

    private func matchesFinalFont(_ record: Record, annotation: PDFAnnotation) -> Bool {
        if record.values.fontName != nil {
            guard let expected = FreeTextAnnotationEditing.explicitFont(record.values.editValues) else { return false }
            return annotation.font?.fontName == expected.fontName
        }
        // New sidecars know the original face; absent legacy fields are unknown.
        return record.baseline.fontName == nil || annotation.font?.fontName == record.baseline.fontName
    }

    private func matchesRecordedColor(_ expected: PDFColorComponents?, annotation: PDFAnnotation) -> Bool {
        guard let expected else { return true }
        guard let actual = FreeTextAnnotationEditing.textColorComponents(of: annotation.fontColor ?? .black) else { return false }
        return zip([actual.red, actual.green, actual.blue, actual.alpha],
            [expected.red, expected.green, expected.blue, expected.alpha])
            .allSatisfy { pair in abs(pair.0 - pair.1) < 0.00001 }
    }

    private func pageFingerprint(_ page: PDFPage) throws -> String {
        // Render the native PDF page's content, excluding interactive standard
        // annotations. Textless scanned pages must not share an empty baseline.
        guard let reference = page.pageRef else { throw RecoveryError.identityChanged }
        let crop = page.bounds(for: .cropBox)
        guard !crop.isEmpty else { throw RecoveryError.identityChanged }
        let scale = 256 / max(crop.width, crop.height)
        let width = max(1, Int((crop.width * scale).rounded()))
        let height = max(1, Int((crop.height * scale).rounded()))
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue), let bytes = context.data else {
            throw RecoveryError.identityChanged
        }
        let rect = CGRect(x: 0, y: 0, width: width, height: height)
        context.setFillColor(gray: 1, alpha: 1); context.fill(rect)
        context.concatenate(reference.getDrawingTransform(.cropBox, rect: rect, rotate: 0, preserveAspectRatio: true))
        context.drawPDFPage(reference)
        return SHA256.hash(data: Data(bytes: bytes, count: width * height * 4)).map { String(format: "%02x", $0) }.joined()
    }

    @discardableResult
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
              (recordURL ?? defaultURL) == permit.url,
              let data = try? Data(contentsOf: permit.url), SHA256.hash(data: data) == permit.digest else {
            report(L10n.string("The note draft changed. Open its discard confirmation again.")); return false
        }
        if record != nil { return finishRecord() }
        do {
            try FileManager.default.removeItem(at: permit.url)
            recordURL = nil; candidates = []; lastError = nil
            revealRemainingRecordIfIdle()
            return true
        } catch { report(error.localizedDescription); return false }
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
                // A completed Save may finish after its editor was released.
                // Other drafts stay recoverable without changing A's success.
                revealRemainingRecordIfIdle()
            }
            return true
        } catch { report(error.localizedDescription); return false }
    }

    private func report(_ message: String) {
        let localized = L10n.string(.init(stringLiteral: message))
        lastError = localized
        feedback.post(localized, kind: .error)
    }
}
#endif
