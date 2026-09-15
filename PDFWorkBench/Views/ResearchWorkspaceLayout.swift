import Foundation

/// One width budget for the sibling PDF, research and annotation panes.
struct ResearchWorkspaceLayout {
    static let minimumReaderWidth: CGFloat = 520
    static let minimumResearchWidth: CGFloat = 360
    static let dividerWidth: CGFloat = 6

    let annotationWidth: CGFloat
    let readingAreaWidth: CGFloat
    let readerWidth: CGFloat
    let researchWidth: CGFloat
    let canSplit: Bool

    init(availableWidth: CGFloat, annotationWidth: CGFloat, showsResearch: Bool,
         readerFraction: Double, focusesResearch: Bool, fixedReadingAreaWidth: CGFloat? = nil) {
        let available = max(0, availableWidth)
        self.annotationWidth = min(available, max(0, annotationWidth))
        // Do not clamp a transition snapshot to the intermediate window width:
        // the window clips/reveals the sidebar instead of relaying out the PDF.
        readingAreaWidth = fixedReadingAreaWidth ?? (available - self.annotationWidth)
        canSplit = readingAreaWidth >= Self.minimumReaderWidth + Self.dividerWidth + Self.minimumResearchWidth
        if !showsResearch {
            readerWidth = readingAreaWidth
            researchWidth = 0
        } else if canSplit {
            let fraction = readerFraction.isFinite ? min(0.75, max(0.25, readerFraction)) : 0.5
            readerWidth = min(readingAreaWidth - Self.dividerWidth - Self.minimumResearchWidth,
                max(Self.minimumReaderWidth, readingAreaWidth * fraction))
            researchWidth = readingAreaWidth - readerWidth - Self.dividerWidth
        } else {
            readerWidth = focusesResearch ? 0 : readingAreaWidth
            researchWidth = focusesResearch ? readingAreaWidth : 0
        }
    }
}

/// Lifetime follows the native window animation, not a guessed delay.
struct AnnotationSidebarTransition {
    let id = UUID()
    let readingAreaWidth: CGFloat
    let annotationWidth: CGFloat
}
