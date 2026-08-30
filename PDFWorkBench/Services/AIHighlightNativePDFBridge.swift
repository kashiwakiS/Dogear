import CryptoKit
import Foundation
import PDFKit

nonisolated enum AIHighlightNativePDFBridgeError: LocalizedError, Equatable {
    case emptyDocument
    case missingPage(Int)
    case pageFingerprintChanged(Int)
    case documentFingerprintChanged
    case missingSegment(AISegmentID)
    case invalidSegmentSequence(String)
    case sourceRangeOutOfBounds(AISegmentID)
    case unsupportedTextSource(String)
    case selectionUnavailable(String)
    case selectionTextMismatch(String)
    case lineGeometryUnavailable(String)

    var errorDescription: String? {
        switch self {
        case .emptyDocument:
            return "The PDF has no pages."
        case .missingPage(let pageNumber):
            return "PDF page \(pageNumber) is unavailable."
        case .pageFingerprintChanged(let pageNumber):
            return "PDF page \(pageNumber) changed after the text snapshot was created."
        case .documentFingerprintChanged:
            return "The PDF changed after the text snapshot was created."
        case .missingSegment(let id):
            return "The segment registry no longer contains \(id)."
        case .invalidSegmentSequence(let candidateID):
            return "The staged segment sequence is invalid: \(candidateID)."
        case .sourceRangeOutOfBounds(let id):
            return "The source range is outside the current PDF page: \(id)."
        case .unsupportedTextSource(let candidateID):
            return "The staged highlight does not use native PDF text: \(candidateID)."
        case .selectionUnavailable(let candidateID):
            return "PDFKit could not create a selection for \(candidateID)."
        case .selectionTextMismatch(let candidateID):
            return "PDFKit selection text did not match the snapshot for \(candidateID)."
        case .lineGeometryUnavailable(let candidateID):
            return "PDFKit could not derive line geometry for \(candidateID)."
        }
    }
}

nonisolated struct AIPageRect: Codable, Equatable, Sendable {
    let x: Double
    let y: Double
    let width: Double
    let height: Double

    init(_ rect: CGRect) {
        x = rect.origin.x
        y = rect.origin.y
        width = rect.width
        height = rect.height
    }

    var cgRect: CGRect {
        CGRect(x: x, y: y, width: width, height: height)
    }
}

nonisolated struct AIPagePoint: Codable, Equatable, Sendable {
    let x: Double
    let y: Double

    init(_ point: CGPoint) {
        x = point.x
        y = point.y
    }

    var cgPoint: CGPoint { CGPoint(x: x, y: y) }
}

nonisolated struct ResolvedAIHighlightAnchor: Equatable, Sendable {
    let candidateID: String
    let segmentIDs: [AISegmentID]
    let pageNumber: Int
    let sourceRange: AISourceTextRange
    let sourceTextHash: String
    let annotationBounds: AIPageRect
    let lineBounds: [AIPageRect]
    let quadrilateralPoints: [AIPagePoint]
}

@MainActor
struct NativePDFTextSnapshotBuilder: AIHighlightTextSnapshotBuilding {
    let document: PDFDocument

    func makeTextSnapshot() throws -> AIHighlightTextSnapshot {
        guard document.pageCount > 0 else {
            throw AIHighlightNativePDFBridgeError.emptyDocument
        }

        var pageSnapshots: [AITextPageSnapshot] = []
        var pageFingerprints: [String] = []
        for pageIndex in 0..<document.pageCount {
            guard let page = document.page(at: pageIndex) else {
                throw AIHighlightNativePDFBridgeError.missingPage(pageIndex + 1)
            }
            let pageNumber = pageIndex + 1
            let fingerprint = NativePDFTextFingerprint.page(
                page,
                pageNumber: pageNumber
            )
            pageFingerprints.append(fingerprint)
            pageSnapshots.append(
                AITextPageSnapshot(
                    pageNumber: pageNumber,
                    text: page.string ?? "",
                    fingerprint: fingerprint,
                    sourceKind: .nativeText
                )
            )
        }

        return AIHighlightTextSnapshot(
            fingerprint: NativePDFTextFingerprint.document(
                pageFingerprints: pageFingerprints
            ),
            pages: pageSnapshots
        )
    }

    func makeRegistry(
        segmenter: AISegmenter = AISegmenter()
    ) throws -> AISegmentRegistry {
        try AISegmentRegistry(snapshot: makeTextSnapshot(), segmenter: segmenter)
    }
}

@MainActor
struct AIHighlightNativeAnchorResolver {
    func resolve(
        _ stagedHighlights: [StagedAIHighlight],
        registry: AISegmentRegistry,
        in document: PDFDocument
    ) throws -> [ResolvedAIHighlightAnchor] {
        let referencedPages = Set(
            stagedHighlights.flatMap { $0.candidate.segmentIDs.map(\.page) }
        )
        for pageNumber in referencedPages {
            guard let page = document.page(at: pageNumber - 1) else {
                throw AIHighlightNativePDFBridgeError.missingPage(pageNumber)
            }
            let expectedFingerprint = stagedHighlights
                .flatMap(\.candidate.segmentIDs)
                .first(where: { $0.page == pageNumber })
                .flatMap(registry.record(for:))?
                .pageFingerprint
            let currentFingerprint = NativePDFTextFingerprint.page(
                page,
                pageNumber: pageNumber
            )
            guard expectedFingerprint == currentFingerprint else {
                throw AIHighlightNativePDFBridgeError.pageFingerprintChanged(pageNumber)
            }
        }

        let currentSnapshot = try NativePDFTextSnapshotBuilder(document: document)
            .makeTextSnapshot()
        guard currentSnapshot.fingerprint == registry.snapshotFingerprint else {
            throw AIHighlightNativePDFBridgeError.documentFingerprintChanged
        }

        return try stagedHighlights.map { staged in
            try resolve(staged, registry: registry, in: document)
        }
    }

