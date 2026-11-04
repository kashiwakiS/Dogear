#if os(iOS)
import SwiftUI

/// Rendering consumes the shared Markdown/citation model. It never reparses
/// source IDs or derives evidence from answer prose.
struct IPadResearchAnswer: View {
    let markdown: String
    var sources: [ResearchSourceSnapshot] = []
    var evidence: [ResearchEvidence] = []
    let onShowEvidence: (ResearchEvidence) -> Void

    var body: some View {
        Text(attributedText)
            .frame(maxWidth: .infinity, alignment: .leading)
            .textSelection(.enabled)
            .environment(\.openURL, OpenURLAction { url in
                switch ResearchLinkTarget(url: url) {
                case .evidence(let id):
                    if let item = evidence.first(where: { $0.id == id }) { onShowEvidence(item) }
                    return .handled
                case .web: return .systemAction
                case .unsupported: return .discarded
                }
            })
    }

    private var attributedText: AttributedString {
        let presentation = ResearchMarkdownPresentation(markdown, sources: sources, evidence: evidence)
        var output = AttributedString()
        for run in presentation.runs {
            var value = AttributedString(run.text)
            if let style = run.style {
                let design: Font.Design = style.font.monospaced ? .monospaced : .default
                var font = Font.system(size: style.font.pointSize,
                    weight: style.font.bold ? .semibold : .regular, design: design)
                if style.font.italic { font = font.italic() }
                value.font = font
                value.strikethroughStyle = style.strikethrough ? .single : nil
                value.link = style.webLink
                if style.quote { value.foregroundColor = .secondary }
            }
            output.append(value)
        }
        for link in presentation.evidenceLinks {
            guard let range = Range(link.range, in: presentation.text),
                  let lower = AttributedString.Index(range.lowerBound, within: output),
                  let upper = AttributedString.Index(range.upperBound, within: output) else { continue }
            output[lower..<upper].link = link.url
            output[lower..<upper].foregroundColor = .accentColor
        }
        return output
    }
}
#endif
