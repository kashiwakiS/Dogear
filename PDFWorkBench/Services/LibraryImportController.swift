import Foundation
import Combine
import CoreGraphics

nonisolated struct LibraryImportFailure: Identifiable, Sendable {
    var id: String { url.path }
    let url: URL
    let reason: String
}

nonisolated struct LibraryImportScan: Sendable {
    var urls: [URL] = []
    var failures: [LibraryImportFailure] = []
    var skipped = 0
}

/// File enumeration and PDF validation do not construct or share PDFKit objects.
nonisolated enum LibraryImportScanner {
    static func scan(_ root: URL, progress: @Sendable (Int) -> Void) throws -> LibraryImportScan {
        var result = LibraryImportScan()
        let manager = FileManager.default
        let isDirectory = try root.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true
        var candidates: [URL] = []
        if isDirectory {
            guard let enumerator = manager.enumerator(at: root,
                includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants], errorHandler: { url, error in
                    result.failures.append(.init(url: url, reason: error.localizedDescription))
                    return true
                }) else { throw CocoaError(.fileReadUnknown) }
            for case let url as URL in enumerator {
                try Task.checkCancellation()
                let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                if values?.isSymbolicLink == true { continue }
                guard values?.isRegularFile == true else { continue }
                if url.pathExtension.lowercased() == "pdf" { candidates.append(url) }
                else { result.skipped += 1 }
                if (candidates.count + result.skipped).isMultiple(of: 100) { progress(candidates.count) }
            }
        } else { candidates = [root] }
        var seen = Set<String>()
        for url in candidates.sorted(by: { $0.path.localizedStandardCompare($1.path) == .orderedAscending }) {
            try Task.checkCancellation()
            guard url.pathExtension.lowercased() == "pdf" else { result.skipped += 1; continue }
            guard seen.insert(url.resolvingSymlinksInPath().standardizedFileURL.path).inserted else {
                result.skipped += 1; continue
            }
            guard let pdf = CGPDFDocument(url as CFURL), pdf.numberOfPages > 0 else {
                result.failures.append(.init(url: url, reason: "Could not read this PDF.")); continue
            }
            result.urls.append(url)
            if result.urls.count.isMultiple(of: 50) { progress(result.urls.count) }
        }
        return result
    }
}

@MainActor
final class LibraryImportController: ObservableObject {
    @Published private(set) var isVisible = false
    @Published private(set) var isRunning = false
    @Published private(set) var isScanning = false
    @Published private(set) var found = 0
    @Published private(set) var completed = 0
    @Published private(set) var total = 0
    @Published private(set) var skipped = 0
    @Published private(set) var cancelled = false
    @Published private(set) var failures: [LibraryImportFailure] = []
    private var task: Task<Void, Never>?
    private var generation = UUID()

    func start(urls: [URL], library: LibraryStore, groupID: UUID, sessionID: UUID,
               assignToGroup: Bool, onOpen: @escaping (LibraryFile, UUID) -> Void) {
        guard !isRunning, !urls.isEmpty else { return }
        isVisible = true; isRunning = true; isScanning = true
        found = 0; completed = 0; total = 0; skipped = 0; cancelled = false; failures = []
        let token = UUID(); generation = token
        let scoped = urls.filter { $0.startAccessingSecurityScopedResource() }
        task = Task { [weak self] in
            guard let self else { scoped.forEach { $0.stopAccessingSecurityScopedResource() }; return }
            defer {
                scoped.forEach { $0.stopAccessingSecurityScopedResource() }
                self.isRunning = false; self.isScanning = false; self.task = nil
            }
            var firstOpen: (LibraryFile, UUID)?
            var countedPaths = Set<String>()
            var completedIDs = Set<UUID>()
            for url in urls {
                do {
                    try Task.checkCancellation()
                    self.isScanning = true
                    self.found = 0
                    let scanTask = Task.detached(priority: .userInitiated) { [self] in
                        try LibraryImportScanner.scan(url) { count in
                            Task { @MainActor in
                                guard self.generation == token, self.isRunning else { return }
                                self.found = count
                            }
                        }
                    }
                    let scan = try await withTaskCancellationHandler(operation: {
                        try await scanTask.value
                    }, onCancel: { scanTask.cancel() })
                    try Task.checkCancellation()
                    self.failures.append(contentsOf: scan.failures)
                    self.skipped += scan.skipped
                    for candidate in scan.urls {
                        if countedPaths.insert(candidate.libraryComparablePath).inserted { self.total += 1 }
                        else { self.skipped += 1 }
                    }
                    self.isScanning = false
                    let folder = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
                    let destination: UUID
                    if folder {
                        guard let group = library.createImportedFolderGroup(named: url.lastPathComponent) else {
                            throw CocoaError(.fileWriteUnknown)
                        }
                        destination = group.id
                    } else { destination = groupID }
                    for start in stride(from: 0, to: scan.urls.count, by: 24) {
                        try Task.checkCancellation()
                        let batch = Array(scan.urls[start..<min(start + 24, scan.urls.count)])
                        let files = library.upsertOpenedURLs(batch, groupID: nil, sessionID: sessionID)
                        if folder || (assignToGroup && destination != LibraryGroup.ungroupedID) {
                            _ = try library.addFiles(files.map(\.id), to: destination)
                        }
                        if !assignToGroup || folder {
                            library.recordOpenedFiles(files.map(\.id), in: destination, sessionID: sessionID)
                        }
                        let newlyCompleted = files.filter { completedIDs.insert($0.id).inserted }
                        self.completed += newlyCompleted.count
                        if firstOpen == nil, let first = files.first { firstOpen = (first, destination) }
                        for file in newlyCompleted {
                            try Task.checkCancellation()
                            do { try await library.captureOriginalFingerprint(for: file.id) }
                            catch is CancellationError { throw CancellationError() }
                            catch { self.failures.append(.init(url: file.url, reason: error.localizedDescription)) }
                        }
                        await Task.yield()
                    }
                } catch is CancellationError { self.cancelled = true; break }
                catch { self.failures.append(.init(url: url, reason: error.localizedDescription)) }
            }
            if Task.isCancelled { self.cancelled = true }
            if let (file, group) = firstOpen { onOpen(file, group) }
        }
    }

    func cancel() { task?.cancel() }
    func dismiss() { if !isRunning { isVisible = false } }
}
