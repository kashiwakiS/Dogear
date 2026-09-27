import Foundation
#if canImport(AppKit)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

/// Adapts shared Markdown presentation to the platform's native text system.
/// No HTML, remote image loads, or changes to the read-only editor's layout.
@MainActor
enum ResearchMarkdown {
    static func render(_ markdown: String, sources: [ResearchSourceSnapshot] = [],
                       evidence: [ResearchEvidence] = []) -> NSAttributedString {
        let presentation = ResearchMarkdownPresentation(markdown, sources: sources, evidence: evidence)
        let result = NSMutableAttributedString(string: "")
        for run in presentation.runs {
            guard let style = run.style else {
                result.append(NSAttributedString(string: run.text))
                continue
            }
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineSpacing = 3
            paragraph.paragraphSpacing = 9
            paragraph.firstLineHeadIndent = CGFloat(max(0, style.listDepth - 1)) * 18 + (style.quote ? 14 : 0)
            paragraph.headIndent = paragraph.firstLineHeadIndent + (style.listDepth > 0 ? 20 : 0)
            var attributes: [NSAttributedString.Key: Any] = [
                .font: PDFPlatformStyle.font(style.font),
                .foregroundColor: style.quote ? PDFPlatformStyle.secondaryLabelColor : PDFPlatformStyle.labelColor,
                .paragraphStyle: paragraph
            ]
            if style.font.monospaced { attributes[.backgroundColor] = PDFPlatformStyle.codeBackgroundColor }
            if style.strikethrough { attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
            if let link = style.webLink { attributes[.link] = link }
            result.append(NSAttributedString(string: run.text, attributes: attributes))
        }
        for link in presentation.evidenceLinks {
            var attributes: [NSAttributedString.Key: Any] = [
                .link: link.url,
                .foregroundColor: PDFPlatformStyle.linkColor,
                .underlineStyle: NSUnderlineStyle.single.rawValue
            ]
            #if canImport(AppKit)
            attributes[.toolTip] = link.help
            #endif
            result.addAttributes(attributes, range: link.range)
        }
        return result
    }
}
