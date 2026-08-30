import AppKit
import Foundation
import PDFKit

nonisolated enum AIHighlightNativeAnnotationError: LocalizedError, Equatable {
    case mismatchedAnchor(String)
    case invalidGeometry(String)
    case metadataAssignmentFailed(String)
    case serializationFailed
    case cloneFailed

    var errorDescription: String? {
        switch self {
        case .mismatchedAnchor(let candidateID):
            return "The staged highlight does not match its resolved anchor: \(candidateID)."
        case .invalidGeometry(let candidateID):
            return "The resolved highlight geometry is invalid: \(candidateID)."
        case .metadataAssignmentFailed(let key):
            return "PDFKit rejected the AI annotation metadata field \(key)."
        case .serializationFailed:
            return "PDFKit could not serialize the PDF."
        case .cloneFailed:
            return "PDFKit could not open the temporary export clone."
        }
    }
}

nonisolated enum AIAnnotationProvenanceClassification: Equatable, Sendable {
    case dogearAI(uniqueName: String)
    case indexedAI(uniqueName: String)
    case notAI

    var isAI: Bool {
        switch self {
        case .dogearAI, .indexedAI:
            return true
        case .notAI:
            return false
        }
    }
}

nonisolated struct AIAnnotationEmbeddedMetadata: Equatable, Sendable {
    let schemaVersion: Int
    let category: AIHighlightCategory
    let groupID: UUID?

    init(
        schemaVersion: Int,
        category: AIHighlightCategory,
        groupID: UUID? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.category = category
        self.groupID = groupID
    }
}

nonisolated struct AIAnnotationProvenanceIdentity: Equatable, Sendable {
    let uniqueName: String
    let groupID: UUID?
}

@MainActor
enum AIAnnotationProvenance {
    static let uniqueNamePrefix = "dogear.ai."
    static let authorName = "Dogear AI"
    static let schemaVersion = 2
    static let legacyGroupID = UUID(
        uuidString: "00000000-0000-0000-0000-000000000001"
    )!

    // /Subj is a standard annotation field, but PDFKit does not publish a
    // typed PDFAnnotationKey constant for it.
    private static let subjectKey = PDFAnnotationKey(rawValue: "/Subj")
    private static let subjectPrefix = "Dogear AI Highlight"

    static func makeUniqueName(id: UUID = UUID()) -> String {
        uniqueNamePrefix + id.uuidString
    }

    static func makeUniqueName(groupID: UUID, id: UUID = UUID()) -> String {
        "\(uniqueNamePrefix)v2.\(groupID.uuidString).\(id.uuidString)"
    }

    static func uniqueName(of annotation: PDFAnnotation) -> String? {
        annotation.value(forAnnotationKey: .name) as? String
    }

    static func identity(
        of annotation: PDFAnnotation
    ) -> AIAnnotationProvenanceIdentity? {
        guard let uniqueName = uniqueName(of: annotation),
              uniqueName.hasPrefix(uniqueNamePrefix)
        else {
            return nil
        }

        let suffix = uniqueName.dropFirst(uniqueNamePrefix.count)
        let components = suffix.split(separator: ".").map(String.init)
        let groupID: UUID?
        if components.count == 3,
           components[0] == "v2",
           let parsedGroupID = UUID(uuidString: components[1]),
           UUID(uuidString: components[2]) != nil {
            groupID = parsedGroupID
        } else {
            groupID = nil
        }
        return AIAnnotationProvenanceIdentity(
            uniqueName: uniqueName,
            groupID: groupID
        )
    }

    static func groupID(of annotation: PDFAnnotation) -> UUID? {
        identity(of: annotation)?.groupID
            ?? embeddedMetadata(of: annotation)?.groupID
    }

    static func displayGroupID(of annotation: PDFAnnotation) -> UUID? {
        guard classify(annotation).isAI else { return nil }
        return groupID(of: annotation) ?? legacyGroupID
    }

    static func classify(
        _ annotation: PDFAnnotation,
        indexedUniqueNames: Set<String> = []
    ) -> AIAnnotationProvenanceClassification {
        guard let uniqueName = uniqueName(of: annotation) else {
            return .notAI
        }
        if uniqueName.hasPrefix(uniqueNamePrefix) {
            return .dogearAI(uniqueName: uniqueName)
        }
        if indexedUniqueNames.contains(uniqueName) {
            return .indexedAI(uniqueName: uniqueName)
        }
        return .notAI
    }

