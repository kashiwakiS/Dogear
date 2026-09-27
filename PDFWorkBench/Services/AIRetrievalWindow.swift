import Foundation

/// A retrieval-only view over canonical evidence sentences. Windows never cross
/// a document, page, or block. A stride of two preserves every adjacent sentence
/// pair while limiting neighboring windows to one shared sentence. The anchor is
/// always one of the immutable canonical sentence IDs and is the only ID exposed
/// by search; callers can read one sentence of context on either side to recover
/// the complete window without inventing a second locator namespace.
nonisolated struct AIRetrievalWindow: Equatable, Sendable {
    static let profile = "same-block-sentence-window-v1-max-3-stride-2"

    static func indexVersion(segmenterVersion: String) -> String {
        "\(segmenterVersion)|\(profile)"
    }

    let anchorID: AISegmentID
    let records: [AISegmentRecord]

    var segmentIDs: [AISegmentID] { records.map(\.id) }

    var indexRecord: AISegmentRecord {
        precondition(!records.isEmpty)
        let anchor = records.first { $0.id == anchorID } ?? records[0]
        let text = records.map(\.text).joined(separator: " ")
        return AISegmentRecord(
            id: anchorID,
            text: text,
            normalizedText: AISegmenter.normalizeForSearch(text),
            sourceRange: anchor.sourceRange,
            pageFingerprint: anchor.pageFingerprint,
            sourceKind: anchor.sourceKind,
            sourceConfidence: anchor.sourceConfidence
        )
    }

    static func make(records: [AISegmentRecord]) -> [Self] {
        struct BlockKey: Hashable {
            let document: Int
            let page: Int
            let block: Int
        }

        let grouped = Dictionary(grouping: records) {
            BlockKey(document: $0.id.document, page: $0.id.page, block: $0.id.block)
        }
        return grouped.keys.sorted {
            ($0.document, $0.page, $0.block) < ($1.document, $1.page, $1.block)
        }.flatMap { key -> [Self] in
            let block = grouped[key, default: []].sorted { $0.id < $1.id }
            var runs: [[AISegmentRecord]] = []
            for record in block {
                if let previous = runs.last?.last,
                   previous.id.sentence + 1 == record.id.sentence {
                    runs[runs.count - 1].append(record)
                } else {
                    runs.append([record])
                }
            }
            return runs.flatMap { run -> [Self] in
                var result: [Self] = []
                var start = 0
                while start < run.count {
                    let end = min(start + 3, run.count)
                    let members = Array(run[start..<end])
                    // The upper midpoint keeps a trailing two-sentence window's
                    // anchor out of the one-sentence overlap with its predecessor.
                    let anchor = members[members.count / 2].id
                    result.append(Self(anchorID: anchor, records: members))
                    if end == run.count { break }
                    start += 2
                }
                return result
            }
        }
    }

    static func indexRecords(from records: [AISegmentRecord]) -> [AISegmentRecord] {
        make(records: records).map(\.indexRecord)
    }
}
