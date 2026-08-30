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
        let data = NSMutableData()
        guard let consumer = CGDataConsumer(data: data as CFMutableData) else {
            throw AIHighlightNativePDFDiagnosticError.cannotCreatePDF
        }
        var mediaBox = CGRect(x: 0, y: 0, width: 612, height: 792)
        guard let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else {
            throw AIHighlightNativePDFDiagnosticError.cannotCreatePDF
        }

        context.beginPDFPage(nil)
        context.textMatrix = .identity
        context.textPosition = CGPoint(x: 72, y: 700)
        let font = CTFontCreateWithName("Helvetica" as CFString, 14, nil)
        let attributedText = NSAttributedString(
            string: text,
            attributes: [kCTFontAttributeName as NSAttributedString.Key: font]
        )
        CTLineDraw(CTLineCreateWithAttributedString(attributedText), context)
        context.endPDFPage()
        context.closePDF()

        guard let document = PDFDocument(data: data as Data), document.pageCount == 1 else {
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
