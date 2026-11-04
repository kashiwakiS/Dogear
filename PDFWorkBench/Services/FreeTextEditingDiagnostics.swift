import AppKit
import Combine
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
        let editorWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
            styleMask: [.titled], backing: .buffered, defer: false)
        editorWindow.isReleasedWhenClosed = false
        let editorID = UUID()
        var unfinished = false
        MacAnnotationEditorLifecycle.register(editorID, window: editorWindow) { unfinished }
        check(MacAnnotationEditorLifecycle.unfinishedWindow == nil, "unchanged sheet must not block normal Quit")
        unfinished = true
        check(MacAnnotationEditorLifecycle.unfinishedWindow === editorWindow, "unfinished annotation must identify its exact native recovery window before Quit")
        MacAnnotationEditorLifecycle.unregister(editorID)
        check(MacAnnotationEditorLifecycle.unfinishedWindow == nil, "finished/dismantled editor retained a stale Quit veto")
        editorWindow.close()
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
            annotation.contents = "A different editor changed the note"
            check(!store.updateFreeText(draft, values: cancelled) && annotation.contents == "A different editor changed the note",
                "stale same-object FreeText editor overwrote a competing text change")
            annotation.contents = original.contents
            annotation.fontColor = .blue
            check(!store.updateFreeText(draft, values: cancelled), "stale FreeText editor overwrote a competing style change")
            annotation.fontColor = originalColor
            check(FreeTextAnnotationEditing.isCurrent(draft, in: document), "restored captured FreeText baseline did not match")
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
            var commitCount = 0
            var legacyMutationCount = 0
            var storeMutationCount = 0
            view.onCommitFreeText = { draft, values in
                let saved = store.saveFreeText(draft, values: values)
                if saved { commitCount += 1 }
                return saved
            }
            view.onAnnotationChanged = { legacyMutationCount += 1 }
            view.onUndoableAnnotationMutation = { _ in legacyMutationCount += 1 }
            let mutationObserver = NotificationCenter.default.publisher(for: .dogearAnnotationsChanged, object: document)
                .sink { _ in storeMutationCount += 1 }
            defer { mutationObserver.cancel() }
            let newDraft = try require(store.newFreeTextDraft(page: page,
                bounds: CGRect(x: 80, y: 150, width: 180, height: 90)))
            let newNote = newDraft.annotation
            // Compare the original calibrated native color itself. Conversion
            // to deviceRGB depends on the display profile, so its components
            // cannot be compared to calibrated RGB input components.
            let originalMacRed = NSColor(calibratedRed: 0.84, green: 0.05, blue: 0.07, alpha: 1)
            check(newNote.font?.pointSize == 14 && newNote.alignment == .left
                && newNote.fontColor?.isEqual(originalMacRed) == true
                && newNote.shouldPrint && newNote.border?.lineWidth == 0,
                "shared new-note defaults changed the Mac red, font, alignment, or print style")
            let defaultDraft = try require(store.newFreeTextDraft(page: page))
            check(defaultDraft.originalBounds.width == 240 && defaultDraft.originalBounds.height == 120,
                "shared default note placement lost the Mac 240 by 120 size")
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
            check(newNote.page == nil && !undo.canUndo, "opening new-note draft inserted an annotation")
            check(!view.commitNewFreeText(newDraft, values: newDraft.values), "empty new note was saved")
            var newValues = newDraft.values
            newValues.text = "New note\nwith multiple lines"
            mutation { check(view.commitNewFreeText(newDraft, values: newValues), "multiline new-note save failed") }
            check(newNote.page === page && newNote.bounds == newDraft.originalBounds && newNote.contents == newValues.text,
                "new note used screen-scale coordinates or lost line breaks")
            check(commitCount == 1 && storeMutationCount == 1 && legacyMutationCount == 0,
                "new-note commit did not notify its owning Store exactly once")
            undo.undo()
            check(newNote.page == nil && !undo.canUndo, "new note did not undo in one step")
            undo.redo()
            check(newNote.page === page && newNote.contents == newValues.text, "new-note Redo lost the original object/text")
            undo.undo()
            check(commitCount == 1 && storeMutationCount == 4 && legacyMutationCount == 0,
                "new-note Undo/Redo repeated creation or used the old view mutation callback")
            undo.removeAllActions()
            let otherDocument = PDFDocument()
            let otherPage = PDFPage()
            otherDocument.insert(otherPage, at: 0)
            check(store.newFreeTextDraft(page: otherPage) == nil,
                "new-note preparation accepted another document's page")
            view.document = otherDocument
            check(!view.commitNewFreeText(newDraft, values: newValues) && newNote.page == nil && !undo.canUndo,
                "new-note commit accepted a reader that switched documents")
            view.document = document

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
            try exerciseTextColor(root: root.appendingPathComponent("text-color"), defaults: defaults,
                check: { value, message in check(value, message) })
            try exerciseFontFace(root: root.appendingPathComponent("font-face"), defaults: defaults,
                check: { value, message in check(value, message) })
        } catch { failures.append("FreeText fixture: \(error.localizedDescription)") }
        return .init(checkCount: checks, failures: failures)
    }

    private static func exerciseTextColor(root: URL, defaults: UserDefaults,
                                          check: (Bool, String) -> Void) throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let originalURL = root.appendingPathComponent("original-color.pdf")
        let originalBytes = externalFreeTextPDF()
        try originalBytes.write(to: originalURL)
        let queue = PDFSaveQueue(recoveryDirectoryURL: root.appendingPathComponent("recovery"))
        defer { queue.waitUntilDrained() }
        let copies = try PDFWorkingCopyStore(directoryURL: root.appendingPathComponent("copies"))
        let access = DocumentAccessCoordinator(saveQueue: queue)
        let store = PDFDocumentStore(feedbackCenter: OperationFeedbackCenter(userDefaults: defaults),
            metadataStore: DocumentMetadataStore(stateURL: root.appendingPathComponent("metadata.json")),
            aiHighlightGroupStore: AIHighlightGroupStore(stateURL: root.appendingPathComponent("groups.json")),
            workingCopyStore: copies, saveQueue: queue, accessCoordinator: access)
        defer { store.releaseEditorAccess() }
        check(store.openPDF(from: originalURL), "text-color fixture could not open its actual external PDF")
        let document = try require(store.document), page = try require(document.page(at: 0))
        let annotation = try require(page.annotations.first { $0.type == "FreeText" })
        let draft = FreeTextEditDraft(document: document, page: page, annotation: annotation)
        let originalColor = try require(annotation.fontColor)
        let originalFont = annotation.font, originalBounds = annotation.bounds, originalText = annotation.contents
        let originalDate = annotation.modificationDate, originalAlignment = annotation.alignment
        let undo = UndoManager(); undo.groupsByEvent = false; store.setUndoManager(undo)
        check(draft.values.fontColor == nil
              && FreeTextAnnotationEditing.resolvedTextColor(draft.values, draft: draft).isEqual(originalColor),
              "omitting an explicit color failed to preserve the imported native text color")

        let green = PDFColorComponents(red: 0.125, green: 0.625, blue: 0.25, alpha: 1)
        let invalidColors = [
            PDFColorComponents(red: .nan, green: 0.5, blue: 0.5, alpha: 1),
            PDFColorComponents(red: -0.001, green: 0.5, blue: 0.5, alpha: 1),
            PDFColorComponents(red: 0.5, green: .infinity, blue: 0.5, alpha: 1),
            PDFColorComponents(red: 0.5, green: 1.001, blue: 0.5, alpha: 1),
            PDFColorComponents(red: 0.5, green: 0.5, blue: .infinity, alpha: 1),
            PDFColorComponents(red: 0.5, green: 0.5, blue: -0.001, alpha: 1),
            PDFColorComponents(red: 0.5, green: 0.5, blue: 0.5, alpha: .nan),
            PDFColorComponents(red: 0.5, green: 0.5, blue: 0.5, alpha: 1.001)
        ]
        for (index, color) in invalidColors.enumerated() {
            var rejected = draft.values; rejected.fontColor = color
            check(FreeTextAnnotationEditing.validationMessage(rejected, draft: draft) != nil
                  && !store.updateFreeText(draft, values: rejected)
                  && annotation.fontColor?.isEqual(originalColor) == true
                  && annotation.modificationDate == originalDate && !undo.canUndo && !store.hasUnsavedChanges,
                  "invalid finite/range RGBA case \(index) changed the standard annotation or its Undo/save state")
        }
        var colored = draft.values; colored.fontColor = green
        undo.beginUndoGrouping(); let saved = store.saveFreeText(draft, values: colored); undo.endUndoGrouping()
        check(saved && FreeTextAnnotationEditing.matchesTextColor(green, annotation: annotation)
              && annotation.contents == originalText && annotation.bounds == originalBounds
              && annotation.font?.isEqual(originalFont) == true && annotation.alignment == originalAlignment
              && annotation.userName == "External author"
              && (annotation.value(forAnnotationKey: .name) as? String) == "external-freetext-fixture",
              "a color-only actual Store save lost its text, geometry, font, alignment or external identity")
        undo.undo()
        check(annotation.fontColor?.isEqual(originalColor) == true
              && annotation.contents == originalText && annotation.bounds == originalBounds
              && annotation.modificationDate == originalDate && !undo.canUndo && undo.canRedo,
              "one document Undo failed to restore the original text color and timestamp")
        undo.redo()
        check(FreeTextAnnotationEditing.matchesTextColor(green, annotation: annotation)
              && annotation.contents == originalText && annotation.font?.isEqual(originalFont) == true,
              "document Redo failed to restore the explicit standard font color")
        let serialized = try require(document.dataRepresentationWithAIAnnotationsDisplayed())
        let reopened = try require(PDFDocument(data: serialized))
        let reopenedPage = try require(reopened.page(at: 0))
        let reopenedAnnotation = try require(reopenedPage.annotations.first { $0.type == "FreeText" })
        check(FreeTextAnnotationEditing.matchesTextColor(green, annotation: reopenedAnnotation)
              && reopenedAnnotation.contents == originalText && reopenedAnnotation.bounds == originalBounds
              && reopenedAnnotation.value(forAnnotationKey: .defaultAppearance) is String,
              "explicit text color failed standard PDF serialization and native /DA readback")
        let greenRendering = try pixels { reopenedPage.draw(with: .mediaBox, to: $0) }
        check(greenPixels(greenRendering) > 100,
              "serialized standard FreeText did not render the selected green text natively")
        let current = FreeTextEditDraft(document: document, page: page, annotation: annotation)
        var omitted = current.values; omitted.text = "A later edit without a color override"
        omitted.fontColor = nil
        undo.beginUndoGrouping(); let omittedSaved = store.saveFreeText(current, values: omitted); undo.endUndoGrouping()
        check(omittedSaved && FreeTextAnnotationEditing.matchesTextColor(green, annotation: annotation),
              "a subsequent nil-color edit rewrote the previously selected native font color")
        undo.undo()
        queue.waitUntilDrained()
        let savedCopy = try require(PDFDocument(url: copies.workingCopyURL(forOriginalURL: originalURL)))
        let savedAnnotation = try require(savedCopy.page(at: 0)?.annotations.first { $0.type == "FreeText" })
        let finalOriginalBytes = try Data(contentsOf: originalURL)
        check(FreeTextAnnotationEditing.matchesTextColor(green, annotation: savedAnnotation)
              && savedAnnotation.contents == originalText && finalOriginalBytes == originalBytes,
              "the actual working copy lost its selected text color or changed original PDF bytes")
    }

    private static func exerciseFontFace(root: URL, defaults: UserDefaults,
                                         check: (Bool, String) -> Void) throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let originalURL = root.appendingPathComponent("original-font.pdf"), originalBytes = externalFreeTextPDF()
        try originalBytes.write(to: originalURL)
        let copies = try PDFWorkingCopyStore(directoryURL: root.appendingPathComponent("copies"))
        let queue = PDFSaveQueue(recoveryDirectoryURL: root.appendingPathComponent("recovery"))
        defer { queue.waitUntilDrained() }
        let access = DocumentAccessCoordinator(saveQueue: queue)
        let store = PDFDocumentStore(feedbackCenter: OperationFeedbackCenter(userDefaults: defaults),
            metadataStore: DocumentMetadataStore(stateURL: root.appendingPathComponent("metadata.json")),
            aiHighlightGroupStore: AIHighlightGroupStore(stateURL: root.appendingPathComponent("groups.json")),
            workingCopyStore: copies, saveQueue: queue, accessCoordinator: access)
        defer { store.releaseEditorAccess() }
        check(store.openPDF(from: originalURL), "font-face fixture could not open its isolated actual PDF")
        let document = try require(store.document), page = try require(document.page(at: 0))
        let annotation = try require(page.annotations.first { $0.type == "FreeText" })
        let originalFont = try require(annotation.font), originalColor = try require(annotation.fontColor)
        let draft = FreeTextEditDraft(document: document, page: page, annotation: annotation)
        let expectedFont = try require(NSFont(name: "Georgia", size: originalFont.pointSize))
        let expectedName = expectedFont.fontName, originalText = annotation.contents
        let originalBounds = annotation.bounds, originalDate = annotation.modificationDate
        let undo = UndoManager(); undo.groupsByEvent = false; store.setUndoManager(undo)
        check(expectedName != originalFont.fontName && draft.originalFontName == originalFont.fontName
            && draft.values.fontName == nil
            && FreeTextAnnotationEditing.resizedFont(draft.values, annotation: annotation).fontName == originalFont.fontName,
            "the font fixture lacks a distinct available canonical face, or omitted face changes the original descriptor")
        let missingName = "Dogear-Unavailable-Font-\(UUID())"
        var invalid = draft.values; invalid.fontName = missingName
        check(NSFont(name: missingName, size: originalFont.pointSize) == nil
            && FreeTextAnnotationEditing.validationMessage(invalid, draft: draft) != nil
            && !store.saveFreeText(draft, values: invalid) && annotation.font?.fontName == originalFont.fontName
            && annotation.modificationDate == originalDate && !undo.canUndo && !store.hasUnsavedChanges,
            "an unavailable explicit font face was accepted or changed the standard PDF/Undo/save state")
        var values = draft.values; values.fontName = expectedName
        undo.beginUndoGrouping(); let saved = store.saveFreeText(draft, values: values); undo.endUndoGrouping()
        check(saved && annotation.font?.fontName == expectedName && annotation.font?.pointSize == originalFont.pointSize
            && annotation.fontColor?.isEqual(originalColor) == true && annotation.contents == originalText
            && annotation.bounds == originalBounds && annotation.userName == "External author"
            && (annotation.value(forAnnotationKey: .name) as? String) == "external-freetext-fixture",
            "a font-only actual Store save failed its exact canonical face or changed unrelated PDF values")
        undo.undo()
        check(annotation.font?.fontName == originalFont.fontName && annotation.font?.isEqual(originalFont) == true
            && annotation.modificationDate == originalDate && !undo.canUndo && undo.canRedo,
            "one document Undo failed to restore the original font face, descriptor and timestamp")
        undo.redo()
        check(annotation.font?.fontName == expectedName && annotation.font?.pointSize == expectedFont.pointSize
            && annotation.contents == originalText && annotation.fontColor?.isEqual(originalColor) == true,
            "document Redo failed to restore the selected canonical font face exactly")
        let serialized = try require(document.dataRepresentationWithAIAnnotationsDisplayed())
        let serializedDocument = try require(PDFDocument(data: serialized))
        let serializedAnnotation = try require(serializedDocument.page(at: 0)?.annotations.first { $0.type == "FreeText" })
        check(serializedAnnotation.font?.fontName == expectedName && serializedAnnotation.font?.pointSize == expectedFont.pointSize
            && serializedAnnotation.contents == originalText && serializedAnnotation.bounds == originalBounds
            && serializedAnnotation.value(forAnnotationKey: .defaultAppearance) is String,
            "standard PDF serialization failed exact canonical font-face and /DA native readback")
        let current = FreeTextEditDraft(document: document, page: page, annotation: annotation)
        var resized = current.values; resized.fontSize = 24
        undo.beginUndoGrouping(); let resizedSaved = store.saveFreeText(current, values: resized); undo.endUndoGrouping()
        check(resized.fontName == nil && resizedSaved && annotation.font?.fontName == expectedName
            && annotation.font?.pointSize == 24,
            "a later omitted-face size edit replaced the previously selected canonical font")
        undo.undo(); queue.waitUntilDrained()
        let diskDocument = try require(PDFDocument(url: copies.workingCopyURL(forOriginalURL: originalURL)))
        let diskAnnotation = try require(diskDocument.page(at: 0)?.annotations.first { $0.type == "FreeText" })
        let originalAfter = try Data(contentsOf: originalURL)
        check(diskAnnotation.font?.fontName == expectedName && diskAnnotation.font?.pointSize == originalFont.pointSize
            && diskAnnotation.contents == originalText && originalAfter == originalBytes,
            "the actual working-copy reload lost the canonical selected face or altered original PDF bytes")
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
        var count = 0
        for index in stride(from: 0, to: bytes.count, by: 4) {
            let channel = Int(bytes[index + 2])
            let red = Int(bytes[index])
            let other = Int(bytes[index + 1])
            if channel > red + 50 && channel > other + 50 { count += 1 }
        }
        return count
    }

    private static func greenPixels(_ bytes: [UInt8]) -> Int {
        var count = 0
        for index in stride(from: 0, to: bytes.count, by: 4) {
            let channel = Int(bytes[index + 1])
            let red = Int(bytes[index])
            let other = Int(bytes[index + 2])
            if channel > red + 50 && channel > other + 50 { count += 1 }
        }
        return count
    }

    private static func require<T>(_ value: T?) throws -> T {
        guard let value else { throw FixtureError.missing }; return value
    }

    private enum FixtureError: Error { case missing }
}
