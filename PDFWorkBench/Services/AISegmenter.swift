import Foundation

nonisolated struct AISegmenter: Sendable {
    static let currentVersion = "punctuation-v5"

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
        // ICU regular expressions use \x{...} for scalar escapes. The prior
        // raw-string \u{00A0} form was rejected by Foundation and silently
        // collapsed every page into one block.
        let pattern = #"(?:\r?\n)[\t \x{00A0}]*(?:\r?\n)+"#
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
            if isSentencePunctuation(unit), shouldSplit(
                at: index,
                unit: unit,
                in: source,
                sentenceStart: start,
                limit: limit
            ) {
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
        sentenceStart: Int,
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
        let token = tokenBeforePeriod(at: index, in: source).lowercased()
        if Self.protectedAbbreviations.contains(token) {
            return false
        }
        if token.count == 1,
           isPersonInitialEnding(
               at: index,
               in: source,
               sentenceStart: sentenceStart,
               limit: limit
           ) {
            return false
        }
        if token.count == 1 && token.unicodeScalars.allSatisfy(CharacterSet.letters.contains),
           isDottedAbbreviationEnding(at: index, in: source)
        {
            return false
        }
        // Preserve domains and compact alphabetic tokens, but do not merge a
        // complete sentence with a directly attached numeric citation such as
        // "result.6 Next". Decimal numbers were handled above.
        if previous.map(isASCIILetter) == true && next.map(isASCIILetter) == true {
            return false
        }
        return true
    }

    /// Preserve a capitalized personal initial before a capitalized surname
    /// (`J. Smith`, `Ada J. Smith`, `according to J. Smith`) while still ending
    /// explicit technical labels such as `model A.`. A bare single letter is
    /// never treated as an abbreviation without a following name-shaped token.
    private func isPersonInitialEnding(
        at index: Int,
        in source: NSString,
        sentenceStart: Int,
        limit: Int
    ) -> Bool {
        guard index > 0, isASCIIUppercase(source.character(at: index - 1)) else {
            return false
        }
        var next = index + 1
        while next < limit && isWhitespace(source.character(at: next)) { next += 1 }
        guard next < limit, isASCIIUppercase(source.character(at: next)) else {
            return false
        }
        var surnameEnd = next + 1
        while surnameEnd < limit && isASCIILetter(source.character(at: surnameEnd)) {
            surnameEnd += 1
        }
        let nextIsInitial = surnameEnd - next == 1
            && surnameEnd < limit
            && source.character(at: surnameEnd) == 0x002E
        guard surnameEnd - next >= 2 || nextIsInitial else { return false }

        var previous = index - 2
        while previous >= sentenceStart && isWhitespace(source.character(at: previous)) {
            previous -= 1
        }
        guard previous >= sentenceStart else { return true }
        if isSentencePunctuation(source.character(at: previous)) { return true }
        guard isASCIILetter(source.character(at: previous)) else { return false }
        var priorStart = previous
        while priorStart > sentenceStart && isASCIILetter(source.character(at: priorStart - 1)) {
            priorStart -= 1
        }
        let priorWord = source.substring(
            with: NSRange(location: priorStart, length: previous - priorStart + 1)
        ).lowercased()
        return !Self.technicalLabelWords.contains(priorWord)
    }

    private func tokenBeforePeriod(at index: Int, in source: NSString) -> String {
        var start = index
        while start > 0 && isASCIILetter(source.character(at: start - 1)) {
            start -= 1
        }
        return source.substring(with: NSRange(location: start, length: index - start))
    }

    /// Keeps the final period in dotted abbreviations such as `U.S.` and
    /// `i.e.` without treating every single-letter technical label as an
    /// abbreviation (`model A.`, `equation 2a.`).
    private func isDottedAbbreviationEnding(at index: Int, in source: NSString) -> Bool {
        guard index >= 3,
              isASCIILetter(source.character(at: index - 1)),
              source.character(at: index - 2) == 0x002E,
              isASCIILetter(source.character(at: index - 3))
        else { return false }
        return true
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

    private func isASCIIUppercase(_ unit: unichar) -> Bool {
        (0x0041...0x005A).contains(unit)
    }

    private func isASCIIDigit(_ unit: unichar) -> Bool {
        (0x0030...0x0039).contains(unit)
    }

    private static let protectedAbbreviations: Set<String> = [
        "approx", "dr", "e.g", "etc", "fig", "i.e", "mr", "mrs", "ms",
        "no", "prof", "sec", "sr", "st", "vs"
    ]

    private static let technicalLabelWords: Set<String> = [
        "algorithm", "appendix", "case", "class", "condition", "dataset",
        "equation", "figure", "group", "model", "panel", "sample",
        "section", "table", "type", "variant", "version"
    ]
}
