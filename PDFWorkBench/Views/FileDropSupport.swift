import AppKit
import UniformTypeIdentifiers

enum FileDropSupport {
    static func loadFileURLs(
        from providers: [NSItemProvider],
        completion: @escaping ([URL]) -> Void
    ) -> Bool {
        let fileProviders = providers.filter {
            $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier)
        }

        guard !fileProviders.isEmpty else {
            return false
        }

        let group = DispatchGroup()
        let lock = NSLock()
        var indexedURLs: [(Int, URL)] = []

        for (index, provider) in fileProviders.enumerated() {
            group.enter()
            provider.loadItem(
                forTypeIdentifier: UTType.fileURL.identifier,
                options: nil
            ) { item, _ in
                defer { group.leave() }

                guard let url = fileURL(from: item) else {
                    return
                }

                lock.lock()
                indexedURLs.append((index, url))
                lock.unlock()
            }
        }

        group.notify(queue: .main) {
            completion(indexedURLs.sorted { $0.0 < $1.0 }.map(\.1))
        }

        return true
    }

    private static func fileURL(from item: NSSecureCoding?) -> URL? {
        if let url = item as? URL {
            return url
        }

        if let data = item as? Data {
            return URL(dataRepresentation: data, relativeTo: nil)
        }

        if let string = item as? String {
            return URL(string: string)
        }

        return nil
    }
}

enum PDFImportScanner {
    static func pdfURLs(in folderURL: URL) -> [URL] {
        let resourceKeys: [URLResourceKey] = [.isRegularFileKey, .isDirectoryKey]
        guard let enumerator = FileManager.default.enumerator(
            at: folderURL,
            includingPropertiesForKeys: resourceKeys,
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            return []
        }

        var urls: [URL] = []
        for case let url as URL in enumerator where url.isPDFFileURL {
            if (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true {
                urls.append(url)
            }
        }

        return urls.sorted {
            $0.path.localizedStandardCompare($1.path) == .orderedAscending
        }
    }
}
