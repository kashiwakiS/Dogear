import Foundation
import Combine

@MainActor
final class LibraryStore: ObservableObject {
    @Published private(set) var state: LibraryState

    private let storage: LibraryJSONStore?
    private let userDefaults: UserDefaults
    private let legacyStorageKey: String
    private let persistenceWriter: LibraryStateWriter
    private let workingCopyStore: PDFWorkingCopyStore?
    private var fingerprintTasks: [UUID: (id: UUID, task: Task<String, Error>)] = [:]

    init(
        userDefaults: UserDefaults = .standard,
        legacyStorageKey: String = "PDFWorkBench.LibraryItems.v1",
        storage: LibraryJSONStore? = nil,
        readingPositionSaveDelay: TimeInterval = 0.3,
        workingCopyStore: PDFWorkingCopyStore? = nil
    ) {
        self.userDefaults = userDefaults
        self.legacyStorageKey = legacyStorageKey
        self.storage = storage ?? (try? LibraryJSONStore())
        self.workingCopyStore = workingCopyStore ?? (try? PDFWorkingCopyStore())
        let resolvedStorage = self.storage
        persistenceWriter = LibraryStateWriter(delay: readingPositionSaveDelay) { state in
            guard let resolvedStorage else {
                throw LibraryJSONStore.StoreError.missingApplicationSupportDirectory
            }
            try resolvedStorage.save(state)
        }

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
        // Refresh app-owned locations before exposing records to PDF, Research
        // or export callers. This preserves the catalog UUID and original path.
        for index in preparedState.files.indices {
            if let recorded = preparedState.files[index].workingCopyURL,
               let relocated = self.workingCopyStore?.portableManagedCopyURL(for: recorded) {
                preparedState.files[index].workingCopyPath = relocated.standardizedFileURL.path
            }
        }
        preparedState.ensureSystemGroups()
        if preparedState.schemaVersion < 4 {
            Self.migrateOrdering(in: &preparedState)
        }
        preparedState.schemaVersion = LibraryState.currentSchemaVersion
        state = preparedState
        persist()
    }

    deinit {
        _ = persistenceWriter.flush()
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
        upsertOpenedURLs([url], refreshBookmark: refreshBookmark,
                         groupID: groupID, sessionID: sessionID)[0]
    }

    /// One in-memory publication and one disk snapshot per import, preserving
    /// source order and first-open membership without a write for each file.
    @discardableResult
    func upsertOpenedURLs(
        _ urls: [URL],
        refreshBookmark: Bool = true,
        groupID: UUID? = nil,
        sessionID: UUID? = nil
    ) -> [LibraryFile] {
        var next = state
        var seenPaths = Set<String>()
        var ids: [UUID] = []
        let now = Date()
        for url in urls {
            let canonicalURL = url.resolvingSymlinksInPath().standardizedFileURL
            guard seenPaths.insert(canonicalURL.path).inserted else { continue }
            let bookmark = refreshBookmark ? Self.makeBookmark(for: url) : nil
            let existingID = next.files.first(where: { $0.canonicalPath == canonicalURL.path })?.id
                ?? fileForOpening(at: canonicalURL)?.id
            if let existingID, let index = next.files.firstIndex(where: { $0.id == existingID }) {
                // A bookmark can follow a Finder move before Library's stored
                // path is refreshed. Keep any old-path-derived copy first.
                if next.files[index].workingCopyPath == nil {
                    next.files[index].workingCopyPath = openingWorkingCopyURL(for: next.files[index])?.path
                }
                // Import may discover a moved bookmark while another window
                // still owns the old path. Only a successful reader handoff
                // (refreshResolvedURL) may change that shared original key.
                next.files[index].bookmarkData = bookmark ?? next.files[index].bookmarkData
                next.files[index].lastOpenedAt = now
                next.files[index].isUnavailable = false
                if !ids.contains(existingID) { ids.append(existingID) }
            } else {
                let file = LibraryFile(displayName: canonicalURL.lastPathComponent,
                    canonicalPath: canonicalURL.path, bookmarkData: bookmark, lastOpenedAt: now,
                    librarySortIndex: (next.files.map(\.librarySortIndex).max() ?? -1) + 1)
                next.files.append(file)
                ids.append(file.id)
                if next.preferences.firstOpenAssignment == .currentWindowGroup,
                   let groupID, groupID != LibraryGroup.ungroupedID,
                   next.groups.contains(where: { $0.id == groupID && !$0.isArchived }) {
                    Self.addMemberships([file.id], to: groupID, in: &next)
                }
            }
        }
        guard !ids.isEmpty else { return [] }
        Self.recordOpenedFiles(ids, in: groupID, sessionID: sessionID, state: &next)
        state = next
        persist()
        let filesByID = Dictionary(uniqueKeysWithValues: state.files.map { ($0.id, $0) })
        return ids.compactMap { filesByID[$0] }
    }

