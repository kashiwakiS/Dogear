import Foundation

typealias LibraryItem = LibraryFile

struct LibraryState: Codable, Equatable {
    static let currentSchemaVersion = 4

    var schemaVersion: Int
    var files: [LibraryFile]
    var groups: [LibraryGroup]
    var memberships: [GroupMembership]
    var windowSessions: [GroupWindowSession]
    var preferences: LibraryPreferences

    init(
        schemaVersion: Int = Self.currentSchemaVersion,
        files: [LibraryFile] = [],
        groups: [LibraryGroup] = [LibraryGroup.ungrouped],
        memberships: [GroupMembership] = [],
        windowSessions: [GroupWindowSession] = [],
        preferences: LibraryPreferences = LibraryPreferences()
    ) {
        self.schemaVersion = schemaVersion
        self.files = files
        self.groups = groups
        self.memberships = memberships
        self.windowSessions = windowSessions
        self.preferences = preferences
        ensureSystemGroups()
    }

    mutating func ensureSystemGroups() {
        if !groups.contains(where: { $0.id == LibraryGroup.ungroupedID }) {
            groups.insert(.ungrouped, at: 0)
        }
    }
}

struct LibraryFile: Identifiable, Codable, Equatable {
    private enum CodingKeys: String, CodingKey {
        case id
        case displayName
        case canonicalPath
        case path
        case workingCopyPath
        case bookmarkData
        case tags
        case lastOpenedAt
        case librarySortIndex
        case lastPageIndex
        case lastPageOffset
        case isUnavailable
    }

    let id: UUID
    var displayName: String
    var canonicalPath: String
    var workingCopyPath: String?
    var bookmarkData: Data?
    var tags: [String]
    var lastOpenedAt: Date
    var librarySortIndex: Int
    var lastPageIndex: Int
    var lastPageOffset: PDFPageOffset?
    var isUnavailable: Bool

    init(
        id: UUID = UUID(),
        displayName: String,
        canonicalPath: String,
        workingCopyPath: String? = nil,
        bookmarkData: Data? = nil,
        tags: [String] = [],
        lastOpenedAt: Date = Date(),
        librarySortIndex: Int = 0,
        lastPageIndex: Int = 0,
        lastPageOffset: PDFPageOffset? = nil,
        isUnavailable: Bool = false
    ) {
        self.id = id
        self.displayName = displayName
        self.canonicalPath = canonicalPath
        self.workingCopyPath = workingCopyPath
        self.bookmarkData = bookmarkData
        self.tags = tags
        self.lastOpenedAt = lastOpenedAt
        self.librarySortIndex = librarySortIndex
        self.lastPageIndex = lastPageIndex
        self.lastPageOffset = lastPageOffset
        self.isUnavailable = isUnavailable
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        id = try container.decode(UUID.self, forKey: .id)
        displayName = try container.decode(String.self, forKey: .displayName)
        canonicalPath = try container.decodeIfPresent(String.self, forKey: .canonicalPath)
            ?? container.decode(String.self, forKey: .path)
        workingCopyPath = try container.decodeIfPresent(String.self, forKey: .workingCopyPath)
        bookmarkData = try container.decodeIfPresent(Data.self, forKey: .bookmarkData)
        tags = try container.decodeIfPresent([String].self, forKey: .tags) ?? []
        lastOpenedAt = try container.decode(Date.self, forKey: .lastOpenedAt)
        librarySortIndex = try container.decodeIfPresent(
            Int.self,
            forKey: .librarySortIndex
        ) ?? 0
        lastPageIndex = try container.decodeIfPresent(Int.self, forKey: .lastPageIndex) ?? 0
        lastPageOffset = try container.decodeIfPresent(PDFPageOffset.self, forKey: .lastPageOffset)
        isUnavailable = try container.decodeIfPresent(Bool.self, forKey: .isUnavailable) ?? false
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)

        try container.encode(id, forKey: .id)
        try container.encode(displayName, forKey: .displayName)
        try container.encode(canonicalPath, forKey: .canonicalPath)
        try container.encodeIfPresent(workingCopyPath, forKey: .workingCopyPath)
        try container.encodeIfPresent(bookmarkData, forKey: .bookmarkData)
        try container.encode(tags, forKey: .tags)
        try container.encode(lastOpenedAt, forKey: .lastOpenedAt)
        try container.encode(librarySortIndex, forKey: .librarySortIndex)
        try container.encode(lastPageIndex, forKey: .lastPageIndex)
        try container.encodeIfPresent(lastPageOffset, forKey: .lastPageOffset)
        try container.encode(isUnavailable, forKey: .isUnavailable)
    }

    var url: URL {
        URL(fileURLWithPath: canonicalPath)
    }

    var workingCopyURL: URL? {
        guard let workingCopyPath else {
            return nil
        }

        return URL(fileURLWithPath: workingCopyPath)
    }

    var path: String {
        get {
            canonicalPath
        }
        set {
            canonicalPath = newValue
        }
    }

    var tagsText: String {
        get {
            tags.joined(separator: ", ")
        }
        set {
            tags = newValue
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        }
    }
}

struct PDFPageOffset: Codable, Equatable {
    var x: Double
    var y: Double
}

