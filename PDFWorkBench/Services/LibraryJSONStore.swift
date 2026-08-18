import Foundation

struct LibraryJSONStore {
    enum StoreError: Error {
        case missingApplicationSupportDirectory
    }

    let fileManager: FileManager
    let stateURL: URL

    init(
        fileManager: FileManager = .default,
        stateURL: URL? = nil
    ) throws {
        self.fileManager = fileManager

        if let stateURL {
            self.stateURL = stateURL
            return
        }

        guard let applicationSupportURL = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else {
            throw StoreError.missingApplicationSupportDirectory
        }

        self.stateURL = applicationSupportURL
            .appendingPathComponent("PDFWorkBench", isDirectory: true)
            .appendingPathComponent("library-state-v2.json")
    }

    func load() throws -> LibraryState? {
        guard fileManager.fileExists(atPath: stateURL.path) else {
            return nil
        }

        let data = try Data(contentsOf: stateURL)
        var decoded = try decoder.decode(LibraryState.self, from: data)
        decoded.ensureSystemGroups()
        return decoded
    }

    func save(_ state: LibraryState) throws {
        var state = state
        state.schemaVersion = LibraryState.currentSchemaVersion
        state.ensureSystemGroups()

        let directoryURL = stateURL.deletingLastPathComponent()
        try fileManager.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true
        )

        let data = try encoder.encode(state)
        let temporaryURL = directoryURL.appendingPathComponent("\(stateURL.lastPathComponent).tmp")
        try data.write(to: temporaryURL, options: [.atomic])

        if fileManager.fileExists(atPath: stateURL.path) {
            _ = try fileManager.replaceItemAt(
                stateURL,
                withItemAt: temporaryURL,
                backupItemName: nil,
                options: []
            )
        } else {
            try fileManager.moveItem(at: temporaryURL, to: stateURL)
        }
    }

    private var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    private var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
