import AppKit
import Foundation
import PDFKit

protocol DocumentOutlineProviding {
    @MainActor
    func outline(for document: PDFDocument) async -> [DocumentOutlineEntry]
}

struct DocumentOutlineService: DocumentOutlineProviding {
    @MainActor
    func outline(for document: PDFDocument) async -> [DocumentOutlineEntry] {
        let bookmarks = bookmarkEntries(in: document)
        if !bookmarks.isEmpty {
            return bookmarks
        }

        return await detectedHeadingEntries(in: document)
    }

    @MainActor
    private func bookmarkEntries(in document: PDFDocument) -> [DocumentOutlineEntry] {
        guard let root = document.outlineRoot else {
            return []
        }

        var entries: [DocumentOutlineEntry] = []

        func visit(_ node: PDFOutline, level: Int, path: String) {
            let title = node.label?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !title.isEmpty,
               let destination = resolvedDestination(for: node),
               let page = destination.page {
                let pageIndex = document.index(for: page)
                if pageIndex != NSNotFound {
                    entries.append(
                        DocumentOutlineEntry(
                            id: "bookmark:\(path):\(pageIndex)",
                            title: title,
                            level: min(level, 5),
                            target: PDFNavigationTarget(
                                pageIndex: pageIndex,
                                point: destination.point
                            ),
                            source: .pdfBookmark
                        )
                    )
                }
            }

            for childIndex in 0..<node.numberOfChildren {
                guard let child = node.child(at: childIndex) else {
                    continue
                }
                visit(child, level: level + 1, path: "\(path).\(childIndex)")
            }
        }

        for childIndex in 0..<root.numberOfChildren {
            guard let child = root.child(at: childIndex) else {
                continue
            }
            visit(child, level: 0, path: "\(childIndex)")
        }

        return entries
    }

    @MainActor
    private func resolvedDestination(for outline: PDFOutline) -> PDFDestination? {
        if let destination = outline.destination {
            return destination
        }

        for childIndex in 0..<outline.numberOfChildren {
            if let child = outline.child(at: childIndex),
               let destination = resolvedDestination(for: child) {
                return destination
            }
        }

        return nil
    }

    @MainActor
    private func detectedHeadingEntries(in document: PDFDocument) async -> [DocumentOutlineEntry] {
        var lines: [DetectedLine] = []

        for pageIndex in 0..<document.pageCount {
            guard !Task.isCancelled,
                  let page = document.page(at: pageIndex),
                  let attributedText = page.attributedString,
                  attributedText.length > 0
            else {
                continue
            }

            lines.append(contentsOf: detectedLines(in: attributedText, page: page, pageIndex: pageIndex))

            if pageIndex.isMultiple(of: 8) {
                await Task.yield()
            }
        }

        guard !Task.isCancelled, !lines.isEmpty else {
            return []
        }

        let bodySize = median(lines.map(\.fontSize))
        let pageCount = max(1, document.pageCount)
        let repeatedTextCounts = Dictionary(grouping: lines, by: \.normalizedText)
            .mapValues { Set($0.map(\.pageIndex)).count }

        let candidates = lines.filter { line in
            guard !line.text.isEmpty,
                  line.text.count <= 120,
                  repeatedTextCounts[line.normalizedText, default: 0] < max(3, Int(Double(pageCount) * 0.2))
            else {
                return false
            }

            let hasHeadingSize = line.fontSize >= bodySize * 1.16
            let isNumbered = line.numberingDepth != nil
            let isBoldHeading = line.isBold && line.fontSize >= bodySize * 0.98
            let looksLikeLongSentence = line.text.count > 80
                && line.text.last.map { ".!?。！？".contains($0) } == true

            return (hasHeadingSize || isNumbered || isBoldHeading) && !looksLikeLongSentence
        }

        let significantSizes = Array(Set(candidates.map { roundedFontSize($0.fontSize) }))
            .sorted(by: >)

        return candidates.enumerated().map { index, line in
            let sizeLevel = significantSizes.firstIndex(of: roundedFontSize(line.fontSize)) ?? 0
            let numberingLevel = line.numberingDepth.map { max(0, $0 - 1) }
            let level = min(numberingLevel ?? sizeLevel, 5)

            return DocumentOutlineEntry(
                id: "detected:\(line.pageIndex):\(line.range.location):\(index)",
                title: line.text,
                level: level,
                target: PDFNavigationTarget(
                    pageIndex: line.pageIndex,
                    point: CGPoint(x: line.bounds.minX, y: line.bounds.maxY)
                ),
                source: .detectedHeading
            )
        }
    }

    @MainActor
    private func detectedLines(
        in attributedText: NSAttributedString,
        page: PDFPage,
        pageIndex: Int
    ) -> [DetectedLine] {
        let string = attributedText.string
        let fullText = string as NSString
        var result: [DetectedLine] = []

        string.enumerateSubstrings(
            in: string.startIndex..<string.endIndex,
            options: [.byLines, .substringNotRequired]
        ) { _, lineRange, _, _ in
            let lineRange = NSRange(lineRange, in: string)
            let text = fullText.substring(with: lineRange)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else {
                return
            }

            var largestFontSize: CGFloat = 0
            var isBold = false
            attributedText.enumerateAttribute(
                .font,
                in: lineRange,
                options: []
            ) { value, _, _ in
                guard let font = value as? NSFont else {
                    return
                }
                largestFontSize = max(largestFontSize, font.pointSize)
                isBold = isBold || font.fontDescriptor.symbolicTraits.contains(.bold)
            }

            guard largestFontSize > 0,
                  let selection = page.selection(for: lineRange)
            else {
                return
            }

            let bounds = selection.bounds(for: page)
            guard !bounds.isEmpty else {
                return
            }

            result.append(
                DetectedLine(
                    text: text,
                    normalizedText: normalized(text),
                    pageIndex: pageIndex,
                    range: lineRange,
                    bounds: bounds,
                    fontSize: largestFontSize,
                    isBold: isBold,
                    numberingDepth: numberingDepth(in: text)
                )
            )
        }

        return result
    }

    private func median(_ values: [CGFloat]) -> CGFloat {
        let sorted = values.sorted()
        guard !sorted.isEmpty else {
            return 12
        }
        return sorted[sorted.count / 2]
    }

    private func roundedFontSize(_ value: CGFloat) -> Int {
        Int((value * 2).rounded())
    }

    private func normalized(_ text: String) -> String {
        text.lowercased()
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    private func numberingDepth(in text: String) -> Int? {
        let patterns = [
            #"^\s*(\d+(?:\.\d+){0,5})[\s.)、]+"#,
            #"^\s*([IVXLCDM]+)[\s.)]+"#,
            #"^\s*([一二三四五六七八九十百]+)[、.)\s]+"#
        ]

        for pattern in patterns {
            guard let expression = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
                  let match = expression.firstMatch(
                    in: text,
                    range: NSRange(text.startIndex..., in: text)
                  )
            else {
                continue
            }

            if match.numberOfRanges > 1,
               let range = Range(match.range(at: 1), in: text) {
                return max(1, text[range].filter { $0 == "." }.count + 1)
            }
            return 1
        }

        return nil
    }

    private struct DetectedLine {
        let text: String
        let normalizedText: String
        let pageIndex: Int
        let range: NSRange
        let bounds: CGRect
        let fontSize: CGFloat
        let isBold: Bool
        let numberingDepth: Int?
    }
}
