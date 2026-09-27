import Combine
import Foundation

nonisolated enum ResearchStoreError: LocalizedError {
    case storageUnavailable, missingRecord, requestAlreadyRunning, staleNoteRevision
    case invalidAttachment, missingAttachment, exportDestinationExists, incompleteAttachmentInventory

    var errorDescription: String? {
        switch self {
        case .storageUnavailable: return "Research storage is unavailable. Your unsaved content remains in memory."
        case .missingRecord: return "The research item could not be found."
        case .requestAlreadyRunning: return "This session already has an active request."
        case .staleNoteRevision: return "The note changed after this suggestion was created. Review it against the latest note."
        case .invalidAttachment: return "The image type or size is not supported."
        case .missingAttachment: return "A research attachment is missing."
        case .exportDestinationExists: return "Choose a new export folder to preserve existing files."
        case .incompleteAttachmentInventory: return "Attachment cleanup is unavailable until all research records can be read and saved."
        }
    }
}

/// Application-owned user content. A reader window only holds a session/note ID.
@MainActor
final class ResearchStore: ObservableObject {
    static let shared = ResearchStore()

    @Published private(set) var sessions: [ResearchSession] = []
    @Published private(set) var notes: [ResearchNote] = []
    @Published private(set) var attachments: [ResearchAttachment] = []
    @Published private(set) var saveFailures: [String: String] = [:]
    @Published private(set) var loadWarnings: [String] = []

    let rootURL: URL?
    private let fileManager: FileManager
    private let atomicWriter: (Data, URL) throws -> Void
    private var noteEditorOwners: [UUID: UUID] = [:]
    private enum NoteEditField { case title, body }
    private struct NoteEditBurst {
        var field: NoteEditField
        var startedAt: Date
        var lastEditAt: Date
        var lastRevision: Int
    }
    private var noteEditBursts: [UUID: NoteEditBurst] = [:]
    private let noteEditClock: () -> Date
    private static let noteEditIdleInterval: TimeInterval = 2
    private static let maximumNoteEditBurstDuration: TimeInterval = 30

    init(
        rootURL: URL? = nil,
        fileManager: FileManager = .default,
        atomicWriter: ((Data, URL) throws -> Void)? = nil,
        noteEditClock: @escaping () -> Date = Date.init
    ) {
        self.fileManager = fileManager
        self.noteEditClock = noteEditClock
        self.atomicWriter = atomicWriter ?? { data, url in try data.write(to: url, options: .atomic) }
        self.rootURL = rootURL ?? fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first?.appendingPathComponent("PDFWorkBench", isDirectory: true)
            .appendingPathComponent("Research-v1", isDirectory: true)
        load()
    }

    func session(id: UUID) -> ResearchSession? { sessions.first { $0.id == id } }
    func note(id: UUID) -> ResearchNote? { notes.first { $0.id == id } }

    @discardableResult
    func createSession(title: String, sourceSelection: ResearchSourceSelection = ResearchSourceSelection()) -> UUID {
        let session = ResearchSession(title: title, sourceSelection: sourceSelection)
        updateSession(session)
        return session.id
    }

    @discardableResult
    func updateSession(_ session: ResearchSession) -> Bool {
        var value = session
        value.updatedAt = Date()
        replace(value, in: &sessions)
        return persist(value, category: "sessions", id: value.id)
    }

    @discardableResult
    func saveDraft(_ draft: ResearchDraft, sessionID: UUID) -> Bool {
        guard var session = session(id: sessionID) else { return false }
        session.draft = draft
        return updateSession(session)
    }

