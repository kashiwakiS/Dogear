import Foundation

/// Uses real durable ResearchStore records in a disposable root; no provider,
/// credential, PDF, or live Library access is involved.
@MainActor
enum ResearchNoteEvidenceContextDiagnostics {
    static func run() -> (checks: Int, failures: [String]) {
        var checks = 0
        var failures: [String] = []
        func check(_ value: Bool, _ message: String) {
            checks += 1
            if !value { failures.append(message) }
        }
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("DogearNoteEvidence-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ResearchStore(rootURL: root)
        let first = ResearchSourceSnapshot(fileID: UUID(), displayName: "same.pdf", fingerprint: "first-v1")
        let second = ResearchSourceSnapshot(fileID: UUID(), displayName: "same.pdf", fingerprint: "second-v7")
        let firstEvidence = ResearchEvidence(source: first, anchor: ResearchPageAnchor(pageIndex: 0), excerpt: "First")
        let secondEvidence = ResearchEvidence(source: second, anchor: ResearchPageAnchor(pageIndex: 1), excerpt: "Second")
        let original = ResearchMessage(question: "Compare sources", sourceSnapshot: [first, second],
            answer: "First [D001 p. 1], second [D002 p. 2].", evidence: [secondEvidence, firstEvidence], status: .accepted)
        var session = ResearchSession(title: "Original request", sourceSelection: ResearchSourceSelection(fileIDs: [second.fileID, first.fileID]),
            messages: [original])
        check(store.updateSession(session), "The frozen-catalog fixture could not persist its real session.")
        let provenance = ResearchNoteProvenance(origin: .verifiedAI, sessionID: session.id,
            messageID: original.id, evidence: original.evidence)
        let context = ResearchNoteEvidenceContext(provenance: [provenance], store: store)
        check(context.sources == [first, second], "The note catalog followed current source selection instead of frozen D001/D002 order.")
        check(context.evidence == [secondEvidence, firstEvidence], "Evidence order was incorrectly used to redefine source ordinals.")
        check(context.sources.map(\.fingerprint) == ["first-v1", "second-v7"], "The context discarded frozen source versions.")
        let noteID = store.createNote(title: "Saved comparison", body: original.answer!, provenance: [provenance])
        let reloaded = ResearchStore(rootURL: root)
        let reloadedContext = ResearchNoteEvidenceContext(provenance: reloaded.note(id: noteID)?.provenance ?? [], store: reloaded)
        check(reloadedContext.sources == context.sources && reloadedContext.evidence == context.evidence,
              "Reloading a saved note changed its frozen catalog or evidence.")

        var later = original
        later.id = UUID()
        later.requestID = UUID()
        session.messages.append(later)
        check(store.updateSession(session), "Could not persist a second request with the same frozen catalog.")
        var duplicate = provenance
        duplicate.messageID = later.id
        var editedDuplicate = secondEvidence
        editedDuplicate.excerpt = "Different content under the same evidence ID"
        duplicate.evidence = [editedDuplicate, firstEvidence]
        let duplicateContext = ResearchNoteEvidenceContext(provenance: [provenance, duplicate], store: store)
        check(duplicateContext.sources == [first, second], "Identical frozen catalogs were rejected.")
        check(duplicateContext.evidence == original.evidence, "Evidence UUID deduplication did not retain the first original value.")

        var missing = provenance
        missing.messageID = UUID()
        let missingContext = ResearchNoteEvidenceContext(provenance: [provenance, missing], store: store)
        check(missingContext.sources.isEmpty && missingContext.evidence == original.evidence,
              "Missing provenance invented D001 IDs or discarded independently usable evidence.")
        missing.sessionID = UUID()
        check(ResearchNoteEvidenceContext(provenance: [missing], store: store).sources.isEmpty,
              "Missing sessions did not fail closed.")
        check(ResearchNoteEvidenceContext(provenance: [ResearchNoteProvenance(evidence: original.evidence)], store: store).sources.isEmpty,
              "Unattributed evidence was used as a replacement source catalog.")

        later.sourceSnapshot = [second, first]
        session.messages[1] = later
        check(store.updateSession(session), "Could not persist the reordered-catalog fixture.")
        check(ResearchNoteEvidenceContext(provenance: [provenance, duplicate], store: store).sources.isEmpty,
              "Different source orders silently redefined a note's D001/D002 citations.")
        later.sourceSnapshot = [first, second]
        later.sourceSnapshot[1].fingerprint = "second-v8"
        session.messages[1] = later
        check(store.updateSession(session), "Could not persist the changed-version fixture.")
        check(ResearchNoteEvidenceContext(provenance: [provenance, duplicate], store: store).sources.isEmpty,
              "Different frozen source versions were treated as one citation catalog.")

        let pending = ResearchSourceSnapshot(fileID: UUID(), displayName: "Unavailable", fingerprint: "pending")
        later.sourceSnapshot = [first, second, pending]
        session.messages[1] = later
        check(store.updateSession(session), "Could not persist the pending-source fixture.")
        check(ResearchNoteEvidenceContext(provenance: [provenance, duplicate], store: store).sources == [first, second],
              "Pending source filtering changed the retained Mac catalog contract.")
        check(ResearchNoteEvidenceContext(provenance: [], store: store).sources.isEmpty,
              "An empty provenance list fabricated a frozen catalog.")
        check(store.saveFailures.isEmpty && store.loadWarnings.isEmpty,
              "The real note-context fixture left persistence failures or load warnings.")
        return (checks, failures)
    }
}
