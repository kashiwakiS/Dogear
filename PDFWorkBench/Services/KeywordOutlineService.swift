import Foundation

protocol KeywordOutlineProviding {
    func keywordOutlineMarkdown(
        documentName: String,
        annotations: [PDFAnnotationItem]
    ) -> String
}

struct FallbackKeywordOutlineProvider: KeywordOutlineProviding {
    func keywordOutlineMarkdown(
        documentName: String,
        annotations: [PDFAnnotationItem]
    ) -> String {
        let highlights = annotations.filter { $0.kind == .highlight }

        var lines: [String] = [
            "# \(documentName) Highlight Outline",
            "",
            "_Generated without an AI provider. All highlights are grouped by page._",
            ""
        ]

        if highlights.isEmpty {
            lines.append("_No highlights found._")
            return lines.joined(separator: "\n")
        }

        let grouped = Dictionary(grouping: highlights, by: \.pageNumber)

        for pageNumber in grouped.keys.sorted() {
            lines.append("## Page \(pageNumber)")
            lines.append("")

            for highlight in grouped[pageNumber, default: []] {
                lines.append("- \(highlight.displayText)")
            }

            lines.append("")
        }

        return lines.joined(separator: "\n")
    }
}
