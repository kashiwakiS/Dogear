import Foundation
import Combine

@MainActor
final class DocumentMetadataStore: ObservableObject {
    static let shared = DocumentMetadataStore()

    @Published private(set) var state: DocumentMetadataState

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
                .appendingPathComponent("document-metadata-v1.json")
        } else {
            self.stateURL = nil
        }

        if let stateURL = self.stateURL,
           let data = try? Data(contentsOf: stateURL),
           let decoded = try? Self.decoder.decode(DocumentMetadataState.self, from: data) {
            state = decoded
        } else {
            state = DocumentMetadataState()
        }
    }

    func dogears(for documentID: UUID) -> [DogearMarker] {
        state.dogears
            .filter { $0.documentID == documentID }
            .sorted {
                if $0.sortIndex == $1.sortIndex {
                    return $0.createdAt < $1.createdAt
                }
                return $0.sortIndex < $1.sortIndex
            }
    }

    func dogear(for documentID: UUID, pageIndex: Int) -> DogearMarker? {
        state.dogears.first {
            $0.documentID == documentID && $0.pageIndex == pageIndex
        }
    }

    @discardableResult
    func addDogear(documentID: UUID, pageIndex: Int, title: String? = nil) -> DogearMarker {
        if let existing = dogear(for: documentID, pageIndex: pageIndex) {
            return existing
        }

        let documentDogears = dogears(for: documentID)
        let marker = DogearMarker(
            documentID: documentID,
            pageIndex: pageIndex,
            title: title ?? "",
            sortIndex: (documentDogears.map(\.sortIndex).max() ?? -1) + 1
        )
        state.dogears.append(marker)
        persist()
        return marker
    }

    func restoreDogear(_ marker: DogearMarker) {
        state.dogears.removeAll { $0.id == marker.id }
        state.dogears.append(marker)
        normalizeSortIndexes(for: marker.documentID)
        persist()
    }

    @discardableResult
    func removeDogear(id: UUID) -> DogearMarker? {
        guard let index = state.dogears.firstIndex(where: { $0.id == id }) else {
            return nil
        }

        let removed = state.dogears.remove(at: index)
        normalizeSortIndexes(for: removed.documentID)
        persist()
        return removed
    }

    func renameDogear(id: UUID, title: String) {
        guard let index = state.dogears.firstIndex(where: { $0.id == id }) else {
            return
        }

        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        state.dogears[index].title = trimmed
        state.dogears[index].updatedAt = Date()
        persist()
    }

    func moveDogear(id: UUID, by offset: Int) {
        guard offset != 0,
              let marker = state.dogears.first(where: { $0.id == id })
        else {
            return
        }

        var markers = dogears(for: marker.documentID)
        guard let sourceIndex = markers.firstIndex(where: { $0.id == id }) else {
            return
        }

        let destinationIndex = min(max(0, sourceIndex + offset), markers.count - 1)
        guard destinationIndex != sourceIndex else { return }
        let moved = markers.remove(at: sourceIndex)
        markers.insert(moved, at: destinationIndex)
        applyOrder(markers, documentID: marker.documentID)
        persist()
    }

    func updateForRemovedPages(documentID: UUID, removedPageIndexes: IndexSet) {
        guard !removedPageIndexes.isEmpty else { return }
        state.dogears.removeAll {
            $0.documentID == documentID && removedPageIndexes.contains($0.pageIndex)
        }

        for index in state.dogears.indices where state.dogears[index].documentID == documentID {
            let oldPageIndex = state.dogears[index].pageIndex
            state.dogears[index].pageIndex -= removedPageIndexes.filter { $0 < oldPageIndex }.count
            state.dogears[index].updatedAt = Date()
        }
        normalizeSortIndexes(for: documentID)
        persist()
    }

    func updatePageIndexes(documentID: UUID, mapping: [Int: Int]) {
        for index in state.dogears.indices where state.dogears[index].documentID == documentID {
            if let newIndex = mapping[state.dogears[index].pageIndex] {
                state.dogears[index].pageIndex = newIndex
                state.dogears[index].updatedAt = Date()
            }
        }
        persist()
    }

    func replaceDogears(for documentID: UUID, with markers: [DogearMarker]) {
        state.dogears.removeAll { $0.documentID == documentID }
        state.dogears.append(contentsOf: markers)
        normalizeSortIndexes(for: documentID)
        persist()
    }

    private func normalizeSortIndexes(for documentID: UUID) {
        applyOrder(dogears(for: documentID), documentID: documentID)
    }

    private func applyOrder(_ markers: [DogearMarker], documentID: UUID) {
        let indexesByID = Dictionary(uniqueKeysWithValues: markers.enumerated().map { ($0.element.id, $0.offset) })
        for index in state.dogears.indices where state.dogears[index].documentID == documentID {
            if let sortIndex = indexesByID[state.dogears[index].id] {
                state.dogears[index].sortIndex = sortIndex
            }
        }
    }

    private func persist() {
        guard let stateURL else { return }
        do {
            let directoryURL = stateURL.deletingLastPathComponent()
            try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
            var savedState = state
            savedState.schemaVersion = DocumentMetadataState.currentSchemaVersion
            let data = try Self.encoder.encode(savedState)
            try data.write(to: stateURL, options: [.atomic])
        } catch {
            assertionFailure("Failed to save document metadata: \(error)")
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
