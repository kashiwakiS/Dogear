import Foundation

final class PDFSaveQueue {
    static let shared = PDFSaveQueue()

    private let fileManager: FileManager
    private let queue = DispatchQueue(label: "com.pdfworkbench.pdf-save-queue", qos: .utility)
    private let group = DispatchGroup()

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    func enqueue(
        data: Data,
        to destinationURL: URL,
        completion: @escaping @MainActor (Result<URL, Error>) -> Void
    ) {
        group.enter()
        queue.async { [fileManager, group] in
            let result: Result<URL, Error>

            do {
                try fileManager.createDirectory(
                    at: destinationURL.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try data.write(to: destinationURL, options: [.atomic])
                result = .success(destinationURL)
            } catch {
                result = .failure(error)
            }

            group.leave()
            Task { @MainActor in
                completion(result)
            }
        }
    }

    func waitUntilDrained() {
        group.wait()
    }
}
