import AppKit
import CoreImage
import CoreText
import PDFKit

@MainActor
enum PDFNightSelectionDiagnostics {
    static func run() -> AIHighlightFoundationDiagnosticReport {
        var count = 0
        var failures: [String] = []
        func check(_ condition: Bool, _ message: String) {
            count += 1
            if !condition { failures.append(message) }
        }
        do {
            let document = try fixture()
            let page = try require(document.page(at: 0))
            let selection = try Self.selection("Selection contrast sample", on: page)
            let yellow = try Self.selection("Yellow highlight remains readable", on: page)
            let dark = try Self.selection("Dark highlight remains readable", on: page)
            let opaque = try Self.selection("Opaque external highlight", on: page)
            let reference = try render(page, selection: nil)
            let yellowAnnotation = highlight(yellow.bounds(for: page), color: NSColor.yellow.withAlphaComponent(0.45))
            let darkAnnotation = highlight(dark.bounds(for: page), color: NSColor.black.withAlphaComponent(0.35))
            let opaqueAnnotation = highlight(opaque.bounds(for: page), color: .black)
            for annotation in [yellowAnnotation, darkAnnotation, opaqueAnnotation] { page.addAnnotation(annotation) }
            let originalColors = page.annotations.map(\.color)
            let originalData = try require(document.dataRepresentation())
            let view = HighlightingPDFView(frame: CGRect(x: 0, y: 0, width: 480, height: 240))
            let undo = UndoManager()
            view.workspaceUndoManager = undo
            view.document = document
            view.autoScales = false
            view.scaleFactor = 1
            view.layoutDocumentView()
            view.setCurrentSelection(selection, animate: false)
            let previousPosition = view.currentReadingPosition
            let previousBounds = selection.bounds(for: page)
            view.applyNightMode(true)
            let displayed = try require(view.currentSelection)
            check(displayed !== selection && selection.color == nil,
                "Night presentation mutated the caller's original selection instead of copying it.")
            check(displayed.string == selection.string && displayed.bounds(for: page) == previousBounds,
                "Night presentation changed the selected text or PDF range.")
            check(displayed.color?.isEqual(PDFNightSelectionPresentation.selectionColor) == true,
                "An existing selection did not receive the night presentation color.")
            check(view.document === document && view.currentReadingPosition == previousPosition,
                "Selection recoloring replaced the PDF or moved the reading position.")
            for name in [NSAppearance.Name.aqua, .darkAqua] {
                var before: NSBitmapImageRep?
                var after: NSBitmapImageRep?
                var inactive: NSBitmapImageRep?
                var renderingError: Error?
                NSAppearance(named: name)?.performAsCurrentDrawingAppearance {
                    do {
                        before = try render(page, selection: selection, usesLegacyInversion: true)
                        after = try render(page, selection: displayed)
                        inactive = try render(page, selection: displayed, active: false)
                    } catch { renderingError = error }
                }
                if let renderingError { throw renderingError }
                let beforeImage = try require(before)
                let afterImage = try require(after)
                let inactiveImage = try require(inactive)
                let beforeContrast = try contrast(beforeImage, reference: reference, bounds: previousBounds)
                let afterContrast = try contrast(afterImage, reference: reference, bounds: previousBounds)
                print("Night selection pixels [\(name.rawValue)]: default \(String(format: "%.2f", beforeContrast)):1, fixed \(String(format: "%.2f", afterContrast)):1")
                check(afterContrast >= 7, "Rendered night selection text did not reach 7:1 contrast in \(name.rawValue).")
                check(try contrast(inactiveImage, reference: reference, bounds: previousBounds) >= 7,
                    "An inactive night selection did not retain readable contrast in \(name.rawValue).")
                check(try contrast(afterImage, reference: reference, bounds: yellow.bounds(for: page)) >= 4.5,
                    "A standard yellow PDF highlight became unreadable in night mode.")
                check(try contrast(afterImage, reference: reference, bounds: dark.bounds(for: page)) >= 4.5,
                    "A translucent external dark highlight became unreadable in night mode.")
                // Opaque black annotations already conceal the glyph pixels in
                // the PDF. Selection styling deliberately leaves those intact.
                check(try contrast(afterImage, reference: reference, bounds: opaque.bounds(for: page)) < 1.5,
                    "The opaque external highlight control no longer demonstrates the source-PDF limitation.")
                let root = FileManager.default.temporaryDirectory.appendingPathComponent("DogearNightSelectionDiagnostics")
                try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
                try require(beforeImage.representation(using: .png, properties: [:])).write(to: root.appendingPathComponent("\(name.rawValue)-before.png"), options: .atomic)
                try require(afterImage.representation(using: .png, properties: [:])).write(to: root.appendingPathComponent("\(name.rawValue)-after.png"), options: .atomic)
                try require(inactiveImage.representation(using: .png, properties: [:])).write(to: root.appendingPathComponent("\(name.rawValue)-inactive.png"), options: .atomic)
            }
            // New drag/search selections arrive after night mode was enabled.
            let searchSelection = try Self.selection("contrast", on: page)
            searchSelection.color = .systemGreen
            view.setCurrentSelection(searchSelection, animate: false)
            NotificationCenter.default.post(name: .PDFViewSelectionChanged, object: view)
            check(view.currentSelection?.color?.isEqual(PDFNightSelectionPresentation.selectionColor) == true,
                "A later drag/search selection retained the unreadable system color.")
            check(searchSelection.color?.isEqual(NSColor.systemGreen) == true,
                "Night styling mutated the cached search-result selection.")
            view.applyNightMode(false)
            check(view.currentSelection?.color?.isEqual(NSColor.systemGreen) == true,
                "Leaving night mode did not restore the original search-selection color.")
            view.setCurrentSelection(selection, animate: false)
            view.applyNightMode(true)
            view.applyNightMode(false)
            check(view.currentSelection?.color == nil, "Leaving night mode did not restore the system selection color.")
            check(!undo.canUndo && !undo.canRedo, "Night presentation created an annotation Undo operation.")
            check(zip(page.annotations.map(\.color), originalColors).allSatisfy { $0.isEqual($1) },
                "Night presentation rewrote a standard PDF annotation color.")
            check(page.annotations.contains { $0 === opaqueAnnotation } && page.annotations.count == 3,
                "Night presentation replaced or removed an external annotation.")
            // A no-op serialization control proved that PDFKit generates a
            // fresh trailer /ID on every dataRepresentation(). Normalize only
            // that volatile identifier; compare every other serialized byte.
            let stableData = try require(document.dataRepresentation())
            let controlData = try require(document.dataRepresentation())
            check(try normalizingTrailerIdentifier(stableData) == normalizingTrailerIdentifier(controlData),
                "The native serialization control changed bytes beyond its generated trailer ID.")
            view.applyNightMode(true)
            view.setCurrentSelection(selection, animate: false)
            view.applyNightMode(false)
            let currentData = try require(document.dataRepresentation())
            check(try normalizingTrailerIdentifier(currentData) == normalizingTrailerIdentifier(originalData),
                "Night selection presentation changed serialized PDF bytes beyond the generated trailer ID.")
            let originalRoundTrip = try require(PDFDocument(data: originalData)?.page(at: 0))
            let currentRoundTrip = try require(PDFDocument(data: currentData)?.page(at: 0))
            check(originalRoundTrip.annotations.count == currentRoundTrip.annotations.count
                && zip(originalRoundTrip.annotations, currentRoundTrip.annotations).allSatisfy { original, current in
                    original.type == current.type && original.bounds == current.bounds
                        && original.color.isEqual(current.color) && original.contents == current.contents
                        && original.quadrilateralPoints == current.quadrilateralPoints
                }, "Presentation changed serialized native annotation content or geometry.")
        } catch {
            failures.append("Night selection fixture: \(error)")
        }
        return .init(checkCount: count, failures: failures)
    }

