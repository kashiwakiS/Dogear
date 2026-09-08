import Foundation

/// The no-provider Ask path is a deterministic document index, not an AI
/// summary. It reuses the reader's bookmark/local-heading entries and reports
/// native-text availability without making claims about document content.
@MainActor
enum AILocalOutlineFallback {
    static func answer(
        documentName: String,
        snapshot: AIHighlightTextSnapshot,
        entries: [DocumentOutlineEntry]
    ) throws -> AIPublishedAnswer {
        try Task.checkCancellation()
        let title = L10n.string("Local structural outline")
        let explanation = L10n.string(
            "Generated on this device from PDF bookmarks or detected headings. This is not an AI summary; no document content was sent to a provider."
        )
        let textPageCount = snapshot.pages.filter {
            !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }.count
        let characterCount = snapshot.pages.reduce(0) { $0 + $1.text.count }
        var lines = [
            "# \(escaped(documentName))",
            "",
            explanation,
            "",
            "- \(L10n.string("Pages: \(snapshot.pages.count)"))",
            "- \(L10n.string("Selectable-text pages: \(textPageCount)"))",
            "- \(L10n.string("Native-text characters: \(characterCount)"))"
        ]
        let pageNumbers = Set(snapshot.pages.map(\.pageNumber))
        let validEntries = entries.filter {
            pageNumbers.contains($0.pageNumber)
                && !$0.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        lines.append("")
        if validEntries.isEmpty {
            lines.append(L10n.string("No PDF bookmarks or local headings were found."))
        } else {
            lines.append("## \(L10n.string("Document structure"))")
            lines.append("")
            for entry in validEntries {
                try Task.checkCancellation()
                let prefix = String(repeating: "  ", count: min(max(entry.level, 0), 5)) + "-"
                lines.append("\(prefix) \(escaped(entry.title)) [p. \(entry.pageNumber)]")
            }
        }
        return AIPublishedAnswer(
            completionStatus: .answered,
            title: title,
            resultMarkdown: lines.joined(separator: "\n"),
            evidenceSegmentIDs: [],
            finalDraftRevision: 0,
            terminate: true
        )
    }

    private static func escaped(_ source: String) -> String {
        let text = source.components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }.joined(separator: " ")
        return text.reduce(into: "") { output, character in
            if "\\`*_{}[]<>()#+-.!|".contains(character) { output.append("\\") }
            output.append(character)
        }
    }
}
