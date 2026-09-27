import AppKit
import CoreImage
import PDFKit

/// Selection is view state, never a PDF annotation. PDFKit's dynamic dark
/// selection color becomes a pale background under the reader's inversion;
/// using a warm pre-inversion color yields a dark blue behind white glyphs.
@MainActor
final class PDFNightSelectionPresentation {
    static let selectionColor = NSColor(calibratedRed: 0.95, green: 0.73, blue: 0.38, alpha: 1)

    /// Core Image's working space is linear light. Inverting those values
    /// directly turns middle-gray/highlight backgrounds almost white. Encode
    /// into sRGB for the inversion, then return to the linear working space.
    /// This is a display transform: native PDF colors are never rewritten.
    static func nightFilters() -> [CIFilter] {
        ["CILinearToSRGBToneCurve", "CIColorInvert", "CISRGBToneCurveToLinear"].compactMap(CIFilter.init(name:))
    }

    static func invertedImage(_ input: CIImage) -> CIImage? {
        var image = input
        let filters = nightFilters()
        guard filters.count == 3 else { return nil }
        for filter in filters {
            filter.setValue(image, forKey: kCIInputImageKey)
            guard let output = filter.outputImage else { return nil }
            image = output
        }
        return image
    }

    private weak var view: PDFView?
    private weak var styledSelection: PDFSelection?
    private var originalColor: NSColor?
    private var observer: NSObjectProtocol?
    private var isEnabled = false
    private var isUpdating = false

    func apply(to view: PDFView, enabled: Bool) {
        if self.view !== view {
            if let observer { NotificationCenter.default.removeObserver(observer) }
            self.view = view
            styledSelection = nil
            originalColor = nil
            observer = NotificationCenter.default.addObserver(
                forName: .PDFViewSelectionChanged, object: view, queue: .main
            ) { [weak self] _ in
                // NotificationCenter delivers this observer on the main
                // queue; update synchronously so a drag cannot style an older
                // selection after the pointer has already advanced.
                MainActor.assumeIsolated { self?.refresh() }
            }
        }
        isEnabled = enabled
        refresh()
    }

    private func refresh() {
        guard !isUpdating, let view else { return }
        guard let selection = view.currentSelection else {
            styledSelection = nil
            originalColor = nil
            return
        }
        guard isEnabled || selection === styledSelection else { return }
        if isEnabled, selection === styledSelection,
           selection.color?.isEqual(Self.selectionColor) == true { return }
        if isEnabled, selection !== styledSelection,
           selection.color?.isEqual(Self.selectionColor) != true {
            originalColor = selection.color
        }
        // PDFKit explicitly documents copying a current selection before
        // changing it. The setter redraws without scrolling or replacing PDF.
        guard let displayed = selection.copy() as? PDFSelection else { return }
        displayed.color = isEnabled ? Self.selectionColor : originalColor
        isUpdating = true
        view.setCurrentSelection(displayed, animate: false)
        styledSelection = isEnabled ? view.currentSelection : nil
        isUpdating = false
        if !isEnabled { originalColor = nil }
    }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }
}
