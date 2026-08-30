import CoreGraphics
import Foundation
import PDFKit

@MainActor
enum AIHighlightNativeAnnotationDiagnostics {
    static func run() -> AIHighlightFoundationDiagnosticReport {
        var checkCount = 0
        var failures: [String] = []

        func check(_ condition: @autoclosure () -> Bool, _ message: String) {
            checkCount += 1
            if !condition() {
                failures.append(message)
            }
        }

        do {
            let document = try makeBlankPDF()
            guard let page = document.page(at: 0) else {
                throw AIHighlightNativeAnnotationDiagnosticError.missingPage
            }

            let (anchor, staged) = fixture()
            let annotationID = UUID(
                uuidString: "71D43315-3BE3-4A0A-A6B0-1816EB3DFE8C"
            )!
            let groupID = UUID(
                uuidString: "9374E84A-2CBD-43DE-9C72-C81FE73C3B1E"
            )!
            let modificationDate = Date(timeIntervalSince1970: 1_700_000_000)
            let aiAnnotation = try AIHighlightNativeAnnotationFactory().makeAnnotation(
                anchor: anchor,
                staged: staged,
                groupID: groupID,
                id: annotationID,
                modificationDate: modificationDate
            )
            page.addAnnotation(aiAnnotation)

            let manualAnnotation = makeManualHighlight(
                color: aiAnnotation.color
            )
            page.addAnnotation(manualAnnotation)

            check(aiAnnotation.type == "Highlight", "The factory did not create a Highlight annotation.")
            check(
                aiAnnotation.contents == staged.candidate.note,
                "The factory did not preserve the AI note in Contents."
            )
            check(
                AIAnnotationProvenance.uniqueName(of: aiAnnotation)
                    == "dogear.ai.v2.\(groupID.uuidString).\(annotationID.uuidString)",
                "The factory did not assign the expected /NM value."
            )
            check(
                AIAnnotationProvenance.classify(aiAnnotation).isAI,
                "The generated annotation was not classified from its /NM prefix."
            )
            check(
                aiAnnotation.userName == AIAnnotationProvenance.authorName
                    && aiAnnotation.modificationDate == modificationDate,
                "The factory did not assign the standard author and modification date."
            )
            check(
                aiAnnotation.quadrilateralPoints?.count == 4
                    && aiAnnotation.shouldPrint,
                "The factory did not preserve printable highlight quadrilateral geometry."
            )
            check(
                !AIAnnotationProvenance.classify(manualAnnotation).isAI,
                "A same-colored manual annotation was misclassified as AI."
            )
            check(
                AIAnnotationProvenance.classify(
                    manualAnnotation,
                    indexedUniqueNames: ["manual-highlight"]
                ) == .indexedAI(uniqueName: "manual-highlight"),
                "An exact provenance-index name was not classified as AI."
            )
            check(
                AIAnnotationProvenance.embeddedMetadata(of: aiAnnotation)
                    == AIAnnotationEmbeddedMetadata(
                        schemaVersion: AIAnnotationProvenance.schemaVersion,
                        category: staged.candidate.category,
                        groupID: groupID
                    ),
                "The factory did not assign standard /Subj category metadata."
            )

            let roundTripData = try require(
                document.dataRepresentationWithAIAnnotationsDisplayed()
            )
            let roundTrip = try require(PDFDocument(data: roundTripData))
            let roundTripAI = try require(firstAIAnnotation(in: roundTrip))
            check(
                AIAnnotationProvenance.classify(roundTripAI).isAI,
                "The /NM provenance marker did not survive PDFKit round-trip."
            )
            check(
                roundTripAI.userName == AIAnnotationProvenance.authorName
                    && abs(
                        (roundTripAI.modificationDate ?? .distantPast)
                            .timeIntervalSince(modificationDate)
                    ) < 1,
                "The standard author or modification date did not survive PDFKit round-trip."
            )
            check(
                AIAnnotationProvenance.embeddedMetadata(of: roundTripAI)
                    == AIAnnotationEmbeddedMetadata(
                        schemaVersion: AIAnnotationProvenance.schemaVersion,
                        category: staged.candidate.category,
                        groupID: groupID
                    ),
                "The standard /Subj metadata did not survive PDFKit round-trip."
            )

            let hiddenState = AIAnnotationDisplayController
                .setAIAnnotationsShouldDisplay(false, in: document)
            check(
                hiddenState.annotationCount == 1
                    && !aiAnnotation.shouldDisplay
                    && manualAnnotation.shouldDisplay,
                "Display hiding changed the wrong annotations."
            )
            hiddenState.restore()
            check(
                aiAnnotation.shouldDisplay && manualAnnotation.shouldDisplay,
                "Display state restoration did not restore exact prior values."
            )

            aiAnnotation.shouldDisplay = false
            let liveCountBeforeExport = annotationCount(in: document)
            let includeData = try AIAnnotationSelectiveExporter.dataRepresentation(
                of: document,
                selection: .include
            )
            let excludeData = try AIAnnotationSelectiveExporter.dataRepresentation(
                of: document,
                selection: .exclude
            )
            let selectedGroupData = try AIAnnotationSelectiveExporter.dataRepresentation(
                of: document,
                selection: .selectedGroups([groupID])
            )
            let includeDocument = try require(PDFDocument(data: includeData))
            let excludeDocument = try require(PDFDocument(data: excludeData))
            let selectedGroupDocument = try require(PDFDocument(data: selectedGroupData))

            check(
                annotationCount(in: includeDocument) == 2
                    && aiAnnotationCount(in: includeDocument) == 1,
                "Include export did not retain both AI and manual annotations."
            )
            check(
                firstAIAnnotation(in: includeDocument)?.shouldDisplay == true,
                "Include export serialized a temporary hidden AI display state."
            )
            check(
                annotationCount(in: excludeDocument) == 1
                    && aiAnnotationCount(in: excludeDocument) == 0,
                "Exclude export did not remove only the AI annotation."
            )
            check(
                annotationCount(in: selectedGroupDocument) == 2
                    && aiAnnotationCount(in: selectedGroupDocument) == 1,
                "Selected-group export did not retain the chosen AI group."
            )
            check(
                annotationCount(in: document) == liveCountBeforeExport
                    && page.annotations.contains(where: { $0 === aiAnnotation })
                    && !aiAnnotation.shouldDisplay,
                "Selective export mutated the live document or leaked display state."
            )

            let noteDocument = try makeBlankPDF()
            let notePage = try require(noteDocument.page(at: 0))
            let textNote = PDFAnnotation(
                bounds: CGRect(x: 72, y: 620, width: 24, height: 24),
                forType: .text,
                withProperties: nil
            )
            textNote.contents = "Selectable margin note"
            let popup = PDFAnnotation(
                bounds: CGRect(x: 112, y: 540, width: 220, height: 120),
                forType: .popup,
                withProperties: nil
            )
            textNote.popup = popup
            notePage.addAnnotation(textNote)
            notePage.addAnnotation(popup)
            let noteDisplayState = noteDocument.setNoteAnnotationsShouldDisplay(false)
            check(
                noteDisplayState.count == 2
                    && !textNote.shouldDisplay
                    && !popup.shouldDisplay,
                "The reader display state did not hide native Text and Popup note UI."
            )
            let noteData = try require(
                noteDocument.dataRepresentationWithNoteAnnotationsDisplayed()
            )
            let noteRoundTrip = try require(PDFDocument(data: noteData))
            let roundTripAnnotations = noteRoundTrip.page(at: 0)?.annotations ?? []
            check(
                roundTripAnnotations.contains(where: {
                    $0.type == "Text" && $0.shouldDisplay
                })
                    && roundTripAnnotations.contains(where: {
                        $0.type == "Popup" && $0.shouldDisplay
                    })
                    && !textNote.shouldDisplay,
                "Text/Popup serialization did not normalize and restore display state."
            )
            noteDocument.restoreNoteAnnotationDisplayStates(noteDisplayState)
            check(
                textNote.shouldDisplay && popup.shouldDisplay,
                "The live Text/Popup display state was not restored."
            )
        } catch {
            failures.append(error.localizedDescription)
        }

        return AIHighlightFoundationDiagnosticReport(
            checkCount: checkCount,
            failures: failures
        )
    }