    /// A nil result forbids starting the provider: the pending request could not be made durable.
    @discardableResult
    func beginRequest(
        sessionID: UUID,
        question: String,
        sourceSnapshot: [ResearchSourceSnapshot],
        input: ResearchDraft? = nil,
        contextSummary: ResearchContextSummary? = nil
    ) -> UUID? {
        guard var session = session(id: sessionID), session.activeRequestID == nil else { return nil }
        let message = ResearchMessage(question: question, input: input ?? session.draft,
            sourceSnapshot: sourceSnapshot, contextSummary: contextSummary)
        session.messages.append(message)
        guard updateSession(session) else {
            // Retain the failed attempt and draft, but never leave a phantom active request.
            if let index = sessions.firstIndex(where: { $0.id == sessionID }),
               let messageIndex = sessions[index].messages.firstIndex(where: { $0.requestID == message.requestID }) {
                sessions[index].messages[messageIndex].status = .failed
                sessions[index].messages[messageIndex].errorMessage = ResearchStoreError.storageUnavailable.localizedDescription
                sessions[index].messages[messageIndex].completedAt = Date()
            }
            return nil
        }
        return message.requestID
    }

    /// Request identity and running status reject late completion after cancellation/deletion.
    @discardableResult
    func finishRequest(
        sessionID: UUID,
        requestID: UUID,
        answer: String? = nil,
        evidence: [ResearchEvidence] = [],
        status: ResearchRequestStatus,
        errorMessage: String? = nil,
        origin: ResearchContentOrigin = .verifiedAI,
        operationResults: [String] = [],
        contextSummary: ResearchContextSummary? = nil
    ) -> Bool {
        guard status != .running, var session = session(id: sessionID),
              let index = session.messages.firstIndex(where: { $0.requestID == requestID && $0.status == .running }) else {
            return false
        }
        let sentDraft = session.messages[index].input
        session.messages[index].answer = answer
        session.messages[index].evidence = evidence
        session.messages[index].status = status
        session.messages[index].errorMessage = errorMessage
        session.messages[index].origin = origin
        session.messages[index].operationResults = operationResults
        if let contextSummary { session.messages[index].contextSummary = contextSummary }
        session.messages[index].completedAt = Date()
        if status == .accepted && session.draft == sentDraft { session.draft = ResearchDraft() }
        return updateSession(session)
    }

    func interruptActiveRequests() {
        for session in sessions where session.activeRequestID != nil {
            for message in session.messages where message.status == .running {
                finishRequest(sessionID: session.id, requestID: message.requestID, status: .interrupted, origin: .user)
            }
        }
    }

    @discardableResult
    func createNote(
        title: String,
        body: String,
        provenance: [ResearchNoteProvenance] = [],
        attachmentIDs: Set<UUID> = []
    ) -> UUID {
        let note = ResearchNote(title: title, body: body, provenance: provenance, attachmentIDs: attachmentIDs)
        replace(note, in: &notes)
        _ = persist(note, category: "notes", id: note.id)
        return note.id
    }

    /// Every content edit advances its version and is saved immediately. Native
    /// typing can opt into a bounded history burst; explicit changes and source
    /// changes always preserve their own prior snapshot. Coalescing affects only
    /// history size, never autosave, suggestion staleness or the editor's Undo.
    @discardableResult
    func updateNote(_ note: ResearchNote, coalescingEdits: Bool = false) -> Bool {
        var value = note
        if let previous = self.note(id: note.id) {
            guard previous.revision == value.revision else { return false }
            let bodyChanged = previous.body != value.body
            let titleChanged = previous.title != value.title
            let sourcesChanged = previous.provenance != value.provenance || previous.attachmentIDs != value.attachmentIDs
            if !coalescingEdits || sourcesChanged || previous.suggestions != value.suggestions {
                endNoteEditBurst(noteID: note.id)
            }
            if bodyChanged || titleChanged || sourcesChanged {
                let field: NoteEditField? = bodyChanged != titleChanged ? (bodyChanged ? .body : .title) : nil
                let now = noteEditClock()
                let existing = noteEditBursts[note.id]
                let canCoalesce: Bool
                if coalescingEdits, !sourcesChanged, let field, let existing {
                    let idle = now.timeIntervalSince(existing.lastEditAt)
                    let duration = now.timeIntervalSince(existing.startedAt)
                    canCoalesce = existing.field == field && existing.lastRevision == previous.revision
                        && idle >= 0 && idle <= Self.noteEditIdleInterval
                        && duration >= 0 && duration <= Self.maximumNoteEditBurstDuration
                } else { canCoalesce = false }
                value.revisions = canCoalesce ? previous.revisions : previous.revisions + [revision(of: previous)]
                value.revision = previous.revision + 1
                value.verificationInvalidated = true
                if coalescingEdits, !sourcesChanged, let field {
                    noteEditBursts[note.id] = NoteEditBurst(field: field,
                        startedAt: canCoalesce ? (existing?.startedAt ?? now) : now,
                        lastEditAt: now, lastRevision: value.revision)
                } else { endNoteEditBurst(noteID: note.id) }
            }
        } else { endNoteEditBurst(noteID: note.id) }
        value.updatedAt = Date()
        replace(value, in: &notes)
        return persist(value, category: "notes", id: value.id)
    }