    static func embeddedMetadata(
        of annotation: PDFAnnotation
    ) -> AIAnnotationEmbeddedMetadata? {
        guard let subject = annotation.value(forAnnotationKey: subjectKey) as? String else {
            return nil
        }

        let components = subject.split(separator: ";").map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard components.first == subjectPrefix else { return nil }

        var schema: Int?
        var category: AIHighlightCategory?
        var groupID: UUID?
        for component in components.dropFirst() {
            let pair = component.split(separator: "=", maxSplits: 1).map(String.init)
            guard pair.count == 2 else { continue }
            switch pair[0] {
            case "schema":
                schema = Int(pair[1])
            case "category":
                category = AIHighlightCategory(rawValue: pair[1])
            case "group":
                groupID = UUID(uuidString: pair[1])
            default:
                continue
            }
        }

        guard let schema, let category else { return nil }
        return AIAnnotationEmbeddedMetadata(
            schemaVersion: schema,
            category: category,
            groupID: groupID
        )
    }

    static func assignMetadata(
        to annotation: PDFAnnotation,
        uniqueName: String,
        category: AIHighlightCategory,
        groupID: UUID? = nil,
        modificationDate: Date
    ) throws {
        guard annotation.setValue(uniqueName, forAnnotationKey: .name) else {
            throw AIHighlightNativeAnnotationError.metadataAssignmentFailed("/NM")
        }
        annotation.userName = authorName
        annotation.modificationDate = modificationDate

        let subject = [
            subjectPrefix,
            "schema=\(schemaVersion)",
            "category=\(category.rawValue)",
            groupID.map { "group=\($0.uuidString)" }
        ].compactMap { $0 }.joined(separator: "; ")
        guard annotation.setValue(subject, forAnnotationKey: subjectKey) else {
            throw AIHighlightNativeAnnotationError.metadataAssignmentFailed("/Subj")
        }
    }
}

@MainActor
struct AIHighlightNativeAnnotationStyle {
    let color = NSColor(
        calibratedRed: 0.30,
        green: 0.78,
        blue: 0.88,
        alpha: 1.0
    )
}

@MainActor
struct AIHighlightNativeAnnotationFactory {
    let style: AIHighlightNativeAnnotationStyle

    init() {
        style = AIHighlightNativeAnnotationStyle()
    }

    init(style: AIHighlightNativeAnnotationStyle) {
        self.style = style
    }

    func makeAnnotation(
        anchor: ResolvedAIHighlightAnchor,
        staged: StagedAIHighlight,
        groupID: UUID,
        id: UUID = UUID(),
        modificationDate: Date = Date()
    ) throws -> PDFAnnotation {
        let candidate = staged.candidate
        guard staged.sourceKind == .nativeText,
              candidate.candidateID == anchor.candidateID,
              candidate.segmentIDs == anchor.segmentIDs,
              staged.pageNumber == anchor.pageNumber
        else {
            throw AIHighlightNativeAnnotationError.mismatchedAnchor(
                candidate.candidateID
            )
        }

        let bounds = anchor.annotationBounds.cgRect
        guard bounds.width > 0,
              bounds.height > 0,
              !bounds.isNull,
              !bounds.isInfinite,
              !anchor.quadrilateralPoints.isEmpty,
              anchor.quadrilateralPoints.count.isMultiple(of: 4)
        else {
            throw AIHighlightNativeAnnotationError.invalidGeometry(
                candidate.candidateID
            )
        }

        let annotation = PDFAnnotation(
            bounds: bounds,
            forType: .highlight,
            withProperties: nil
        )
        annotation.color = style.color
        annotation.quadrilateralPoints = anchor.quadrilateralPoints.map {
            NSValue(point: $0.cgPoint)
        }
        annotation.shouldDisplay = true
        annotation.shouldPrint = true

        if let note = candidate.note?.trimmingCharacters(in: .whitespacesAndNewlines),
           !note.isEmpty {
            annotation.contents = note
        }

        try AIAnnotationProvenance.assignMetadata(
            to: annotation,
            uniqueName: AIAnnotationProvenance.makeUniqueName(
                groupID: groupID,
                id: id
            ),
            category: candidate.category,
            groupID: groupID,
            modificationDate: modificationDate
        )
        return annotation
    }
}

@MainActor
struct AIAnnotationDisplayState {
    fileprivate struct Entry {
        let annotation: PDFAnnotation
        let shouldDisplay: Bool
    }

    fileprivate let entries: [Entry]

    var annotationCount: Int { entries.count }

    func restore() {
        for entry in entries {
            entry.annotation.shouldDisplay = entry.shouldDisplay
        }
    }
}

