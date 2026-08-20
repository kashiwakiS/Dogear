import Foundation
import Combine

@MainActor
final class LibraryStore: ObservableObject {
    @Published private(set) var state: LibraryState

    private let storage: LibraryJSONStore?
    private let userDefaults: UserDefaults
    private let legacyStorageKey: String

    init(
        userDefaults: UserDefaults = .standard,
        legacyStorageKey: String = "PDFWorkBench.LibraryItems.v1",
        storage: LibraryJSONStore? = nil
    ) {
        self.userDefaults = userDefaults
        self.legacyStorageKey = legacyStorageKey
        self.storage = storage ?? (try? LibraryJSONStore())

        let initialState: LibraryState
        if let loadedState = try? self.storage?.load() {
            initialState = loadedState
        } else {
            initialState = Self.migratedState(
                userDefaults: userDefaults,
                legacyStorageKey: legacyStorageKey
            )
        }

        var preparedState = initialState
        preparedState.ensureSystemGroups()
        if preparedState.schemaVersion < LibraryState.currentSchemaVersion {
            Self.migrateOrdering(in: &preparedState)
        }
        preparedState.schemaVersion = LibraryState.currentSchemaVersion
        state = preparedState
        persist()
    }

    var allFiles: [LibraryFile] {
        sortedFiles(state.files)
    }

    var initialWindowGroupID: UUID {
        Self.initialSelectedGroupID(for: state)
    }

    var initialWindowSessionID: UUID {
        let groupID = initialWindowGroupID
        return state.windowSessions
            .filter { $0.groupID == groupID }
            .sorted { $0.updatedAt > $1.updatedAt }
            .first?.id ?? UUID()
    }

    var userGroups: [LibraryGroup] {
        state.groups
            .filter { !$0.isSystemGroup }
            .sorted(by: sortGroups)
    }

    var activeUserGroups: [LibraryGroup] {
        userGroups.filter { !$0.isArchived }
    }

    var sidebarGroups: [LibraryGroup] {
        [LibraryGroup.ungrouped] + userGroups
    }

    @discardableResult
    func createGroup(named proposedName: String) -> LibraryGroup? {
        let trimmedName = proposedName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else {
            return nil
        }

        if let existing = state.groups.first(where: {
            !$0.isSystemGroup && $0.name.localizedCaseInsensitiveCompare(trimmedName) == .orderedSame
        }) {
            return existing
        }

        let nextSortIndex = (userGroups.map(\.sortIndex).max() ?? 0) + 1
        let group = LibraryGroup(name: trimmedName, sortIndex: nextSortIndex)
        state.groups.append(group)
        persist()
        return group
    }

    @discardableResult
    func createImportedFolderGroup(named proposedName: String) -> LibraryGroup? {
        let trimmedName = proposedName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else {
            return nil
        }

        var uniqueName = trimmedName
        var suffix = 2
        let existingNames = Set(userGroups.map { $0.name.lowercased() })

        while existingNames.contains(uniqueName.lowercased()) {
            uniqueName = "\(trimmedName) \(suffix)"
            suffix += 1
        }

        let nextSortIndex = (userGroups.map(\.sortIndex).max() ?? 0) + 1
        let group = LibraryGroup(name: uniqueName, sortIndex: nextSortIndex)
        state.groups.append(group)
        persist()
        return group
    }

    @discardableResult
    func renameGroup(_ group: LibraryGroup, to proposedName: String) -> Bool {
        guard !group.isSystemGroup,
              let index = state.groups.firstIndex(where: { $0.id == group.id })
        else {
            return false
        }

        let trimmedName = proposedName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else {
            return false
        }

        let conflictsWithExistingGroup = state.groups.contains {
            !$0.isSystemGroup
                && $0.id != group.id
                && $0.name.localizedCaseInsensitiveCompare(trimmedName) == .orderedSame
        }
        guard !conflictsWithExistingGroup else {
            return false
        }

        state.groups[index].name = trimmedName
        state.groups[index].updatedAt = Date()
        persist()
        return true
    }