    /// Use for native Undo/Redo, explicit restore and editor/focus boundaries.
    func endNoteEditBurst(noteID: UUID) { noteEditBursts[noteID] = nil }

    @discardableResult
    func addSuggestion(_ suggestion: ResearchNoteSuggestion, noteID: UUID) -> Bool {
        guard var note = note(id: noteID), suggestion.baseRevision == note.revision else { return false }
        note.suggestions.append(suggestion)
        return updateNote(note)
    }

    /// Call only after the user explicitly applies the visible suggestion.
    func applySuggestion(id: UUID, noteID: UUID) throws {
        guard var note = note(id: noteID), let suggestion = note.suggestions.first(where: { $0.id == id }) else {
            throw ResearchStoreError.missingRecord
        }
        guard suggestion.baseRevision == note.revision else { throw ResearchStoreError.staleNoteRevision }
        note.body = suggestion.body
        note.provenance.append(contentsOf: suggestion.provenance)
        note.attachmentIDs.formUnion(suggestion.attachmentIDs)
        note.suggestions.removeAll { $0.id == id }
        guard updateNote(note) else { throw ResearchStoreError.storageUnavailable }
    }

    /// Returns an existing editor owner so callers can focus it instead of creating a competing editor.
    func claimNoteEditor(noteID: UUID, editorID: UUID) -> UUID {
        if let existing = noteEditorOwners[noteID] { return existing }
        noteEditorOwners[noteID] = editorID
        return editorID
    }

    func releaseNoteEditor(noteID: UUID, editorID: UUID) {
        if noteEditorOwners[noteID] == editorID {
            noteEditorOwners[noteID] = nil
            endNoteEditBurst(noteID: noteID)
        }
    }

    /// Deletion is explicit and affects only this record. Notes, PDFs and attachments never cascade.
    @discardableResult
    func deleteSession(id: UUID) -> Bool {
        guard removeRecord(category: "sessions", id: id) else { return false }
        sessions.removeAll { $0.id == id }
        return true
    }

    @discardableResult
    func deleteNote(id: UUID) -> Bool {
        guard removeRecord(category: "notes", id: id) else { return false }
        notes.removeAll { $0.id == id }
        noteEditorOwners[id] = nil
        endNoteEditBurst(noteID: id)
        return true
    }

    func retryFailedSaves() {
        let keys = Set(saveFailures.keys)
        for session in sessions where keys.contains(recordKey(category: "sessions", id: session.id)) {
            _ = persist(session, category: "sessions", id: session.id)
        }
        for note in notes where keys.contains(recordKey(category: "notes", id: note.id)) {
            _ = persist(note, category: "notes", id: note.id)
        }
    }