    func updateLastPage(for url: URL, pageIndex: Int) {
        // Stored paths are already canonical. The usual PDF callback uses that
        // same path, so avoid resolving every Library URL on every page change.
        let path = url.standardizedFileURL.path
        let directIndex = state.files.firstIndex { $0.canonicalPath == path }
        let index = directIndex ?? {
            let comparablePath = url.libraryComparablePath
            return state.files.firstIndex { $0.url.libraryComparablePath == comparablePath }
        }()
        guard let index else {
            return
        }

        let safePageIndex = max(0, pageIndex)

        guard state.files[index].lastPageIndex != safePageIndex else {
            return
        }

        state.files[index].lastPageIndex = safePageIndex
        state.files[index].lastPageOffset = nil
        // Page changes do not affect Library ordering. Keep the immediate
        // in-memory update, coalescing only encoding and disk writes.
        persistenceWriter.saveSoon(state)
    }

    /// Native PDF destination in page points (including viewport margins), not
    /// normalized fractions. Uses the existing optional schema-6 offset field.
    func updateReadingPosition(fileID: UUID, pageIndex: Int, offset: PDFPageOffset) {
        guard pageIndex >= 0, offset.x.isFinite, offset.y.isFinite,
              let index = state.files.firstIndex(where: { $0.id == fileID }) else { return }
        guard state.files[index].lastPageIndex != pageIndex || state.files[index].lastPageOffset != offset else { return }
        state.files[index].lastPageIndex = pageIndex
        state.files[index].lastPageOffset = offset
        persistenceWriter.saveSoon(state)
    }

    func updateZoomState(_ zoomState: PDFZoomState, for url: URL) {
        guard let index = state.files.firstIndex(where: {
            $0.url.libraryComparablePath == url.libraryComparablePath
        }) else {
            return
        }

        guard state.files[index].lastZoomState != zoomState else {
            return
        }

        state.files[index].lastZoomState = zoomState
        persist()
    }

    func update(_ item: LibraryItem) {
        guard let index = state.files.firstIndex(where: { $0.id == item.id }) else {
            return
        }

        var updated = item
        // Legacy metadata editors can hold a draft made before background
        // fingerprint capture. Only the identity service may change the baseline.
        updated.originalSHA256 = state.files[index].originalSHA256
        state.files[index] = updated
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
        if state.files[index].workingCopyPath == nil {
            state.files[index].workingCopyPath = openingWorkingCopyURL(for: state.files[index])?.path
        }
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
        #if os(macOS)
        let options: URL.BookmarkResolutionOptions = .withSecurityScope
        #else
        let options: URL.BookmarkResolutionOptions = []
        #endif
        if let resolvedURL = try? URL(
            resolvingBookmarkData: bookmarkData,
            options: options,
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        ) {
            return resolvedURL
        }

        return item.url
    }

