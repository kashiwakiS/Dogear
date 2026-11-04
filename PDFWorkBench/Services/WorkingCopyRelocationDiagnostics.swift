import Foundation

/// Recreates an OS sandbox move with isolated Library state and actual files.
@MainActor
enum WorkingCopyRelocationDiagnostics {
    static func run() throws -> (checks: Int, failures: [String]) {
        var checks = 0
        var failures: [String] = []
        func check(_ condition: Bool, _ message: String) {
            checks += 1
            if !condition { failures.append(message) }
        }
        let manager = FileManager.default
        let root = manager.temporaryDirectory.appendingPathComponent("DogearCopyRelocation-\(UUID())")
        let domain = "DogearCopyRelocation.\(UUID())"
        guard let defaults = UserDefaults(suiteName: domain) else {
            return (1, ["Could not create isolated relocation defaults."])
        }
        defer {
            defaults.removePersistentDomain(forName: domain)
            try? manager.removeItem(at: root)
        }
        let suffix = "Library/Application Support/PDFWorkBench/WorkingCopies"
        let oldRoot = root.appendingPathComponent("old-container")
        let newRoot = root.appendingPathComponent("new-container")
        let oldCopies = try PDFWorkingCopyStore(directoryURL: oldRoot.appendingPathComponent(suffix))
        let newCopies = try PDFWorkingCopyStore(directoryURL: newRoot.appendingPathComponent(suffix))
        try manager.createDirectory(at: newCopies.directoryURL, withIntermediateDirectories: true)
        let original = root.appendingPathComponent("original.pdf")
        let originalBytes = Data("unchanged original".utf8)
        try originalBytes.write(to: original)
        let oldCopy = oldCopies.workingCopyURL(forOriginalURL: original)
        let relocated = newCopies.directoryURL.appendingPathComponent(oldCopy.lastPathComponent)
        let editedBytes = Data("retained standard annotation bytes".utf8)
        try editedBytes.write(to: relocated)
        var file = LibraryFile(displayName: "original.pdf", canonicalPath: original.path,
                               workingCopyPath: oldCopy.path)
        file.lastPageIndex = 3
        let storage = try LibraryJSONStore(stateURL: newRoot.appendingPathComponent("library.json"))
        try storage.save(LibraryState(files: [file]))
        let library = LibraryStore(userDefaults: defaults, storage: storage, workingCopyStore: newCopies)
        let restored = library.allFiles.first
        check(restored?.id == file.id && restored?.canonicalPath == file.canonicalPath,
              "Sandbox relocation changed the document identity or original location.")
        check(restored?.workingCopyURL?.libraryComparablePath == relocated.libraryComparablePath,
              "Library did not restore the existing managed copy in the new container.")
        let persisted = try storage.load()
        check(restored?.lastPageIndex == 3 && persisted?.files.first?.workingCopyURL?.libraryComparablePath == relocated.libraryComparablePath,
              "Relocation was not persisted with the latest reading state.")
        check(library.openingWorkingCopyURL(for: file)?.libraryComparablePath == relocated.libraryComparablePath,
              "A captured pre-relocation Library record did not resolve the retained copy.")
        let savedOriginal = try Data(contentsOf: original)
        let savedCopy = try Data(contentsOf: relocated)
        check(savedOriginal == originalBytes && savedCopy == editedBytes,
              "Location restoration rewrote source or edited-copy bytes.")
        let missing = oldCopies.workingCopyURL(forOriginalURL: root.appendingPathComponent("absent-source.pdf"))
        check(newCopies.relocatedManagedCopyURL(for: missing) == nil,
              "A missing managed copy was fabricated instead of retained for recovery.")
        let rebasedMissing = newCopies.portableManagedCopyURL(for: missing)
        check(rebasedMissing?.deletingLastPathComponent().libraryComparablePath == newCopies.directoryURL.libraryComparablePath
              && rebasedMissing.map { !manager.fileExists(atPath: $0.path) } == true,
              "A pending first edit cannot retain a missing portable destination without creating bytes.")
        let external = root.appendingPathComponent("external/\(oldCopy.lastPathComponent)")
        check(newCopies.relocatedManagedCopyURL(for: external) == nil,
              "An external same-name path was silently adopted as an app-owned copy.")
        let nonManagedStore = try PDFWorkingCopyStore(directoryURL: root.appendingPathComponent("external"))
        check(nonManagedStore.relocatedManagedCopyURL(for: oldCopy) == nil,
              "A non-managed store inferred relocation by file name.")
        let linkedOld = oldCopies.workingCopyURL(forOriginalURL: root.appendingPathComponent("linked-source.pdf"))
        let linkedNew = newCopies.directoryURL.appendingPathComponent(linkedOld.lastPathComponent)
        try manager.createSymbolicLink(at: linkedNew, withDestinationURL: original)
        check(newCopies.portableManagedCopyURL(for: linkedOld) == nil,
              "A symbolic-link candidate was adopted during sandbox restoration.")
        try manager.createDirectory(at: oldCopies.directoryURL, withIntermediateDirectories: true)
        try Data("existing recorded location".utf8).write(to: oldCopy)
        check(newCopies.relocatedManagedCopyURL(for: oldCopy) == nil,
              "An existing explicit copy was replaced by a same-name candidate.")
        var externalFile = file
        externalFile.workingCopyPath = external.path
        try storage.save(LibraryState(files: [externalFile]))
        let externalLibrary = LibraryStore(userDefaults: defaults, storage: storage, workingCopyStore: newCopies)
        check(externalLibrary.allFiles.first?.workingCopyPath == external.path,
              "Reload lost a missing external copy's explicit recovery location.")
        return (checks, failures)
    }
}
