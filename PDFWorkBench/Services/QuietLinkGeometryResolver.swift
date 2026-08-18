import Foundation
import PDFKit

enum QuietLinkGeometryResolver {
    static func rects(for annotation: PDFAnnotation, on page: PDFPage) -> [NSRect] {
        let fallback = [annotation.bounds]
        guard annotation.type == "Link",
              let url = (annotation.action as? PDFActionURL)?.url ?? annotation.url,
              let pageText = page.string as NSString?,
              let selection = page.selection(for: annotation.bounds),
              selection.numberOfTextRanges(on: page) > 0,
              let visibleText = selection.string
        else {
            return fallback
        }

        let compactVisibleText = removingWhitespace(from: visibleText)
        let targetText = url.absoluteString
        let compactTargetText = removingWhitespace(from: targetText)
        guard !compactVisibleText.isEmpty,
              compactTargetText.hasPrefix(compactVisibleText),
              compactVisibleText != compactTargetText
        else {
            return fallback
        }

        let selectionRange = selection.range(at: 0, on: page)
        guard selectionRange.location != NSNotFound,
              selectionRange.location < pageText.length,
              let characterIndices = matchedCharacterIndices(
                for: targetText as NSString,
                in: pageText,
                near: selectionRange
              )
        else {
            return fallback
        }

        var lineRects = lineRects(for: characterIndices, on: page)
        guard lineRects.count > 1,
              let firstIntersectingIndex = lineRects.firstIndex(where: {
                $0.intersects(annotation.bounds.insetBy(dx: -2, dy: -2))
              })
        else {
            return fallback
        }

        lineRects[firstIntersectingIndex] = lineRects[firstIntersectingIndex].union(annotation.bounds)
        return lineRects.map { $0.insetBy(dx: -0.75, dy: -0.5) }
    }

    private static func matchedCharacterIndices(
        for targetText: NSString,
        in pageText: NSString,
        near selectionRange: NSRange
    ) -> [Int]? {
        guard targetText.length > 0 else {
            return nil
        }

        let searchEnd = min(pageText.length, NSMaxRange(selectionRange))
        for candidateIndex in selectionRange.location..<searchEnd {
            guard pageText.character(at: candidateIndex) == targetText.character(at: 0) else {
                continue
            }

            if let match = match(
                targetText: targetText,
                in: pageText,
                startingAt: candidateIndex
            ) {
                return match
            }
        }

        return nil
    }

    private static func match(
        targetText: NSString,
        in pageText: NSString,
        startingAt startIndex: Int
    ) -> [Int]? {
        var pageIndex = startIndex
        var targetIndex = 0
        var consecutiveWhitespaceCount = 0
        var matchedIndices: [Int] = []

        while pageIndex < pageText.length, targetIndex < targetText.length {
            let pageCharacter = pageText.character(at: pageIndex)
            if isWhitespace(pageCharacter) {
                consecutiveWhitespaceCount += 1
                guard consecutiveWhitespaceCount <= 4 else {
                    return nil
                }
                pageIndex += 1
                continue
            }

            consecutiveWhitespaceCount = 0
            guard pageCharacter == targetText.character(at: targetIndex) else {
                return nil
            }

            matchedIndices.append(pageIndex)
            pageIndex += 1
            targetIndex += 1
        }

        return targetIndex == targetText.length ? matchedIndices : nil
    }

    private static func lineRects(for characterIndices: [Int], on page: PDFPage) -> [NSRect] {
        guard let firstCharacterIndex = characterIndices.first,
              let lastCharacterIndex = characterIndices.last,
              let matchedSelection = page.selection(
                for: NSRange(
                    location: firstCharacterIndex,
                    length: lastCharacterIndex - firstCharacterIndex + 1
                )
              )
        else {
            return []
        }

        return matchedSelection.selectionsByLine()
            .map { $0.bounds(for: page) }
            .filter { !$0.isEmpty && $0.width > 0 && $0.height > 0 }
    }

    private static func removingWhitespace(from text: String) -> String {
        String(text.filter { !$0.isWhitespace })
    }

    private static func isWhitespace(_ character: unichar) -> Bool {
        guard let scalar = UnicodeScalar(character) else {
            return false
        }

        return CharacterSet.whitespacesAndNewlines.contains(scalar)
    }
}
