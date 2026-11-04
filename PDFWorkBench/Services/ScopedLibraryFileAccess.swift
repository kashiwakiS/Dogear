import Foundation

/// Retains native importer access through asynchronous content validation.
/// Both platform hosts release the same lease on cancellation or completion.
final class ScopedLibraryFileAccess {
    let url: URL
    private let didAccess: Bool
    init(url: URL) {
        self.url = url
        didAccess = url.startAccessingSecurityScopedResource()
    }
    deinit { if didAccess { url.stopAccessingSecurityScopedResource() } }
}
