import Foundation

/// Resolves note citations only against the frozen request catalogs that created
/// them. Current Group members and evidence ordering cannot redefine D001 IDs.
@MainActor
struct ResearchNoteEvidenceContext {
    let sources: [ResearchSourceSnapshot]
    let evidence: [ResearchEvidence]

    init(provenance: [ResearchNoteProvenance], store: ResearchStore) {
        var seen = Set<UUID>()
        evidence = provenance.flatMap(\.evidence).filter { seen.insert($0.id).inserted }
        // D001-style citations refer to a frozen request catalog. Combining
        // evidence or live Group members would silently change their meaning.
        let catalogs = provenance.compactMap { item -> [ResearchSourceSnapshot]? in
            guard let sessionID = item.sessionID, let messageID = item.messageID,
                  let message = store.session(id: sessionID)?.messages.first(where: { $0.id == messageID })
            else { return nil }
            return message.sourceSnapshot.filter { $0.fingerprint != "pending" }
        }
        guard catalogs.count == provenance.count, let catalog = catalogs.first,
              catalogs.allSatisfy({ $0 == catalog }) else { sources = []; return }
        sources = catalog
    }
}