    private static func selection(_ text: String, on page: PDFPage) throws -> PDFSelection {
        let string = try require(page.string) as NSString
        let range = string.range(of: text)
        guard range.location != NSNotFound else { throw FixtureError.missing }
        return try require(page.selection(for: range))
    }

    private static func fixture() throws -> PDFDocument {
        let data = NSMutableData()
        var bounds = CGRect(x: 0, y: 0, width: 480, height: 240)
        let consumer = try require(CGDataConsumer(data: data))
        let context = try require(CGContext(consumer: consumer, mediaBox: &bounds, nil))
        context.beginPDFPage(nil)
        for (text, y) in [("Selection contrast sample", 190.0), ("Yellow highlight remains readable", 145.0),
                          ("Dark highlight remains readable", 100.0), ("Opaque external highlight", 55.0)] {
            context.textPosition = CGPoint(x: 30, y: y)
            let string = NSAttributedString(string: text, attributes: [
                .font: CTFontCreateWithName("Helvetica" as CFString, 20, nil),
                .foregroundColor: CGColor(gray: 0, alpha: 1)
            ])
            CTLineDraw(CTLineCreateWithAttributedString(string), context)
        }
        context.endPDFPage()
        context.closePDF()
        return try require(PDFDocument(data: data as Data))
    }