    @discardableResult
    func deleteGroup(_ group: LibraryGroup) -> Bool {
        guard !group.isSystemGroup,
              state.groups.contains(where: { $0.id == group.id })
        else {
            return false
        }

        state.groups.removeAll { $0.id == group.id }
        state.memberships.removeAll { $0.groupID == group.id }
        state.windowSessions.removeAll { $0.groupID == group.id }
        persist()
        return true
    }

    @discardableResult
    func setGroupArchived(_ group: LibraryGroup, archived: Bool) -> Bool {
        guard !group.isSystemGroup,
              let index = state.groups.firstIndex(where: { $0.id == group.id })
        else {
            return false
        }

        guard state.groups[index].isArchived != archived else {
            return false
        }

        state.groups[index].isArchived = archived
        state.groups[index].updatedAt = Date()
        persist()
        return true
    }

    @discardableResult
    func upsertOpenedURL(
        _ url: URL,
        refreshBookmark: Bool = true,
        groupID: UUID? = nil,
        sessionID: UUID? = nil
    ) -> LibraryFile {
        let canonicalURL = url.resolvingSymlinksInPath().standardizedFileURL
        let bookmarkData = refreshBookmark
            ? try? url.bookmarkData(
                options: .withSecurityScope,
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
            : nil

        let comparablePath = canonicalURL.path
        let now = Date()

        if let index = state.files.firstIndex(where: { $0.path == comparablePath }) {
            state.files[index].displayName = canonicalURL.lastPathComponent
            state.files[index].path = comparablePath
            state.files[index].bookmarkData = bookmarkData ?? state.files[index].bookmarkData
            state.files[index].lastOpenedAt = now
            state.files[index].isUnavailable = false
            recordOpenedFile(state.files[index].id, in: groupID, sessionID: sessionID)
            persist()
            return state.files[index]
        }

        let file = LibraryFile(
            displayName: canonicalURL.lastPathComponent,
            canonicalPath: comparablePath,
            bookmarkData: bookmarkData,
            lastOpenedAt: now,
            librarySortIndex: nextLibrarySortIndex
        )
        state.files.append(file)

        if state.preferences.firstOpenAssignment == .currentWindowGroup,
           let groupID,
           groupID != LibraryGroup.ungroupedID,
           group(withID: groupID) != nil {
            addFile(file.id, to: groupID, persistChange: false)
        }

        recordOpenedFile(file.id, in: groupID, sessionID: sessionID)
        persist()
        return file
    }

    func updateLastPage(for url: URL, pageIndex: Int) {
        guard let index = state.files.firstIndex(where: { $0.url.libraryComparablePath == url.libraryComparablePath }) else {
            return
        }

        let safePageIndex = max(0, pageIndex)

        guard state.files[index].lastPageIndex != safePageIndex else {
            return
        }

        state.files[index].lastPageIndex = safePageIndex
        persist()
    }

    func update(_ item: LibraryItem) {
        guard let index = state.files.firstIndex(where: { $0.id == item.id }) else {
            return
        }

        state.files[index] = item
        persist()
    }

    @discardableResult
    func remove(_ item: LibraryItem) -> Bool {
        guard let index = state.files.firstIndex(where: { $0.id == item.id }) else {
            return false
        }

        state.files.remove(at: index)
        state.memberships.removeAll { $0.fileID == item.id }
        for sessionIndex in state.windowSessions.indices {
            state.windowSessions[sessionIndex].openFileIDs.removeAll { $0 == item.id }
            if state.windowSessions[sessionIndex].selectedFileID == item.id {
                state.windowSessions[sessionIndex].selectedFileID = state.windowSessions[sessionIndex].openFileIDs.first
            }
        }
        persist()
        return true
    }

    func refreshResolvedURL(_ url: URL, for item: LibraryItem) {
        guard let index = state.files.firstIndex(where: { $0.id == item.id }) else {
            return
        }

        let canonicalURL = url.resolvingSymlinksInPath().standardizedFileURL
        state.files[index].displayName = canonicalURL.lastPathComponent
        state.files[index].path = canonicalURL.path
        state.files[index].isUnavailable = false
        persist()
    }

    func updateWorkingCopyURL(_ workingCopyURL: URL?, for item: LibraryItem) {
        guard let index = state.files.firstIndex(where: { $0.id == item.id }) else {
            return
        }

        let path = workingCopyURL?.standardizedFileURL.path
        guard state.files[index].workingCopyPath != path else {
            return
        }

        state.files[index].workingCopyPath = path
        persist()
    }

    func markUnavailable(_ item: LibraryItem) {
        guard let index = state.files.firstIndex(where: { $0.id == item.id }) else {
            return
        }

        guard !state.files[index].isUnavailable else {
            return
        }

        state.files[index].isUnavailable = true
        persist()
    }

    func resolvedURL(for item: LibraryItem) -> URL {
        guard let bookmarkData = item.bookmarkData else {
            return item.url
        }

        var isStale = false
        if let resolvedURL = try? URL(
            resolvingBookmarkData: bookmarkData,
            options: .withSecurityScope,
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        ) {
            return resolvedURL
        }

        return item.url
    }

    func groups(containing file: LibraryFile) -> [LibraryGroup] {
        let groupIDs = Set(state.memberships.filter { $0.fileID == file.id }.map(\.groupID))
        return userGroups.filter { groupIDs.contains($0.id) }
    }

    func isFile(_ file: LibraryFile, in group: LibraryGroup) -> Bool {
        if group.id == LibraryGroup.ungroupedID {
            return !state.memberships.contains { $0.fileID == file.id }
        }

        return state.memberships.contains { $0.fileID == file.id && $0.groupID == group.id }
    }

    func addFile(_ file: LibraryFile, to group: LibraryGroup) {
        addFile(file.id, to: group.id)
    }

    func addFile(_ fileID: UUID, to groupID: UUID, persistChange: Bool = true) {
        guard groupID != LibraryGroup.ungroupedID,
              state.files.contains(where: { $0.id == fileID }),
              group(withID: groupID)?.isArchived == false,
              !state.memberships.contains(where: { $0.fileID == fileID && $0.groupID == groupID })
        else {
            return
        }

        state.memberships.append(
            GroupMembership(
                groupID: groupID,
                fileID: fileID,
                addedAt: Date(),
                sortIndex: nextMembershipSortIndex(in: groupID)
            )
        )

        if persistChange {
            persist()
        }
    }

    func removeFile(_ file: LibraryFile, from group: LibraryGroup) {
        guard group.id != LibraryGroup.ungroupedID else {
            return
        }

        state.memberships.removeAll { membership in
            membership.fileID == file.id && membership.groupID == group.id
        }
        persist()
    }

    func moveFile(_ file: LibraryFile, to targetGroup: LibraryGroup, from sourceGroup: LibraryGroup?) {
        guard !targetGroup.isSystemGroup, !targetGroup.isArchived else {
            return
        }

        if let sourceGroup,
           sourceGroup.id != LibraryGroup.ungroupedID {
            state.memberships.removeAll { membership in
                membership.fileID == file.id && membership.groupID == sourceGroup.id
            }
        }

        addFile(file.id, to: targetGroup.id, persistChange: false)
        persist()
    }

    @discardableResult
    func mergeGroupContents(
        from sourceGroupID: UUID,
        into targetGroupID: UUID
    ) -> Int {
        guard sourceGroupID != targetGroupID,
              sourceGroupID != LibraryGroup.ungroupedID,
              targetGroupID != LibraryGroup.ungroupedID,
              group(withID: sourceGroupID)?.isArchived == false,
              group(withID: targetGroupID)?.isArchived == false
        else {
            return 0
        }

        let targetFileIDs = Set(files(in: targetGroupID).map(\.id))
        let fileIDsToAdd = files(in: sourceGroupID)
            .map(\.id)
            .filter { !targetFileIDs.contains($0) }

        guard !fileIDsToAdd.isEmpty else {
            return 0
        }

        for fileID in fileIDsToAdd {
            addFile(fileID, to: targetGroupID, persistChange: false)
        }
        persist()
        return fileIDsToAdd.count
    }

    func file(for url: URL?) -> LibraryFile? {
        guard let url else {
            return nil
        }

        return state.files.first { $0.path == url.libraryComparablePath }
    }

    func files(in groupID: UUID) -> [LibraryFile] {
        if groupID == LibraryGroup.ungroupedID {
            let groupedFileIDs = Set(state.memberships.map(\.fileID))
            return sortedFiles(state.files.filter { !groupedFileIDs.contains($0.id) })
        }

        let filesByID = Dictionary(uniqueKeysWithValues: state.files.map { ($0.id, $0) })
        return state.memberships
            .filter { $0.groupID == groupID }
            .sorted(by: sortMemberships)
            .compactMap { filesByID[$0.fileID] }
    }

    func reorderGroup(
        _ draggedGroupID: UUID,
        relativeTo targetGroupID: UUID,
        placeAfterTarget: Bool
    ) {
        guard draggedGroupID != LibraryGroup.ungroupedID,
              draggedGroupID != targetGroupID,
              state.groups.contains(where: {
                  $0.id == draggedGroupID && !$0.isSystemGroup
              })
        else {
            return
        }

        var orderedGroups = userGroups
        guard let sourceIndex = orderedGroups.firstIndex(where: {
            $0.id == draggedGroupID
        }) else {
            return
        }

        let draggedGroup = orderedGroups.remove(at: sourceIndex)
        let insertionIndex: Int

        if targetGroupID == LibraryGroup.ungroupedID {
            insertionIndex = 0
        } else if let targetIndex = orderedGroups.firstIndex(where: {
            $0.id == targetGroupID
        }) {
            insertionIndex = targetIndex + (placeAfterTarget ? 1 : 0)
        } else {
            return
        }

        orderedGroups.insert(
            draggedGroup,
            at: min(max(insertionIndex, 0), orderedGroups.count)
        )

        let now = Date()
        for (sortIndex, group) in orderedGroups.enumerated() {
            guard let stateIndex = state.groups.firstIndex(where: {
                $0.id == group.id
            }) else {
                continue
            }

            state.groups[stateIndex].sortIndex = sortIndex
            state.groups[stateIndex].updatedAt = now
        }

        persist()
    }

    func reorderFile(
        _ draggedFileID: UUID,
        relativeTo targetFileID: UUID,
        in groupID: UUID,
        sessionID: UUID,
        placeAfterTarget: Bool
    ) {
        guard draggedFileID != targetFileID,
              let draggedFile = state.files.first(where: {
                  $0.id == draggedFileID
              }),
              let targetFile = state.files.first(where: {
                  $0.id == targetFileID
              })
        else {
            return
        }

        let draggedIsTemporary = isTemporaryFile(draggedFile, in: groupID, sessionID: sessionID)
        let targetIsTemporary = isTemporaryFile(targetFile, in: groupID, sessionID: sessionID)
        guard draggedIsTemporary == targetIsTemporary else {
            return
        }

        if draggedIsTemporary {
            reorderTemporaryFile(
                draggedFileID,
                relativeTo: targetFileID,
                in: groupID,
                sessionID: sessionID,
                placeAfterTarget: placeAfterTarget
            )
        } else if groupID == LibraryGroup.ungroupedID {
            reorderLibraryFile(
                draggedFileID,
                relativeTo: targetFileID,
                placeAfterTarget: placeAfterTarget
            )
        } else {
            reorderMembership(
                draggedFileID,
                relativeTo: targetFileID,
                in: groupID,
                placeAfterTarget: placeAfterTarget
            )
        }

        persist()
    }

    func filesForWindow(in groupID: UUID, sessionID: UUID) -> [LibraryFile] {
        let persistentFiles = files(in: groupID)
        let filesByID = Dictionary(uniqueKeysWithValues: state.files.map { ($0.id, $0) })
        var combinedFiles = persistentFiles
        var includedIDs = Set(persistentFiles.map(\.id))

        for fileID in openSession(for: groupID, sessionID: sessionID)?.openFileIDs ?? [] {
            guard !includedIDs.contains(fileID),
                  let file = filesByID[fileID]
            else {
                continue
            }

            combinedFiles.append(file)
            includedIDs.insert(fileID)
        }

        return combinedFiles
    }

    func persistentFileCount(in groupID: UUID) -> Int {
        files(in: groupID).count
    }

    func isTemporaryFile(
        _ file: LibraryFile,
        in groupID: UUID,
        sessionID: UUID
    ) -> Bool {
        guard openSession(for: groupID, sessionID: sessionID)?.openFileIDs.contains(file.id) == true else {
            return false
        }

        return !isFile(file, in: group(withID: groupID) ?? .ungrouped)
    }

    func group(withID groupID: UUID?) -> LibraryGroup? {
        guard let groupID else {
            return nil
        }

        if groupID == LibraryGroup.ungroupedID {
            return .ungrouped
        }

        return state.groups.first { $0.id == groupID }
    }

    func openSession(for groupID: UUID, sessionID: UUID) -> GroupWindowSession? {
        state.windowSessions.first { $0.id == sessionID && $0.groupID == groupID }
    }

    func recordOpenedFile(_ fileID: UUID, in groupID: UUID?, sessionID: UUID?) {
        guard let groupID,
              let sessionID,
              group(withID: groupID) != nil
        else {
            return
        }

        if let index = state.windowSessions.firstIndex(where: {
            $0.id == sessionID && $0.groupID == groupID
        }) {
            if !state.windowSessions[index].openFileIDs.contains(fileID) {
                state.windowSessions[index].openFileIDs.append(fileID)
            }
            state.windowSessions[index].selectedFileID = fileID
            state.windowSessions[index].updatedAt = Date()
        } else {
            state.windowSessions.append(
                GroupWindowSession(
                    id: sessionID,
                    groupID: groupID,
                    openFileIDs: [fileID],
                    selectedFileID: fileID
                )
            )
        }

        persist()
    }

    private func persist() {
        var stateToPersist = state
        stateToPersist.files = sortedFiles(stateToPersist.files)
        stateToPersist.groups = [LibraryGroup.ungrouped] + userGroups
        stateToPersist.ensureSystemGroups()
        state = stateToPersist
        try? storage?.save(stateToPersist)
    }

    private func sortedFiles(_ files: [LibraryFile]) -> [LibraryFile] {
        files.sorted { lhs, rhs in
            if lhs.librarySortIndex != rhs.librarySortIndex {
                return lhs.librarySortIndex < rhs.librarySortIndex
            }

            return Self.legacyFileOrder(lhs, rhs)
        }
    }

    private func sortGroups(_ lhs: LibraryGroup, _ rhs: LibraryGroup) -> Bool {
        if lhs.sortIndex != rhs.sortIndex {
            return lhs.sortIndex < rhs.sortIndex
        }

        return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
    }

    private func sortMemberships(_ lhs: GroupMembership, _ rhs: GroupMembership) -> Bool {
        if lhs.sortIndex != rhs.sortIndex {
            return lhs.sortIndex < rhs.sortIndex
        }

        if lhs.addedAt != rhs.addedAt {
            return lhs.addedAt < rhs.addedAt
        }

        return lhs.fileID.uuidString < rhs.fileID.uuidString
    }

    private var nextLibrarySortIndex: Int {
        (state.files.map(\.librarySortIndex).max() ?? -1) + 1
    }

    private func nextMembershipSortIndex(in groupID: UUID) -> Int {
        let maximumIndex = state.memberships
            .filter { $0.groupID == groupID }
            .map(\.sortIndex)
            .max() ?? -1
        return maximumIndex + 1
    }

    private func reorderLibraryFile(
        _ draggedFileID: UUID,
        relativeTo targetFileID: UUID,
        placeAfterTarget: Bool
    ) {
        var orderedFileIDs = sortedFiles(state.files).map(\.id)
        guard let sourceIndex = orderedFileIDs.firstIndex(of: draggedFileID) else {
            return
        }

        orderedFileIDs.remove(at: sourceIndex)
        guard let targetIndex = orderedFileIDs.firstIndex(of: targetFileID) else {
            return
        }

        orderedFileIDs.insert(
            draggedFileID,
            at: targetIndex + (placeAfterTarget ? 1 : 0)
        )

        for (sortIndex, fileID) in orderedFileIDs.enumerated() {
            if let stateIndex = state.files.firstIndex(where: { $0.id == fileID }) {
                state.files[stateIndex].librarySortIndex = sortIndex
            }
        }
    }

    private func reorderMembership(
        _ draggedFileID: UUID,
        relativeTo targetFileID: UUID,
        in groupID: UUID,
        placeAfterTarget: Bool
    ) {
        var orderedFileIDs = state.memberships
            .filter { $0.groupID == groupID }
            .sorted(by: sortMemberships)
            .map(\.fileID)

        guard let sourceIndex = orderedFileIDs.firstIndex(of: draggedFileID) else {
            return
        }

        orderedFileIDs.remove(at: sourceIndex)
        guard let targetIndex = orderedFileIDs.firstIndex(of: targetFileID) else {
            return
        }

        orderedFileIDs.insert(
            draggedFileID,
            at: targetIndex + (placeAfterTarget ? 1 : 0)
        )

        for (sortIndex, fileID) in orderedFileIDs.enumerated() {
            if let stateIndex = state.memberships.firstIndex(where: {
                $0.groupID == groupID && $0.fileID == fileID
            }) {
                state.memberships[stateIndex].sortIndex = sortIndex
            }
        }
    }

    private func reorderTemporaryFile(
        _ draggedFileID: UUID,
        relativeTo targetFileID: UUID,
        in groupID: UUID,
        sessionID: UUID,
        placeAfterTarget: Bool
    ) {
        guard let sessionIndex = state.windowSessions.firstIndex(where: {
            $0.id == sessionID && $0.groupID == groupID
        }) else {
            return
        }

        let group = group(withID: groupID) ?? .ungrouped
        let filesByID = Dictionary(uniqueKeysWithValues: state.files.map {
            ($0.id, $0)
        })
        let temporarySlots = state.windowSessions[sessionIndex].openFileIDs.indices.filter {
            guard let file = filesByID[state.windowSessions[sessionIndex].openFileIDs[$0]] else {
                return false
            }

            return !isFile(file, in: group)
        }
        var temporaryFileIDs = temporarySlots.map {
            state.windowSessions[sessionIndex].openFileIDs[$0]
        }

        guard let sourceIndex = temporaryFileIDs.firstIndex(of: draggedFileID) else {
            return
        }

        temporaryFileIDs.remove(at: sourceIndex)
        guard let targetIndex = temporaryFileIDs.firstIndex(of: targetFileID) else {
            return
        }

        temporaryFileIDs.insert(
            draggedFileID,
            at: targetIndex + (placeAfterTarget ? 1 : 0)
        )

        for (slot, fileID) in zip(temporarySlots, temporaryFileIDs) {
            state.windowSessions[sessionIndex].openFileIDs[slot] = fileID
        }
        state.windowSessions[sessionIndex].updatedAt = Date()
    }

    private static func initialSelectedGroupID(for state: LibraryState) -> UUID {
        state.preferences.defaultLaunchGroupID
            ?? state.windowSessions.sorted { $0.updatedAt > $1.updatedAt }.first?.groupID
            ?? LibraryGroup.ungroupedID
    }

    private static func migratedState(
        userDefaults: UserDefaults,
        legacyStorageKey: String
    ) -> LibraryState {
        guard let data = userDefaults.data(forKey: legacyStorageKey),
              let decoded = try? JSONDecoder().decode([LegacyLibraryItem].self, from: data)
        else {
            return LibraryState()
        }

        let deduplicatedItems = deduplicated(decoded)
        var groupsByName: [String: LibraryGroup] = [:]
        var groups: [LibraryGroup] = [.ungrouped]
        var files: [LibraryFile] = []
        var memberships: [GroupMembership] = []

        for item in deduplicatedItems {
            let canonicalPath = URL(fileURLWithPath: item.path).libraryComparablePath
            let file = LibraryFile(
                id: item.id,
                displayName: item.displayName,
                canonicalPath: canonicalPath,
                bookmarkData: item.bookmarkData,
                tags: item.tags,
                lastOpenedAt: item.lastOpenedAt,
                lastPageIndex: item.lastPageIndex,
                isUnavailable: item.isUnavailable
            )
            files.append(file)

            let projectName = item.project.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !projectName.isEmpty else {
                continue
            }

            let normalizedName = projectName.lowercased()
            let group: LibraryGroup
            if let existingGroup = groupsByName[normalizedName] {
                group = existingGroup
            } else {
                group = LibraryGroup(
                    name: projectName,
                    sortIndex: groupsByName.count
                )
                groupsByName[normalizedName] = group
                groups.append(group)
            }

            memberships.append(
                GroupMembership(
                    groupID: group.id,
                    fileID: file.id,
                    addedAt: item.lastOpenedAt
                )
            )
        }

        return LibraryState(
            schemaVersion: 3,
            files: files,
            groups: groups,
            memberships: memberships
        )
    }

    private static func migrateOrdering(in state: inout LibraryState) {
        let legacyOrderedFiles = legacySortedFiles(state.files)

        for (sortIndex, file) in legacyOrderedFiles.enumerated() {
            if let stateIndex = state.files.firstIndex(where: { $0.id == file.id }) {
                state.files[stateIndex].librarySortIndex = sortIndex
            }
        }

        for group in state.groups where !group.isSystemGroup {
            let memberFileIDs = Set(
                state.memberships
                    .filter { $0.groupID == group.id }
                    .map(\.fileID)
            )
            let orderedMemberIDs = legacyOrderedFiles
                .filter { memberFileIDs.contains($0.id) }
                .map(\.id)

            for (sortIndex, fileID) in orderedMemberIDs.enumerated() {
                if let membershipIndex = state.memberships.firstIndex(where: {
                    $0.groupID == group.id && $0.fileID == fileID
                }) {
                    state.memberships[membershipIndex].sortIndex = sortIndex
                }
            }
        }
    }

    private static func legacySortedFiles(_ files: [LibraryFile]) -> [LibraryFile] {
        let groups = Dictionary(grouping: files) {
            $0.displayName.lowercased()
        }

        return groups.values
            .sorted { lhs, rhs in
                let lhsLatest = lhs.map(\.lastOpenedAt).max() ?? .distantPast
                let rhsLatest = rhs.map(\.lastOpenedAt).max() ?? .distantPast

                if lhsLatest != rhsLatest {
                    return lhsLatest > rhsLatest
                }

                let lhsName = lhs.first?.displayName ?? ""
                let rhsName = rhs.first?.displayName ?? ""
                return lhsName.localizedStandardCompare(rhsName) == .orderedAscending
            }
            .flatMap { group in
                group.sorted(by: legacyFileOrder)
            }
    }

    private static func legacyFileOrder(_ lhs: LibraryFile, _ rhs: LibraryFile) -> Bool {
        if lhs.isUnavailable != rhs.isUnavailable {
            return !lhs.isUnavailable && rhs.isUnavailable
        }

        let nameComparison = lhs.displayName.localizedStandardCompare(rhs.displayName)
        if nameComparison != .orderedSame {
            return nameComparison == .orderedAscending
        }

        return lhs.path.localizedStandardCompare(rhs.path) == .orderedAscending
    }

    private static func deduplicated(_ decodedItems: [LegacyLibraryItem]) -> [LegacyLibraryItem] {
        var mergedItemsByPath: [String: LegacyLibraryItem] = [:]

        for var item in decodedItems {
            item.path = URL(fileURLWithPath: item.path).libraryComparablePath

            if let existing = mergedItemsByPath[item.path],
               existing.lastOpenedAt >= item.lastOpenedAt {
                continue
            }

            mergedItemsByPath[item.path] = item
        }

        return Array(mergedItemsByPath.values)
    }
}
