import CoreGraphics
import CoreText
import Foundation
import PDFKit

@MainActor
enum AIHighlightNativePDFDiagnostics {
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
            let document = try makeTextPDF("First sentence. Second sentence.")
            let builder = NativePDFTextSnapshotBuilder(document: document)
            let firstSnapshot = try builder.makeTextSnapshot()
            let secondSnapshot = try builder.makeTextSnapshot()
            check(firstSnapshot == secondSnapshot, "Native PDF fingerprints were not repeatable.")

            if let firstPage = document.page(at: 0) {
                let annotation = PDFAnnotation(
                    bounds: CGRect(x: 70, y: 695, width: 120, height: 20),
                    forType: .highlight,
                    withProperties: nil
                )
                firstPage.addAnnotation(annotation)
                let annotatedSnapshot = try builder.makeTextSnapshot()
                check(
                    annotatedSnapshot == firstSnapshot,
                    "A highlight annotation changed the page-text cache fingerprint."
                )
                firstPage.removeAnnotation(annotation)

                let freeText = PDFAnnotation(
                    bounds: CGRect(x: 70, y: 650, width: 180, height: 40),
                    forType: .freeText,
                    withProperties: nil
                )
                freeText.contents = "Reader note version one"
                firstPage.addAnnotation(freeText)
                let freeTextAdded = try builder.makeTextSnapshot()
                freeText.contents = "Reader note version two"
                freeText.bounds = CGRect(x: 90, y: 630, width: 200, height: 50)
                let freeTextEdited = try builder.makeTextSnapshot()
                firstPage.removeAnnotation(freeText)
                let freeTextRemoved = try builder.makeTextSnapshot()
                check(
                    freeTextAdded == firstSnapshot
                        && freeTextEdited == firstSnapshot
                        && freeTextRemoved == firstSnapshot,
                    "Adding, editing, or removing a FreeText annotation changed the page-text cache fingerprint."
                )
            } else {
                check(false, "The annotation-insensitivity fixture had no first page.")
            }

            let deletionDocument = try makeTextPDF("Retained page text.")
            let removedPageDocument = try makeTextPDF("Deleted page text.")
            if let removedPage = removedPageDocument.page(at: 0) {
                deletionDocument.insert(removedPage, at: deletionDocument.pageCount)
                let beforeDeletion = try NativePDFTextSnapshotBuilder(
                    document: deletionDocument
                ).makeTextSnapshot()
                deletionDocument.removePage(at: 1)
                let afterDeletion = try NativePDFTextSnapshotBuilder(
                    document: deletionDocument
                ).makeTextSnapshot()
                check(
                    beforeDeletion.fingerprint != afterDeletion.fingerprint
                        && beforeDeletion.pages.count == 2
                        && afterDeletion.pages.count == 1,
                    "Deleting a PDF page did not invalidate the page-text cache fingerprint."
                )
            } else {
                check(false, "The page-deletion fingerprint fixture had no removable page.")
            }

            let orderedDocument = try makeTextPDF(pages: [
                "First ordered page.", "Second ordered page."
            ])
            let reorderedDocument = try makeTextPDF(pages: [
                "Second ordered page.", "First ordered page."
            ])
            let beforeReorder = try NativePDFTextSnapshotBuilder(
                document: orderedDocument
            ).makeTextSnapshot()
            let afterReorder = try NativePDFTextSnapshotBuilder(
                document: reorderedDocument
            ).makeTextSnapshot()
            check(
                beforeReorder.fingerprint != afterReorder.fingerprint
                    && beforeReorder.pages.map(\.text)
                        == Array(afterReorder.pages.map(\.text).reversed()),
                "Reordering PDF pages did not invalidate the page-text cache fingerprint."
            )

            let rotatedDocument = try makeTextPDF("Rotated page text.")
            if let page = rotatedDocument.page(at: 0) {
                let beforeRotation = try NativePDFTextSnapshotBuilder(
                    document: rotatedDocument
                ).makeTextSnapshot()
                page.rotation = 90
                let afterRotation = try NativePDFTextSnapshotBuilder(
                    document: rotatedDocument
                ).makeTextSnapshot()
                check(
                    beforeRotation.fingerprint != afterRotation.fingerprint,
                    "Changing PDF page rotation did not invalidate the page-text cache fingerprint."
                )
            } else {
                check(false, "The rotation fingerprint fixture had no page.")
            }

            let mediaDocument = try makeTextPDF("Media geometry text.")
            if let page = mediaDocument.page(at: 0) {
                let beforeMedia = try NativePDFTextSnapshotBuilder(
                    document: mediaDocument
                ).makeTextSnapshot()
                var mediaBounds = page.bounds(for: .mediaBox)
                mediaBounds.size.width -= 12
                page.setBounds(mediaBounds, for: .mediaBox)
                let afterMedia = try NativePDFTextSnapshotBuilder(
                    document: mediaDocument
                ).makeTextSnapshot()
                check(
                    beforeMedia.fingerprint != afterMedia.fingerprint,
                    "Changing PDF media-box geometry did not invalidate the page-text cache fingerprint."
                )
            } else {
                check(false, "The media-box fingerprint fixture had no page.")
            }

