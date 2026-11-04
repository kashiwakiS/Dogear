import CryptoKit
import Foundation

/// Storage mechanics only. Each annotation kind keeps its own PDF identity and
/// matching rules. Existing schema-1 sidecars and filenames are unchanged.
@MainActor
protocol AnnotationDraftRecord {
    var schema: Int { get }
    var fileID: UUID { get }
    var draftID: UUID { get }
    var pageIndex: Int { get }
    var updatedAt: Date { get }
    var completed: Bool { get set }
    var recoveryText: String { get }
}

struct AnnotationDraftCandidate: Identifiable {
    var id: URL { url }
    let url: URL
    let fileID: UUID
    let digest: SHA256.Digest
    let pageIndex: Int?
    let updatedAt: Date?
    let text: String?
}

@MainActor
enum AnnotationDraftFiles {
    struct Entry<Record> {
        let candidate: AnnotationDraftCandidate
        let record: Record?
    }

    /// Never chooses a winner or removes another owner's record. An unreadable
    /// same-file filename participates in the conflict, including other windows.
    static func scan<Record: AnnotationDraftRecord & Decodable>(_ type: Record.Type, directory: URL,
                                                     fileID: UUID) throws -> [Entry<Record>] {
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        let urls = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        var entries: [Entry<Record>] = []
        for url in urls {
            let data: Data
            do { data = try Data(contentsOf: url) }
            catch {
                if url.lastPathComponent.hasSuffix("-\(fileID.uuidString).json") { throw error }
                continue
            }
            let record = try? JSONDecoder().decode(Record.self, from: data)
            guard record?.fileID == fileID || (record == nil && url.lastPathComponent.hasSuffix("-\(fileID.uuidString).json")) else { continue }
            guard record?.completed != true || record?.schema != 1 else { continue }
            entries.append(.init(candidate: .init(url: url, fileID: fileID, digest: SHA256.hash(data: data),
                pageIndex: record?.pageIndex, updatedAt: record?.updatedAt, text: record?.recoveryText), record: record))
        }
        return entries
    }

    static func unchanged(_ candidate: AnnotationDraftCandidate) -> Bool {
        guard let data = try? Data(contentsOf: candidate.url) else { return false }
        return SHA256.hash(data: data) == candidate.digest
    }

    static func write<Record: Encodable>(_ record: Record, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(record).write(to: url, options: .atomic)
    }

    /// A thrown error means completion was NOT durable. A returned cleanup error
    /// means replay is already prevented; callers must still display that error.
    static func complete<Record: AnnotationDraftRecord & Encodable>(_ record: Record, at url: URL) throws -> (record: Record, cleanupError: String?) {
        var completed = record
        completed.completed = true
        try write(completed, to: url)
        do {
            try FileManager.default.removeItem(at: url)
            return (completed, nil)
        } catch { return (completed, error.localizedDescription) }
    }
}