    private static func fixture() -> (
        anchor: ResolvedAIHighlightAnchor,
        staged: StagedAIHighlight
    ) {
        let segmentID = AISegmentID(
            document: 1,
            page: 1,
            block: 1,
            sentence: 1
        )
        let candidate = AIHighlightCandidate(
            candidateID: "native-annotation-diagnostic",
            segmentIDs: [segmentID],
            category: .evidence,
            importance: 4,
            note: "AI evidence note"
        )
        let staged = StagedAIHighlight(
            candidate: candidate,
            pageNumber: 1,
            sourceKind: .nativeText
        )
        let bounds = CGRect(x: 72, y: 680, width: 180, height: 18)
        let anchor = ResolvedAIHighlightAnchor(
            candidateID: candidate.candidateID,
            segmentIDs: candidate.segmentIDs,
            pageNumber: 1,
            sourceRange: AISourceTextRange(location: 0, length: 12),
            sourceTextHash: "diagnostic-source-hash",
            annotationBounds: AIPageRect(bounds),
            lineBounds: [AIPageRect(bounds)],
            quadrilateralPoints: [
                AIPagePoint(CGPoint(x: 0, y: bounds.height)),
                AIPagePoint(CGPoint(x: bounds.width, y: bounds.height)),
                AIPagePoint(CGPoint(x: 0, y: 0)),
                AIPagePoint(CGPoint(x: bounds.width, y: 0))
            ]
        )
        return (anchor, staged)
    }