    /// Capture only the original. A saved baseline is never refreshed by an
    /// ordinary reopen, even when the original has subsequently changed.
    @discardableResult
    func captureOriginalFingerprint(for fileID: UUID, replacingExisting: Bool = false) async throws -> String {
        try Task.checkCancellation()
        guard let file = state.files.first(where: { $0.id == fileID }) else {
            throw LibraryWorkflowError.unknownFile
        }
        if !replacingExisting, let hash = file.originalSHA256, PDFOriginalIdentityService.isSHA256(hash) {
            return hash
        }
        if !replacingExisting, let pending = fingerprintTasks[fileID] {
            return try await Self.awaitFingerprint(pending.task)
        }
        if replacingExisting { fingerprintTasks[fileID]?.task.cancel() }
        let sourceURL = resolvedURL(for: file)
        let ticket = UUID()
        let task = Task { @MainActor [weak self] () async throws -> String in
            try Task.checkCancellation()
            let fingerprint = try await PDFOriginalIdentityService.fingerprint(at: sourceURL)
            try Task.checkCancellation()
            guard let self, let index = self.state.files.firstIndex(where: { $0.id == fileID }),
                  self.state.files[index].canonicalPath == file.canonicalPath,
                  self.state.files[index].bookmarkData == file.bookmarkData,
                  self.state.files[index].originalSHA256 == file.originalSHA256 else {
                throw LibraryWorkflowError.recordChanged
            }
            try PDFOriginalIdentityService.validate(fingerprint, at: sourceURL)
            var next = self.state
            next.files[index].originalSHA256 = fingerprint.sha256
            try self.commitState(next)
            return fingerprint.sha256
        }
        fingerprintTasks[fileID] = (ticket, task)
        defer {
            if fingerprintTasks[fileID]?.id == ticket { fingerprintTasks.removeValue(forKey: fileID) }
        }
        return try await Self.awaitFingerprint(task)
    }

    private static func awaitFingerprint(_ task: Task<String, Error>) async throws -> String {
        try await withTaskCancellationHandler {
            let hash = try await task.value
            try Task.checkCancellation()
            return hash
        } onCancel: { task.cancel() }
    }

    func prepareRelink(fileID: UUID, to candidateURL: URL) async throws -> LibraryRelinkPlan {
        guard let original = state.files.first(where: { $0.id == fileID }) else {
            throw LibraryWorkflowError.unknownFile
        }
        if original.originalSHA256.map(PDFOriginalIdentityService.isSHA256) != true {
            // Legacy records can bootstrap only from their own readable original,
            // never from the chosen candidate or the edited working copy.
            do { try await captureOriginalFingerprint(for: fileID) }
            catch is CancellationError { throw CancellationError() }
            catch let error as LibraryWorkflowError where error == .persistenceFailed || error == .recordChanged {
                throw error
            }
            catch { /* An unavailable legacy baseline remains explicitly unknown. */ }
        }
        try Task.checkCancellation()
        guard let file = state.files.first(where: { $0.id == fileID }),
              file.canonicalPath == original.canonicalPath,
              file.workingCopyPath == original.workingCopyPath,
              file.bookmarkData == original.bookmarkData else {
            throw LibraryWorkflowError.recordChanged
        }
        let fingerprint = try await PDFOriginalIdentityService.fingerprint(at: candidateURL)
        try Task.checkCancellation()
        try validateRelinkRecord(file)
        try validateRelinkDestination(candidateURL, for: fileID)
        let bookmark = try Self.requiredBookmark(for: candidateURL)
        try PDFOriginalIdentityService.validate(fingerprint, at: candidateURL)
        let baseline = file.originalSHA256.flatMap { PDFOriginalIdentityService.isSHA256($0) ? $0 : nil }
        let disposition: LibraryRelinkDisposition = baseline.map {
            $0 == fingerprint.sha256 ? .sameContent : .differentContent
        } ?? .baselineUnavailable
        let legacyCopy = workingCopyStore?.workingCopyURL(forOriginalURL: file.url)
        let effectiveCopy = file.workingCopyURL ?? legacyCopy.flatMap {
            FileManager.default.fileExists(atPath: $0.path) ? $0 : nil
        }
        return LibraryRelinkPlan(fileID: fileID, originalURL: file.url,
            candidateURL: candidateURL, disposition: disposition, originalSHA256: baseline,
            candidateSHA256: fingerprint.sha256, workingCopyURL: effectiveCopy,
            expectedCanonicalPath: file.canonicalPath, expectedWorkingCopyPath: file.workingCopyPath,
            expectedBookmark: file.bookmarkData, candidateFingerprint: fingerprint,
            candidateBookmark: bookmark)
    }

