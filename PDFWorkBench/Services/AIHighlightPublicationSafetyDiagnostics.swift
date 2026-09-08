import CoreGraphics
import CoreText
import Foundation
import PDFKit

/// In-memory PDF fixtures only; never opens, saves, or modifies a user's PDF.
@MainActor
enum AIHighlightPublicationSafetyDiagnostics {
    static func run() async -> AIHighlightFoundationDiagnosticReport {
        var checks = 0
        var failures: [String] = []
        func check(_ condition: @autoclosure () -> Bool, _ message: String) {
            checks += 1
            if !condition() { failures.append(message) }
        }

        do {
            let document = try makeTextPDF(pageCount: 4)
            let builder = NativePDFTextSnapshotBuilder(document: document)
            let snapshot = try builder.makeTextSnapshot()
            let cooperative = try await builder.makeTextSnapshotCooperatively()
            check(
                cooperative.fingerprint == snapshot.fingerprint
                    && cooperative.pages.map(\.text) == snapshot.pages.map(\.text),
                "Cooperative snapshots changed the synchronous text/fingerprint contract."
            )
            let registry = try AISegmentRegistry(snapshot: snapshot)
            let resolver = AIHighlightNativeAnchorResolver()
            try await resolver.validateSnapshotCooperatively(
                fingerprint: registry.snapshotFingerprint,
                in: document
            )
            checks += 1

            let staged = registry.records.map { record in
                StagedAIHighlight(
                    candidate: AIHighlightCandidate(
                        candidateID: "safety-\(record.id)",
                        segmentIDs: [record.id],
                        category: .evidence,
                        importance: 3,
                        note: "Fixture evidence"
                    ),
                    pageNumber: record.id.page,
                    sourceKind: .nativeText
                )
            }
            let expectedAnchors = try resolver.resolve(staged, registry: registry, in: document)
            let actualAnchors = try await resolver.resolveCooperatively(
                staged,
                registry: registry,
                in: document
            )
            check(actualAnchors == expectedAnchors, "Cooperative anchor geometry changed.")

            let layout = try NativePDFDocumentLayoutSnapshot(document: document)
            document.page(at: 3)?.rotation = 90
            do {
                try layout.validate(in: document)
                check(false, "Layout validation allowed a rotated page.")
            } catch AIHighlightNativePDFBridgeError.documentFingerprintChanged {
                check(true, "")
            }
            do {
                // This is the answer-only path: no staged highlight is required
                // for a changed document to invalidate the answer.
                try await resolver.validateSnapshotCooperatively(
                    fingerprint: snapshot.fingerprint,
                    in: document
                )
                check(false, "Answer-only fingerprint validation accepted a changed PDF.")
            } catch AIHighlightNativePDFBridgeError.documentFingerprintChanged {
                check(true, "")
            }

            let replaced = try makeTextPDF(pageCount: 2)
            let replacementLayout = try NativePDFDocumentLayoutSnapshot(document: replaced)
            guard let replacementPage = try makeTextPDF(pageCount: 1).page(at: 0) else {
                throw FixtureError.cannotCreatePDF
            }
            replaced.removePage(at: 0)
            replaced.insert(replacementPage, at: 0)
            do {
                try replacementLayout.validate(in: replaced)
                check(false, "Layout validation accepted replacement by an identical-text page.")
            } catch AIHighlightNativePDFBridgeError.documentFingerprintChanged {
                check(true, "")
            }

            let cancellable = try makeTextPDF(pageCount: 64)
            var scanStarted = false
            let scan = Task {
                scanStarted = true
                return try await NativePDFTextSnapshotBuilder(document: cancellable)
                    .makeTextSnapshotCooperatively()
            }
            let cancelScan = Task {
                while !scanStarted { await Task.yield() }
                scan.cancel()
            }
            do {
                _ = try await scan.value
                check(false, "Cooperative snapshot ignored cancellation after starting.")
            } catch is CancellationError {
                check(true, "")
            }
            await cancelScan.value

            let mutable = try makeTextPDF(pageCount: 64)
            var mutableScanStarted = false
            let mutableScan = Task {
                mutableScanStarted = true
                return try await NativePDFTextSnapshotBuilder(document: mutable)
                    .makeTextSnapshotCooperatively()
            }
            let mutateScan = Task {
                while !mutableScanStarted { await Task.yield() }
                mutable.page(at: 0)?.rotation = 90
            }
            do {
                _ = try await mutableScan.value
                check(false, "Cooperative snapshot accepted a layout mutation while suspended.")
            } catch AIHighlightNativePDFBridgeError.documentFingerprintChanged {
                check(true, "")
            }
            await mutateScan.value
        } catch {
            failures.append("Safety fixture failed: \(error.localizedDescription)")
        }
        return AIHighlightFoundationDiagnosticReport(checkCount: checks, failures: failures)
    }

    private static func makeTextPDF(pageCount: Int) throws -> PDFDocument {
        let data = NSMutableData()
        guard let consumer = CGDataConsumer(data: data as CFMutableData) else {
            throw FixtureError.cannotCreatePDF
        }
        var mediaBox = CGRect(x: 0, y: 0, width: 612, height: 792)
        guard let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else {
            throw FixtureError.cannotCreatePDF
        }
        for index in 0..<pageCount {
            context.beginPDFPage(nil)
            let text = NSAttributedString(
                string: "Page \(index + 1) contains verified evidence.",
                attributes: [.font: CTFontCreateWithName("Helvetica" as CFString, 14, nil)]
            )
            context.textPosition = CGPoint(x: 72, y: 700)
            CTLineDraw(CTLineCreateWithAttributedString(text), context)
            context.endPDFPage()
        }
        context.closePDF()
        guard let document = PDFDocument(data: data as Data) else {
            throw FixtureError.cannotCreatePDF
        }
        return document
    }

    private enum FixtureError: Error {
        case cannotCreatePDF
    }
}
