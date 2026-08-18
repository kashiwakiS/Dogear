import Foundation

extension URL {
    var libraryComparablePath: String {
        resolvingSymlinksInPath().standardizedFileURL.path
    }

    var isDirectoryURL: Bool {
        (try? resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
    }
}
