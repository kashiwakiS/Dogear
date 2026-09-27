import Foundation

enum MarkdownExportService {
    static func annotationsMarkdown(
        documentName: String,
        annotations: [PDFAnnotationItem]
    ) -> String {
        var lines: [String] = [
            "# \(escapeLiteral(documentName))",
            "",
            "## Annotations",
            ""
        ]

        if annotations.isEmpty {
            lines.append("_No highlights or notes found._")
            return lines.joined(separator: "\n")
        }

        for annotation in annotations {
            lines.append("### Page \(annotation.pageNumber) · \(annotation.kind.rawValue)")
            lines.append("")
            if !annotation.text.isEmpty {
                lines.append(contentsOf: quotedLines(annotation.text))
                lines.append("")
            }
            if !annotation.note.isEmpty {
                if annotation.kind == .highlight { lines.append("**Comment**"); lines.append("") }
                lines.append(contentsOf: quotedLines(annotation.note))
                lines.append("")
            }
            if annotation.text.isEmpty && annotation.note.isEmpty {
                lines.append("_No text._")
                lines.append("")
            }
        }

        return lines.joined(separator: "\n")
    }

    private static func quotedLines(_ text: String) -> [String] {
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n")
        return lines.enumerated().map { index, line in
            let continuesParagraph = !line.isEmpty && index + 1 < lines.count
                && !lines[index + 1].isEmpty
            return "> \(escapeLiteral(line))" + (continuesParagraph ? "  " : "")
        }
    }

    private static func escapeLiteral(_ text: String) -> String {
        text.reduce(into: "") { result, character in
            if "\\`*_[]<>#".contains(character) { result.append("\\") }
            result.append(character)
        }
    }
}
