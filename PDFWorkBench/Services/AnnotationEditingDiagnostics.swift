import AppKit
import Foundation
import PDFKit

/// Native PDF fixtures and private temporary stores; no user documents or AI.
@MainActor
enum AnnotationEditingDiagnostics {
    static func run() -> AIHighlightFoundationDiagnosticReport {
        var checks = 0
        var failures: [String] = []
        func check(_ condition: @autoclosure () -> Bool, _ message: String) {
            checks += 1
            if !condition() { failures.append(message) }
        }
        do {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("DogearAnnotationEditing-\(UUID())")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }
            let defaultsName = "DogearAnnotationEditing-\(UUID())"
            let defaults = UserDefaults(suiteName: defaultsName)!
            defer { defaults.removePersistentDomain(forName: defaultsName) }
            let queue = PDFSaveQueue(recoveryDirectoryURL: root.appendingPathComponent("recovery"))
            defer { queue.waitUntilDrained() }
            let copies = try PDFWorkingCopyStore(directoryURL: root.appendingPathComponent("copies"))
            let coordinator = DocumentAccessCoordinator(saveQueue: queue)
            let store = PDFDocumentStore(feedbackCenter: OperationFeedbackCenter(userDefaults: defaults),
                metadataStore: DocumentMetadataStore(stateURL: root.appendingPathComponent("metadata.json")),
                aiHighlightGroupStore: AIHighlightGroupStore(stateURL: root.appendingPathComponent("groups.json")),
                workingCopyStore: copies, saveQueue: queue, accessCoordinator: coordinator)
            defer { store.releaseEditorAccess() }
            let groupA = UUID(), groupB = UUID()
            let fixture = try linkedNotePDF()
            let fixturePage = try require(fixture.page(at: 0))
            let manual = highlight(quote: "Literal **quote**\nsecond line", y: 600)
            fixturePage.addAnnotation(manual)
            let freeText = PDFAnnotation(bounds: CGRect(x: 72, y: 450, width: 180, height: 60), forType: .freeText, withProperties: nil)
            freeText.contents = "FreeText line one\nline two"
            fixturePage.addAnnotation(freeText)
            for (group, y) in [(groupA, 560.0), (groupA, 530.0), (groupB, 500.0)] {
                let annotation = highlight(quote: "AI quote \(y)", y: y)
                _ = annotation.setValue(AIAnnotationProvenance.makeUniqueName(groupID: group), forAnnotationKey: .name)
                annotation.userName = AIAnnotationProvenance.authorName
                fixturePage.addAnnotation(annotation)
            }
            let originalURL = root.appendingPathComponent("original.pdf")
            let originalBytes = try require(fixture.dataRepresentation())
            try originalBytes.write(to: originalURL)
            guard store.openPDF(from: originalURL) else { throw FixtureError.missing }
            store.bindLibraryFile(UUID())
            let document = try require(store.document)
            let page = try require(document.page(at: 0))
            let undo = UndoManager()
            undo.groupsByEvent = false
            store.setUndoManager(undo)
            func mutation(_ body: () -> Void) { undo.beginUndoGrouping(); body(); undo.endUndoGrouping() }
            let manualItem = try require(store.annotations.first { $0.kind == .highlight && !$0.isAIGenerated })
            let draft = try require(store.highlightEditDraft(for: manualItem))
            let annotation = draft.annotation
            let oldDate = annotation.modificationDate
            let oldName = annotation.value(forAnnotationKey: .name) as? String
            let oldBounds = annotation.bounds
            let oldPoints = annotation.quadrilateralPoints
            let comment = "Changed **comment**\n\nsecond paragraph"
            check(undo.canUndo == false && annotation.contents == draft.comment, "Opening an editor mutated the PDF.")
            mutation { check(store.updateHighlight(draft, color: .systemPink, comment: comment), "The valid highlight edit was rejected.") }
            check(annotation.contents == comment && annotation.color.alphaComponent == draft.color.alphaComponent,
                "The highlight comment or opacity was not preserved correctly.")
            check(annotation.bounds == oldBounds && annotation.quadrilateralPoints == oldPoints
                && (annotation.value(forAnnotationKey: .name) as? String) == oldName,
                "Editing changed highlight identity or geometry.")
            check(store.annotations.first { $0.id == manualItem.id }?.text == manualItem.text,
                "Editing the comment replaced the quoted source text.")
            undo.undo()
            check(annotation.contents == draft.comment && annotation.color.isEqual(draft.color)
                && annotation.modificationDate == oldDate, "One Undo did not restore all original highlight properties.")
            check(!undo.canUndo, "One highlight edit registered multiple Undo operations.")
            undo.redo()
            check(annotation.contents == comment, "Redo did not reapply the highlight comment.")
            let changedColor = annotation.color
            let roundTrip = try require(document.dataRepresentationWithAIAnnotationsDisplayed().flatMap(PDFDocument.init(data:)))
            let copiedManual = try require(AnnotationExtractor.annotationItems(in: roundTrip).first { $0.kind == .highlight && !$0.isAIGenerated })
            check(copiedManual.note == comment && copiedManual.text == manualItem.text,
                "Edited quote/comment did not survive native PDF serialization.")
            let roundTripAnnotation = try require(AnnotationExtractor.annotation(matching: copiedManual, in: roundTrip))
            check(sameRGB(roundTripAnnotation.color, changedColor), "Edited highlight color did not survive PDF serialization.")

            // A model-generated highlight remains the same native AI annotation after manual editing.
            let aiItem = try require(store.annotations.first { $0.aiGroupID == groupB })
            let aiDraft = try require(store.highlightEditDraft(for: aiItem))
            let aiName = AIAnnotationProvenance.uniqueName(of: aiDraft.annotation)
            mutation { _ = store.updateHighlight(aiDraft, color: .systemGreen, comment: "Human comment") }
            check(AIAnnotationProvenance.uniqueName(of: aiDraft.annotation) == aiName
                && store.annotations.first { $0.id == aiItem.id }?.aiGroupID == groupB,
                "Editing an AI highlight lost its provenance or group.")
            undo.removeAllActions()

            let textItem = try require(store.annotations.first { $0.note == "Sticky fixture" })
            let textAnnotation = try require(AnnotationExtractor.annotation(matching: textItem, in: document))
            let popup = try require(textAnnotation.popup)
            check(popup.page === page, "The canonical Text note fixture did not have a page-owned Popup.")
            mutation { store.removeAnnotation(textItem) }
            check(textAnnotation.page == nil && popup.page == nil, "Deleting Text left its native Popup on the page.")
            undo.undo()
            check(textAnnotation.page === page && popup.page === page && textAnnotation.popup === popup,
                "Undo did not restore the exact Text/Popup pair.")
            undo.redo()
            check(textAnnotation.page == nil && popup.page == nil, "Redo did not remove the Text/Popup pair.")
            undo.undo()
            undo.removeAllActions()
            let freeTextItem = try require(store.annotations.first { $0.note.hasPrefix("FreeText") })
            let nativeFreeText = try require(AnnotationExtractor.annotation(matching: freeTextItem, in: document))
            mutation { store.removeAnnotation(freeTextItem) }
            check(nativeFreeText.page == nil, "FreeText deletion did not remove its native annotation.")
            undo.undo()
            check(nativeFreeText.page === page && nativeFreeText.contents == freeTextItem.note,
                "FreeText Undo lost the annotation object or text.")
            undo.redo()
            check(nativeFreeText.page == nil, "FreeText Redo did not remove its native annotation.")
            undo.undo()
            undo.removeAllActions()

            store.activateAIHighlightGroup(groupB)
            store.setAIHighlightGroupVisible(groupA, isVisible: false)
            let originalGroup = try require(store.aiHighlightGroups.first { $0.id == groupA })
            let groupObjects = page.annotations.filter { AIAnnotationProvenance.displayGroupID(of: $0) == groupA }
            mutation { check(store.removeAIHighlightGroupAnnotations(groupA) == 2, "Group deletion did not count exactly two highlights.") }
            check(groupObjects.allSatisfy { $0.page == nil } && store.aiHighlightCount(in: groupB) == 1
                && annotation.page === page && nativeFreeText.page === page && textAnnotation.page === page,
                "Group deletion touched manual notes/highlights or a different AI group.")
            check(!store.aiHighlightGroups.contains { $0.id == groupA }, "Deleted group metadata remained visible.")
            undo.undo()
            check(!undo.canUndo && groupObjects.allSatisfy { $0.page === page && !$0.shouldDisplay },
                "One Undo failed to restore the entire hidden group with its exact native objects.")
            check(store.aiHighlightGroups.first { $0.id == groupA } == originalGroup
                && store.activeAIHighlightGroupID == groupB, "Group Undo changed metadata or the previous active group.")
            undo.redo()
            check(store.aiHighlightCount(in: groupA) == 0 && store.aiHighlightCount(in: groupB) == 1,
                "Group Redo removed a different group or restored deleted annotations.")
            undo.undo()
            undo.removeAllActions()

            store.activateAIHighlightGroup(nil)
            store.annotationOriginFilter = .manual
            store.annotationKindFilter = .highlights
            store.annotationSearchText = "Changed"
            check(store.annotationsForExport(scope: .all).count == 6, "All export silently excluded hidden groups or notes.")
            check(store.annotationsForExport(scope: .filtered).count == 1
                && store.annotationsForExport(scope: .filtered).first?.text == manualItem.text,
                "Filtered export ignored the current source/type/query scope.")
            store.selectAnnotation(try require(store.filteredAnnotations.first))
            check(store.annotationsForExport(scope: .selected).count == 1, "Selected export was not exactly one selected annotation.")
            let markdown = MarkdownExportService.annotationsMarkdown(documentName: "Fixture", annotations: store.annotationsForExport(scope: .selected))
            check(markdown.contains("### Page 1 · Highlight") && markdown.contains("> Literal \\*\\*quote\\*\\*  \n> second line")
                && markdown.contains("> Changed \\*\\*comment\\*\\*\n> \n> second paragraph"),
                "Markdown lost page/type/quote/comment structure or multiline literal content.")
            store.annotationSearchText = "no matching annotation"
            check(store.annotationsForExport(scope: .filtered).isEmpty && store.annotationsForExport(scope: .selected).isEmpty,
                "Empty filtered export retained a stale hidden selection.")
            check(MarkdownExportService.annotationsMarkdown(documentName: "Empty", annotations: []).contains("No highlights or notes found"),
                "Empty Markdown output was not explicit.")
            store.annotationSearchText = ""
            let currentManualItem = try require(store.annotations.first { $0.kind == .highlight && !$0.isAIGenerated })
            mutation { store.removeAnnotation(currentManualItem) }
            check(!store.updateHighlight(draft, color: .black, comment: "stale"), "A removed editor target was mutated.")
            undo.undo()
            queue.waitUntilDrained()
            let unchangedOriginal = try Data(contentsOf: originalURL)
            check(unchangedOriginal == originalBytes, "An annotation edit/delete/export modified the original PDF.")
            let saved = try require(PDFDocument(url: copies.workingCopyURL(forOriginalURL: originalURL)))
            check(AnnotationExtractor.annotationItems(in: saved).count == 6, "The working copy lost annotations after edit/delete/Undo.")
            check(AnnotationExtractor.annotationItems(in: saved).first { !$0.isAIGenerated && $0.kind == .highlight }?.note == comment,
                "The working copy did not contain the final edited comment.")
            store.releaseEditorAccess()
            check(!store.updateHighlight(draft, color: .black, comment: "unauthorized"), "An editor without the document write lease changed a highlight.")
            check(store.removeAIHighlightGroupAnnotations(groupA) == 0, "Group deletion bypassed the document write lease.")
        } catch {
            failures.append(error.localizedDescription)
        }
        return .init(checkCount: checks, failures: failures)
    }

    private static func highlight(quote: String, y: Double) -> PDFAnnotation {
        let annotation = PDFAnnotation(bounds: CGRect(x: 72, y: y, width: 200, height: 18), forType: .highlight, withProperties: nil)
        annotation.color = NSColor.systemYellow.withAlphaComponent(0.4)
        annotation.contents = "Initial comment"
        annotation.modificationDate = Date(timeIntervalSince1970: 1_700_000_000)
        annotation.quadrilateralPoints = [NSValue(point: NSPoint(x: 0, y: 18)), NSValue(point: NSPoint(x: 200, y: 18)),
            NSValue(point: .zero), NSValue(point: NSPoint(x: 200, y: 0))]
        AnnotationExtractor.storeExactHighlightText(quote, in: annotation)
        return annotation
    }

    private static func sameRGB(_ lhs: NSColor, _ rhs: NSColor) -> Bool {
        guard let lhs = lhs.usingColorSpace(.deviceRGB), let rhs = rhs.usingColorSpace(.deviceRGB) else { return false }
        return abs(lhs.redComponent - rhs.redComponent) < 0.02 && abs(lhs.greenComponent - rhs.greenComponent) < 0.02
            && abs(lhs.blueComponent - rhs.blueComponent) < 0.02
    }

    private static func require<T>(_ value: T?) throws -> T {
        guard let value else { throw FixtureError.missing }; return value
    }

    private enum FixtureError: Error { case missing }

    private static func linkedNotePDF() throws -> PDFDocument {
        let objects = [
            "<< /Type /Catalog /Pages 2 0 R >>",
            "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Resources << >> /Annots [4 0 R 5 0 R] >>",
            "<< /Type /Annot /Subtype /Text /Rect [72 650 96 674] /Contents (Sticky fixture) /Popup 5 0 R /P 3 0 R /F 4 >>",
            "<< /Type /Annot /Subtype /Popup /Rect [112 600 332 720] /Parent 4 0 R /P 3 0 R /Open false /F 4 >>"
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
        return try require(PDFDocument(data: data))
    }
}
