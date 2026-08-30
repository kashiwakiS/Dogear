import Foundation

nonisolated struct AISegmenter: Sendable {
    static let currentVersion = "punctuation-v1"

    let version: String

    init(version: String = AISegmenter.currentVersion) {
        self.version = version
    }

    func segments(
        from snapshot: AIHighlightTextSnapshot,
        documentNumber: Int = 1
    ) -> [AISegmentRecord] {
        snapshot.pages
            .sorted { $0.pageNumber < $1.pageNumber }
            .flatMap { page in
                segments(from: page, documentNumber: documentNumber)
            }
    }

    static func normalizeForSearch(_ text: String) -> String {
        let folded = text.folding(
            options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
            locale: Locale(identifier: "en_US_POSIX")
        )
        let scalars = folded.unicodeScalars.map { scalar -> Character in
            if CharacterSet.alphanumerics.contains(scalar) {
                return Character(String(scalar))
            }
            return " "
        }
        return String(scalars)
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }

    private func segments(
        from page: AITextPageSnapshot,
        documentNumber: Int
    ) -> [AISegmentRecord] {
        guard page.pageNumber > 0, documentNumber > 0 else { return [] }
        let source = page.text as NSString
        return blockRanges(in: source).enumerated().flatMap { blockOffset, blockRange in
            sentenceRanges(in: source, blockRange: blockRange).enumerated().map {
                sentenceOffset, sentenceRange in
                let text = source.substring(with: sentenceRange)
                return AISegmentRecord(
                    id: AISegmentID(
                        document: documentNumber,
                        page: page.pageNumber,
                        block: blockOffset + 1,
                        sentence: sentenceOffset + 1
                    ),
                    text: text,
                    normalizedText: Self.normalizeForSearch(text),
                    sourceRange: AISourceTextRange(
                        location: sentenceRange.location,
                        length: sentenceRange.length
                    ),
                    pageFingerprint: page.fingerprint,
                    sourceKind: page.sourceKind,
                    sourceConfidence: page.sourceConfidence
                )
            }
        }
    }

    private func blockRanges(in source: NSString) -> [NSRange] {
        guard source.length > 0 else { return [] }
        let pattern = #"(?:\r?\n)[\t \u{00A0}]*(?:\r?\n)+"#
        guard let expression = try? NSRegularExpression(pattern: pattern) else {
            return nonemptyRange(NSRange(location: 0, length: source.length), in: source)
                .map { [$0] } ?? []
        }

        var result: [NSRange] = []
        var location = 0
        for match in expression.matches(
            in: source as String,
            range: NSRange(location: 0, length: source.length)
        ) {
            let candidate = NSRange(location: location, length: match.range.location - location)
            if let range = nonemptyRange(candidate, in: source) {
                result.append(range)
            }
            location = match.range.location + match.range.length
        }

        let remainder = NSRange(location: location, length: source.length - location)
        if let range = nonemptyRange(remainder, in: source) {
            result.append(range)
        }
        return result
    }

    private func sentenceRanges(in source: NSString, blockRange: NSRange) -> [NSRange] {
        let limit = blockRange.location + blockRange.length
        var start = blockRange.location
        var index = start
        var result: [NSRange] = []

        while index < limit {
            let unit = source.character(at: index)
            if isSentencePunctuation(unit), shouldSplit(at: index, unit: unit, in: source, limit: limit) {
                var end = index + 1
                while end < limit && isTrailingSentenceUnit(source.character(at: end)) {
                    end += 1
                }
                let candidate = NSRange(location: start, length: end - start)
                if let range = nonemptyRange(candidate, in: source) {
                    result.append(range)
                }
                start = end
                index = end
            } else {
                index += 1
            }
        }

        if start < limit,
           let range = nonemptyRange(NSRange(location: start, length: limit - start), in: source)
        {
            result.append(range)
        }
        return result
    }

    private func shouldSplit(
        at index: Int,
        unit: unichar,
        in source: NSString,
        limit: Int
    ) -> Bool {
        guard unit == 0x002E else { return true }

        let previous = index > 0 ? source.character(at: index - 1) : nil
        let next = index + 1 < limit ? source.character(at: index + 1) : nil
        if previous.map(isASCIIDigit) == true && next.map(isASCIIDigit) == true {
            return false
        }
        if next == 0x002E {
            return false
        }
        if previous == 0x002E {
            return next != 0x002E
        }
        if previous.map(isASCIIAlphanumeric) == true && next.map(isASCIIAlphanumeric) == true {
            return false
        }

        let token = tokenBeforePeriod(at: index, in: source).lowercased()
        if Self.protectedAbbreviations.contains(token) {
            return false
        }
        if token.count == 1 && token.unicodeScalars.allSatisfy(CharacterSet.letters.contains) {
            return false
        }
        return true
    }

    private func tokenBeforePeriod(at index: Int, in source: NSString) -> String {
        var start = index
        while start > 0 && isASCIILetter(source.character(at: start - 1)) {
            start -= 1
        }
        return source.substring(with: NSRange(location: start, length: index - start))
    }

    private func nonemptyRange(_ range: NSRange, in source: NSString) -> NSRange? {
        var lower = range.location
        var upper = range.location + range.length
        while lower < upper && isWhitespace(source.character(at: lower)) {
            lower += 1
        }
        while upper > lower && isWhitespace(source.character(at: upper - 1)) {
            upper -= 1
        }
        guard lower < upper else { return nil }
        return NSRange(location: lower, length: upper - lower)
    }

    private func isSentencePunctuation(_ unit: unichar) -> Bool {
        unit == 0x002E || unit == 0x003F || unit == 0x0021
            || unit == 0x3002 || unit == 0xFF1F || unit == 0xFF01
    }

    private func isTrailingSentenceUnit(_ unit: unichar) -> Bool {
        isSentencePunctuation(unit)
            || unit == 0x0022 || unit == 0x0027
            || unit == 0x2019 || unit == 0x201D
            || unit == 0x3009 || unit == 0x300B || unit == 0x300D
            || unit == 0x300F || unit == 0x3011 || unit == 0x3015
            || unit == 0x0029 || unit == 0x005D || unit == 0x007D
    }

    private func isWhitespace(_ unit: unichar) -> Bool {
        guard let scalar = UnicodeScalar(unit) else { return false }
        return CharacterSet.whitespacesAndNewlines.contains(scalar)
    }

    private func isASCIIAlphanumeric(_ unit: unichar) -> Bool {
        isASCIILetter(unit) || isASCIIDigit(unit)
    }

    private func isASCIILetter(_ unit: unichar) -> Bool {
        (0x0041...0x005A).contains(unit) || (0x0061...0x007A).contains(unit)
    }

    private func isASCIIDigit(_ unit: unichar) -> Bool {
        (0x0030...0x0039).contains(unit)
    }

    private static let protectedAbbreviations: Set<String> = [
        "approx", "dr", "e.g", "etc", "fig", "i.e", "mr", "mrs", "ms",
        "no", "prof", "sec", "sr", "st", "vs"
    ]
}
