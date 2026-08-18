import Foundation

enum MarkdownExportService {
    static func annotationsMarkdown(
        documentName: String,
        annotations: [PDFAnnotationItem]
    ) -> String {
        var lines: [String] = [
            "# \(documentName)",
            "",
            "## Annotations",
            ""
        ]

        if annotations.isEmpty {
            lines.append("_No highlights or notes found._")
            return lines.joined(separator: "\n")
        }

        for annotation in annotations {
            lines.append("- Page \(annotation.pageNumber) · \(annotation.kind.rawValue)")
            lines.append("  - \(annotation.displayText)")

            if !annotation.note.isEmpty && annotation.kind != .note {
                lines.append("  - Note: \(annotation.note)")
            }
        }

        return lines.joined(separator: "\n")
    }
}
