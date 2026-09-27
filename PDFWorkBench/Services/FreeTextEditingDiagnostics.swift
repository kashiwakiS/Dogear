import AppKit
import PDFKit

/// Isolated native PDFs, the production editor/store/renderer, and working copies.
/// No existing document, user preferences, network, or application windows.
@MainActor
enum FreeTextEditingDiagnostics {
    static func run() -> AIHighlightFoundationDiagnosticReport {
        var checks = 0
        var failures: [String] = []
        func check(_ condition: @autoclosure () -> Bool, _ message: String) {
            checks += 1
            if !condition() { failures.append("FreeText: " + message) }
        }
        do {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("DogearFreeText-\(UUID())")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }
            let defaultsName = "DogearFreeText-\(UUID())"
            let defaults = UserDefaults(suiteName: defaultsName)!
            defer { defaults.removePersistentDomain(forName: defaultsName) }
            let queue = PDFSaveQueue(recoveryDirectoryURL: root.appendingPathComponent("recovery"))
            defer { queue.waitUntilDrained() }
            let copies = try PDFWorkingCopyStore(directoryURL: root.appendingPathComponent("copies"))
            let access = DocumentAccessCoordinator(saveQueue: queue)
            let store = PDFDocumentStore(feedbackCenter: OperationFeedbackCenter(userDefaults: defaults),
                metadataStore: DocumentMetadataStore(stateURL: root.appendingPathComponent("metadata.json")),
                aiHighlightGroupStore: AIHighlightGroupStore(stateURL: root.appendingPathComponent("groups.json")),
                workingCopyStore: copies, saveQueue: queue, accessCoordinator: access)
            defer { store.releaseEditorAccess() }

            let originalURL = root.appendingPathComponent("original.pdf")
            let originalBytes = externalFreeTextPDF()
            try originalBytes.write(to: originalURL)
            check(store.openPDF(from: originalURL), "could not open isolated native PDF")
            let document = try require(store.document)
            let page = try require(document.page(at: 0))
            let item = try require(store.annotations.first { $0.note == "Original plain text" })
            let draft = try require(store.freeTextEditDraft(for: item))
            let annotation = draft.annotation
            check((annotation.value(forAnnotationKey: .name) as? String) == "external-freetext-fixture",
                "external fixture identity was missing before editing")
            let original = FreeTextAnnotationEditing.Snapshot(annotation)
            let originalFont = try require(annotation.font)
            let originalColor = try require(annotation.fontColor)
            let originalAlignment = annotation.alignment
            let originalRendering = try pixels { FreeTextAnnotationEditing.draw(annotation, in: $0) }
            let undo = UndoManager()
            undo.groupsByEvent = false
            store.setUndoManager(undo)
            func mutation(_ body: () -> Void) { undo.beginUndoGrouping(); body(); undo.endUndoGrouping() }

            // Opening a form, changing its value copy, then cancelling never
            // enters the write path. A submitted identical draft is also clean.
            var cancelled = draft.values
            cancelled.text = "Cancelled changes"
            cancelled.fontSize = 32
            check(annotation.contents == original.contents && !undo.canUndo && !store.hasUnsavedChanges,
                "draft/cancel mutated the page or registered Undo")
            check(store.updateFreeText(draft, values: draft.values), "no-op edit was rejected")
            check(!undo.canUndo && !store.hasUnsavedChanges && annotation.modificationDate == original.modificationDate,
                "no-op edit dirtied or retimestamped the PDF")
            var invalid = draft.values
            invalid.text = "  \n "
            check(!store.updateFreeText(draft, values: invalid), "blank text was accepted")
            invalid = draft.values
            invalid.width = .infinity
            check(!store.updateFreeText(draft, values: invalid), "nonfinite width was accepted")
            invalid = draft.values
            invalid.height = -10
            check(!store.updateFreeText(draft, values: invalid), "negative height was accepted")
            invalid = draft.values
            invalid.fontSize = 0
            check(!store.updateFreeText(draft, values: invalid), "zero font size was accepted")
            check(!undo.canUndo && !store.hasUnsavedChanges, "rejected edit produced Undo or dirty state")

            var values = draft.values
            values.text = "Updated first line\nSecond line\n第三行"
            values.width = 260
            values.height = 120
            values.fontSize = 22
            mutation { check(store.updateFreeText(draft, values: values), "ordinary external FreeText edit was rejected") }
            check(annotation.contents == values.text && annotation.font?.pointSize == 22,
                "multiline text or new font size was not applied")
            check(annotation.font?.familyName == originalFont.familyName
                && NSFontManager.shared.traits(of: annotation.font!) == NSFontManager.shared.traits(of: originalFont),
                "editing the size changed font family or traits")
            check(annotation.fontColor?.isEqual(originalColor) == true && annotation.alignment == originalAlignment,
                "editing changed text color or alignment")
            check(annotation === AnnotationExtractor.annotation(matching: item, in: document)
                && annotation.userName == "External author"
                && (annotation.value(forAnnotationKey: .name) as? String) == "external-freetext-fixture",
                "editing replaced annotation identity or external metadata")
            check(annotation.bounds.width == 260 && annotation.bounds.height == 120
                && annotation.bounds.maxY == original.bounds.maxY, "resize lost its page-space top anchor")
            check(!annotation.hasAppearanceStream, "old PDF appearance remained after changing text")
            undo.undo()
            check(!undo.canUndo && annotation.contents == original.contents && annotation.bounds == original.bounds
                && annotation.font?.isEqual(original.font) == true && annotation.modificationDate == original.modificationDate,
                "one Undo did not restore all edited fields")
            let undoneRendering = try pixels { FreeTextAnnotationEditing.draw(annotation, in: $0) }
            check(similarPixels(originalRendering, undoneRendering), "Undo did not restore the original native text appearance")
            undo.redo()
            check(annotation.contents == values.text && annotation.bounds.height == 120 && annotation.font?.pointSize == 22,
                "Redo did not restore the complete edit")
            undo.removeAllActions()

            let serialized = try require(document.dataRepresentationWithAIAnnotationsDisplayed())
            let reopened = try require(PDFDocument(data: serialized))
            let reopenedPage = try require(reopened.page(at: 0))
            let reopenedNote = try require(reopenedPage.annotations.first { $0.type == "FreeText" })
            check(reopenedNote.contents == values.text && reopenedNote.bounds == annotation.bounds,
                "multiline text/size did not survive PDF serialization")
            check(abs((reopenedNote.font?.pointSize ?? 0) - 22) < 0.1
                && reopenedNote.font?.familyName == originalFont.familyName,
                "resized font did not survive PDF serialization")
            check((reopenedNote.fontColor?.usingColorSpace(.deviceRGB)?.blueComponent ?? 0) > 0.7,
                "font color was lost during serialization")
            check((reopenedNote.value(forAnnotationKey: .name) as? String) == "external-freetext-fixture"
                && reopenedNote.userName == "External author", "external identity/author did not survive serialization")

            // The annotation renderer used by the live PDFView must use native
            // style rather than a hard-coded red 14-point font.
            let rendered = try pixels { FreeTextAnnotationEditing.draw(annotation, in: $0) }
            check(bluePixels(rendered) > 100, "production renderer ignored the external blue font")
            let nativeRendered = try pixels { reopenedPage.draw(with: .mediaBox, to: $0) }
            check(bluePixels(nativeRendered) > 100, "saved PDF does not render its edited blue text natively")
            check(reopenedNote.hasAppearanceStream, "saved/reopened FreeText did not contain a native appearance")
            let secondDraft = FreeTextEditDraft(document: reopened, page: reopenedPage, annotation: reopenedNote)
            var secondValues = secondDraft.values
            secondValues.text = "Edited after reopening\n仍然保留样式"
            secondValues.fontSize = 26
            check(FreeTextAnnotationEditing.validationMessage(secondValues, draft: secondDraft) == nil,
                "a saved/reopened ordinary FreeText could not be edited again")
            FreeTextAnnotationEditing.apply(secondValues, draft: secondDraft)
            let secondRead = try require(reopened.dataRepresentationWithAIAnnotationsDisplayed().flatMap(PDFDocument.init(data:)))
            let secondReadNote = try require(secondRead.page(at: 0)?.annotations.first { $0.type == "FreeText" })
            check(secondReadNote.contents == secondValues.text && secondReadNote.font?.pointSize == 26
                && secondReadNote.font?.familyName == originalFont.familyName,
                "editing after reopening lost multiline text, font family, or the second font size")
            check((secondReadNote.fontColor?.usingColorSpace(.deviceRGB)?.blueComponent ?? 0) > 0.7
                && secondReadNote.userName == "External author"
                && (secondReadNote.value(forAnnotationKey: .name) as? String) == "external-freetext-fixture",
                "editing after reopening lost font color or external identity/author")
            var larger = values
            larger.fontSize = 34
            let savedState = FreeTextAnnotationEditing.Snapshot(annotation)
            FreeTextAnnotationEditing.apply(larger, draft: draft)
            let renderedLarger = try pixels { FreeTextAnnotationEditing.draw(annotation, in: $0) }
            check(rendered != renderedLarger, "production renderer did not respond to font-size changes")
            savedState.restore(to: annotation)

            // Crop box has a non-zero origin; rotation and zoom must not leak
            // screen geometry into native annotation coordinates.
            for rotation in [0, 90, 180, 270] {
                page.rotation = rotation
                var oversized = values
                oversized.width = 900
                oversized.height = 1000
                let edit = FreeTextEditDraft(document: document, page: page, annotation: annotation)
                mutation { check(store.updateFreeText(edit, values: oversized), "oversized edit was rejected at rotation \(rotation)") }
                check(annotation.bounds == page.bounds(for: .cropBox), "resize exceeded crop bounds at rotation \(rotation)")
                undo.undo()
                check(annotation.bounds == savedState.bounds && annotation.contents == values.text,
                    "clamped resize Undo lost original geometry at rotation \(rotation)")
                undo.removeAllActions()
            }
            page.rotation = 0

            // A fresh note uses the exact save path called by the native sheet.
            let view = HighlightingPDFView(frame: CGRect(x: 0, y: 0, width: 300, height: 400))
            view.document = document
            view.scaleFactor = 1.75
            view.workspaceUndoManager = undo
            view.canCommitFreeText = { [weak store] document in
                store?.canEditDocument == true && store?.document === document
            }
            view.onAnnotationChanged = { store.markAnnotationsChanged() }
            view.onUndoableAnnotationMutation = { store.markAnnotationsChanged(action: $0) }
            let newNote = PDFAnnotation(bounds: CGRect(x: 80, y: 150, width: 180, height: 90), forType: .freeText, withProperties: nil)
            newNote.font = FreeTextAnnotationEditing.defaultFont
            newNote.removeValue(forAnnotationKey: .color)
            newNote.removeValue(forAnnotationKey: .interiorColor)
            let previewCopy = PDFAnnotation(bounds: newNote.bounds, forType: .freeText, withProperties: nil)
            FreeTextPreviewStyle.copyExplicitColors(from: newNote, to: previewCopy)
            check(previewCopy.value(forAnnotationKey: .color) == nil
                && previewCopy.value(forAnnotationKey: .interiorColor) == nil,
                "transparent note preview acquired PDFKit's default yellow fill")
            let coloredNote = PDFAnnotation(bounds: newNote.bounds, forType: .freeText, withProperties: nil)
            coloredNote.color = .green
            coloredNote.interiorColor = .blue
            FreeTextPreviewStyle.copyExplicitColors(from: coloredNote, to: previewCopy)
            check(previewCopy.color.isEqual(coloredNote.color)
                && previewCopy.interiorColor?.isEqual(coloredNote.interiorColor) == true,
                "preview lost explicitly stored annotation colors")
            let newDraft = FreeTextEditDraft(document: document, page: page, annotation: newNote, isNew: true)
            check(newNote.page == nil && !undo.canUndo, "opening new-note draft inserted an annotation")
            check(!view.commitNewFreeText(newDraft, values: newDraft.values), "empty new note was saved")
            var newValues = newDraft.values
            newValues.text = "New note\nwith multiple lines"
            mutation { check(view.commitNewFreeText(newDraft, values: newValues), "multiline new-note save failed") }
            check(newNote.page === page && newNote.bounds == newDraft.originalBounds && newNote.contents == newValues.text,
                "new note used screen-scale coordinates or lost line breaks")
            undo.undo()
            check(newNote.page == nil && !undo.canUndo, "new note did not undo in one step")
            undo.redo()
            check(newNote.page === page && newNote.contents == newValues.text, "new-note Redo lost the original object/text")
            undo.undo()
            undo.removeAllActions()

            let richNote = PDFAnnotation(bounds: original.bounds, forType: .freeText, withProperties: nil)
            richNote.contents = "rich"
            _ = richNote.setValue("<body><p>rich</p></body>", forAnnotationKey: FreeTextAnnotationEditing.richTextKey)
            let richDraft = FreeTextEditDraft(document: document, page: page, annotation: richNote)
            check(FreeTextAnnotationEditing.validationMessage(richDraft.values, draft: richDraft) != nil,
                "rich text would silently lose its formatting")
            page.removeAnnotation(annotation)
            check(!store.updateFreeText(draft, values: values), "a removed target was edited")
            page.addAnnotation(annotation)
            check(page.annotations.contains { $0.type == "Text" && $0.contents == "Unchanged sticky note" },
                "FreeText edit changed a separate sticky note")
            store.markAnnotationsChanged()
            queue.waitUntilDrained()
            let workingCopy = try require(PDFDocument(url: copies.workingCopyURL(forOriginalURL: originalURL)))
            check(workingCopy.page(at: 0)?.annotations.first { $0.type == "FreeText" }?.contents == values.text,
                "working copy did not contain the final edit")
            let finalOriginalBytes = try Data(contentsOf: originalURL)
            check(finalOriginalBytes == originalBytes, "editing overwrote the original PDF")
            store.releaseEditorAccess()
            check(!view.commitNewFreeText(newDraft, values: newValues) && newNote.page == nil && !undo.canUndo,
                "new-note save bypassed a released write lease")
            check(!store.updateFreeText(draft, values: cancelled), "editing bypassed the document write lease")
        } catch { failures.append("FreeText fixture: \(error.localizedDescription)") }
        return .init(checkCount: checks, failures: failures)
    }

    private static func externalFreeTextPDF() -> Data {
        // A real external /NM is part of the source bytes. PDFKit's initial
        // writer for a newly synthesized PDFPage drops NM on FreeText, so that
        // would not exercise preservation of pre-existing external identity.
        let objects = [
            "<< /Type /Catalog /Pages 2 0 R >>",
            "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 400 500] /CropBox [20 30 380 470] /Resources << /Font << /Helvetica-BoldOblique 6 0 R >> >> /Annots [4 0 R 5 0 R] >>",
            "<< /Type /Annot /Subtype /FreeText /Rect [60 250 250 340] /Contents (Original plain text) /T (External author) /NM (external-freetext-fixture) /M (D:20231114221320Z) /DA (/Helvetica-BoldOblique 14 Tf 0.05 0.15 0.85 rg) /Q 2 /Border [0 0 0] /F 4 >>",
            "<< /Type /Annot /Subtype /Text /Rect [30 40 50 60] /Contents (Unchanged sticky note) /F 4 >>",
            "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica-BoldOblique >>"
        ]
        var data = Data("%PDF-1.4\n".utf8)
        var offsets = [0]
        for (index, object) in objects.enumerated() {
            offsets.append(data.count)
            data.append(Data("\(index + 1) 0 obj\n\(object)\nendobj\n".utf8))
        }
        let xref = data.count
        data.append(Data("xref\n0 \(offsets.count)\n0000000000 65535 f \n".utf8))
        for offset in offsets.dropFirst() { data.append(Data(String(format: "%010d 00000 n \n", offset).utf8)) }
        data.append(Data("trailer\n<< /Size \(offsets.count) /Root 1 0 R >>\nstartxref\n\(xref)\n%%EOF\n".utf8))
        return data
    }

    private static func pixels(draw: (CGContext) -> Void) throws -> [UInt8] {
        let width = 400, height = 500
        var bytes = [UInt8](repeating: 255, count: width * height * 4)
        try bytes.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw FixtureError.missing }
            context.setFillColor(NSColor.white.cgColor)
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            draw(context)
        }
        return bytes
    }

    private static func similarPixels(_ lhs: [UInt8], _ rhs: [UInt8]) -> Bool {
        // Native AP text vs a regenerated native text drawing may differ at
        // antialiased glyph edges. Compare against ink, not the blank page.
        var difference = 0, ink = 0
        for index in lhs.indices where index % 4 != 3 {
            difference += abs(Int(lhs[index]) - Int(rhs[index]))
            ink += 255 - min(Int(lhs[index]), Int(rhs[index]))
        }
        return ink > 0 && Double(difference) / Double(ink) < 0.03
    }

    private static func bluePixels(_ bytes: [UInt8]) -> Int {
        stride(from: 0, to: bytes.count, by: 4).filter {
            Int(bytes[$0 + 2]) > Int(bytes[$0]) + 50 && Int(bytes[$0 + 2]) > Int(bytes[$0 + 1]) + 50
        }.count
    }

    private static func require<T>(_ value: T?) throws -> T {
        guard let value else { throw FixtureError.missing }; return value
    }

    private enum FixtureError: Error { case missing }
}
