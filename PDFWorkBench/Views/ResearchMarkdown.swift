import AppKit
import Foundation

/// Foundation parses Markdown; AppKit renders it without HTML or remote loads.
@MainActor
enum ResearchMarkdown {
    private static let literal = NSAttributedString.Key("DogearMarkdownLiteral")

    static func render(_ markdown: String, sources: [ResearchSourceSnapshot] = [],
                       evidence: [ResearchEvidence] = []) -> NSAttributedString {
        guard let parsed = try? AttributedString(markdown: markdown) else {
            return NSAttributedString(string: markdown, attributes: [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor.labelColor])
        }
        let result = NSMutableAttributedString(string: "")
        var previousBlock: Int?
        var seenItems = Set<Int>()
        for run in parsed.runs {
            let components = run.presentationIntent?.components ?? []
            let block = components.first?.identity
            let newBlock = block != previousBlock
            if newBlock && result.length > 0 { result.append(NSAttributedString(string: "\n")) }
            previousBlock = block
            var size: CGFloat = 13
            var bold = run.inlinePresentationIntent?.contains(.stronglyEmphasized) == true
            let italic = run.inlinePresentationIntent?.contains(.emphasized) == true
            var code = run.inlinePresentationIntent?.contains(.code) == true
            var quote = false
            var depth = 0
            var item: (id: Int, ordinal: Int)?
            var ordered = false
            var foundList = false
            for component in components {
                switch component.kind {
                case .header(let level): size = level == 1 ? 22 : (level == 2 ? 18 : 15); bold = true
                case .codeBlock: code = true
                case .blockQuote: quote = true
                case .listItem(let ordinal): if item == nil { item = (component.identity, ordinal) }
                case .orderedList:
                    depth += 1
                    if !foundList { ordered = true; foundList = true }
                case .unorderedList:
                    depth += 1
                    if !foundList { foundList = true }
                default: break
                }
            }
            var font = code ? NSFont.monospacedSystemFont(ofSize: 12, weight: .regular) : NSFont.systemFont(ofSize: size)
            if bold { font = NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask) }
            if italic { font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask) }
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineSpacing = 3
            paragraph.paragraphSpacing = 9
            paragraph.firstLineHeadIndent = CGFloat(max(0, depth - 1)) * 18 + (quote ? 14 : 0)
            paragraph.headIndent = paragraph.firstLineHeadIndent + (depth > 0 ? 20 : 0)
            var attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: quote ? NSColor.secondaryLabelColor : NSColor.labelColor,
                                                           .paragraphStyle: paragraph]
            if code { attributes[.backgroundColor] = NSColor.quaternaryLabelColor; attributes[literal] = true }
            if run.inlinePresentationIntent?.contains(.strikethrough) == true { attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
            if let link = run.link, ["https", "http"].contains(link.scheme?.lowercased() ?? "") { attributes[.link] = link }
            if newBlock, let item, seenItems.insert(item.id).inserted {
                result.append(NSAttributedString(string: ordered ? "\(item.ordinal).  " : "•  ", attributes: attributes))
            }
            result.append(NSAttributedString(string: String(parsed[run.range].characters), attributes: attributes))
        }
        addEvidenceLinks(to: result, sources: sources, evidence: evidence)
        return result
    }

    private static func addEvidenceLinks(to text: NSMutableAttributedString, sources: [ResearchSourceSnapshot], evidence: [ResearchEvidence]) {
        // Source order is the frozen, successfully prepared request catalog,
        // never the current Library/Group order or the order citations appear.
        let citations = try! NSRegularExpression(pattern: #"\[(?:D(\d{3})\s+)?p\.\s*([0-9][0-9\s,，–—\-p\.]*)\]"#, options: .caseInsensitive)
        let numbers = try! NSRegularExpression(pattern: #"\d+"#)
        let raw = text.string as NSString
        for match in citations.matches(in: text.string, range: NSRange(location: 0, length: text.length)) {
            guard text.attribute(literal, at: match.range.location, effectiveRange: nil) == nil,
                  text.attribute(.link, at: match.range.location, effectiveRange: nil) == nil else { continue }
            let fileID: UUID?
            if match.range(at: 1).location != NSNotFound {
                let number = Int(raw.substring(with: match.range(at: 1))) ?? 0
                fileID = sources.indices.contains(number - 1) ? sources[number - 1].fileID : nil
            } else {
                let files = Set(evidence.compactMap { $0.source?.fileID })
                fileID = files.count == 1 ? files.first : nil
            }
            guard let fileID else { continue }
            let pagesRange = match.range(at: 2)
            let pages = numbers.matches(in: text.string, range: pagesRange)
            for page in pages {
                guard let number = Int(raw.substring(with: page.range)),
                      let target = evidence.first(where: { $0.source?.fileID == fileID && $0.anchor?.pageIndex == number - 1 }) else { continue }
                let link = URL(string: "dogear-evidence://\(target.id.uuidString)")!
                // Single-page references are one link. Multi-page references
                // expose each written page separately, including range endpoints.
                text.addAttributes([.link: link, .foregroundColor: NSColor.linkColor,
                                    .toolTip: "\(target.source?.displayName ?? "") — p. \(number)",
                                    .underlineStyle: NSUnderlineStyle.single.rawValue],
                                   range: pages.count == 1 ? match.range : page.range)
            }
        }
    }
}