    /// Rehash after user interaction; MainActor is not occupied by the read.
    func revalidateRelink(_ plan: LibraryRelinkPlan) async throws -> LibraryRelinkPlan {
        try validateRelinkPlanRecord(plan)
        let refreshed = try await prepareRelink(fileID: plan.fileID, to: plan.candidateURL)
        try validateRelinkPlanRecord(plan)
        guard refreshed.originalSHA256 == plan.originalSHA256,
              refreshed.candidateSHA256 == plan.candidateSHA256,
              refreshed.workingCopyURL == plan.workingCopyURL else {
            throw LibraryWorkflowError.changedWhileReading
        }
        return refreshed
    }

    /// The document coordinator invokes this synchronously after draining the
    /// active writer and before rebinding it. Failure leaves both disk and the
    /// published Library unchanged; originals and working-copy bytes are untouched.
    @discardableResult
    func commitRelink(_ plan: LibraryRelinkPlan) throws -> LibraryFile {
        switch plan.disposition {
        case .differentContent: throw LibraryWorkflowError.contentMismatch
        case .baselineUnavailable: throw LibraryWorkflowError.baselineUnavailable
        case .sameContent: break
        }
        try validateRelinkPlanRecord(plan)
        try validateRelinkDestination(plan.candidateURL, for: plan.fileID)
        guard plan.originalSHA256 == plan.candidateSHA256,
              plan.candidateSHA256 == plan.candidateFingerprint.sha256,
              PDFOriginalIdentityService.isSHA256(plan.candidateSHA256) else {
            throw LibraryWorkflowError.contentMismatch
        }
        try PDFOriginalIdentityService.validate(plan.candidateFingerprint, at: plan.candidateURL)
        guard let index = state.files.firstIndex(where: { $0.id == plan.fileID }) else {
            throw LibraryWorkflowError.unknownFile
        }
        var next = state
        // The coordinator has just drained the writer. A first edit may have
        // created the old path's copy while its UI-to-Library notification was
        // still pending; persist that location before changing the original key.
        let legacyCopy = workingCopyStore?.workingCopyURL(forOriginalURL: plan.originalURL)
        let preservedCopy = plan.workingCopyURL ?? legacyCopy.flatMap {
            FileManager.default.fileExists(atPath: $0.path) ? $0 : nil
        }
        next.files[index].canonicalPath = plan.candidateFingerprint.stamp.canonicalPath
        next.files[index].displayName = plan.candidateURL.lastPathComponent
        next.files[index].bookmarkData = plan.candidateBookmark
        next.files[index].workingCopyPath = preservedCopy?.standardizedFileURL.path
        next.files[index].isUnavailable = false
        let updated = next.files[index]
        try commitState(next)
        return updated
    }

    private func validateRelinkRecord(_ expected: LibraryFile) throws {
        guard let current = state.files.first(where: { $0.id == expected.id }),
              current.canonicalPath == expected.canonicalPath,
              current.workingCopyPath == expected.workingCopyPath,
              current.bookmarkData == expected.bookmarkData,
              current.originalSHA256 == expected.originalSHA256 else {
            throw LibraryWorkflowError.recordChanged
        }
    }

    private func validateRelinkPlanRecord(_ plan: LibraryRelinkPlan) throws {
        guard let current = state.files.first(where: { $0.id == plan.fileID }),
              current.canonicalPath == plan.expectedCanonicalPath,
              current.workingCopyPath == plan.expectedWorkingCopyPath,
              current.bookmarkData == plan.expectedBookmark,
              current.originalSHA256 == plan.originalSHA256 else {
            throw LibraryWorkflowError.recordChanged
        }
    }

    private func validateRelinkDestination(_ url: URL, for fileID: UUID) throws {
        let path = url.resolvingSymlinksInPath().standardizedFileURL.path
        if let managedRoot = workingCopyStore?.directoryURL.resolvingSymlinksInPath().standardizedFileURL.path,
           path == managedRoot || path.hasPrefix(managedRoot + "/") {
            throw LibraryWorkflowError.unsafeWorkingCopy
        }
        guard !state.files.contains(where: { file in
            file.workingCopyURL?.resolvingSymlinksInPath().standardizedFileURL.path == path
        }) else { throw LibraryWorkflowError.unsafeWorkingCopy }
        guard !state.files.contains(where: { file in
            file.id != fileID && (file.canonicalPath == path || resolvedURL(for: file).libraryComparablePath == path)
        }) else { throw LibraryWorkflowError.alreadyInLibrary }
    }

