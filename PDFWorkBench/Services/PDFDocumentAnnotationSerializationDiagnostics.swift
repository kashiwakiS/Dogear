import Foundation
import PDFKit

/// Native mixed-annotation PDFs exercise the complete serializer used by
/// document snapshots, working copies and selective exports. No user files.
@MainActor
enum PDFDocumentAnnotationSerializationDiagnostics {
    static func run() -> (checks: Int, failures: [String]) {
        var checks = 0
        var failures: [String] = []
        func check(_ condition: @autoclosure () -> Bool, _ message: String) {
            checks += 1
            if !condition() { failures.append(message) }
        }
        do {
            let document = try linkedNoteAndLinkPDF()
            let page = try require(document.page(at: 0))
            let text = try require(named("note-fixture", in: page))
            let popup = try require(named("popup-fixture", in: page))
            let visibleLink = try require(named("link-visible", in: page))
            let hiddenLink = try require(named("link-hidden", in: page))
            text.shouldDisplay = false
            popup.shouldDisplay = true
            hiddenLink.shouldDisplay = false
            let freeText = PDFAnnotation(bounds: CGRect(x: 40, y: 160, width: 180, height: 40),
                forType: .freeText, withProperties: nil)
            freeText.contents = "FreeText fixture"
            freeText.font = PDFPlatformFont(name: "Helvetica", size: 14)
            freeText.shouldDisplay = false
            _ = freeText.setValue("freetext-fixture", forAnnotationKey: .name)
            page.addAnnotation(freeText)
            let manual = highlight(name: "manual-visible", in: page)
            let hiddenManual = highlight(name: "manual-hidden", in: page)
            hiddenManual.shouldDisplay = false
            let groupA = UUID(), groupB = UUID()
            let aiA = highlight(name: AIAnnotationProvenance.makeUniqueName(groupID: groupA), in: page)
            let aiB = highlight(name: AIAnnotationProvenance.makeUniqueName(groupID: groupB), in: page)
            try AIAnnotationProvenance.assignMetadata(to: aiA,
                uniqueName: try require(AIAnnotationProvenance.uniqueName(of: aiA)), category: .evidence,
                groupID: groupA, modificationDate: Date(timeIntervalSince1970: 1_700_000_000))
            try AIAnnotationProvenance.assignMetadata(to: aiB,
                uniqueName: try require(AIAnnotationProvenance.uniqueName(of: aiB)), category: .limitation,
                groupID: groupB, modificationDate: Date(timeIntervalSince1970: 1_700_000_000))
            aiA.shouldDisplay = false
            let indexed = highlight(name: "indexed-ai-fixture", in: page)
            indexed.shouldDisplay = false
            let indexedNames: Set<String> = ["indexed-ai-fixture"]
            check(text.popup === popup && popup.page === page,
                "The native Text/Popup fixture did not retain its linked objects.")

            let noteState = document.setNoteAnnotationsShouldDisplay(false)
            check(noteState.count == 3 && Set(noteState.map { ObjectIdentifier($0.annotation) }).count == 3
                && !text.shouldDisplay && !popup.shouldDisplay && !freeText.shouldDisplay,
                "Note normalization omitted a native note or captured the linked Popup twice.")
            document.restoreNoteAnnotationDisplayStates(noteState)
            check(!text.shouldDisplay && popup.shouldDisplay && !freeText.shouldDisplay,
                "Note restoration lost distinct Text/Popup/FreeText display values.")

            let registry = QuietLinkDisplayRegistry.shared
            var readerCount = 0
            defer { for _ in 0..<readerCount { registry.endDisplaying(document) } }
            registry.beginDisplaying(document); readerCount += 1
            registry.beginDisplaying(document); readerCount += 1
            check(!visibleLink.shouldDisplay && !hiddenLink.shouldDisplay,
                "Quiet-link display did not hide the native links for both readers.")
            let liveState = page.annotations.map { ($0, $0.shouldDisplay) }
            let originalCount = page.annotations.count
            let data = try require(document.dataRepresentationWithAIAnnotationsDisplayed(indexedUniqueNames: indexedNames))
            let restored = try require(PDFDocument(data: data))
            let restoredPage = try require(restored.page(at: 0))
            check(restored !== document && restoredPage.annotations.count == originalCount,
                "Shared serialization lost annotations or returned the writable document.")
            check(liveState.allSatisfy { $0.0.page === page && $0.0.shouldDisplay == $0.1 },
                "Shared serialization leaked temporary visibility into the live PDF.")
            let restoredA = try require(named(try require(AIAnnotationProvenance.uniqueName(of: aiA)), in: restoredPage))
            let restoredB = try require(named(try require(AIAnnotationProvenance.uniqueName(of: aiB)), in: restoredPage))
            let restoredIndexed = try require(named("indexed-ai-fixture", in: restoredPage))
            check(restoredA.shouldDisplay && restoredB.shouldDisplay && restoredIndexed.shouldDisplay
                && AIAnnotationProvenance.groupID(of: restoredA) == groupA
                && AIAnnotationProvenance.embeddedMetadata(of: restoredB)?.category == .limitation,
                "Shared serialization lost AI visibility, group identity or embedded metadata.")
            let restoredText = try require(named("note-fixture", in: restoredPage))
            let restoredPopup = try require(named("popup-fixture", in: restoredPage))
            let restoredFreeText = try require(named("freetext-fixture", in: restoredPage))
            check(restoredText.shouldDisplay && restoredPopup.shouldDisplay && restoredFreeText.shouldDisplay
                && restoredText.popup === restoredPopup && restoredText.contents == text.contents
                && restoredFreeText.contents == "FreeText fixture",
                "Shared serialization lost displayed native notes, linked Popup or note content.")
            check(named("link-visible", in: restoredPage)?.shouldDisplay == true
                && named("link-hidden", in: restoredPage)?.shouldDisplay == false,
                "Shared serialization persisted quiet-reader flags instead of original link appearance.")
            check(named("manual-visible", in: restoredPage)?.shouldDisplay == true
                && named("manual-hidden", in: restoredPage)?.shouldDisplay == false,
                "Shared serialization normalized a manual annotation's original visibility.")

            let included = try exported(document, selection: .include, indexedNames: indexedNames)
            let excluded = try exported(document, selection: .exclude, indexedNames: indexedNames)
            let selected = try exported(document, selection: .selectedGroups([groupA]), indexedNames: indexedNames)
            let none = try exported(document, selection: .selectedGroups([]), indexedNames: indexedNames)
            check(aiCount(in: included, indexedNames: indexedNames) == 3
                && included.page(at: 0)?.annotations.count == originalCount,
                "Include export lost genuine or indexed AI annotations.")
            check(aiCount(in: excluded, indexedNames: indexedNames) == 0
                && excluded.page(at: 0)?.annotations.count == originalCount - 3,
                "Exclude export removed manual annotations or retained AI annotations.")
            check(aiCount(in: selected, indexedNames: indexedNames) == 1
                && selected.page(at: 0)?.annotations.contains { AIAnnotationProvenance.groupID(of: $0) == groupA } == true
                && selected.page(at: 0)?.annotations.count == originalCount - 2,
                "Selected-group export did not keep exactly the requested genuine AI group.")
            check(aiCount(in: none, indexedNames: indexedNames) == 0
                && none.page(at: 0)?.annotations.count == originalCount - 3,
                "Selecting no AI groups changed manual annotations or kept an AI annotation.")
            check([included, excluded, selected, none].allSatisfy { copy in
                guard let copyPage = copy.page(at: 0) else { return false }
                return named("note-fixture", in: copyPage)?.shouldDisplay == true
                    && named("popup-fixture", in: copyPage)?.shouldDisplay == true
                    && named("freetext-fixture", in: copyPage)?.shouldDisplay == true
                    && named("link-visible", in: copyPage)?.shouldDisplay == true
                    && named("link-hidden", in: copyPage)?.shouldDisplay == false
                    && named("manual-visible", in: copyPage)?.shouldDisplay == true
                    && named("manual-hidden", in: copyPage)?.shouldDisplay == false
            }, "An AI export scope changed notes, manual visibility or original link appearance.")
            check(page.annotations.count == originalCount && manual.page === page
                && liveState.allSatisfy { $0.0.page === page && $0.0.shouldDisplay == $0.1 },
                "Selective export changed live annotation identity, count or display state.")
            registry.endDisplaying(document); readerCount -= 1
            check(!visibleLink.shouldDisplay && !hiddenLink.shouldDisplay,
                "Closing one reader prematurely restored quiet native links.")
            registry.endDisplaying(document); readerCount -= 1
            check(visibleLink.shouldDisplay && !hiddenLink.shouldDisplay,
                "Closing the last reader lost the original distinct link display values.")

            let failed = FailingAnnotationSerializationDocument()
            let failedPage = PDFPage()
            failed.insert(failedPage, at: 0)
            let failedNote = PDFAnnotation(bounds: CGRect(x: 20, y: 30, width: 80, height: 30),
                forType: .freeText, withProperties: nil)
            failedNote.shouldDisplay = false
            failedPage.addAnnotation(failedNote)
            let failedAI = highlight(name: AIAnnotationProvenance.makeUniqueName(groupID: groupA), in: failedPage)
            failedAI.shouldDisplay = false
            let failedLink = PDFAnnotation(bounds: CGRect(x: 20, y: 60, width: 80, height: 20),
                forType: .link, withProperties: nil)
            failedPage.addAnnotation(failedLink)
            registry.beginDisplaying(failed)
            defer { registry.endDisplaying(failed) }
            check(failed.dataRepresentationWithAIAnnotationsDisplayed() == nil
                && !failedNote.shouldDisplay && !failedAI.shouldDisplay && !failedLink.shouldDisplay,
                "A nil native serialization result leaked temporary note, AI or link flags.")
            do {
                _ = try AIAnnotationSelectiveExporter.dataRepresentation(of: failed, selection: .include)
                check(false, "A failed native serializer reported a successful selective export.")
            } catch AIHighlightNativeAnnotationError.serializationFailed { check(true, "") }
            check(!failedNote.shouldDisplay && !failedAI.shouldDisplay && !failedLink.shouldDisplay,
                "A throwing selective export failed to restore live display state.")
        } catch { failures.append("Annotation serialization fixture: \(error.localizedDescription)") }
        return (checks, failures)
    }

