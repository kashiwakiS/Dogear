import Combine
import Foundation

@MainActor
final class AIHighlightGroupStore: ObservableObject {
    static let shared = AIHighlightGroupStore()

    @Published private(set) var state: AIHighlightGroupPersistenceState

    private let fileManager: FileManager
    private let stateURL: URL?

    init(fileManager: FileManager = .default, stateURL: URL? = nil) {
        self.fileManager = fileManager

        if let stateURL {
            self.stateURL = stateURL
        } else if let applicationSupportURL = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first {
            self.stateURL = applicationSupportURL
                .appendingPathComponent("PDFWorkBench", isDirectory: true)
                .appendingPathComponent("ai-highlight-groups-v1.json")
        } else {
            self.stateURL = nil
        }

        if let stateURL = self.stateURL,
           let data = try? Data(contentsOf: stateURL),
           let decoded = try? Self.decoder.decode(
               AIHighlightGroupPersistenceState.self,
               from: data
           ),
           decoded.schemaVersion <= AIHighlightGroupPersistenceState.currentSchemaVersion {
            state = decoded
        } else {
            state = AIHighlightGroupPersistenceState()
        }
    }

    func documentState(for documentID: UUID) -> AIHighlightDocumentGroupState? {
        state.documents.first { $0.documentID == documentID }
    }

    func replaceDocumentState(_ documentState: AIHighlightDocumentGroupState) {
        state.documents.removeAll { $0.documentID == documentState.documentID }
        state.documents.append(documentState)
        persist()
    }

    func removeDocumentState(for documentID: UUID) {
        guard state.documents.contains(where: { $0.documentID == documentID }) else {
            return
        }
        state.documents.removeAll { $0.documentID == documentID }
        persist()
    }

    private func persist() {
        guard let stateURL else { return }
        do {
            let directoryURL = stateURL.deletingLastPathComponent()
            try fileManager.createDirectory(
                at: directoryURL,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            try fileManager.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: directoryURL.path
            )
            var savedState = state
            savedState.schemaVersion = AIHighlightGroupPersistenceState.currentSchemaVersion
            let data = try Self.encoder.encode(savedState)
            try data.write(to: stateURL, options: [.atomic])
            try fileManager.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: stateURL.path
            )
        } catch {
            assertionFailure("Failed to save AI highlight groups: \(error)")
        }
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}
