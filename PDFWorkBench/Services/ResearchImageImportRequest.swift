import Foundation

/// A file picker belongs to the session that opened it, even if the visible
/// panel changes sessions before the system delivers its completion.
nonisolated struct ResearchImageImportRequest: Sendable {
    let sessionID: UUID

    @MainActor
    func complete(_ result: Result<[URL], Error>, store: ResearchStore) -> [Error] {
        switch result {
        case .failure(let error):
            let cocoaError = error as NSError
            if error is CancellationError ||
                (cocoaError.domain == NSCocoaErrorDomain && cocoaError.code == NSUserCancelledError) { return [] }
            return [error]
        case .success(let urls):
            guard store.session(id: sessionID) != nil else { return [ResearchStoreError.missingRecord] }
            var failures: [Error] = []
            for url in urls {
                do { try importURL(url, store: store) }
                catch { failures.append(error) }
            }
            return failures
        }
    }

    @MainActor
    func importURL(_ url: URL, store: ResearchStore) throws {
        guard let session = store.session(id: sessionID) else { throw ResearchStoreError.missingRecord }
        guard session.draft.attachmentIDs.count < ResearchInputLimits.maximumImages else {
            throw ResearchImageError.tooLarge
        }
        let data: Data
        do {
            data = try ResearchImageFileReader.read(url, maximumBytes: ResearchInputLimits.maximumImportedImageBytes)
        } catch ResearchImageFileReadError.tooLarge {
            throw ResearchImageError.tooLarge
        } catch ResearchImageFileReadError.unsupported {
            throw ResearchStoreError.invalidAttachment
        }
        try ResearchImagePipeline.importImage(data: data, displayName: url.lastPathComponent,
            sessionID: sessionID, store: store)
    }
}
