import Foundation

/// Shared Markdown semantics and evidence resolution. Native renderers choose
/// fonts/colors without reparsing citations or changing the frozen source order.
nonisolated struct ResearchMarkdownPresentation {
    struct Style {
        var font = PDFTextStyle()
        var quote = false
        var listDepth = 0
        var strikethrough = false
        var webLink: URL?
    }

    struct Run {
        let text: String
        let style: Style?
    }

    struct EvidenceLink {
        let range: NSRange
        let url: URL
        let help: String
    }

    let runs: [Run]
    let evidenceLinks: [EvidenceLink]
    var text: String { runs.map(\.text).joined() }

    init(_ markdown: String, sources: [ResearchSourceSnapshot] = [], evidence: [ResearchEvidence] = []) {
        guard let parsed = try? AttributedString(markdown: markdown) else {
            runs = [Run(text: markdown, style: Style())]
            evidenceLinks = []
            return
        }
        var output: [Run] = []
        var text = ""
        var textLength = 0
        var excludedRanges: [NSRange] = []
        func append(_ value: String, style: Style?) {
            if style?.font.monospaced == true || style?.webLink != nil {
                excludedRanges.append(NSRange(location: textLength, length: value.utf16.count))
            }
            output.append(Run(text: value, style: style))
            text += value
            textLength += value.utf16.count
        }
        var previousBlock: Int?
        var seenItems = Set<Int>()
        for run in parsed.runs {
            let components = run.presentationIntent?.components ?? []
            let block = components.first?.identity
            let newBlock = block != previousBlock
            if newBlock && !text.isEmpty { append("\n", style: nil) }
            previousBlock = block
            var style = Style()
            style.font.bold = run.inlinePresentationIntent?.contains(.stronglyEmphasized) == true
            style.font.italic = run.inlinePresentationIntent?.contains(.emphasized) == true
            style.font.monospaced = run.inlinePresentationIntent?.contains(.code) == true
            style.strikethrough = run.inlinePresentationIntent?.contains(.strikethrough) == true
            if let link = run.link, case .web = ResearchLinkTarget(url: link) { style.webLink = link }
            var item: (id: Int, ordinal: Int)?
            var ordered = false
            var foundList = false
            for component in components {
                switch component.kind {
                case .header(let level):
                    style.font.pointSize = level == 1 ? 22 : (level == 2 ? 18 : 15)
                    style.font.bold = true
                case .codeBlock: style.font.monospaced = true
                case .blockQuote: style.quote = true
                case .listItem(let ordinal): if item == nil { item = (component.identity, ordinal) }
                case .orderedList:
                    style.listDepth += 1
                    if !foundList { ordered = true; foundList = true }
                case .unorderedList:
                    style.listDepth += 1
                    if !foundList { foundList = true }
                default: break
                }
            }
            if style.font.monospaced { style.font.pointSize = 12 }
            if newBlock, let item, seenItems.insert(item.id).inserted {
                append(ordered ? "\(item.ordinal).  " : "•  ", style: style)
            }
            append(String(parsed[run.range].characters), style: style)
        }
        runs = output
        evidenceLinks = Self.links(in: text, excluding: excludedRanges, sources: sources, evidence: evidence)
    }

    private static func links(in text: String, excluding excluded: [NSRange],
                              sources: [ResearchSourceSnapshot], evidence: [ResearchEvidence]) -> [EvidenceLink] {
        let citations = try! NSRegularExpression(pattern: #"\[(?:D(\d{3})\s+)?p\.\s*([0-9][0-9\s,，–—\-p\.]*)\]"#, options: .caseInsensitive)
        let numbers = try! NSRegularExpression(pattern: #"\d+"#)
        let raw = text as NSString
        var result: [EvidenceLink] = []
        for match in citations.matches(in: text, range: NSRange(location: 0, length: raw.length)) {
            guard !excluded.contains(where: { NSLocationInRange(match.range.location, $0) }) else { continue }
            let fileID: UUID?
            if match.range(at: 1).location != NSNotFound {
                let number = Int(raw.substring(with: match.range(at: 1))) ?? 0
                fileID = sources.indices.contains(number - 1) ? sources[number - 1].fileID : nil
            } else {
                let files = Set(evidence.compactMap { $0.source?.fileID })
                fileID = files.count == 1 ? files.first : nil
            }
            guard let fileID else { continue }
            let pages = numbers.matches(in: text, range: match.range(at: 2))
            for page in pages {
                guard let number = Int(raw.substring(with: page.range)),
                      let target = evidence.first(where: { $0.source?.fileID == fileID && $0.anchor?.pageIndex == number - 1 }) else { continue }
                result.append(EvidenceLink(range: pages.count == 1 ? match.range : page.range,
                    url: URL(string: "dogear-evidence://\(target.id.uuidString)")!,
                    help: "\(target.source?.displayName ?? "") — p. \(number)"))
            }
        }
        return result
    }
}

/// Unsupported schemes and malformed internal references never reach the OS.
nonisolated enum ResearchLinkTarget: Equatable {
    case evidence(UUID)
    case web(URL)
    case unsupported

    init(url: URL) {
        switch url.scheme?.lowercased() {
        case "dogear-evidence":
            if let host = url.host, let id = UUID(uuidString: host) { self = .evidence(id) }
            else { self = .unsupported }
        case "https", "http": self = .web(url)
        default: self = .unsupported
        }
    }
}