    /// Stores already processed image bytes. Import never mutates the external source file.
    func importAttachment(
        data: Data,
        displayName: String,
        mimeType: String,
        fileExtension: String,
        pixelWidth: Int? = nil,
        pixelHeight: Int? = nil
    ) throws -> ResearchAttachment {
        let ext = fileExtension.lowercased()
        let types = ["png": "image/png", "jpg": "image/jpeg", "jpeg": "image/jpeg", "webp": "image/webp", "gif": "image/gif"]
        guard types[ext] == mimeType, !data.isEmpty,
              data.count <= ResearchInputLimits.maximumProcessedImageBytes else { throw ResearchStoreError.invalidAttachment }
        let attachment = ResearchAttachment(displayName: displayName, mimeType: mimeType, fileExtension: ext,
                                            byteCount: data.count, pixelWidth: pixelWidth, pixelHeight: pixelHeight)
        let directory = try directoryURL("attachments")
        try prepareDirectory(directory)
        let dataURL = directory.appendingPathComponent(attachment.filename)
        try writePrivate(data, to: dataURL)
        do {
            try writePrivate(Self.encoder.encode(attachment), to: directory.appendingPathComponent("\(attachment.id.uuidString).json"))
        } catch {
            try? fileManager.removeItem(at: dataURL)
            throw error
        }
        attachments.append(attachment)
        return attachment
    }

    func attachmentURL(id: UUID) -> URL? {
        guard let attachment = attachments.first(where: { $0.id == id }),
              let rootURL, Self.isValid(attachment) else { return nil }
        let url = rootURL.appendingPathComponent("attachments", isDirectory: true).appendingPathComponent(attachment.filename)
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        return url
    }

    /// Counts references from current and historical user content; no age-based automatic deletion.
    func attachmentReferenceCounts() -> [UUID: Int] {
        var counts: [UUID: Int] = [:]
        for session in sessions { for id in session.attachmentIDs { counts[id, default: 0] += 1 } }
        for note in notes { for id in note.allAttachmentIDs { counts[id, default: 0] += 1 } }
        return counts
    }

    /// User-invoked capacity management only. Any unreadable record blocks cleanup conservatively.
    func removeUnreferencedAttachments() throws -> Int {
        guard loadWarnings.isEmpty && saveFailures.isEmpty else { throw ResearchStoreError.incompleteAttachmentInventory }
        let counts = attachmentReferenceCounts()
        var removed = 0
        for attachment in attachments where counts[attachment.id, default: 0] == 0 {
            if let url = attachmentURL(id: attachment.id) { try fileManager.removeItem(at: url) }
            let metadata = try directoryURL("attachments").appendingPathComponent("\(attachment.id.uuidString).json")
            if fileManager.fileExists(atPath: metadata.path) { try fileManager.removeItem(at: metadata) }
            attachments.removeAll { $0.id == attachment.id }
            removed += 1
        }
        return removed
    }

    func sessionMarkdown(id: UUID) throws -> String {
        guard let session = session(id: id) else { throw ResearchStoreError.missingRecord }
        var parts = ["# \(session.title)"]
        for message in session.messages {
            parts.append("## \(message.question.isEmpty ? "Overview" : message.question)")
            parts.append("Status: \(message.status.rawValue)")
            if let answer = message.answer { parts.append(answer) }
            if let error = message.errorMessage { parts.append(error) }
            parts.append(contentsOf: message.operationResults)
            parts.append(contentsOf: message.evidence.map(Self.evidenceMarkdown))
            for block in message.input.blocks {
                if !block.text.isEmpty { parts.append("> \(block.text.replacingOccurrences(of: "\n", with: "\n> "))") }
                if !block.explanation.isEmpty { parts.append(block.explanation) }
                if let evidence = block.evidence { parts.append(Self.evidenceMarkdown(evidence)) }
            }
            parts.append(contentsOf: attachmentMarkdown(ids: message.input.attachmentIDs.union(message.evidence.compactMap(\.attachmentID))))
        }
        if !session.draft.isEmpty {
            parts.append("## Unsent draft\n\n\(session.draft.text)")
            for block in session.draft.blocks {
                if !block.text.isEmpty { parts.append(block.text) }
                if !block.explanation.isEmpty { parts.append(block.explanation) }
                if let evidence = block.evidence { parts.append(Self.evidenceMarkdown(evidence)) }
            }
            parts.append(contentsOf: attachmentMarkdown(ids: session.draft.attachmentIDs))
        }
        return parts.filter { !$0.isEmpty }.joined(separator: "\n\n") + "\n"
    }