    private static func makeBookmark(for url: URL) -> Data? {
        try? requiredBookmark(for: url)
    }

    private static func requiredBookmark(for url: URL) throws -> Data {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        #if os(macOS)
        let options: URL.BookmarkCreationOptions = .withSecurityScope
        #else
        let options: URL.BookmarkCreationOptions = []
        #endif
        return try url.bookmarkData(options: options,
            includingResourceValuesForKeys: nil, relativeTo: nil)
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
        // Menu actions can hold snapshots across archive/delete operations.
        // Validate all current identities before removing any source membership.
        guard let currentFile = state.files.first(where: { $0.id == file.id }),
              let currentTarget = group(withID: targetGroup.id),
              !currentTarget.isSystemGroup, !currentTarget.isArchived else {
            return
        }
        let sourceGroupID: UUID?
        if let sourceGroup {
            guard let currentSource = group(withID: sourceGroup.id) else { return }
            sourceGroupID = currentSource.id
        } else {
            sourceGroupID = nil
        }
        guard sourceGroupID != currentTarget.id else { return }

        var next = state
        if let sourceGroupID, sourceGroupID != LibraryGroup.ungroupedID {
            next.memberships.removeAll { membership in
                membership.fileID == currentFile.id && membership.groupID == sourceGroupID
            }
        }

        Self.addMemberships([currentFile.id], to: currentTarget.id, in: &next)
        state = next
        persist()
    }

    @discardableResult
    func addFiles(_ fileIDs: [UUID], to groupID: UUID) throws -> Int {
        let ids = try validatedFileIDs(fileIDs)
        try validateDestinationGroup(groupID)
        var next = state
        let before = next.memberships.count
        Self.addMemberships(ids, to: groupID, in: &next)
        guard next.memberships.count != before else { return 0 }
        try commitState(next)
        return next.memberships.count - before
    }

    @discardableResult
    func removeFiles(_ fileIDs: [UUID], from groupID: UUID) throws -> Int {
        let ids = Set(try validatedFileIDs(fileIDs))
        guard groupID != LibraryGroup.ungroupedID else { return 0 }
        guard group(withID: groupID) != nil else { throw LibraryWorkflowError.invalidGroup }
        var next = state
        let before = next.memberships.count
        next.memberships.removeAll { $0.groupID == groupID && ids.contains($0.fileID) }
        guard next.memberships.count != before else { return 0 }
        try commitState(next)
        return before - next.memberships.count
    }

    @discardableResult
    func moveFiles(_ fileIDs: [UUID], to targetGroupID: UUID, from sourceGroupID: UUID?) throws -> Int {
        let ids = try validatedFileIDs(fileIDs)
        try validateDestinationGroup(targetGroupID)
        if let sourceGroupID, group(withID: sourceGroupID) == nil {
            throw LibraryWorkflowError.invalidGroup
        }
        guard sourceGroupID != targetGroupID, !ids.isEmpty else { return 0 }
        var next = state
        let selected = Set(ids)
        if let sourceGroupID, sourceGroupID != LibraryGroup.ungroupedID {
            next.memberships.removeAll { $0.groupID == sourceGroupID && selected.contains($0.fileID) }
        }
        Self.addMemberships(ids, to: targetGroupID, in: &next)
        guard next != state else { return 0 }
        try commitState(next)
        return ids.count
    }