    private static func highlight(_ bounds: CGRect, color: NSColor) -> PDFAnnotation {
        let annotation = PDFAnnotation(bounds: bounds, forType: .highlight, withProperties: nil)
        annotation.color = color
        annotation.quadrilateralPoints = [NSValue(point: CGPoint(x: 0, y: bounds.height)),
            NSValue(point: CGPoint(x: bounds.width, y: bounds.height)), NSValue(point: .zero),
            NSValue(point: CGPoint(x: bounds.width, y: 0))]
        return annotation
    }

    /// Actual PDFKit glyph/annotation/selection rendering followed by the same
    /// CIColorInvert filter as the reader; no synthetic color-only simulation.
    private static func render(_ page: PDFPage, selection: PDFSelection?, active: Bool = true,
        usesLegacyInversion: Bool = false) throws -> NSBitmapImageRep {
        let bitmap = try require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 480, pixelsHigh: 240,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        let graphics = try require(NSGraphicsContext(bitmapImageRep: bitmap))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = graphics
        graphics.cgContext.setFillColor(NSColor.white.cgColor)
        graphics.cgContext.fill(CGRect(x: 0, y: 0, width: 480, height: 240))
        page.draw(with: .mediaBox, to: graphics.cgContext)
        selection?.draw(for: page, active: active)
        NSGraphicsContext.restoreGraphicsState()
        let input = CIImage(cgImage: try require(bitmap.cgImage))
        let output = usesLegacyInversion ? input.applyingFilter("CIColorInvert")
            : try require(PDFNightSelectionPresentation.invertedImage(input))
        let result = try require(CIContext(options: [.useSoftwareRenderer: true]).createCGImage(output, from: input.extent))
        return NSBitmapImageRep(cgImage: result)
    }

    private static func contrast(_ image: NSBitmapImageRep, reference: NSBitmapImageRep, bounds: CGRect) throws -> Double {
        var text: [Double] = [], background: [Double] = []
        for x in max(0, Int(bounds.minX) + 2)..<min(image.pixelsWide, Int(bounds.maxX) - 2) {
            for y in max(0, image.pixelsHigh - Int(bounds.maxY) + 2)..<min(image.pixelsHigh, image.pixelsHigh - Int(bounds.minY) - 2) {
                let base = try luminance(require(reference.colorAt(x: x, y: y)))
                let actual = try luminance(require(image.colorAt(x: x, y: y)))
                if base > 0.95 { text.append(actual) }
                if base < 0.01 { background.append(actual) }
            }
        }
        guard text.count > 20, background.count > 20 else { throw FixtureError.missing }
        let t = text.reduce(0, +) / Double(text.count)
        let b = background.reduce(0, +) / Double(background.count)
        return (max(t, b) + 0.05) / (min(t, b) + 0.05)
    }

    private static func luminance(_ color: NSColor) throws -> Double {
        let rgb = try require(color.usingColorSpace(.deviceRGB))
        func linear(_ value: CGFloat) -> Double {
            let value = Double(value)
            return value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(rgb.redComponent) + 0.7152 * linear(rgb.greenComponent) + 0.0722 * linear(rgb.blueComponent)
    }

    private enum FixtureError: Error { case missing }

    private static func normalizingTrailerIdentifier(_ data: Data) throws -> Data {
        let marker = try require(data.range(of: Data("trailer".utf8), options: .backwards))
        let trailer = try require(String(data: data[marker.lowerBound...], encoding: .isoLatin1))
        let expression = try NSRegularExpression(pattern: #"/ID\s*\[\s*<[0-9A-Fa-f]+>\s*<[0-9A-Fa-f]+>\s*\]"#)
        let range = NSRange(trailer.startIndex..., in: trailer)
        guard expression.numberOfMatches(in: trailer, range: range) == 1 else { throw FixtureError.missing }
        let normalized = expression.stringByReplacingMatches(in: trailer, range: range, withTemplate: "/ID [<generated><generated>]")
        var output = Data(data[..<marker.lowerBound])
        output.append(Data(normalized.utf8))
        return output
    }

    private static func require<T>(_ value: T?) throws -> T {
        guard let value else { throw FixtureError.missing }
        return value
    }
}