    func noteMarkdown(id: UUID) throws -> String {
        guard let note = note(id: id) else { throw ResearchStoreError.missingRecord }
        var parts = ["# \(note.title)", note.body]
        let evidence = note.provenance.flatMap(\.evidence)
        if !evidence.isEmpty {
            parts.append("## Sources")
            parts.append(contentsOf: evidence.map(Self.evidenceMarkdown))
        }
        parts.append(contentsOf: attachmentMarkdown(ids: note.attachmentIDs.union(evidence.compactMap(\.attachmentID))))
        return parts.joined(separator: "\n\n") + "\n"
    }

    /// Exports a new, visible folder containing research.md and a relative attachments directory.
    func exportSession(id: UUID, to directory: URL) throws {
        guard let session = session(id: id) else { throw ResearchStoreError.missingRecord }
        try export(markdown: sessionMarkdown(id: id), attachmentIDs: session.attachmentIDs, to: directory)
    }

    func exportNote(id: UUID, to directory: URL) throws {
        guard let note = note(id: id) else { throw ResearchStoreError.missingRecord }
        var ids = note.attachmentIDs
        ids.formUnion(note.provenance.flatMap { $0.evidence.compactMap(\.attachmentID) })
        try export(markdown: noteMarkdown(id: id), attachmentIDs: ids, to: directory)
    }

    private func export(markdown: String, attachmentIDs: Set<UUID>, to directory: URL) throws {
        let scoped = directory.startAccessingSecurityScopedResource()
        defer { if scoped { directory.stopAccessingSecurityScopedResource() } }
        guard !fileManager.fileExists(atPath: directory.path) else { throw ResearchStoreError.exportDestinationExists }
        let sources = try attachmentIDs.sorted { $0.uuidString < $1.uuidString }.map { id -> URL in
            guard let source = attachmentURL(id: id) else { throw ResearchStoreError.missingAttachment }
            return source
        }
        // NSSavePanel grants the chosen destination, not arbitrary siblings in
        // its parent. Foundation supplies writable staging on the target volume.
        // Use the existing parent to select that volume: passing a nonexistent
        // destination can make Foundation create a placeholder at that path.
        let replacementDirectory = try fileManager.url(for: .itemReplacementDirectory, in: .userDomainMask,
            appropriateFor: directory.deletingLastPathComponent(), create: true)
        defer { try? fileManager.removeItem(at: replacementDirectory) }
        let staging = replacementDirectory.appendingPathComponent("export", isDirectory: true)
        try fileManager.createDirectory(at: staging, withIntermediateDirectories: false)
        try Data(markdown.utf8).write(to: staging.appendingPathComponent("research.md"), options: .atomic)
        if !sources.isEmpty {
            let attachmentDirectory = staging.appendingPathComponent("attachments", isDirectory: true)
            try fileManager.createDirectory(at: attachmentDirectory, withIntermediateDirectories: false)
            for source in sources { try fileManager.copyItem(at: source, to: attachmentDirectory.appendingPathComponent(source.lastPathComponent)) }
        }
        try fileManager.moveItem(at: staging, to: directory)
    }