@MainActor
enum AIAnnotationDisplayController {
    static func setAIAnnotationsShouldDisplay(
        _ shouldDisplay: Bool,
        in document: PDFDocument,
        indexedUniqueNames: Set<String> = []
    ) -> AIAnnotationDisplayState {
        var entries: [AIAnnotationDisplayState.Entry] = []

        for pageIndex in 0..<document.pageCount {
            guard let page = document.page(at: pageIndex) else { continue }
            for annotation in page.annotations where AIAnnotationProvenance.classify(
                annotation,
                indexedUniqueNames: indexedUniqueNames
            ).isAI {
                entries.append(
                    AIAnnotationDisplayState.Entry(
                        annotation: annotation,
                        shouldDisplay: annotation.shouldDisplay
                    )
                )
                annotation.shouldDisplay = shouldDisplay
            }
        }

        return AIAnnotationDisplayState(entries: entries)
    }

    static func setAIAnnotationGroupsShouldDisplay(
        visibleGroupIDs: Set<UUID>,
        in document: PDFDocument,
        indexedUniqueNames: Set<String> = []
    ) -> AIAnnotationDisplayState {
        var entries: [AIAnnotationDisplayState.Entry] = []

        for pageIndex in 0..<document.pageCount {
            guard let page = document.page(at: pageIndex) else { continue }
            for annotation in page.annotations where AIAnnotationProvenance.classify(
                annotation,
                indexedUniqueNames: indexedUniqueNames
            ).isAI {
                entries.append(
                    AIAnnotationDisplayState.Entry(
                        annotation: annotation,
                        shouldDisplay: annotation.shouldDisplay
                    )
                )
                let groupID = AIAnnotationProvenance.displayGroupID(of: annotation)
                annotation.shouldDisplay = groupID.map {
                    visibleGroupIDs.contains($0)
                } ?? false
            }
        }

        return AIAnnotationDisplayState(entries: entries)
    }
}

nonisolated enum AIAnnotationExportSelection: Equatable, Sendable {
    case include
    case exclude
    case selectedGroups(Set<UUID>)
}

@MainActor
enum AIAnnotationSelectiveExporter {
    static func dataRepresentation(
        of liveDocument: PDFDocument,
        selection: AIAnnotationExportSelection,
        indexedUniqueNames: Set<String> = []
    ) throws -> Data {
        guard let serializedLiveDocument = liveDocument
            .dataRepresentationWithAIAnnotationsDisplayed(
                indexedUniqueNames: indexedUniqueNames
            )
        else {
            throw AIHighlightNativeAnnotationError.serializationFailed
        }
        guard let clone = PDFDocument(data: serializedLiveDocument) else {
            throw AIHighlightNativeAnnotationError.cloneFailed
        }

        switch selection {
        case .include:
            break
        case .exclude:
            removeAIAnnotations(
                from: clone,
                keepingGroupIDs: [],
                indexedUniqueNames: indexedUniqueNames
            )
        case .selectedGroups(let groupIDs):
            removeAIAnnotations(
                from: clone,
                keepingGroupIDs: groupIDs,
                indexedUniqueNames: indexedUniqueNames
            )
        }

        guard let result = clone.dataRepresentationWithNoteAnnotationsDisplayed() else {
            throw AIHighlightNativeAnnotationError.serializationFailed
        }
        return result
    }

    private static func removeAIAnnotations(
        from document: PDFDocument,
        keepingGroupIDs: Set<UUID>,
        indexedUniqueNames: Set<String>
    ) {
        for pageIndex in 0..<document.pageCount {
            guard let page = document.page(at: pageIndex) else { continue }
            let aiAnnotations = page.annotations.filter { annotation in
                guard AIAnnotationProvenance.classify(
                    annotation,
                    indexedUniqueNames: indexedUniqueNames
                ).isAI else {
                    return false
                }
                guard let groupID = AIAnnotationProvenance.displayGroupID(
                    of: annotation
                ) else {
                    return true
                }
                return !keepingGroupIDs.contains(groupID)
            }
            for annotation in aiAnnotations {
                page.removeAnnotation(annotation)
            }
        }
    }
}

extension PDFDocument {
    @MainActor
    func dataRepresentationWithAIAnnotationsDisplayed(
        indexedUniqueNames: Set<String> = []
    ) -> Data? {
        let displayState = AIAnnotationDisplayController
            .setAIAnnotationsShouldDisplay(
                true,
                in: self,
                indexedUniqueNames: indexedUniqueNames
            )
        defer {
            displayState.restore()
        }

        return dataRepresentationWithNoteAnnotationsDisplayed()
    }
}
