import AppKit
import PDFKit

@MainActor
struct MarginCanvasAnnotationEntry {
    let id: String
    let pageIndex: Int
    let annotation: PDFAnnotation
    let note: String
    let anchorFrame: NSRect
    let pageFrame: NSRect
    let isAIGenerated: Bool
    let category: AIHighlightCategory?

    var pageNumber: Int { pageIndex + 1 }
}

@MainActor
final class MarginCanvasView: NSView {
    weak var pdfView: PDFView?
    var onSelectText: ((String, MarginCanvasAnnotationEntry) -> Void)?

    private var entries: [MarginCanvasAnnotationEntry] = []
    private var cardLayouts: [CardLayout] = []
    private var textViewsByEntryID: [String: MarginSelectableTextView] = [:]
    private var selectedEntryID: String?
    private var laneFrame = NSRect.zero
    private var isNightMode = false

    override var isFlipped: Bool { false }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func update(
        entries: [MarginCanvasAnnotationEntry],
        laneFrame: NSRect,
        selectedEntryID: String?,
        isNightMode: Bool
    ) {
        self.entries = entries
        self.laneFrame = laneFrame
        self.selectedEntryID = selectedEntryID
        self.isNightMode = isNightMode
        cardLayouts = makeCardLayouts()
        updateSelectableTextViews()
        needsDisplay = true
    }

    func select(entryID: String) {
        selectedEntryID = entryID
        needsDisplay = true
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !isHidden else { return nil }
        if let hitView = super.hitTest(point), hitView !== self {
            return hitView
        }
        if cardLayouts.contains(where: { $0.frame.contains(point) }) {
            return self
        }
        return nil
    }

    override func mouseDown(with event: NSEvent) {
        if let pdfView {
            window?.makeFirstResponder(pdfView)
        }
    }

    override func scrollWheel(with event: NSEvent) {
        guard let scrollView = pdfView?.documentView?.enclosingScrollView else {
            super.scrollWheel(with: event)
            return
        }
        scrollView.scrollWheel(with: event)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard !laneFrame.isEmpty else { return }

        for layout in cardLayouts where layout.frame.intersects(dirtyRect) {
            drawConnector(for: layout)
        }
        for layout in cardLayouts where layout.frame.intersects(dirtyRect) {
            drawCard(layout)
        }
    }

    private func makeCardLayouts() -> [CardLayout] {
        guard laneFrame.width >= 120 else { return [] }

        let horizontalInset: CGFloat = 0
        let cardWidth = laneFrame.width - horizontalInset * 2
        let groupedEntries = Dictionary(grouping: entries, by: \.pageIndex)
        var result: [CardLayout] = []

        for pageEntries in groupedEntries.values {
            guard let pageFrame = pageEntries.first?.pageFrame else { continue }
            let usablePageFrame = pageFrame.insetBy(dx: 0, dy: 10)
            let ordered = pageEntries.sorted {
                if $0.anchorFrame.midY == $1.anchorFrame.midY {
                    return $0.id < $1.id
                }
                return $0.anchorFrame.midY < $1.anchorFrame.midY
            }

            var pageLayouts: [CardLayout] = []
            var previousMaxY = usablePageFrame.minY
            for entry in ordered {
                let height = cardHeight(for: entry, width: cardWidth)
                let desiredY = entry.anchorFrame.midY - height / 2
                let y = max(desiredY, previousMaxY)
                let frame = NSRect(
                    x: laneFrame.minX + horizontalInset,
                    y: y,
                    width: cardWidth,
                    height: height
                )
                pageLayouts.append(CardLayout(entry: entry, frame: frame))
                previousMaxY = frame.maxY + 8
            }

            if let lastFrame = pageLayouts.last?.frame,
               lastFrame.maxY > usablePageFrame.maxY {
                let shift = lastFrame.maxY - usablePageFrame.maxY
                pageLayouts = pageLayouts.map {
                    CardLayout(
                        entry: $0.entry,
                        frame: $0.frame.offsetBy(dx: 0, dy: -shift)
                    )
                }
            }

            result.append(contentsOf: pageLayouts)
        }

        return result.sorted {
            if $0.entry.pageIndex == $1.entry.pageIndex {
                return $0.frame.minY < $1.frame.minY
            }
            return $0.entry.pageIndex < $1.entry.pageIndex
        }
    }

