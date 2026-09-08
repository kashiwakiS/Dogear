import Foundation

/// BGE Small EN's BERT uncased BasicTokenizer + WordPiece contract.
/// Kept local/offline; parity fixtures are generated with the pinned upstream tokenizer.
nonisolated struct AIBertWordPieceTokenizer: Sendable {
    static let version = "bert-uncased-wordpiece-v1"
    private let vocabulary: [String: Int32]
    private let specialTokens = ["[UNK]", "[SEP]", "[PAD]", "[CLS]", "[MASK]"]

    init(vocabulary text: String) throws {
        let words = text.components(separatedBy: "\n").filter { !$0.isEmpty }
        guard words.count == 30_522, Set(words).count == words.count else {
            throw AIRetrievalError.invalidModel
        }
        vocabulary = Dictionary(uniqueKeysWithValues: words.enumerated().map { ($0.element, Int32($0.offset)) })
        guard vocabulary["[PAD]"] == 0, vocabulary["[UNK]"] == 100,
              vocabulary["[CLS]"] == 101, vocabulary["[SEP]"] == 102 else {
            throw AIRetrievalError.invalidModel
        }
    }

    func tokens(_ text: String) -> [Int32] {
        // Added special tokens are recognized before lowercasing/basic splitting.
        var remainder = text[...]
        var result: [Int32] = []
        while !remainder.isEmpty {
            let match = specialTokens.compactMap { token -> (String, Range<String.Index>)? in
                remainder.range(of: token).map { (token, $0) }
            }.min { $0.1.lowerBound < $1.1.lowerBound }
            guard let (token, range) = match else {
                result += basicTokens(String(remainder)); break
            }
            result += basicTokens(String(remainder[..<range.lowerBound]))
            result.append(vocabulary[token]!)
            remainder = remainder[range.upperBound...]
        }
        return result
    }

    private func basicTokens(_ text: String) -> [Int32] {
        var cleaned = ""
        for scalar in text.unicodeScalars {
            let value = scalar.value
            let category = scalar.properties.generalCategory
            if value == 9 || value == 10 || value == 13 || category == .spaceSeparator {
                cleaned.append(" ")
            } else if value == 0 || value == 0xFFFD || [.control, .format, .privateUse, .surrogate, .unassigned].contains(category) {
                continue
            } else if Self.isCJK(value) {
                cleaned.append(" "); cleaned.unicodeScalars.append(scalar); cleaned.append(" ")
            } else {
                cleaned.unicodeScalars.append(scalar)
            }
        }
        var result: [Int32] = []
        for word in cleaned.split(separator: " ") {
            let normalized = String(word).lowercased().decomposedStringWithCanonicalMapping
            var current = ""
            func flush() {
                if !current.isEmpty { result += wordPieces(current); current = "" }
            }
            for scalar in normalized.unicodeScalars {
                if scalar.properties.generalCategory == .nonspacingMark { continue }
                let v = scalar.value
                let punctuation = (33...47).contains(v) || (58...64).contains(v)
                    || (91...96).contains(v) || (123...126).contains(v)
                    || CharacterSet.punctuationCharacters.contains(scalar)
                if punctuation {
                    flush(); result += wordPieces(String(scalar))
                } else {
                    current.unicodeScalars.append(scalar)
                }
            }
            flush()
        }
        return result
    }

    private func wordPieces(_ word: String) -> [Int32] {
        let scalars = Array(word.unicodeScalars)
        guard scalars.count <= 100 else { return [100] }
        var start = 0
        var output: [Int32] = []
        while start < scalars.count {
            var end = scalars.count
            var found: Int32?
            while start < end {
                let part = String(String.UnicodeScalarView(scalars[start..<end]))
                if let id = vocabulary[(start == 0 ? "" : "##") + part] { found = id; break }
                end -= 1
            }
            guard let found else { return [100] }
            output.append(found); start = end
        }
        return output
    }

    private static func isCJK(_ v: UInt32) -> Bool {
        [(0x4E00...0x9FFF), (0x3400...0x4DBF), (0x20000...0x2A6DF),
         (0x2A700...0x2B73F), (0x2B740...0x2B81F), (0x2B820...0x2CEAF),
         (0xF900...0xFAFF), (0x2F800...0x2FA1F)].contains { $0.contains(v) }
    }
}