    private func attachmentMarkdown(ids: Set<UUID>) -> [String] {
        ids.sorted { $0.uuidString < $1.uuidString }.compactMap { id in
            guard let attachment = attachments.first(where: { $0.id == id }) else { return "Missing attachment: \(id)" }
            return "![\(attachment.displayName.replacingOccurrences(of: "]", with: "\\]"))](attachments/\(attachment.filename))"
        }
    }

    private static func evidenceMarkdown(_ evidence: ResearchEvidence) -> String {
        let name = evidence.source?.displayName ?? evidence.kind.rawValue
        let page = evidence.anchor.map { ", page \($0.pageIndex + 1)" } ?? ""
        let identity = evidence.source.map { " (file \($0.fileID.uuidString), version \($0.fingerprint))" } ?? ""
        return "Source: \(name)\(page)\(identity)\n\n> \(evidence.excerpt.replacingOccurrences(of: "\n", with: "\n> "))"
    }

    private func load() {
        guard rootURL != nil else { loadWarnings.append(ResearchStoreError.storageUnavailable.localizedDescription); return }
        sessions = loadRecords(ResearchSession.self, category: "sessions") { $0.schemaVersion == ResearchSession.currentSchemaVersion }
        notes = loadRecords(ResearchNote.self, category: "notes") { $0.schemaVersion == ResearchNote.currentSchemaVersion }
        attachments = loadRecords(ResearchAttachment.self, category: "attachments", validate: Self.isValid)
        sessions.sort { $0.updatedAt > $1.updatedAt }
        notes.sort { $0.updatedAt > $1.updatedAt }
        interruptActiveRequests()
    }

    private func loadRecords<T: Decodable & Identifiable>(
        _ type: T.Type, category: String, validate: (T) -> Bool
    ) -> [T] where T.ID == UUID {
        do {
            let directory = try directoryURL(category)
            guard fileManager.fileExists(atPath: directory.path) else { return [] }
            let files = try fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
                .filter { $0.pathExtension == "json" }
            var records: [T] = []
            for file in files {
                do {
                    let record = try Self.decoder.decode(T.self, from: Data(contentsOf: file))
                    guard validate(record), file.deletingPathExtension().lastPathComponent == record.id.uuidString else {
                        throw ResearchStoreError.storageUnavailable
                    }
                    records.append(record)
                } catch { loadWarnings.append("Could not restore \(category)/\(file.lastPathComponent): \(error.localizedDescription)") }
            }
            return records
        } catch {
            loadWarnings.append("Could not restore \(category): \(error.localizedDescription)")
            return []
        }
    }

    private static func isValid(_ attachment: ResearchAttachment) -> Bool {
        ["png", "jpg", "jpeg", "webp", "gif"].contains(attachment.fileExtension)
            && attachment.byteCount > 0 && attachment.byteCount <= ResearchInputLimits.maximumProcessedImageBytes
    }

    private func revision(of note: ResearchNote) -> ResearchNoteRevision {
        ResearchNoteRevision(number: note.revision, title: note.title, body: note.body,
                             provenance: note.provenance, attachmentIDs: note.attachmentIDs,
                             verificationInvalidated: note.verificationInvalidated)
    }

    private func replace<T: Identifiable>(_ value: T, in array: inout [T]) {
        if let index = array.firstIndex(where: { $0.id == value.id }) { array[index] = value }
        else { array.insert(value, at: 0) }
    }

    private func recordKey(category: String, id: UUID) -> String { "\(category)/\(id.uuidString)" }

    private func directoryURL(_ category: String) throws -> URL {
        guard let rootURL else { throw ResearchStoreError.storageUnavailable }
        return rootURL.appendingPathComponent(category, isDirectory: true)
    }

    private func prepareDirectory(_ directory: URL) throws {
        guard let rootURL else { throw ResearchStoreError.storageUnavailable }
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: rootURL.path)
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
    }

    private func writePrivate(_ data: Data, to url: URL) throws {
        try atomicWriter(data, url)
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    private func persist<T: Encodable>(_ record: T, category: String, id: UUID) -> Bool {
        let key = recordKey(category: category, id: id)
        do {
            let directory = try directoryURL(category)
            try prepareDirectory(directory)
            try writePrivate(Self.encoder.encode(record), to: directory.appendingPathComponent("\(id.uuidString).json"))
            saveFailures[key] = nil
            return true
        } catch { saveFailures[key] = error.localizedDescription; return false }
    }

    private func removeRecord(category: String, id: UUID) -> Bool {
        let key = recordKey(category: category, id: id)
        do {
            let url = try directoryURL(category).appendingPathComponent("\(id.uuidString).json")
            if fileManager.fileExists(atPath: url.path) { try fileManager.removeItem(at: url) }
            saveFailures[key] = nil
            return true
        } catch { saveFailures[key] = error.localizedDescription; return false }
    }

    private static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .millisecondsSince1970
        return encoder
    }

    private static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return decoder
    }
}