            let cropDocument = try makeTextPDF("Crop geometry text.")
            if let page = cropDocument.page(at: 0) {
                let beforeCrop = try NativePDFTextSnapshotBuilder(
                    document: cropDocument
                ).makeTextSnapshot()
                page.setBounds(page.bounds(for: .cropBox).insetBy(dx: 8, dy: 8), for: .cropBox)
                let afterCrop = try NativePDFTextSnapshotBuilder(
                    document: cropDocument
                ).makeTextSnapshot()
                check(
                    beforeCrop.fingerprint != afterCrop.fingerprint,
                    "Changing PDF crop-box geometry did not invalidate the page-text cache fingerprint."
                )
            } else {
                check(false, "The crop-box fingerprint fixture had no page.")
            }

            let registry = try AISegmentRegistry(snapshot: firstSnapshot)
            let staged = try makeStagedHighlight(from: registry)
            let anchors = try AIHighlightNativeAnchorResolver().resolve(
                [staged],
                registry: registry,
                in: document
            )
            check(anchors.count == 1, "The native anchor resolver returned no anchor.")
            check(
                anchors.first?.lineBounds.isEmpty == false,
                "The native anchor resolver returned no line bounds."
            )
            check(
                anchors.first?.quadrilateralPoints.count == 4,
                "The native anchor resolver did not return one PDF highlight quadrilateral."
            )

            let changedDocument = try makeTextPDF("Changed sentence. Second sentence.")
            do {
                _ = try AIHighlightNativeAnchorResolver().resolve(
                    [staged],
                    registry: registry,
                    in: changedDocument
                )
                check(false, "Changed page text was accepted by the anchor resolver.")
            } catch let error as AIHighlightNativePDFBridgeError {
                check(
                    error == .pageFingerprintChanged(1),
                    "Changed page text returned an unexpected resolver error."
                )
            }

            let noSelectionDocument = PDFDocument()
            noSelectionDocument.insert(
                NoSelectionPDFPage(text: "Selection cannot be created."),
                at: 0
            )
            let noSelectionSnapshot = try NativePDFTextSnapshotBuilder(
                document: noSelectionDocument
            ).makeTextSnapshot()
            let noSelectionRegistry = try AISegmentRegistry(snapshot: noSelectionSnapshot)
            let noSelectionStaged = try makeStagedHighlight(from: noSelectionRegistry)
            do {
                _ = try AIHighlightNativeAnchorResolver().resolve(
                    [noSelectionStaged],
                    registry: noSelectionRegistry,
                    in: noSelectionDocument
                )
                check(false, "A page without PDFKit selection support was accepted.")
            } catch let error as AIHighlightNativePDFBridgeError {
                if case .selectionUnavailable = error {
                    check(true, "")
                } else {
                    check(false, "Missing selection returned an unexpected resolver error.")
                }
            }
        } catch {
            failures.append(error.localizedDescription)
        }

        return AIHighlightFoundationDiagnosticReport(
            checkCount: checkCount,
            failures: failures
        )
    }

    private static func makeStagedHighlight(
        from registry: AISegmentRegistry
    ) throws -> StagedAIHighlight {
        guard let record = registry.records.first else {
            throw AIHighlightNativePDFDiagnosticError.noSegments
        }
        let candidate = AIHighlightCandidate(
            candidateID: "native-pdf-diagnostic",
            segmentIDs: [record.id],
            category: .evidence,
            importance: 4,
            note: nil
        )
        return StagedAIHighlight(
            candidate: candidate,
            pageNumber: record.id.page,
            sourceKind: .nativeText
        )
    }

    private static func makeTextPDF(_ text: String) throws -> PDFDocument {
        try makeTextPDF(pages: [text])
    }

    private static func makeTextPDF(pages: [String]) throws -> PDFDocument {
        let data = NSMutableData()
        guard let consumer = CGDataConsumer(data: data as CFMutableData) else {
            throw AIHighlightNativePDFDiagnosticError.cannotCreatePDF
        }
        var mediaBox = CGRect(x: 0, y: 0, width: 612, height: 792)
        guard let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else {
            throw AIHighlightNativePDFDiagnosticError.cannotCreatePDF
        }

        let font = CTFontCreateWithName("Helvetica" as CFString, 14, nil)
        for text in pages {
            context.beginPDFPage(nil)
            context.textMatrix = .identity
            context.textPosition = CGPoint(x: 72, y: 700)
            let attributedText = NSAttributedString(
                string: text,
                attributes: [kCTFontAttributeName as NSAttributedString.Key: font]
            )
            CTLineDraw(CTLineCreateWithAttributedString(attributedText), context)
            context.endPDFPage()
        }
        context.closePDF()

        guard let document = PDFDocument(data: data as Data), document.pageCount == pages.count else {
            throw AIHighlightNativePDFDiagnosticError.cannotCreatePDF
        }
        return document
    }
}

@MainActor
private final class NoSelectionPDFPage: PDFPage {
    private let diagnosticText: String

    init(text: String) {
        diagnosticText = text
        super.init()
        setBounds(CGRect(x: 0, y: 0, width: 612, height: 792), for: .mediaBox)
        setBounds(CGRect(x: 0, y: 0, width: 612, height: 792), for: .cropBox)
    }

    required init?(coder: NSCoder) {
        return nil
    }

    override var string: String? { diagnosticText }

    override func selection(for range: NSRange) -> PDFSelection? {
        nil
    }
}

nonisolated private enum AIHighlightNativePDFDiagnosticError: LocalizedError {
    case cannotCreatePDF
    case noSegments

    var errorDescription: String? {
        switch self {
        case .cannotCreatePDF:
            return "Could not create the in-memory native-text PDF fixture."
        case .noSegments:
            return "The in-memory native-text PDF fixture produced no segments."
        }
    }
}