    private func cardHeight(for entry: MarginCanvasAnnotationEntry, width: CGFloat) -> CGFloat {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byWordWrapping
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12),
            .paragraphStyle: paragraph
        ]
        let textBounds = (entry.note as NSString).boundingRect(
            with: NSSize(
                width: max(80, width - 20),
                height: CGFloat.greatestFiniteMagnitude
            ),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: attributes
        )
        return max(54, ceil(textBounds.height) + 36)
    }

    private func drawConnector(for layout: CardLayout) {
        let isSelected = layout.entry.id == selectedEntryID
        let accent = accentColor(for: layout.entry)
        let start = NSPoint(
            x: min(layout.entry.anchorFrame.maxX, laneFrame.minX - 5),
            y: layout.entry.anchorFrame.midY
        )
        let end = NSPoint(x: layout.frame.minX, y: layout.frame.midY)

        let connector = NSBezierPath()
        connector.move(to: start)
        let elbowX = max(start.x + 8, end.x - 14)
        connector.line(to: NSPoint(x: elbowX, y: start.y))
        connector.line(to: NSPoint(x: elbowX, y: end.y))
        connector.line(to: end)
        connector.lineWidth = isSelected ? 1.8 : 1
        accent.withAlphaComponent(isSelected ? 0.88 : 0.42).setStroke()
        connector.stroke()
    }

    private func drawCard(_ layout: CardLayout) {
        let entry = layout.entry
        let isSelected = entry.id == selectedEntryID
        let accent = accentColor(for: entry)
        let cardPath = NSBezierPath(roundedRect: layout.frame, xRadius: 7, yRadius: 7)
        let background = isNightMode
            ? NSColor(calibratedWhite: 0.19, alpha: 0.98)
            : NSColor.textBackgroundColor.withAlphaComponent(0.98)
        background.setFill()
        cardPath.fill()

        accent.withAlphaComponent(isSelected ? 0.95 : 0.62).setStroke()
        cardPath.lineWidth = isSelected ? 2 : 1
        cardPath.stroke()

        let pageLabel = L10n.string("Page \(entry.pageNumber)")
        let label = entry.isAIGenerated
            ? "AI · \(categoryTitle(entry.category)) · \(pageLabel)"
            : "\(L10n.string("Note")) · \(pageLabel)"
        let labelAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 10, weight: .semibold),
            .foregroundColor: accent
        ]
        (label as NSString).draw(
            in: NSRect(
                x: layout.frame.minX + 10,
                y: layout.frame.maxY - 20,
                width: layout.frame.width - 20,
                height: 13
            ),
            withAttributes: labelAttributes
        )

    }

    private func updateSelectableTextViews() {
        let activeEntryIDs = Set(cardLayouts.map(\.entry.id))
        let obsoleteEntryIDs = textViewsByEntryID.keys.filter {
            !activeEntryIDs.contains($0)
        }
        for entryID in obsoleteEntryIDs {
            textViewsByEntryID[entryID]?.removeFromSuperview()
            textViewsByEntryID.removeValue(forKey: entryID)
        }

        for layout in cardLayouts {
            let entry = layout.entry
            let textView: MarginSelectableTextView
            if let existing = textViewsByEntryID[entry.id] {
                textView = existing
            } else {
                textView = makeSelectableTextView(entryID: entry.id)
                textViewsByEntryID[entry.id] = textView
                addSubview(textView)
            }

            if textView.string != entry.note {
                textView.string = entry.note
            }
            textView.frame = NSRect(
                x: layout.frame.minX + 10,
                y: layout.frame.minY + 8,
                width: layout.frame.width - 20,
                height: layout.frame.height - 32
            )
            textView.textColor = isNightMode
                ? NSColor(calibratedWhite: 0.88, alpha: 1)
                : NSColor.labelColor
            textView.toolTip = L10n.string("Select text to ask a follow-up question")
            textView.forwardedScrollView = pdfView?.documentView?.enclosingScrollView
        }
    }

    private func makeSelectableTextView(entryID: String) -> MarginSelectableTextView {
        let textView = MarginSelectableTextView(frame: .zero)
        textView.drawsBackground = false
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = false
        textView.font = NSFont.systemFont(ofSize: 12)
        textView.textContainerInset = .zero
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.widthTracksTextView = true
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = false
        textView.focusRingType = .none
        textView.onSelectionCommitted = { [weak self, weak textView] in
            guard let self,
                  let textView,
                  let entry = self.entries.first(where: { $0.id == entryID })
            else {
                return
            }
            let selectedRange = textView.selectedRange()
            guard selectedRange.length > 0,
                  NSMaxRange(selectedRange) <= (textView.string as NSString).length
            else {
                return
            }
            let selectedText = (textView.string as NSString)
                .substring(with: selectedRange)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !selectedText.isEmpty else { return }
            self.selectedEntryID = entry.id
            self.needsDisplay = true
            self.onSelectText?(selectedText, entry)
        }
        return textView
    }

    private func accentColor(for entry: MarginCanvasAnnotationEntry) -> NSColor {
        if entry.isAIGenerated {
            return NSColor(calibratedRed: 0.22, green: 0.66, blue: 0.76, alpha: 1)
        }
        return NSColor(calibratedRed: 0.76, green: 0.24, blue: 0.28, alpha: 1)
    }

    private func categoryTitle(_ category: AIHighlightCategory?) -> String {
        category?.displayTitle ?? L10n.string("Highlight")
    }

    private struct CardLayout {
        let entry: MarginCanvasAnnotationEntry
        let frame: NSRect
    }
}

private final class MarginSelectableTextView: NSTextView {
    weak var forwardedScrollView: NSScrollView?
    var onSelectionCommitted: (() -> Void)?

    override func mouseUp(with event: NSEvent) {
        super.mouseUp(with: event)
        onSelectionCommitted?()
    }

    override func keyUp(with event: NSEvent) {
        super.keyUp(with: event)
        onSelectionCommitted?()
    }

    override func scrollWheel(with event: NSEvent) {
        if let forwardedScrollView {
            forwardedScrollView.scrollWheel(with: event)
        } else {
            super.scrollWheel(with: event)
        }
    }
}
