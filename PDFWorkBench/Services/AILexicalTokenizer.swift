import Foundation

/// Deterministic lexical tokenization shared by indexing and queries.
///
/// The profile deliberately avoids locale-sensitive word segmentation. Latin,
/// numeric and other non-CJK alphanumeric runs retain a small set of technical
/// connectors. Han, kana and Hangul scalars are emitted as individual tokens;
/// this is the explicit dictionary-free CJK baseline for this index version.
nonisolated struct AILexicalTokenizer: Equatable, Sendable {
    static let currentVersion = "lexical-nfkc-technical-cjk-unit-v1"

    let version: String

    init(version: String = Self.currentVersion) {
        self.version = version
    }

    func tokens(_ text: String) -> [String] {
        let normalized = text
            .precomposedStringWithCompatibilityMapping
            .folding(
                options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
                locale: Locale(identifier: "en_US_POSIX")
            )
            .precomposedStringWithCanonicalMapping
        let scalars = Array(normalized.unicodeScalars)
        var result: [String] = []
        var current = ""

        func flush() {
            guard !current.isEmpty else { return }
            result.append(current)
            current.removeAll(keepingCapacity: true)
        }

        for (offset, scalar) in scalars.enumerated() {
            if Self.isCJKUnit(scalar.value) {
                flush()
                result.append(String(scalar))
                continue
            }
            if Self.isTokenBody(scalar) {
                current.unicodeScalars.append(scalar)
                continue
            }
            if Self.isCombiningMark(scalar), !current.isEmpty {
                current.unicodeScalars.append(scalar)
                continue
            }
            if let connector = Self.canonicalConnector(scalar), !current.isEmpty,
               Self.shouldRetain(connector: connector, after: offset, in: scalars)
            {
                current.append(connector)
                continue
            }
            flush()
        }
        flush()
        return result
    }

    private static func isTokenBody(_ scalar: Unicode.Scalar) -> Bool {
        CharacterSet.alphanumerics.contains(scalar)
    }

    private static func isCombiningMark(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.properties.generalCategory {
        case .nonspacingMark, .spacingMark, .enclosingMark:
            return true
        default:
            return false
        }
    }

    private static func canonicalConnector(_ scalar: Unicode.Scalar) -> Character? {
        switch scalar.value {
        case 0x002D, 0x2010, 0x2011, 0x2212: "-"
        case 0x005F: "_"
        case 0x002B: "+"
        case 0x0023: "#"
        case 0x002E: "."
        case 0x002F: "/"
        default: nil
        }
    }

    private static func shouldRetain(
        connector: Character,
        after offset: Int,
        in scalars: [Unicode.Scalar]
    ) -> Bool {
        let next = scalars.indices.contains(offset + 1) ? scalars[offset + 1] : nil
        switch connector {
        case "+", "#":
            // Preserve suffix operators in identifiers such as C++ and C# as
            // well as infix forms. A connector can never start a token because
            // the caller requires a nonempty current token.
            return true
        default:
            // Hyphen, underscore, dot and slash are retained only internally,
            // so surrounding prose punctuation cannot become part of a token.
            return next.map { isTokenBody($0) && !isCJKUnit($0.value) } ?? false
        }
    }

    private static func isCJKUnit(_ value: UInt32) -> Bool {
        switch value {
        case 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF,
             0x20000...0x2A6DF, 0x2A700...0x2B73F, 0x2B740...0x2B81F,
             0x2B820...0x2CEAF, 0x2CEB0...0x2EBEF, 0x2F800...0x2FA1F,
             0x3040...0x309F, 0x30A0...0x30FF, 0x31F0...0x31FF,
             0x1100...0x11FF, 0x3130...0x318F, 0xAC00...0xD7AF:
            return true
        default:
            return false
        }
    }
}
