import Combine
import CoreGraphics
import Foundation

/// Exercises actual scanning and import tasks using generated PDFs and isolated
/// Library storage. No existing Library, original document or window is used.
@MainActor
enum LibraryImportDiagnostics {
    static func run() async -> AIHighlightFoundationDiagnosticReport {
        var checks = 0
        var failures: [String] = []
        func check(_ condition: @autoclosure () -> Bool, _ message: String) {
            checks += 1
            if !condition() { failures.append("Library import: " + message) }
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("DogearImportDiagnostics-\(UUID())")
        let domain = "DogearImportDiagnostics.\(UUID())"
        guard let defaults = UserDefaults(suiteName: domain) else {
            return AIHighlightFoundationDiagnosticReport(checkCount: 1, failures: ["Could not create isolated import defaults."])
        }
        defer {
            defaults.removePersistentDomain(forName: domain)
            try? FileManager.default.removeItem(at: root)
        }
        do {
            let manager = FileManager.default
            let folder = root.appendingPathComponent("Papers", isDirectory: true)
            let nested = folder.appendingPathComponent("Nested", isDirectory: true)
            try manager.createDirectory(at: nested, withIntermediateDirectories: true)
            let pdf = try fixturePDF()
            let first = folder.appendingPathComponent("A.pdf")
            let second = folder.appendingPathComponent("B.PDF")
            let third = nested.appendingPathComponent("C.pdf")
            let hidden = folder.appendingPathComponent(".hidden.pdf")
            let outside = root.appendingPathComponent("Outside.pdf")
            let originals = [first, second, third, hidden, outside]
            for url in originals { try pdf.write(to: url) }
            let invalid = folder.appendingPathComponent("Invalid.pdf")
            let invalidBytes = Data("Not a PDF".utf8)
            try invalidBytes.write(to: invalid)
            let plain = folder.appendingPathComponent("Notes.txt")
            try Data("Keep this text file".utf8).write(to: plain)
            let symbolic = folder.appendingPathComponent("linked.pdf")
            try manager.createSymbolicLink(at: symbolic, withDestinationURL: outside)

            let scan = try await Task.detached { try LibraryImportScanner.scan(folder) { _ in } }.value
            check(Set(scan.urls.map(\.lastPathComponent)) == ["A.pdf", "B.PDF", "C.pdf"],
                  "Nested/case-insensitive scan returned \(scan.urls.map(\.lastPathComponent))")
            check(scan.urls.map(\.path) == scan.urls.map(\.path).sorted(by: { $0.localizedStandardCompare($1) == .orderedAscending }),
                  "Folder import order is not deterministic")
            check(scan.failures.count == 1 && scan.failures.first?.url.resolvingSymlinksInPath().path
                    == invalid.resolvingSymlinksInPath().path,
                  "Invalid PDF failures were \(scan.failures.map { $0.url.path + ": " + $0.reason })")
            check(scan.skipped == 1, "Non-PDF skipped count is incorrect")
            try manager.removeItem(at: symbolic)
            let withoutSymbolic = try LibraryImportScanner.scan(folder) { _ in }
            check(Set(withoutSymbolic.urls.map(\.lastPathComponent)) == ["A.pdf", "B.PDF", "C.pdf"],
                  "Nested PDF scan failed even without a symbolic input")
            try manager.createSymbolicLink(at: symbolic, withDestinationURL: outside)
            let singleScan = try LibraryImportScanner.scan(second) { _ in }
            check(singleScan.urls == [second] && singleScan.failures.isEmpty, "Small direct-file import failed")
            let nonPDF = try LibraryImportScanner.scan(plain) { _ in }
            check(nonPDF.urls.isEmpty && nonPDF.skipped == 1, "A direct non-PDF input was accepted")
            do {
                _ = try LibraryImportScanner.scan(root.appendingPathComponent("missing.pdf")) { _ in }
                check(false, "A missing import path did not fail")
            } catch { check(true, "") }

            let bulk = root.appendingPathComponent("Bulk", isDirectory: true)
            try manager.createDirectory(at: bulk, withIntermediateDirectories: true)
            var bulkURLs: [URL] = []
            for index in 0..<110 {
                let url = bulk.appendingPathComponent(String(format: "%03d.pdf", index))
                try pdf.write(to: url)
                bulkURLs.append(url)
            }
            let cancelledScan = Task.detached {
                try LibraryImportScanner.scan(bulk) { _ in
                    // This callback runs inside the scanner's task, so cancellation
                    // deterministically occurs during enumeration, before PDF reads.
                    withUnsafeCurrentTask { $0?.cancel() }
                }
            }
            do {
                _ = try await cancelledScan.value
                check(false, "Scanner ignored cancellation delivered during enumeration")
            } catch is CancellationError { check(true, "") }
            catch { check(false, "Scanner cancellation became a file error: \(error)") }

            let storage = try LibraryJSONStore(stateURL: root.appendingPathComponent("library.json"))
            let copies = try PDFWorkingCopyStore(directoryURL: root.appendingPathComponent("copies"))
            let library = LibraryStore(userDefaults: defaults, storage: storage, workingCopyStore: copies)
            guard let current = library.createGroup(named: "Current"),
                  let target = library.createGroup(named: "Explicit target") else { throw FixtureError.group }
            let windowID = UUID()
            let importer = LibraryImportController()
            var opened: [(UUID, UUID)] = []
            importer.start(urls: [first, second], library: library, groupID: current.id,
                           sessionID: windowID, assignToGroup: false) { opened.append(($0.id, $1)) }
            try await waitUntilFinished(importer)
            check(importer.completed == 2 && importer.total == 2 && importer.failures.isEmpty && !importer.cancelled,
                  "Small multi-file import did not complete cleanly")
            check(importer.isVisible && !importer.isRunning && !importer.isScanning,
                  "Completed import did not retain its summary or clear running state")
            check(library.state.files.count == 2 && library.state.memberships.isEmpty,
                  "Opening files in a window silently changed persistent Group membership")
            let expectedWindowPaths = Set([first, second].map { $0.resolvingSymlinksInPath().path })
            let expectedWindowIDs = library.state.files.filter { expectedWindowPaths.contains($0.canonicalPath) }.map(\.id)
            let session = library.state.windowSessions.first { $0.id == windowID && $0.groupID == current.id }
            check(Set(session?.openFileIDs ?? []) == Set(expectedWindowIDs),
                  "Multi-file opening did not preserve the temporary window file list")
            check(opened.count == 1 && opened.first?.1 == current.id
                  && library.state.files.first(where: { $0.id == opened.first!.0 })?.url == first.resolvingSymlinksInPath(),
                  "Import did not request the first file in the captured window Group")
            check(library.state.files.allSatisfy { $0.originalSHA256 != nil && $0.workingCopyPath == nil },
                  "Import omitted source fingerprints or created working copies before editing")
            importer.dismiss()
            check(!importer.isVisible, "Completed import summary cannot be dismissed")

            let beforeExistingIDs = Set(library.state.files.map(\.id))
            importer.start(urls: [first, third], library: library, groupID: target.id,
                           sessionID: UUID(), assignToGroup: true) { _, _ in }
            try await waitUntilFinished(importer)
            check(Set(library.files(in: target.id).map(\.url)) == Set([first, third].map { $0.resolvingSymlinksInPath() }),
                  "Explicit Group import did not add all selected files")
            check(beforeExistingIDs.isSubset(of: Set(library.state.files.map(\.id))) && library.state.files.count == 3,
                  "Reimport changed an existing file identity or duplicated its record")
            check(library.files(in: current.id).isEmpty, "Explicit import added membership to the current reading Group")
            check(library.state.windowSessions.count == 1, "Explicit Group import created an unintended temporary session")

            let overlapAlias = folder.appendingPathComponent("Nested/../A.pdf")
            importer.start(urls: [first, first, overlapAlias], library: library, groupID: current.id,
                           sessionID: windowID, assignToGroup: false) { _, _ in }
            try await waitUntilFinished(importer)
            check(library.state.files.count == 3, "Overlapping paths duplicated a Library file")
            check(importer.completed == 1 && importer.total == 1,
                  "Overlapping paths were counted as multiple imported files")
            check(library.state.memberships.count == 2, "Overlapping ordinary opens changed existing memberships")

            importer.start(urls: [folder], library: library, groupID: current.id,
                           sessionID: UUID(), assignToGroup: false) { _, _ in }
            try await waitUntilFinished(importer)
            let importedGroup = library.userGroups.first { $0.name == "Papers" }
            check(importedGroup != nil && library.files(in: importedGroup!.id).count == 3,
                  "Folder Group contains \(importedGroup.map { library.files(in: $0.id).count } ?? -1) files, expected 3")
            check(importer.completed == 3 && importer.failures.count == 1 && importer.skipped == 1,
                  "Folder summary is \(importer.completed) completed, \(importer.failures.count) failed, \(importer.skipped) skipped")
            check(library.files(in: current.id).isEmpty && library.files(in: target.id).count == 2,
                  "Folder import changed unrelated memberships")

            importer.start(urls: [folder, nested], library: library, groupID: current.id,
                           sessionID: UUID(), assignToGroup: false) { _, _ in }
            try await waitUntilFinished(importer)
            check(library.state.files.count == 3 && importer.completed == 3 && importer.total == 3,
                  "Overlapping folder roots duplicated imported file records or progress counts")

            let immediate = LibraryImportController()
            let stateBeforeCancel = library.state
            var openedOnCancel = false
            immediate.start(urls: [bulk], library: library, groupID: current.id,
                            sessionID: UUID(), assignToGroup: false) { _, _ in openedOnCancel = true }
            immediate.cancel()
            try await waitUntilFinished(immediate)
            check(immediate.cancelled && immediate.completed == 0 && immediate.failures.isEmpty,
                  "Immediate cancellation was treated as a file failure or imported content")
            check(library.state == stateBeforeCancel && !openedOnCancel,
                  "Cancelling before scan changed Library state or opened a file")

            let batchImport = LibraryImportController()
            let batchSessionID = UUID()
            var openedAfterBatchCancel = false
            let subscription = batchImport.$completed.sink { count in
                if count >= 24 { batchImport.cancel() }
            }
            batchImport.start(urls: [bulk], library: library, groupID: current.id,
                              sessionID: batchSessionID, assignToGroup: false) { _, _ in openedAfterBatchCancel = true }
            try await waitUntilFinished(batchImport)
            withExtendedLifetime(subscription) {}
            let batchGroup = library.userGroups.first { $0.name == "Bulk" }
            check(batchImport.cancelled && batchImport.completed == 24 && !batchImport.isRunning,
                  "Cancellation after a completed batch did not stop later batches")
            check(batchGroup != nil && library.files(in: batchGroup!.id).count == 24,
                  "Batch cancellation discarded completed imports or kept processing the remaining files")
            check(batchImport.failures.isEmpty, "User cancellation was reported as a failed file")
            check(!openedAfterBatchCancel, "A cancelled import retained its reader-open capability")

            let rejected = LibraryImportController()
            let stateBeforeRejection = library.state
            rejected.start(urls: [first], library: library, groupID: current.id,
                           sessionID: UUID(), assignToGroup: true, mayContinue: { false }) { _, _ in
                check(false, "A closed import capability opened a reader")
            }
            check(!rejected.isVisible && !rejected.isRunning && library.state == stateBeforeRejection,
                  "A request with a revoked capability scanned or changed the Library")
            rejected.start(urls: [first], library: library, groupID: UUID(),
                           sessionID: UUID(), assignToGroup: true) { _, _ in
                check(false, "An unknown Group import opened a reader")
            }
            check(!rejected.isVisible && !rejected.isRunning && library.state == stateBeforeRejection,
                  "An import into a missing Group created Library records")

            let revoked = LibraryImportController()
            var capabilityIsLive = true
            var openedAfterRevocation = false
            let revokedSubscription = revoked.$completed.sink { count in
                if count >= 24 { capabilityIsLive = false }
            }
            revoked.start(urls: [bulk], library: library, groupID: current.id,
                          sessionID: UUID(), assignToGroup: true, mayContinue: { capabilityIsLive }) { _, _ in
                openedAfterRevocation = true
            }
            try await waitUntilFinished(revoked)
            withExtendedLifetime(revokedSubscription) {}
            check(revoked.cancelled && revoked.completed == 24 && revoked.failures.isEmpty,
                  "Revoking an import capability did not stop at the completed batch")
            check(!openedAfterRevocation, "Revoked scene import opened a reader after its batch completed")

            guard let deletedOrigin = library.createGroup(named: "Deleted origin") else { throw FixtureError.group }
            let deleted = LibraryImportController()
            var openedAfterGroupDeletion = false
            let deletedSubscription = deleted.$completed.sink { count in
                if count >= 24 { _ = library.deleteGroup(deletedOrigin) }
            }
            deleted.start(urls: [bulk], library: library, groupID: deletedOrigin.id,
                          sessionID: UUID(), assignToGroup: true) { _, _ in openedAfterGroupDeletion = true }
            try await waitUntilFinished(deleted)
            withExtendedLifetime(deletedSubscription) {}
            check(deleted.cancelled && deleted.completed == 24 && deleted.failures.isEmpty,
                  "Deleting the originating Group allowed later folder-import batches")
            check(!openedAfterGroupDeletion && library.group(withID: deletedOrigin.id) == nil,
                  "A deleted Group import reopened a reader or recreated the Group")
            let stored = try storage.load()
            check(stored?.files.map(\.id) == library.state.files.map(\.id)
                  && Set(stored?.memberships.map { "\($0.groupID):\($0.fileID):\($0.sortIndex)" } ?? [])
                    == Set(library.state.memberships.map { "\($0.groupID):\($0.fileID):\($0.sortIndex)" }),
                  "Completed imports or cancelled-batch state did not survive JSON readback")
            let originalsPreserved = try originals.allSatisfy { try Data(contentsOf: $0) == pdf }
                  && bulkURLs.allSatisfy { try Data(contentsOf: $0) == pdf }
                  && Data(contentsOf: invalid) == invalidBytes
            check(originalsPreserved,
                  "Scanning/import/cancellation rewrote an original input")
            let copyFiles = manager.fileExists(atPath: copies.directoryURL.path)
                ? try manager.contentsOfDirectory(at: copies.directoryURL, includingPropertiesForKeys: nil) : []
            check(copyFiles.isEmpty, "Import created editable PDF copies")
        } catch { check(false, "Fixture failed: \(error)") }
        return AIHighlightFoundationDiagnosticReport(checkCount: checks, failures: failures)
    }

    private enum FixtureError: Error { case pdf, group, timedOut }

    private static func fixturePDF() throws -> Data {
        let data = NSMutableData()
        var mediaBox = CGRect(x: 0, y: 0, width: 240, height: 320)
        guard let consumer = CGDataConsumer(data: data as CFMutableData),
              let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else { throw FixtureError.pdf }
        context.beginPDFPage(nil)
        context.setFillColor(CGColor(gray: 0.2, alpha: 1))
        context.fill(CGRect(x: 20, y: 250, width: 160, height: 30))
        context.endPDFPage(); context.closePDF()
        return data as Data
    }

    private static func waitUntilFinished(_ controller: LibraryImportController) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while controller.isRunning {
            if ContinuousClock.now >= deadline { controller.cancel(); throw FixtureError.timedOut }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}
