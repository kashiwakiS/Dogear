import AppKit
import PDFKit

/// Exercise real native text views without showing a window or editing a PDF.
@MainActor
enum MarginCanvasLayoutDiagnostics {
    struct Report: Sendable { let checks: Int; let failures: [String] }

    static func run() -> Report {
        var checks = 0
        var failures: [String] = []
        func check(_ value: Bool, _ message: String) {
            checks += 1
            if !value { failures.append(message) }
        }
        let view = MarginCanvasView(frame: NSRect(x: 0, y: 0, width: 900, height: 900))
        let annotationA = PDFAnnotation(bounds: NSRect(x: 20, y: 50, width: 60, height: 20),
                                       forType: .freeText, withProperties: nil)
        let annotationB = PDFAnnotation(bounds: NSRect(x: 20, y: 90, width: 60, height: 20),
                                       forType: .freeText, withProperties: nil)
        let noteA = "First note. " + String(repeating: "Evidence remains tied to the page. ", count: 9)
        let noteB = "Second note. " + String(repeating: "A second independently positioned comment. ", count: 8)
        let pageFrame = NSRect(x: 0, y: 0, width: 600, height: 3_000)
        let lane = NSRect(x: 620, y: 0, width: 240, height: 900)
        func entry(_ id: String, text: String, annotation: PDFAnnotation, y: CGFloat,
                   offset: CGFloat = 0) -> MarginCanvasAnnotationEntry {
            MarginCanvasAnnotationEntry(id: id, pageIndex: 0, annotation: annotation,
                note: text, anchorFrame: NSRect(x: 40, y: y + offset, width: 160, height: 20),
                pageFrame: pageFrame.offsetBy(dx: 0, dy: offset), isAIGenerated: false, category: nil)
        }
        func entries(offset: CGFloat = 0, firstText: String? = nil) -> [MarginCanvasAnnotationEntry] {
            [entry("A", text: firstText ?? noteA, annotation: annotationA, y: 900, offset: offset),
             entry("B", text: noteB, annotation: annotationB, y: 1_500, offset: offset)]
        }
        func textView(_ text: String) -> NSTextView? {
            view.subviews.compactMap { $0 as? NSTextView }.first { $0.string == text }
        }

        view.update(entries: entries(), laneFrame: lane, selectedEntryID: nil, isNightMode: false)
        check(view.textMeasurementCount == 2 && view.cachedTextMeasurementCount == 2,
              "Initial visible notes did not receive their individual text measurements")
        guard let first = textView(noteA), let second = textView(noteB) else {
            check(false, "Margin canvas did not create native selectable note views")
            return .init(checks: checks, failures: failures)
        }
        let initialFirstFrame = first.frame
        let initialSecondFrame = second.frame
        first.setSelectedRange(NSRange(location: 0, length: 5))
        var correctFrames = true
        for step in 1...60 {
            let offset = CGFloat(step) * -7.25
            view.update(entries: entries(offset: offset), laneFrame: lane,
                        selectedEntryID: "A", isNightMode: false)
            correctFrames = correctFrames
                && first.frame == initialFirstFrame.offsetBy(dx: 0, dy: offset)
                && second.frame == initialSecondFrame.offsetBy(dx: 0, dy: offset)
        }
        check(correctFrames, "Cached text metrics froze or drifted the scrolling card positions")
        check(view.textMeasurementCount == 2, "Sixty scroll updates repeated unchanged text measurement")
        check(textView(noteA) === first && first.selectedRange() == NSRange(location: 0, length: 5),
              "Scrolling replaced the selectable text view or its native selection")

        let changedNote = noteA + String(repeating: "Added lines must increase the card height.\n", count: 10)
        view.update(entries: entries(firstText: changedNote), laneFrame: lane,
                    selectedEntryID: nil, isNightMode: false)
        check(view.textMeasurementCount == 3 && view.cachedTextMeasurementCount == 2,
              "Editing one note invalidated unrelated notes or retained obsolete versions")
        check(textView(changedNote) === first && first.frame.height > initialFirstFrame.height,
              "Edited text did not update the same native view and expand its card")

        let narrowLane = NSRect(x: 620, y: 0, width: 160, height: 900)
        let wideHeight = first.frame.height
        view.update(entries: entries(firstText: changedNote), laneFrame: narrowLane,
                    selectedEntryID: nil, isNightMode: false)
        check(view.textMeasurementCount == 5 && first.frame.width == 140 && first.frame.height > wideHeight,
              "A width change reused stale wrapping measurements")
        let narrowFrame = first.frame
        view.update(entries: entries(firstText: changedNote), laneFrame: narrowLane.offsetBy(dx: 12, dy: 0),
                    selectedEntryID: nil, isNightMode: false)
        check(view.textMeasurementCount == 5 && first.frame == narrowFrame.offsetBy(dx: 12, dy: 0),
              "Moving the lane either remeasured text or failed to update horizontal position")

        view.update(entries: entries(firstText: changedNote), laneFrame: narrowLane,
                    selectedEntryID: nil, isNightMode: true)
        check(view.textMeasurementCount == 7 && first.textColor?.isEqual(NSColor(calibratedWhite: 0.88, alpha: 1)) == true,
              "Changing presentation style retained stale cached metrics or text appearance")
        view.update(entries: entries(firstText: changedNote), laneFrame: narrowLane,
                    selectedEntryID: "B", isNightMode: true)
        check(view.textMeasurementCount == 7, "Selection-only update repeated text measurement")

        view.update(entries: [entries(firstText: changedNote)[1]], laneFrame: narrowLane,
                    selectedEntryID: nil, isNightMode: true)
        check(view.cachedTextMeasurementCount == 1 && textView(changedNote) == nil && view.textMeasurementCount == 7,
              "Leaving the visible entries retained an offscreen note or discarded the remaining measurement")
        view.update(entries: [], laneFrame: .zero, selectedEntryID: nil, isNightMode: true)
        check(view.cachedTextMeasurementCount == 0 && view.subviews.compactMap { $0 as? NSTextView }.isEmpty,
              "Closing the canvas retained note text or native text views")
        view.update(entries: entries(), laneFrame: lane, selectedEntryID: nil, isNightMode: true)
        check(view.textMeasurementCount == 9 && view.cachedTextMeasurementCount == 2,
              "Returning entries reused measurements evicted when the canvas closed")
        check(annotationA.contents == nil && annotationB.contents == nil,
              "Margin presentation changed PDF annotation contents")

        return .init(checks: checks, failures: failures)
    }
}
