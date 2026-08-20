import Foundation

struct DogearMarker: Identifiable, Codable, Equatable {
    let id: UUID
    let documentID: UUID
    var pageIndex: Int
    var title: String
    var sortIndex: Int
    let createdAt: Date
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        documentID: UUID,
        pageIndex: Int,
        title: String,
        sortIndex: Int,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.documentID = documentID
        self.pageIndex = pageIndex
        self.title = title
        self.sortIndex = sortIndex
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    var pageNumber: Int { pageIndex + 1 }

    func displayTitle(language: AppLanguage) -> String {
        isDefaultTitle
            ? L10n.string("Page \(pageNumber)", language: language)
            : title
    }

    private var isDefaultTitle: Bool {
        title.isEmpty
            || title == "Page \(pageNumber)"
            || title == "第 \(pageNumber) 页"
    }
}

struct DocumentMetadataState: Codable, Equatable {
    static let currentSchemaVersion = 1

    var schemaVersion: Int = Self.currentSchemaVersion
    var dogears: [DogearMarker] = []
}