    private static func makeManualHighlight(color: NSColor) -> PDFAnnotation {
        let bounds = CGRect(x: 72, y: 640, width: 160, height: 18)
        let annotation = PDFAnnotation(
            bounds: bounds,
            forType: .highlight,
            withProperties: nil
        )
        annotation.color = color
        annotation.quadrilateralPoints = [
            NSValue(point: CGPoint(x: 0, y: bounds.height)),
            NSValue(point: CGPoint(x: bounds.width, y: bounds.height)),
            NSValue(point: CGPoint(x: 0, y: 0)),
            NSValue(point: CGPoint(x: bounds.width, y: 0))
        ]
        _ = annotation.setValue("manual-highlight", forAnnotationKey: .name)
        annotation.shouldDisplay = true
        annotation.shouldPrint = true
        return annotation
    }

    private static func makeBlankPDF() throws -> PDFDocument {
        let data = NSMutableData()
        guard let consumer = CGDataConsumer(data: data as CFMutableData) else {
            throw AIHighlightNativeAnnotationDiagnosticError.cannotCreatePDF
        }
        var mediaBox = CGRect(x: 0, y: 0, width: 612, height: 792)
        guard let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else {
            throw AIHighlightNativeAnnotationDiagnosticError.cannotCreatePDF
        }
        context.beginPDFPage(nil)
        context.endPDFPage()
        context.closePDF()

        guard let document = PDFDocument(data: data as Data), document.pageCount == 1 else {
            throw AIHighlightNativeAnnotationDiagnosticError.cannotCreatePDF
        }
        return document
    }

    private static func annotationCount(in document: PDFDocument) -> Int {
        (0..<document.pageCount).reduce(into: 0) { count, pageIndex in
            count += document.page(at: pageIndex)?.annotations.count ?? 0
        }
    }

    private static func aiAnnotationCount(in document: PDFDocument) -> Int {
        (0..<document.pageCount).reduce(into: 0) { count, pageIndex in
            guard let page = document.page(at: pageIndex) else { return }
            count += page.annotations.filter {
                AIAnnotationProvenance.classify($0).isAI
            }.count
        }
    }

    private static func firstAIAnnotation(
        in document: PDFDocument
    ) -> PDFAnnotation? {
        for pageIndex in 0..<document.pageCount {
            guard let page = document.page(at: pageIndex) else { continue }
            if let annotation = page.annotations.first(where: {
                AIAnnotationProvenance.classify($0).isAI
            }) {
                return annotation
            }
        }
        return nil
    }

    private static func require<T>(_ value: T?) throws -> T {
        guard let value else {
            throw AIHighlightNativeAnnotationDiagnosticError.missingValue
        }
        return value
    }
}

nonisolated private enum AIHighlightNativeAnnotationDiagnosticError: LocalizedError {
    case cannotCreatePDF
    case missingPage
    case missingValue

    var errorDescription: String? {
        switch self {
        case .cannotCreatePDF:
            return "Could not create the in-memory PDF fixture."
        case .missingPage:
            return "The in-memory PDF fixture had no page."
        case .missingValue:
            return "A required PDFKit round-trip value was missing."
        }
    }
}
