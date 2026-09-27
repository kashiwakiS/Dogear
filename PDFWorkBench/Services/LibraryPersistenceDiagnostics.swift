import AppKit
import Foundation

/// Disposable storage only; no real Library data or PDF is opened.
@MainActor
enum LibraryPersistenceDiagnostics {
    static func run() async -> (checks: Int, failures: [String]) {
        var checks = 0
        var failures: [String] = []
        func check(_ condition: Bool, _ message: String) {
            checks += 1
            if !condition { failures.append(message) }
        }
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("LibraryPersistenceDiagnostics-\(UUID().uuidString)")
        let domain = "Dogear.LibraryPersistenceDiagnostics.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: domain) else {
            return (1, ["Could not create isolated Library defaults."])
        }
        defer {
            try? FileManager.default.removeItem(at: root)
            defaults.removePersistentDomain(forName: domain)
        }

        do {
            let storage = try LibraryJSONStore(stateURL: root.appendingPathComponent("library.json"))
            let fileURL = root.appendingPathComponent("source.pdf")
            let file = LibraryFile(displayName: "source.pdf", canonicalPath: fileURL.path)
            try storage.save(LibraryState(files: [file]))
            let notifications = NotificationCenter()
            var library: LibraryStore? = LibraryStore(userDefaults: defaults, storage: storage,
                readingPositionSaveDelay: 60)
            let lifecycle = library.map { LibraryMacLifecycleAdapter(library: $0, notificationCenter: notifications) }
            defer { withExtendedLifetime(lifecycle) {} }

            for page in 1...100 { library?.updateLastPage(for: fileURL, pageIndex: page) }
            let diskBeforeFlush = try storage.load()
            check(library?.state.files.first?.lastPageIndex == 100
                    && diskBeforeFlush?.files.first?.lastPageIndex == 0,
                  "Page callbacks did not update memory immediately while deferring disk writes.")

            let group = library?.createGroup(named: "Must survive old page snapshots")
            let mutationState = try storage.load()
            check(mutationState?.files.first?.lastPageIndex == 100
                    && mutationState?.groups.contains(where: { $0.id == group?.id }) == true,
                  "An immediate Group mutation lost the newest pending reading position or group.")

            library?.updateLastPage(for: fileURL, pageIndex: 101)
            notifications.post(name: NSWindow.willCloseNotification, object: nil)
            check((try storage.load())?.files.first?.lastPageIndex == 101,
                  "Closing a window did not synchronously flush the latest pending page.")
            library?.updateLastPage(for: fileURL, pageIndex: 102)
            notifications.post(name: NSApplication.willTerminateNotification, object: nil)
            check((try storage.load())?.files.first?.lastPageIndex == 102,
                  "Application termination did not synchronously flush the latest pending page.")

            try Data().write(to: fileURL)
            let aliasURL = root.appendingPathComponent("alias.pdf")
            try FileManager.default.createSymbolicLink(at: aliasURL, withDestinationURL: fileURL)
            library?.updateLastPage(for: aliasURL, pageIndex: 103)
            let aliasFlushed = library?.flushPendingPersistence()
            let aliasState = try storage.load()
            check(aliasFlushed == true && aliasState?.files.first?.lastPageIndex == 103,
                  "The reading-position fast path lost the existing symlink identity fallback.")
            library?.updateLastPage(for: fileURL, pageIndex: -5)
            check(library?.state.files.first?.lastPageIndex == 0,
                  "Deferred persistence stopped clamping negative reading positions.")
            library?.updateLastPage(for: fileURL, pageIndex: 104)
            library = nil
            check((try storage.load())?.files.first?.lastPageIndex == 104,
                  "Releasing a LibraryStore discarded its pending reading position.")

            let writerStorage = try LibraryJSONStore(stateURL: root.appendingPathComponent("writer.json"))
            let probe = SaveProbe(storage: writerStorage)
            let writer = LibraryStateWriter(delay: 60, save: probe.save)
            var snapshot = LibraryState(files: [file])
            for page in 1...100 {
                snapshot.files[0].lastPageIndex = page
                writer.saveSoon(snapshot)
            }
            let burstFlushed = writer.flush()
            let burstState = try writerStorage.load()
            check(burstFlushed && probe.writeCount == 1 && burstState?.files.first?.lastPageIndex == 100,
                  "A page burst was not coalesced into one write of its newest snapshot.")

            snapshot.files[0].lastPageIndex = 105
            writer.saveSoon(snapshot)
            snapshot.groups.append(LibraryGroup(name: "Newest", sortIndex: 1))
            let mutationSaved = writer.saveImmediately(snapshot)
            let mutationFlushed = writer.flush()
            let writerMutationState = try writerStorage.load()
            let mutationMatches = try storedStateMatches(writerMutationState, snapshot)
            check(mutationSaved && mutationFlushed
                    && mutationMatches && probe.writeCount == 2,
                  "A stale delayed page snapshot overwrote a newer non-reading mutation.")

            probe.failNextWrite = true
            snapshot.files[0].lastPageIndex = 106
            writer.saveSoon(snapshot)
            let failedFlush = writer.flush()
            let recoveredFlush = writer.flush()
            let recoveredState = try writerStorage.load()
            check(!failedFlush && recoveredFlush && recoveredState?.files.first?.lastPageIndex == 106,
                  "A failed Library write was acknowledged or could not retry the latest snapshot.")

            // The actual delayed path must save without a lifecycle flush.
            let delayedProbe = SaveProbe(storage: writerStorage)
            let delayed = LibraryStateWriter(delay: 0.01, save: delayedProbe.save)
            snapshot.files[0].lastPageIndex = 107
            delayed.saveSoon(snapshot)
            for _ in 0..<50 {
                if (try writerStorage.load())?.files.first?.lastPageIndex == 107 { break }
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            check((try writerStorage.load())?.files.first?.lastPageIndex == 107
                    && delayedProbe.allWritesOffMain,
                  "The delayed reading-position checkpoint never saved on its background queue.")
            _ = delayed.flush()

            // Hold an old write in flight while queuing a later Library mutation.
            // The immediate writer must wait, then leave the newer state on disk.
            let started = DispatchSemaphore(value: 0)
            let release = DispatchSemaphore(value: 0)
            let orderedWriter = LibraryStateWriter(delay: 0) { state in
                if state.files.first?.lastPageIndex == 108 {
                    started.signal()
                    _ = release.wait(timeout: .now() + 1)
                }
                try writerStorage.save(state)
            }
            snapshot.files[0].lastPageIndex = 108
            orderedWriter.saveSoon(snapshot)
            let didStart = await withCheckedContinuation { continuation in
                DispatchQueue.global().async {
                    continuation.resume(returning: started.wait(timeout: .now() + 1) == .success)
                }
            }
            snapshot.files[0].lastPageIndex = 109
            snapshot.preferences.firstOpenAssignment = .ungrouped
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.02) { release.signal() }
            let orderedSaved = orderedWriter.saveImmediately(snapshot)
            let orderedFlushed = orderedWriter.flush()
            let orderedState = try writerStorage.load()
            let orderedMatches = try storedStateMatches(orderedState, snapshot)
            check(didStart && orderedSaved && orderedFlushed && orderedMatches,
                  "An in-flight old page write overwrote a later Library preference/page snapshot.")
        } catch {
            check(false, "Library persistence fixture failed: \(error.localizedDescription)")
        }
        return (checks, failures)
    }

    private static func storedStateMatches(_ actual: LibraryState?, _ expected: LibraryState) throws -> Bool {
        guard let actual else { return false }
        // Preserve the full-state ordering/mutation assertion, comparing dates
        // with the same second precision as LibraryJSONStore's ISO-8601 format.
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(actual) == encoder.encode(expected)
    }

    /// The production writer serializes access; the lock also lets the test
    /// inspect a completed background checkpoint without racing its bookkeeping.
    private nonisolated final class SaveProbe: @unchecked Sendable {
        private let storage: LibraryJSONStore
        private let lock = NSLock()
        private var writes = 0
        private var offMain = true
        private var shouldFail = false

        init(storage: LibraryJSONStore) { self.storage = storage }
        var writeCount: Int { lock.withLock { writes } }
        var allWritesOffMain: Bool { lock.withLock { offMain } }
        var failNextWrite: Bool {
            get { lock.withLock { shouldFail } }
            set { lock.withLock { shouldFail = newValue } }
        }

        func save(_ state: LibraryState) throws {
            let fail = lock.withLock {
                offMain = offMain && !Thread.isMainThread
                if shouldFail {
                    shouldFail = false
                    return true
                }
                writes += 1
                return false
            }
            if fail { throw CocoaError(.fileWriteUnknown) }
            try storage.save(state)
        }
    }
}
