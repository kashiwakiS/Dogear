import Foundation
import UniformTypeIdentifiers

nonisolated enum ResearchImageFileReadError: Error {
    case unsupported, tooLarge
}

/// Native file URLs only. Importer/drop security access remains alive throughout
/// the bounded read; image decoding and request limits belong to the pipeline.
nonisolated enum ResearchImageFileReader {
    static func read(_ url: URL, maximumBytes: Int) throws -> Data {
        guard url.isFileURL, maximumBytes > 0, maximumBytes < Int.max else {
            throw ResearchImageFileReadError.unsupported
        }
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        let values = try url.resourceValues(forKeys: [.contentTypeKey, .fileSizeKey, .isRegularFileKey])
        guard values.isRegularFile == true, values.contentType?.conforms(to: .image) == true,
              let size = values.fileSize, size >= 0 else { throw ResearchImageFileReadError.unsupported }
        guard size <= maximumBytes else { throw ResearchImageFileReadError.tooLarge }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var data = Data()
        data.reserveCapacity(size)
        while true {
            // The file may grow after its resource values were read. Consume
            // at most the permitted size plus one byte before rejecting it.
            let chunk = try handle.read(upToCount: min(1_048_576, maximumBytes + 1 - data.count)) ?? Data()
            if chunk.isEmpty { return data }
            data.append(chunk)
            guard data.count <= maximumBytes else { throw ResearchImageFileReadError.tooLarge }
        }
    }
}