    private static func named(_ name: String, in page: PDFPage) -> PDFAnnotation? {
        page.annotations.first { ($0.value(forAnnotationKey: .name) as? String) == name }
    }

    private static func highlight(name: String, in page: PDFPage) -> PDFAnnotation {
        let annotation = PDFAnnotation(bounds: CGRect(x: 40, y: 80, width: 80, height: 20),
            forType: .highlight, withProperties: nil)
        annotation.quadrilateralPoints = [CGPoint(x: 0, y: 20), CGPoint(x: 80, y: 20),
            CGPoint.zero, CGPoint(x: 80, y: 0)].map(PDFPlatformStyle.pointValue)
        _ = annotation.setValue(name, forAnnotationKey: .name)
        page.addAnnotation(annotation)
        return annotation
    }

    private static func aiCount(in document: PDFDocument, indexedNames: Set<String>) -> Int {
        (0..<document.pageCount).reduce(0) { count, index in
            count + (document.page(at: index)?.annotations.filter {
                AIAnnotationProvenance.classify($0, indexedUniqueNames: indexedNames).isAI
            }.count ?? 0)
        }
    }

    private static func exported(
        _ document: PDFDocument, selection: AIAnnotationExportSelection, indexedNames: Set<String>
    ) throws -> PDFDocument {
        try require(PDFDocument(data: AIAnnotationSelectiveExporter.dataRepresentation(
            of: document, selection: selection, indexedUniqueNames: indexedNames)))
    }