struct LibraryGroup: Identifiable, Codable, Equatable, Hashable {
    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case createdAt
        case updatedAt
        case sortIndex
        case isSystemGroup
        case isArchived
    }

    static let ungroupedID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    static let ungroupedLocalizationKey: String.LocalizationValue = "Ungrouped"
    static let ungrouped = LibraryGroup(
        id: ungroupedID,
        name: "Ungrouped",
        createdAt: .distantPast,
        updatedAt: .distantPast,
        sortIndex: Int.min,
        isSystemGroup: true
    )

    let id: UUID
    var name: String
    var createdAt: Date
    var updatedAt: Date
    var sortIndex: Int
    var isSystemGroup: Bool
    var isArchived: Bool

    init(
        id: UUID = UUID(),
        name: String,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        sortIndex: Int,
        isSystemGroup: Bool = false,
        isArchived: Bool = false
    ) {
        self.id = id
        self.name = name
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.sortIndex = sortIndex
        self.isSystemGroup = isSystemGroup
        self.isArchived = isArchived
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        updatedAt = try container.decode(Date.self, forKey: .updatedAt)
        sortIndex = try container.decode(Int.self, forKey: .sortIndex)
        isSystemGroup = try container.decodeIfPresent(Bool.self, forKey: .isSystemGroup) ?? false
        isArchived = try container.decodeIfPresent(Bool.self, forKey: .isArchived) ?? false
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(updatedAt, forKey: .updatedAt)
        try container.encode(sortIndex, forKey: .sortIndex)
        try container.encode(isSystemGroup, forKey: .isSystemGroup)
        try container.encode(isArchived, forKey: .isArchived)
    }

    var localizedName: String {
        isSystemGroup ? L10n.string(Self.ungroupedLocalizationKey) : name
    }

    func localizedName(language: AppLanguage) -> String {
        isSystemGroup
            ? L10n.string(Self.ungroupedLocalizationKey, language: language)
            : name
    }
}

struct GroupMembership: Codable, Equatable, Hashable {
    private enum CodingKeys: String, CodingKey {
        case groupID
        case fileID
        case addedAt
        case sortIndex
    }

    var groupID: UUID
    var fileID: UUID
    var addedAt: Date
    var sortIndex: Int

    init(
        groupID: UUID,
        fileID: UUID,
        addedAt: Date,
        sortIndex: Int = 0
    ) {
        self.groupID = groupID
        self.fileID = fileID
        self.addedAt = addedAt
        self.sortIndex = sortIndex
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        groupID = try container.decode(UUID.self, forKey: .groupID)
        fileID = try container.decode(UUID.self, forKey: .fileID)
        addedAt = try container.decode(Date.self, forKey: .addedAt)
        sortIndex = try container.decodeIfPresent(Int.self, forKey: .sortIndex) ?? 0
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)

        try container.encode(groupID, forKey: .groupID)
        try container.encode(fileID, forKey: .fileID)
        try container.encode(addedAt, forKey: .addedAt)
        try container.encode(sortIndex, forKey: .sortIndex)
    }
}

struct GroupWindowSession: Identifiable, Codable, Equatable {
    let id: UUID
    var groupID: UUID
    var openFileIDs: [UUID]
    var selectedFileID: UUID?
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        groupID: UUID,
        openFileIDs: [UUID] = [],
        selectedFileID: UUID? = nil,
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.groupID = groupID
        self.openFileIDs = openFileIDs
        self.selectedFileID = selectedFileID
        self.updatedAt = updatedAt
    }
}

struct GroupWindowPayload: Codable, Hashable {
    private enum CodingKeys: String, CodingKey {
        case sessionID
        case groupID
    }

    var sessionID: UUID
    var groupID: UUID

    init(sessionID: UUID = UUID(), groupID: UUID) {
        self.sessionID = sessionID
        self.groupID = groupID
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        sessionID = try container.decodeIfPresent(UUID.self, forKey: .sessionID) ?? UUID()
        groupID = try container.decode(UUID.self, forKey: .groupID)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(sessionID, forKey: .sessionID)
        try container.encode(groupID, forKey: .groupID)
    }
}

struct LibraryPreferences: Codable, Equatable {
    var firstOpenAssignment: FirstOpenAssignment
    var launchBehavior: LaunchBehavior
    var defaultLaunchGroupID: UUID?

    init(
        firstOpenAssignment: FirstOpenAssignment = .currentWindowGroup,
        launchBehavior: LaunchBehavior = .restoreLastGroupWindows,
        defaultLaunchGroupID: UUID? = nil
    ) {
        self.firstOpenAssignment = firstOpenAssignment
        self.launchBehavior = launchBehavior
        self.defaultLaunchGroupID = defaultLaunchGroupID
    }
}

enum FirstOpenAssignment: String, Codable {
    case currentWindowGroup
    case ungrouped
}

enum LaunchBehavior: String, Codable {
    case restoreLastGroupWindows
    case openDefaultGroup
    case openChooser
}

struct LegacyLibraryItem: Identifiable, Codable, Equatable {
    private enum CodingKeys: String, CodingKey {
        case id
        case displayName
        case path
        case bookmarkData
        case project
        case tags
        case lastOpenedAt
        case lastPageIndex
        case isUnavailable
    }

    let id: UUID
    var displayName: String
    var path: String
    var bookmarkData: Data?
    var project: String
    var tags: [String]
    var lastOpenedAt: Date
    var lastPageIndex: Int
    var isUnavailable: Bool

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        id = try container.decode(UUID.self, forKey: .id)
        displayName = try container.decode(String.self, forKey: .displayName)
        path = try container.decode(String.self, forKey: .path)
        bookmarkData = try container.decodeIfPresent(Data.self, forKey: .bookmarkData)
        project = try container.decodeIfPresent(String.self, forKey: .project) ?? ""
        tags = try container.decodeIfPresent([String].self, forKey: .tags) ?? []
        lastOpenedAt = try container.decode(Date.self, forKey: .lastOpenedAt)
        lastPageIndex = try container.decodeIfPresent(Int.self, forKey: .lastPageIndex) ?? 0
        isUnavailable = try container.decodeIfPresent(Bool.self, forKey: .isUnavailable) ?? false
    }
}