    @discardableResult
    func createGroup(named proposedName: String, containing fileIDs: [UUID]) throws -> LibraryGroup {
        let ids = try validatedFileIDs(fileIDs)
        let name = proposedName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw LibraryWorkflowError.invalidName }
        guard !state.groups.contains(where: {
            !$0.isSystemGroup && $0.name.localizedCaseInsensitiveCompare(name) == .orderedSame
        }) else { throw LibraryWorkflowError.groupNameExists }
        let group = LibraryGroup(name: name, sortIndex: (userGroups.map(\.sortIndex).max() ?? -1) + 1)
        var next = state
        next.groups.append(group)
        Self.addMemberships(ids, to: group.id, in: &next)
        try commitState(next)
        return group
    }

    func updateTags(_ tags: [String], for fileIDs: [UUID]) throws {
        let ids = Set(try validatedFileIDs(fileIDs))
        var seen = Set<String>()
        let normalized = tags.compactMap { raw -> String? in
            let tag = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !tag.isEmpty, seen.insert(tag.lowercased()).inserted else { return nil }
            return tag
        }
        var next = state
        for index in next.files.indices where ids.contains(next.files[index].id) {
            next.files[index].tags = normalized
        }
        guard next != state else { return }
        try commitState(next)
    }

    private func validatedFileIDs(_ fileIDs: [UUID]) throws -> [UUID] {
        let known = Set(state.files.map(\.id))
        guard fileIDs.allSatisfy({ known.contains($0) }) else { throw LibraryWorkflowError.unknownFile }
        var seen = Set<UUID>()
        return fileIDs.filter { seen.insert($0).inserted }
    }

    private func validateDestinationGroup(_ groupID: UUID) throws {
        guard let group = group(withID: groupID), !group.isSystemGroup, !group.isArchived else {
            throw LibraryWorkflowError.invalidGroup
        }
    }

    private static func addMemberships(_ fileIDs: [UUID], to groupID: UUID, in state: inout LibraryState) {
        var members = Set(state.memberships.filter { $0.groupID == groupID }.map(\.fileID))
        var nextIndex = (state.memberships.filter { $0.groupID == groupID }.map(\.sortIndex).max() ?? -1) + 1
        for id in fileIDs where members.insert(id).inserted {
            state.memberships.append(GroupMembership(groupID: groupID, fileID: id,
                addedAt: Date(), sortIndex: nextIndex))
            nextIndex += 1
        }
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

    /// Opening is infrequent enough to resolve bookmarks. Keep this fallback
    /// away from page/zoom callbacks and other high-frequency identity lookups.
    func fileForOpening(at url: URL) -> LibraryFile? {
        if let known = file(for: url) { return known }
        let path = url.libraryComparablePath
        return state.files.first {
            $0.bookmarkData != nil && resolvedURL(for: $0).libraryComparablePath == path
        }
    }

    /// Older records may not yet persist their working-copy path. Resolve it
    /// against the stored original path before a bookmark refresh changes it.
    func openingWorkingCopyURL(for file: LibraryFile) -> URL? {
        if let copy = file.workingCopyURL {
            return workingCopyStore?.portableManagedCopyURL(for: copy) ?? copy
        }
        guard let copy = workingCopyStore?.workingCopyURL(forOriginalURL: file.url),
              FileManager.default.fileExists(atPath: copy.path) else { return nil }
        return copy
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

    /// Empty workspaces can own research drafts before any PDF is opened.
    func ensureWindowSession(for groupID: UUID, sessionID: UUID) {
        guard group(withID: groupID) != nil,
              openSession(for: groupID, sessionID: sessionID) == nil else { return }
        state.windowSessions.append(GroupWindowSession(id: sessionID, groupID: groupID))
        persist()
    }

    func recordOpenedFile(_ fileID: UUID, in groupID: UUID?, sessionID: UUID?) {
        recordOpenedFiles([fileID], in: groupID, sessionID: sessionID)
    }

    func recordOpenedFiles(_ fileIDs: [UUID], in groupID: UUID?, sessionID: UUID?) {
        var next = state
        Self.recordOpenedFiles(fileIDs, in: groupID, sessionID: sessionID, state: &next)
        guard next != state else { return }
        state = next
        persist()
    }

    private static func recordOpenedFiles(
        _ fileIDs: [UUID], in groupID: UUID?, sessionID: UUID?, state: inout LibraryState
    ) {
        guard let groupID,
              let sessionID,
              state.groups.contains(where: { $0.id == groupID })
        else {
            return
        }
        let known = Set(state.files.map(\.id))
        var seen = Set<UUID>()
        let ids = fileIDs.filter { known.contains($0) && seen.insert($0).inserted }
        guard let selectedID = ids.last else { return }

        if let index = state.windowSessions.firstIndex(where: {
            $0.id == sessionID && $0.groupID == groupID
        }) {
            var existing = Set(state.windowSessions[index].openFileIDs)
            for id in ids where existing.insert(id).inserted {
                state.windowSessions[index].openFileIDs.append(id)
            }
            state.windowSessions[index].selectedFileID = selectedID
            state.windowSessions[index].updatedAt = Date()
        } else {
            state.windowSessions.append(
                GroupWindowSession(
                    id: sessionID,
                    groupID: groupID,
                    openFileIDs: ids,
                    selectedFileID: selectedID
                )
            )
        }

    }

    private func persist() {
        let stateToPersist = normalizedState(state)
        state = stateToPersist
        _ = persistenceWriter.saveImmediately(stateToPersist)
    }

    private func normalizedState(_ candidate: LibraryState) -> LibraryState {
        var stateToPersist = candidate
        stateToPersist.files = sortedFiles(stateToPersist.files)
        stateToPersist.groups = [LibraryGroup.ungrouped]
            + candidate.groups.filter { !$0.isSystemGroup }.sorted(by: sortGroups)
        stateToPersist.schemaVersion = LibraryState.currentSchemaVersion
        stateToPersist.ensureSystemGroups()
        return stateToPersist
    }

    private func commitState(_ candidate: LibraryState) throws {
        let normalized = normalizedState(candidate)
        do { try persistenceWriter.saveTransactionally(normalized) }
        catch { throw LibraryWorkflowError.persistenceFailed }
        state = normalized
    }

    /// A normal close/quit waits for the latest reading position. A failed write
    /// remains pending so another mutation or flush can retry it.
    @discardableResult
    func flushPendingPersistence() -> Bool {
        persistenceWriter.flush()
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

/// All mutable writer state and all writes use one queue. Ordinary Library
/// mutations and lifecycle flushes wait behind any in-flight reading-position
/// write, so an older snapshot cannot overwrite a newer Library/Group/session.
nonisolated final class LibraryStateWriter: @unchecked Sendable {
    private let queue = DispatchQueue(label: "Dogear.LibraryPersistence", qos: .utility)
    private let delay: TimeInterval
    private let saveState: @Sendable (LibraryState) throws -> Void
    private var pendingState: LibraryState?
    private var scheduledWrite: DispatchWorkItem?
    private var scheduledID: UUID?

    init(delay: TimeInterval, save: @escaping @Sendable (LibraryState) throws -> Void) {
        self.delay = max(0, delay)
        saveState = save
    }

    func saveSoon(_ state: LibraryState) {
        queue.async { [self] in
            pendingState = state
            guard scheduledWrite == nil else { return }
            let id = UUID()
            scheduledID = id
            let work = DispatchWorkItem { [weak self] in
                guard let self, self.scheduledID == id else { return }
                self.scheduledWrite = nil
                self.scheduledID = nil
                _ = self.savePendingState()
            }
            scheduledWrite = work
            // Bound the delay from the first page change; continuous scrolling
            // still checkpoints its latest position instead of deferring forever.
            queue.asyncAfter(deadline: .now() + delay, execute: work)
        }
    }

    func saveImmediately(_ state: LibraryState) -> Bool {
        queue.sync {
            cancelScheduledWrite()
            pendingState = state
            return savePendingState()
        }
    }

    /// A rejected transaction must never remain queued for a later flush. The
    /// previous pending snapshot still belongs to accepted in-memory state.
    func saveTransactionally(_ state: LibraryState) throws {
        try queue.sync {
            cancelScheduledWrite()
            let previousPending = pendingState
            do {
                try saveState(state)
                pendingState = nil
            } catch {
                pendingState = previousPending
                throw error
            }
        }
    }

    func flush() -> Bool {
        queue.sync {
            cancelScheduledWrite()
            return savePendingState()
        }
    }

    private func cancelScheduledWrite() {
        scheduledWrite?.cancel()
        scheduledWrite = nil
        scheduledID = nil
    }

    private func savePendingState() -> Bool {
        guard let pendingState else { return true }
        do {
            try saveState(pendingState)
            self.pendingState = nil
            return true
        } catch {
            // Do not acknowledge failed snapshots: a close/quit or the next
            // mutation can retry the newest complete state.
            return false
        }
    }
}