    private static func require<T>(_ value: T?) throws -> T {
        guard let value else { throw FixtureError.missing }
        return value
    }

    private static func linkedNoteAndLinkPDF() throws -> PDFDocument {
        let objects = [
            "<< /Type /Catalog /Pages 2 0 R >>",
            "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 300 400] /Resources << >> /Annots [4 0 R 5 0 R 6 0 R 7 0 R] >>",
            "<< /Type /Annot /Subtype /Text /NM (note-fixture) /Rect [20 300 40 320] /Contents (Linked note fixture) /Popup 5 0 R /P 3 0 R /F 4 >>",
            "<< /Type /Annot /Subtype /Popup /NM (popup-fixture) /Rect [50 260 250 340] /Parent 4 0 R /P 3 0 R /Open false /F 4 >>",
            "<< /Type /Annot /Subtype /Link /NM (link-visible) /Rect [20 220 100 240] /A << /S /URI /URI (https://example.invalid/visible) >> /F 4 >>",
            "<< /Type /Annot /Subtype /Link /NM (link-hidden) /Rect [20 190 100 210] /A << /S /URI /URI (https://example.invalid/hidden) >> /F 4 >>"
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

    private enum FixtureError: Error { case missing }
}

/// Inject a native writer failure while retaining real PDFPage/PDFAnnotation
/// objects, to verify every defer-based visibility restoration path.
@MainActor
private final class FailingAnnotationSerializationDocument: PDFDocument {
    override func dataRepresentation() -> Data? { nil }
}