    private func resolve(
        _ staged: StagedAIHighlight,
        registry: AISegmentRegistry,
        in document: PDFDocument
    ) throws -> ResolvedAIHighlightAnchor {
        let candidate = staged.candidate
        let records = try candidate.segmentIDs.map { id in
            guard let record = registry.record(for: id) else {
                throw AIHighlightNativePDFBridgeError.missingSegment(id)
            }
            return record
        }
        guard staged.sourceKind == .nativeText,
              records.allSatisfy({ $0.sourceKind == .nativeText })
        else {
            throw AIHighlightNativePDFBridgeError.unsupportedTextSource(
                candidate.candidateID
            )
        }
        guard let firstRecord = records.first,
              let lastRecord = records.last,
              records.allSatisfy({
                  $0.id.document == firstRecord.id.document
                      && $0.id.page == firstRecord.id.page
                      && $0.id.block == firstRecord.id.block
              }),
              records.enumerated().allSatisfy({ offset, record in
                  record.id.sentence == firstRecord.id.sentence + offset
              })
        else {
            throw AIHighlightNativePDFBridgeError.invalidSegmentSequence(
                candidate.candidateID
            )
        }

        let pageNumber = firstRecord.id.page
        guard staged.pageNumber == pageNumber,
              let page = document.page(at: pageNumber - 1)
        else {
            throw AIHighlightNativePDFBridgeError.missingPage(pageNumber)
        }
        let source = (page.string ?? "") as NSString
        let sourceRange = NSRange(
            location: firstRecord.sourceRange.location,
            length: lastRecord.sourceRange.upperBound - firstRecord.sourceRange.location
        )
        guard sourceRange.location >= 0,
              sourceRange.length > 0,
              sourceRange.location + sourceRange.length <= source.length
        else {
            throw AIHighlightNativePDFBridgeError.sourceRangeOutOfBounds(firstRecord.id)
        }
        guard let selection = page.selection(for: sourceRange),
              selection.string?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        else {
            throw AIHighlightNativePDFBridgeError.selectionUnavailable(candidate.candidateID)
        }

        let expectedText = source.substring(with: sourceRange)
        guard Self.comparableText(selection.string ?? "") == Self.comparableText(expectedText) else {
            throw AIHighlightNativePDFBridgeError.selectionTextMismatch(candidate.candidateID)
        }

        let lineBounds = selection.selectionsByLine().compactMap { lineSelection -> CGRect? in
            guard lineSelection.pages.contains(where: { $0 === page }) else { return nil }
            let bounds = lineSelection.bounds(for: page)
            guard !bounds.isEmpty, !bounds.isNull, !bounds.isInfinite else { return nil }
            return bounds.insetBy(dx: -1, dy: -1)
        }
        guard let annotationBounds = lineBounds.reduce(nil, { partial, bounds in
            partial?.union(bounds) ?? bounds
        }), !annotationBounds.isEmpty else {
            throw AIHighlightNativePDFBridgeError.lineGeometryUnavailable(candidate.candidateID)
        }

        let quadrilateralPoints = lineBounds.flatMap { bounds in
            Self.quadrilateralPoints(for: bounds, relativeTo: annotationBounds.origin)
        }
        return ResolvedAIHighlightAnchor(
            candidateID: candidate.candidateID,
            segmentIDs: candidate.segmentIDs,
            pageNumber: pageNumber,
            sourceRange: AISourceTextRange(
                location: sourceRange.location,
                length: sourceRange.length
            ),
            sourceTextHash: NativePDFTextFingerprint.text(expectedText),
            annotationBounds: AIPageRect(annotationBounds),
            lineBounds: lineBounds.map(AIPageRect.init),
            quadrilateralPoints: quadrilateralPoints.map(AIPagePoint.init)
        )
    }

    private static func comparableText(_ text: String) -> String {
        text.precomposedStringWithCanonicalMapping
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }

    private static func quadrilateralPoints(
        for bounds: CGRect,
        relativeTo origin: CGPoint
    ) -> [CGPoint] {
        [
            CGPoint(x: bounds.minX - origin.x, y: bounds.maxY - origin.y),
            CGPoint(x: bounds.maxX - origin.x, y: bounds.maxY - origin.y),
            CGPoint(x: bounds.minX - origin.x, y: bounds.minY - origin.y),
            CGPoint(x: bounds.maxX - origin.x, y: bounds.minY - origin.y)
        ]
    }
}

@MainActor
private enum NativePDFTextFingerprint {
    static func page(_ page: PDFPage, pageNumber: Int) -> String {
        let mediaBounds = page.bounds(for: .mediaBox)
        let cropBounds = page.bounds(for: .cropBox)
        return text(
            [
                "native-pdf-text-page-v1",
                String(pageNumber),
                String(page.rotation),
                rectComponent(mediaBounds),
                rectComponent(cropBounds),
                page.string ?? ""
            ].joined(separator: "\u{1F}")
        )
    }

    static func document(pageFingerprints: [String]) -> String {
        text(
            (["native-pdf-text-document-v1", String(pageFingerprints.count)]
                + pageFingerprints)
                .joined(separator: "\u{1E}")
        )
    }

    nonisolated static func text(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    nonisolated private static func rectComponent(_ rect: CGRect) -> String {
        [rect.minX, rect.minY, rect.width, rect.height]
            .map { String(Double($0).bitPattern, radix: 16) }
            .joined(separator: ",")
    }
}
