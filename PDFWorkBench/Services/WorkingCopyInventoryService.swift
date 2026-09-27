import Foundation

nonisolated enum WorkingCopyInventoryStatus: String, Codable, Sendable {
    case available, missing, unassociated, protected, unsafeReference
}

nonisolated struct WorkingCopyInventoryItem: Identifiable, Sendable {
    let id: String
    let url: URL
    let fileIDs: [UUID]
    let displayNames: [String]
    let missingOriginalFileIDs: [UUID]
    let sizeBytes: Int64?
    let modifiedAt: Date?
    let status: WorkingCopyInventoryStatus

    let managedDirectoryURL: URL
    let readStamp: PDFFileReadStamp?
}

/// Disk inventory only. Being absent from Library does not establish that a
/// copy has no live writer; native hosts pass their pending/active destinations.
/// The service deliberately has no deletion or automatic-cleanup API.
nonisolated enum WorkingCopyInventoryService {
    static func scan(
        directoryURL: URL,
        files: [LibraryFile],
        originalURLs: [UUID: URL] = [:],
        protectedURLs: Set<URL> = []
    ) async throws -> [WorkingCopyInventoryItem] {
        let worker = Task.detached(priority: .utility) {
            try readInventory(directoryURL: directoryURL, files: files,
                originalURLs: originalURLs, protectedURLs: protectedURLs)
        }
        return try await withTaskCancellationHandler {
            let items = try await worker.value
            try Task.checkCancellation()
            return items
        } onCancel: { worker.cancel() }
    }

    /// Recovery creates a user-selected independent copy. Importing that copy
    /// through the ordinary open workflow gives it a new Library identity.
    /// Associated/protected copies must export through DocumentAccessCoordinator
    /// so the latest authorized in-memory edits, including failed saves, win.
    @discardableResult
    static func exportUnassociatedCopy(_ item: WorkingCopyInventoryItem, to destinationURL: URL) async throws -> URL {
        let worker = Task.detached(priority: .utility) {
            try Task.checkCancellation()
            guard item.status == .unassociated, item.fileIDs.isEmpty,
                  let expected = item.readStamp,
                  isManagedRegularFile(item.url, directoryURL: item.managedDirectoryURL),
                  try PDFOriginalIdentityService.currentStamp(at: item.url) == expected else {
                throw LibraryWorkflowError.unsafeWorkingCopy
            }
            guard destinationURL.isFileURL,
                  destinationURL.resolvingSymlinksInPath().standardizedFileURL.path != expected.canonicalPath else {
                throw LibraryWorkflowError.destinationExists
            }
            let accessing = destinationURL.startAccessingSecurityScopedResource()
            defer { if accessing { destinationURL.stopAccessingSecurityScopedResource() } }
            let manager = FileManager.default
            guard (try? manager.attributesOfItem(atPath: destinationURL.path)) == nil else {
                throw LibraryWorkflowError.destinationExists
            }
            // Exclusive creation prevents replacing an existing destination even
            // if another process creates it after the preceding check.
            try Data().write(to: destinationURL, options: .withoutOverwriting)
            let created = try PDFOriginalIdentityService.currentStamp(at: destinationURL)
            do {
                let source = try FileHandle(forReadingFrom: item.url)
                defer { try? source.close() }
                let output = try FileHandle(forWritingTo: destinationURL)
                defer { try? output.close() }
                var copied: Int64 = 0
                while true {
                    try Task.checkCancellation()
                    guard let bytes = try source.read(upToCount: 1_048_576), !bytes.isEmpty else { break }
                    try output.write(contentsOf: bytes)
                    copied += Int64(bytes.count)
                }
                try output.synchronize()
                try Task.checkCancellation()
                guard try PDFOriginalIdentityService.currentStamp(at: item.url) == expected,
                      copied == expected.size else {
                    throw LibraryWorkflowError.changedWhileReading
                }
            } catch {
                // Only remove the output this operation created, never an output
                // another process has since changed/replaced.
                if let current = try? PDFOriginalIdentityService.currentStamp(at: destinationURL),
                   current.fileNumber == created.fileNumber,
                   current.fileSystemNumber == created.fileSystemNumber,
                   current.createdAt == created.createdAt {
                    try? manager.removeItem(at: destinationURL)
                }
                throw error
            }
            return destinationURL
        }
        return try await withTaskCancellationHandler {
            try await worker.value
        } onCancel: { worker.cancel() }
    }

    private static func readInventory(
        directoryURL: URL, files: [LibraryFile], originalURLs: [UUID: URL], protectedURLs: Set<URL>
    ) throws -> [WorkingCopyInventoryItem] {
        let manager = FileManager.default
        let root = directoryURL.resolvingSymlinksInPath().standardizedFileURL
        let copyStore = try PDFWorkingCopyStore(directoryURL: root)
        var urlsByPath: [String: URL] = [:]
        var associations: [String: [LibraryFile]] = [:]
        var unavailableOriginals = Set<UUID>()
        let originalPaths = Set(files.map { file in
            (originalURLs[file.id] ?? file.url).resolvingSymlinksInPath().standardizedFileURL.path
        })
        let protected = Set(protectedURLs.map { $0.resolvingSymlinksInPath().standardizedFileURL.path })

        for file in files {
            try Task.checkCancellation()
            let recorded = file.workingCopyURL
            let legacy = copyStore.workingCopyURL(forOriginalURL: file.url)
            guard let copyURL = recorded ?? (manager.fileExists(atPath: legacy.path) ? legacy : nil) else { continue }
            let key = inventoryPath(copyURL)
            urlsByPath[key] = copyURL
            associations[key, default: []].append(file)
            let originalURL = originalURLs[file.id] ?? file.url
            let accessing = originalURL.startAccessingSecurityScopedResource()
            let isAvailable = (try? originalURL.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
            if accessing { originalURL.stopAccessingSecurityScopedResource() }
            if !isAvailable { unavailableOriginals.insert(file.id) }
        }
        if manager.fileExists(atPath: root.path) {
            for url in try manager.contentsOfDirectory(at: root,
                includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey], options: [.skipsHiddenFiles])
                where url.pathExtension.lowercased() == "pdf" {
                try Task.checkCancellation()
                urlsByPath[inventoryPath(url)] = url
            }
        }
        for url in protectedURLs {
            urlsByPath[inventoryPath(url)] = url
        }

        return try urlsByPath.keys.sorted().map { key in
            try Task.checkCancellation()
            let url = urlsByPath[key]!
            let associated = (associations[key] ?? []).sorted { $0.id.uuidString < $1.id.uuidString }
            let attributes = try? manager.attributesOfItem(atPath: url.path)
            let exists = attributes != nil
            let canonical = url.resolvingSymlinksInPath().standardizedFileURL.path
            let refersToOriginal = originalPaths.contains(canonical)
            let safeLocation = isManagedLocation(url, directoryURL: root) && !refersToOriginal
            let safeFile = !exists || isManagedRegularFile(url, directoryURL: root)
            let status: WorkingCopyInventoryStatus
            if !safeLocation || !safeFile || associated.count > 1 { status = .unsafeReference }
            else if protected.contains(canonical) { status = .protected }
            else if !exists { status = .missing }
            else { status = associated.isEmpty ? .unassociated : .available }
            let stamp = safeLocation && exists && safeFile ? try? PDFOriginalIdentityService.currentStamp(at: url) : nil
            return WorkingCopyInventoryItem(id: key, url: url, fileIDs: associated.map(\.id),
                displayNames: associated.map(\.displayName),
                missingOriginalFileIDs: associated.filter { unavailableOriginals.contains($0.id) }.map(\.id),
                sizeBytes: (attributes?[.size] as? NSNumber)?.int64Value,
                modifiedAt: attributes?[.modificationDate] as? Date,
                status: status, managedDirectoryURL: root, readStamp: stamp)
        }
    }

    private static func isManagedLocation(_ url: URL, directoryURL: URL) -> Bool {
        url.isFileURL && url.deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL
            == directoryURL.resolvingSymlinksInPath().standardizedFileURL
    }

    /// Resolve directory aliases such as /tmp, but do not follow a final symlink
    /// and accidentally present it as a separate unassociated regular file.
    private static func inventoryPath(_ url: URL) -> String {
        url.deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL
            .appendingPathComponent(url.lastPathComponent).path
    }

    private static func isManagedRegularFile(_ url: URL, directoryURL: URL) -> Bool {
        guard isManagedLocation(url, directoryURL: directoryURL),
              let attributes = try? FileManager.default.attributesOfItem(atPath: url.path) else { return false }
        return attributes[.type] as? FileAttributeType == .typeRegular
    }
}
