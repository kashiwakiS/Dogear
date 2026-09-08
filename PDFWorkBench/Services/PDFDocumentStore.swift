import AppKit
import Combine
import Foundation
import PDFKit
import UniformTypeIdentifiers

enum AIHighlightCommitError: LocalizedError {
    case incompleteResolution
    case missingPage(Int)
    case annotationCommitFailed

    var errorDescription: String? {
        switch self {
        case .incompleteResolution:
            return "The verified AI highlight draft did not have a complete anchor set."
        case .missingPage(let pageNumber):
            return "PDF page \(pageNumber) is no longer available."
        case .annotationCommitFailed:
            return "Dogear could not apply the complete AI highlight batch."
        }
    }
}

@MainActor
final class PDFDocumentStore: ObservableObject {
    @Published var selectedPDFURL: URL?
    @Published var document: PDFDocument?
    @Published var hasUnsavedChanges = false
    @Published var annotations: [PDFAnnotationItem] = []
    @Published var selectedAnnotationID: PDFAnnotationItem.ID?
    @Published var documentSearchText = "" {
        didSet {
            refreshDocumentSearchResults()
        }
    }
    @Published var documentSearchResults: [PDFSearchResult] = []
    @Published var selectedDocumentSearchResultID: PDFSearchResult.ID?
    @Published var currentPageIndex = 0
    @Published var freeTextRequestID = 0
    @Published private(set) var currentWorkingCopyURL: URL?
    @Published private(set) var outlineEntries: [DocumentOutlineEntry] = []
    @Published private(set) var isLoadingOutline = false
    @Published private(set) var outlineNavigationRequest: PDFOutlineNavigationRequest?
    @Published private(set) var currentTextSelection: PDFTextSelectionSnapshot?
    @Published private(set) var dogears: [DogearMarker] = []
    @Published private(set) var aiHighlightGroups: [AIHighlightGroup] = []
    @Published private(set) var visibleAIHighlightGroupIDs: Set<UUID> = []
    @Published private(set) var activeAIHighlightGroupID: UUID?
    @Published var showsAIGeneratedContent = true {
        didSet {
            guard oldValue != showsAIGeneratedContent else { return }
            guard !isSynchronizingAIMasterVisibility else { return }
            setAllAIHighlightGroupsVisible(showsAIGeneratedContent)
        }
    }

    private let outlineProvider: KeywordOutlineProviding
    private let documentOutlineProvider: DocumentOutlineProviding
    private let workingCopyStore: PDFWorkingCopyStore?
    private let saveQueue: PDFSaveQueue
    private let feedbackCenter: OperationFeedbackCenter
    private let metadataStore: DocumentMetadataStore
    private let aiHighlightGroupStore: AIHighlightGroupStore
    private var accessedSecurityScopedURL: URL?
    private var openedDocumentID = UUID()
    private var saveGeneration = 0
    private var outlineNavigationRequestID = 0
    private var outlineLoadingTask: Task<Void, Never>?
    private weak var undoManager: UndoManager?
    private var currentLibraryFileID: UUID?
    private var isSynchronizingAIMasterVisibility = false

    init(
        feedbackCenter: OperationFeedbackCenter,
        outlineProvider: KeywordOutlineProviding? = nil,
        documentOutlineProvider: DocumentOutlineProviding? = nil,
        metadataStore: DocumentMetadataStore? = nil,
        aiHighlightGroupStore: AIHighlightGroupStore? = nil,
        workingCopyStore: PDFWorkingCopyStore? = nil,
        saveQueue: PDFSaveQueue? = nil
    ) {
        self.feedbackCenter = feedbackCenter
        self.outlineProvider = outlineProvider ?? FallbackKeywordOutlineProvider()
        self.documentOutlineProvider = documentOutlineProvider ?? DocumentOutlineService()
        self.metadataStore = metadataStore ?? .shared
        self.aiHighlightGroupStore = aiHighlightGroupStore ?? .shared
        self.workingCopyStore = workingCopyStore ?? (try? PDFWorkingCopyStore())
        self.saveQueue = saveQueue ?? .shared
    }

    var selectedDocumentName: String {
        selectedPDFURL?.lastPathComponent ?? "Untitled PDF"
    }

    var displayedDocumentTitle: String {
        hasUnsavedChanges ? "\(selectedDocumentName) - saving" : selectedDocumentName
    }

    var filteredAnnotations: [PDFAnnotationItem] {
        var visibleAnnotations = annotations.filter { annotation in
            guard annotation.isAIGenerated else { return true }
            guard let groupID = annotation.aiGroupID else { return false }
            return visibleAIHighlightGroupIDs.contains(groupID)
        }

        if let activeAIHighlightGroupID {
            visibleAnnotations = visibleAnnotations.filter {
                $0.aiGroupID == activeAIHighlightGroupID
            }
        }

        return visibleAnnotations
    }

    var selectedAnnotation: PDFAnnotationItem? {
        guard let selectedAnnotationID else {
            return nil
        }

        return annotations.first { $0.id == selectedAnnotationID }
    }

    var selectedDocumentSearchResult: PDFSearchResult? {
        guard let selectedDocumentSearchResultID else {
            return nil
        }

        return documentSearchResults.first { $0.id == selectedDocumentSearchResultID }
    }

    var filteredAnnotationCountDescription: String {
        let count = filteredAnnotations.count
        return count == 1
            ? L10n.string("1 annotation")
            : L10n.string("\(count) annotations")
    }

    var documentSearchCountDescription: String {
        let count = documentSearchResults.count
        return count == 1
            ? L10n.string("1 match")
            : L10n.string("\(count) matches")
    }

    var visibleAIHighlightRailMarkers: [AIHighlightRailMarker] {
        guard let document else { return [] }
        let groupsByID = Dictionary(uniqueKeysWithValues: aiHighlightGroups.map { ($0.id, $0) })
        var markers: [AIHighlightRailMarker] = []

        for pageIndex in 0..<document.pageCount {
            guard let page = document.page(at: pageIndex) else { continue }
            let pageBounds = page.bounds(for: .cropBox)
            guard pageBounds.height > 0 else { continue }

            for (annotationIndex, annotation) in page.annotations.enumerated() {
                let classification = AIAnnotationProvenance.classify(annotation)
                guard classification.isAI,
                      let groupID = AIAnnotationProvenance.displayGroupID(of: annotation),
                      visibleAIHighlightGroupIDs.contains(groupID)
                else {
                    continue
                }

                let annotationID = PDFAnnotationItem.id(
                    pageIndex: pageIndex,
                    annotationIndex: annotationIndex,
                    annotation: annotation
                )
                let relativePosition = min(
                    1,
                    max(0, (pageBounds.maxY - annotation.bounds.maxY) / pageBounds.height)
                )
                let inheritedLevel = outlineEntries
                    .filter { entry in
                        guard entry.target.pageIndex <= pageIndex else { return false }
                        if entry.target.pageIndex < pageIndex { return true }
                        return (entry.target.relativePagePosition ?? 0) <= relativePosition
                    }
                    .max { lhs, rhs in
                        let lhsPosition = (
                            lhs.target.pageIndex,
                            lhs.target.relativePagePosition ?? 0
                        )
                        let rhsPosition = (
                            rhs.target.pageIndex,
                            rhs.target.relativePagePosition ?? 0
                        )
                        return lhsPosition < rhsPosition
                    }?
                    .level ?? 0

                markers.append(
                    AIHighlightRailMarker(
                        id: annotationID,
                        annotationID: annotationID,
                        pageIndex: pageIndex,
                        relativePagePosition: relativePosition,
                        level: inheritedLevel,
                        title: groupsByID[groupID]?.displayTitle
                            ?? L10n.string("AI Highlight")
                    )
                )
            }
        }

        return markers.sorted { lhs, rhs in
            if lhs.pageIndex != rhs.pageIndex {
                return lhs.pageIndex < rhs.pageIndex
            }
            if lhs.relativePagePosition != rhs.relativePagePosition {
                return lhs.relativePagePosition < rhs.relativePagePosition
            }
            return lhs.id < rhs.id
        }
    }

    var canDeleteCurrentPage: Bool {
        guard let document else {
            return false
        }

        return document.pageCount > 1
    }

    var pageCount: Int {
        document?.pageCount ?? 0
    }

    var currentPageNumber: Int {
        guard pageCount > 0 else {
            return 0
        }

        return min(max(0, currentPageIndex), pageCount - 1) + 1
    }

    func setUndoManager(_ undoManager: UndoManager?) {
        guard self.undoManager !== undoManager else { return }
        self.undoManager = undoManager
        undoManager?.removeAllActions()
    }

    var canUndoDocumentChange: Bool { undoManager?.canUndo == true }
    var canRedoDocumentChange: Bool { undoManager?.canRedo == true }

    func undoDocumentChange() {
        undoManager?.undo()
    }

    func redoDocumentChange() {
        undoManager?.redo()
    }

    @discardableResult
    func openPDF(
        from url: URL?,
        workingCopyURL existingWorkingCopyURL: URL? = nil,
        initialPageIndex: Int = 0,
        trigger: FeedbackTrigger? = nil
    ) -> Bool {
        guard let url else {
            return false
        }

        closeSecurityScopedAccess()

        let documentURL: URL
        let workingCopyURL: URL?

        if let existingWorkingCopyURL,
           FileManager.default.fileExists(atPath: existingWorkingCopyURL.path) {
            documentURL = existingWorkingCopyURL
            workingCopyURL = existingWorkingCopyURL
        } else {
            _ = url.startAccessingSecurityScopedResource()
            accessedSecurityScopedURL = url
            documentURL = url
            workingCopyURL = nil
        }

        guard let document = PDFDocument(url: documentURL) else {
            postFeedback(
                "Could not open this PDF.",
                kind: .error,
                action: "Open PDF",
                trigger: trigger
            )
            closeSecurityScopedAccess()
            return false
        }

        selectedPDFURL = url
        currentWorkingCopyURL = workingCopyURL
        self.document = document
        undoManager?.removeAllActions()
        openedDocumentID = UUID()
        saveGeneration = 0
        hasUnsavedChanges = false
        currentPageIndex = min(max(0, initialPageIndex), max(0, document.pageCount - 1))
        selectedAnnotationID = nil
        selectedDocumentSearchResultID = nil
        outlineNavigationRequest = nil
        currentTextSelection = nil
        currentLibraryFileID = nil
        dogears = []
        aiHighlightGroups = []
        visibleAIHighlightGroupIDs = []
        activeAIHighlightGroupID = nil
        synchronizeAIMasterVisibility()
        refreshAnnotations()
        refreshAIHighlightGroups()
        refreshDocumentSearchResults(selectFirstResult: true)
        refreshDocumentOutline(for: document)
        postFeedback(
            workingCopyURL == nil
                ? "Opened original PDF read-only. The first edit will create an app-managed working copy."
                : "Opened app-managed working copy. Exports leave the original PDF unchanged.",
            action: "Open PDF",
            trigger: trigger
        )
        return true
    }

    func bindLibraryFile(_ fileID: UUID) {
        currentLibraryFileID = fileID
        refreshDogears()
        refreshAIHighlightGroups()
    }

    var currentPageDogear: DogearMarker? {
        dogears.first { $0.pageIndex == currentPageIndex }
    }

    func toggleDogearOnCurrentPage(trigger: FeedbackTrigger? = nil) {
        toggleDogear(onPage: currentPageIndex, trigger: trigger)
    }

    func toggleDogear(onPage pageIndex: Int, trigger: FeedbackTrigger? = nil) {
        guard document != nil, let documentID = currentLibraryFileID else { return }

        if let marker = dogears.first(where: { $0.pageIndex == pageIndex }) {
            metadataStore.removeDogear(id: marker.id)
            registerUndoForRemovedDogear(marker, actionName: "Remove Dog-ear")
            refreshDogears()
            postFeedback(
                "Dog-ear removed from page \(marker.pageNumber).",
                action: "Remove Dog-ear",
                trigger: trigger
            )
        } else {
            let marker = metadataStore.addDogear(
                documentID: documentID,
                pageIndex: pageIndex
            )
            registerUndoForAddedDogear(marker, actionName: "Add Dog-ear")
            refreshDogears()
            postFeedback(
                "Dog-ear added to page \(marker.pageNumber).",
                kind: .success,
                action: "Add Dog-ear",
                trigger: trigger
            )
        }
    }

    func renameDogear(_ marker: DogearMarker, title: String) {
        let previousDogears = dogears
        metadataStore.renameDogear(id: marker.id, title: title)
        refreshDogears()
        guard dogears != previousDogears else { return }
        registerUndoForDogearSnapshot(previousDogears, actionName: "Rename Dog-ear")
    }

    func removeDogear(_ marker: DogearMarker, trigger: FeedbackTrigger? = nil) {
        guard metadataStore.removeDogear(id: marker.id) != nil else { return }
        registerUndoForRemovedDogear(marker, actionName: "Remove Dog-ear")
        refreshDogears()
        postFeedback(
            "Dog-ear removed from page \(marker.pageNumber).",
            action: "Remove Dog-ear",
            trigger: trigger
        )
    }

    func moveDogear(_ marker: DogearMarker, by offset: Int) {
        let previousDogears = dogears
        metadataStore.moveDogear(id: marker.id, by: offset)
        refreshDogears()
        guard dogears != previousDogears else { return }
        registerUndoForDogearSnapshot(previousDogears, actionName: "Reorder Dog-ears")
    }

    func navigate(to dogear: DogearMarker) {
        goToPageNumber(dogear.pageNumber, trigger: .pointer)
    }

    func recordCurrentPage(_ pageIndex: Int) {
        currentPageIndex = max(0, pageIndex)
    }

    func navigate(to outlineEntry: DocumentOutlineEntry) {
        outlineNavigationRequestID += 1
        selectedAnnotationID = nil
        selectedDocumentSearchResultID = nil
        currentPageIndex = outlineEntry.target.pageIndex
        outlineNavigationRequest = PDFOutlineNavigationRequest(
            id: outlineNavigationRequestID,
            target: outlineEntry.target
        )
    }

    func recordTextSelection(_ selection: PDFTextSelectionSnapshot?) {
        currentTextSelection = selection?.isEmpty == false ? selection : nil
    }

    func markAnnotationsChanged(
        message: String = "Annotation updated. Saving working copy.",
        action: String = "Update Annotation",
        trigger: FeedbackTrigger? = nil
    ) {
        refreshAnnotations()
        postFeedback(message, action: action, trigger: trigger)
        enqueueCurrentDocumentSave(action: action, trigger: trigger)
    }

    @discardableResult
    func applyAIHighlights(
        stagedHighlights: [StagedAIHighlight],
        anchors: [ResolvedAIHighlightAnchor],
        group: AIHighlightGroup? = nil,
        trigger: FeedbackTrigger? = nil
    ) throws -> Int {
        guard let document else { return 0 }
        let anchorsByCandidateID = Dictionary(
            anchors.map { ($0.candidateID, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        guard anchorsByCandidateID.count == anchors.count,
              stagedHighlights.count == anchors.count
        else {
            throw AIHighlightCommitError.incompleteResolution
        }

        let factory = AIHighlightNativeAnnotationFactory()
        let effectiveGroup = group ?? AIHighlightGroup(
            requestKind: .recovered,
            providerName: AIAnnotationProvenance.authorName,
            modelName: "",
            promptVersion: AIHighlightWorkflowService.promptVersion
        )
        var prepared: [AIAnnotationUndoRecord] = []
        for staged in stagedHighlights {
            guard let anchor = anchorsByCandidateID[staged.candidate.candidateID] else {
                throw AIHighlightCommitError.incompleteResolution
            }
            guard let page = document.page(at: anchor.pageNumber - 1) else {
                throw AIHighlightCommitError.missingPage(anchor.pageNumber)
            }
            if hasDuplicateAIHighlight(
                anchor,
                groupID: effectiveGroup.id,
                on: page
            ) {
                continue
            }
            let annotation = try factory.makeAnnotation(
                anchor: anchor,
                staged: staged,
                groupID: effectiveGroup.id
            )
            annotation.shouldDisplay = true
            prepared.append(AIAnnotationUndoRecord(page: page, annotation: annotation))
        }

        guard !prepared.isEmpty else { return 0 }
        var applied: [AIAnnotationUndoRecord] = []
        for record in prepared {
            record.page.addAnnotation(record.annotation)
            guard record.annotation.page === record.page else {
                for appliedRecord in applied where appliedRecord.annotation.page === appliedRecord.page {
                    appliedRecord.page.removeAnnotation(appliedRecord.annotation)
                }
                throw AIHighlightCommitError.annotationCommitFailed
            }
            applied.append(record)
        }

        var committedGroup = effectiveGroup
        committedGroup.annotationUniqueNames = applied.compactMap {
            AIAnnotationProvenance.uniqueName(of: $0.annotation)
        }
        registerAIHighlightGroup(committedGroup, visible: true)
        registerUndoForAddedAIAnnotationBatch(
            applied,
            group: committedGroup,
            actionName: "Generate AI Highlights"
        )
        selectedAnnotationID = nil
        markAnnotationsChanged(
            message: "Added \(applied.count) AI highlight(s). Saving working copy.",
            action: "Generate AI Highlights",
            trigger: trigger
        )
        if let firstAnnotation = filteredAnnotations.first {
            selectAnnotation(firstAnnotation)
        }
        return applied.count
    }

    func selectAnnotation(_ annotation: PDFAnnotationItem) {
        selectedDocumentSearchResultID = nil
        selectedAnnotationID = annotation.id
    }

    func selectMarginAnnotation(_ annotation: PDFAnnotationItem) {
        activeAIHighlightGroupID = annotation.aiGroupID
        selectAnnotation(annotation)
    }

    func activateAIHighlightGroup(_ groupID: UUID?) {
        guard let groupID else {
            activeAIHighlightGroupID = nil
            return
        }
        guard aiHighlightGroups.contains(where: { $0.id == groupID }) else {
            return
        }

        if !visibleAIHighlightGroupIDs.contains(groupID) {
            visibleAIHighlightGroupIDs.insert(groupID)
            persistAIHighlightGroupState()
            synchronizeAIMasterVisibility()
            applyAIAnnotationDisplayPreference()
            refreshAnnotations()
        }

        activeAIHighlightGroupID = groupID
        if selectedAnnotation?.aiGroupID != groupID {
            selectedAnnotationID = nil
        }
        if let firstAnnotation = filteredAnnotations.first,
           selectedAnnotationID == nil {
            selectAnnotation(firstAnnotation)
        }
    }

    func isAIHighlightGroupVisible(_ groupID: UUID) -> Bool {
        visibleAIHighlightGroupIDs.contains(groupID)
    }

    func aiHighlightCount(in groupID: UUID) -> Int {
        annotations.reduce(into: 0) { count, annotation in
            if annotation.aiGroupID == groupID {
                count += 1
            }
        }
    }

    func setAIHighlightGroupVisible(_ groupID: UUID, isVisible: Bool) {
        guard aiHighlightGroups.contains(where: { $0.id == groupID }) else {
            return
        }
        if isVisible {
            visibleAIHighlightGroupIDs.insert(groupID)
        } else {
            visibleAIHighlightGroupIDs.remove(groupID)
            if activeAIHighlightGroupID == groupID {
                activeAIHighlightGroupID = nil
            }
            if selectedAnnotation?.aiGroupID == groupID {
                selectedAnnotationID = nil
            }
        }
        persistAIHighlightGroupState()
        synchronizeAIMasterVisibility()
        applyAIAnnotationDisplayPreference()
        refreshAnnotations()
    }

    func setAllAIHighlightGroupsVisible(_ isVisible: Bool) {
        visibleAIHighlightGroupIDs = isVisible
            ? Set(aiHighlightGroups.map(\.id))
            : []
        if !isVisible, selectedAnnotation?.isAIGenerated == true {
            selectedAnnotationID = nil
        }
        if !isVisible {
            activeAIHighlightGroupID = nil
        }
        persistAIHighlightGroupState()
        synchronizeAIMasterVisibility()
        applyAIAnnotationDisplayPreference()
        refreshAnnotations()
    }

    func removeAnnotation(
        _ item: PDFAnnotationItem,
        trigger: FeedbackTrigger? = nil
    ) {
        guard let document,
              let annotation = AnnotationExtractor.annotation(matching: item, in: document),
              let page = annotation.page
        else {
            refreshAnnotations()
            postFeedback(
                "The annotation is no longer present.",
                kind: .warning,
                action: "Remove Annotation",
                trigger: trigger
            )
            return
        }

        page.removeAnnotation(annotation)
        registerUndoForRemovedAnnotation(
            annotation,
            page: page,
            actionName: "Remove \(item.kind.rawValue)"
        )
        selectedAnnotationID = nil
        markAnnotationsChanged(
            message: "\(item.kind.rawValue) removed. Saving working copy.",
            action: "Remove \(item.kind.rawValue)",
            trigger: trigger
        )
    }

    func selectDocumentSearchResult(_ result: PDFSearchResult) {
        selectedAnnotationID = nil
        selectedDocumentSearchResultID = result.id
        currentPageIndex = result.pageIndex
    }

    func selectNextFilteredAnnotation() {
        selectRelativeFilteredAnnotation(offset: 1)
    }

    func selectPreviousFilteredAnnotation() {
        selectRelativeFilteredAnnotation(offset: -1)
    }

    func selectNextDocumentSearchResult() {
        selectRelativeDocumentSearchResult(offset: 1)
    }

    func selectPreviousDocumentSearchResult() {
        selectRelativeDocumentSearchResult(offset: -1)
    }

    func goToPageNumber(_ pageNumber: Int, trigger: FeedbackTrigger? = nil) {
        guard pageCount > 0 else {
            return
        }

        let pageIndex = min(max(0, pageNumber - 1), pageCount - 1)
        selectedAnnotationID = nil
        selectedDocumentSearchResultID = nil
        currentPageIndex = pageIndex
        postFeedback(
            "Page \(pageIndex + 1) of \(pageCount).",
            action: "Go to Page",
            trigger: trigger
        )
    }

    func goToRelativePage(offset: Int, trigger: FeedbackTrigger? = nil) {
        goToPageNumber(currentPageNumber + offset, trigger: trigger)
    }

    func goToFirstPage(trigger: FeedbackTrigger? = nil) {
        goToPageNumber(1, trigger: trigger)
    }

    func goToLastPage(trigger: FeedbackTrigger? = nil) {
        goToPageNumber(pageCount, trigger: trigger)
    }

    func isOriginalDocumentURL(_ destinationURL: URL) -> Bool {
        destinationURL.libraryComparablePath == selectedPDFURL?.libraryComparablePath
    }

    func requestFreeTextNote(trigger: FeedbackTrigger? = nil) {
        guard document != nil else {
            return
        }

        freeTextRequestID += 1
        postFeedback(
            "Type a free text note on the page, then press Return.",
            action: "Add Free Text Note",
            trigger: trigger
        )
    }

    func exportAnnotatedCopy(trigger: FeedbackTrigger? = nil) {
        guard let document else {
            return
        }

        let hasAIAnnotations = (0..<document.pageCount).contains { pageIndex in
            document.page(at: pageIndex)?.annotations.contains {
                AIAnnotationProvenance.classify($0).isAI
            } == true
        }
        guard let aiSelection = hasAIAnnotations
            ? requestAIAnnotationExportSelection()
            : .include
        else {
            postFeedback(
                "Export canceled.",
                action: "Export Annotated Copy",
                trigger: trigger
            )
            return
        }

        writePDF(
            document,
            suggestedName: suggestedFileName(suffix: "annotated"),
            successMessage: "Annotated copy exported",
            action: "Export Annotated Copy",
            trigger: trigger,
            aiSelection: aiSelection
        )
    }

    func savePDF(trigger: FeedbackTrigger? = nil) {
        overwriteOriginalPDF(trigger: trigger)
    }

    func deleteCurrentPageFromWorkingCopy(trigger: FeedbackTrigger? = nil) {
        guard let document else {
            return
        }

        guard canDeleteCurrentPage else {
            postFeedback(
                "Cannot delete the only page in a PDF.",
                kind: .warning,
                action: "Delete Page",
                trigger: trigger
            )
            return
        }

        let alert = NSAlert()
        alert.messageText = "Delete page \(currentPageIndex + 1)?"
        alert.informativeText = "Dogear will update the app-managed working copy. The original PDF will not be changed."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Delete from Working Copy")
        alert.addButton(withTitle: "Cancel")

        guard alert.runModal() == .alertFirstButtonReturn else {
            postFeedback(
                "Page deletion canceled.",
                action: "Delete Page",
                trigger: trigger
            )
            return
        }

        let deletedPageIndex = currentPageIndex
        guard let deletedPage = document.page(at: deletedPageIndex) else { return }
        let dogearsBeforeDeletion = dogears
        document.removePage(at: deletedPageIndex)
        if let documentID = currentLibraryFileID {
            metadataStore.updateForRemovedPages(
                documentID: documentID,
                removedPageIndexes: IndexSet(integer: deletedPageIndex)
            )
            refreshDogears()
        }
        registerUndoForRemovedPage(
            deletedPage,
            at: deletedPageIndex,
            dogearsBeforeDeletion: dogearsBeforeDeletion,
            actionName: "Delete Page"
        )
        currentPageIndex = min(currentPageIndex, max(0, document.pageCount - 1))
        selectedAnnotationID = nil
        selectedDocumentSearchResultID = nil
        refreshAnnotations()
        refreshDocumentSearchResults(selectFirstResult: false)
        refreshDocumentOutlineAfterPageMutation()
        enqueueCurrentDocumentSave(
            successMessage: "Page deleted from working copy.",
            action: "Delete Page",
            trigger: trigger
        )
    }

    func movePages(fromOffsets source: IndexSet, toOffset destination: Int) {
        guard let document,
              !source.isEmpty,
              source.allSatisfy({ $0 >= 0 && $0 < document.pageCount })
        else { return }

        performPageArrangement(actionName: "Reorder Pages") {
            let pages = source.compactMap { document.page(at: $0) }
            for index in source.sorted(by: >) {
                document.removePage(at: index)
            }

            var insertionIndex = destination - source.filter { $0 < destination }.count
            insertionIndex = min(max(0, insertionIndex), document.pageCount)
            for page in pages {
                document.insert(page, at: insertionIndex)
                insertionIndex += 1
            }
        }
    }

    func moveSelectedPages(_ indexes: IndexSet, by offset: Int) -> IndexSet {
        guard !indexes.isEmpty, offset != 0 else { return indexes }
        if offset < 0 {
            guard let first = indexes.first, first > 0 else { return indexes }
            movePages(fromOffsets: indexes, toOffset: first - 1)
            return IndexSet(indexes.map { $0 - 1 })
        }

        guard let last = indexes.last, last + 1 < pageCount else { return indexes }
        movePages(fromOffsets: indexes, toOffset: last + 2)
        return IndexSet(indexes.map { $0 + 1 })
    }

    func duplicatePages(at indexes: IndexSet) -> IndexSet {
        guard let document,
              !indexes.isEmpty,
              indexes.allSatisfy({ $0 >= 0 && $0 < document.pageCount })
        else { return [] }

        let sourcePages = indexes.compactMap { document.page(at: $0) }
        let copies = sourcePages.compactMap { $0.copy() as? PDFPage }
        guard copies.count == sourcePages.count, let last = indexes.last else {
            postFeedback(
                "Could not duplicate the selected pages.",
                kind: .error,
                action: "Duplicate Pages"
            )
            return []
        }

        let insertionIndex = last + 1
        performPageArrangement(actionName: "Duplicate Pages") {
            for (offset, page) in copies.enumerated() {
                document.insert(page, at: insertionIndex + offset)
            }
        }
        return IndexSet(insertionIndex..<(insertionIndex + copies.count))
    }

    func rotatePages(at indexes: IndexSet, clockwise: Bool) {
        guard let document,
              !indexes.isEmpty,
              indexes.allSatisfy({ $0 >= 0 && $0 < document.pageCount })
        else { return }

        performPageArrangement(actionName: clockwise ? "Rotate Pages Right" : "Rotate Pages Left") {
            for index in indexes {
                guard let page = document.page(at: index) else { continue }
                let rotation = page.rotation + (clockwise ? 90 : -90)
                page.rotation = ((rotation % 360) + 360) % 360
            }
        }
    }

    @discardableResult
    func deletePagesFromWorkingCopy(
        at indexes: IndexSet,
        trigger: FeedbackTrigger? = nil
    ) -> Bool {
        guard let document, !indexes.isEmpty else { return false }
        guard document.pageCount - indexes.count >= 1 else {
            postFeedback(
                "A PDF must keep at least one page.",
                kind: .warning,
                action: "Delete Pages",
                trigger: trigger
            )
            return false
        }

        let alert = NSAlert()
        alert.messageText = indexes.count == 1
            ? "Delete the selected page?"
            : "Delete \(indexes.count) selected pages?"
        alert.informativeText = "Dogear will update the app-managed working copy. The original PDF will not be changed."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Delete from Working Copy")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return false }

        performPageArrangement(actionName: "Delete Pages", trigger: trigger) {
            for index in indexes.sorted(by: >) {
                document.removePage(at: index)
            }
        }
        return true
    }

    func exportPages(at indexes: IndexSet, trigger: FeedbackTrigger? = nil) {
        guard let document, !indexes.isEmpty else { return }
        let exportedDocument = PDFDocument()
        exportedDocument.documentAttributes = document.documentAttributes

        for index in indexes.sorted() {
            guard let page = document.page(at: index)?.copy() as? PDFPage else {
                postFeedback(
                    "Could not prepare all selected pages for export.",
                    kind: .error,
                    action: "Export Selected Pages",
                    trigger: trigger
                )
                return
            }
            exportedDocument.insert(page, at: exportedDocument.pageCount)
        }

        writePDF(
            exportedDocument,
            suggestedName: suggestedFileName(suffix: "selected-pages"),
            successMessage: "Selected pages exported",
            action: "Export Selected Pages",
            trigger: trigger
        )
    }

    func discardCurrentWorkingCopyAndReopenOriginal() -> Bool {
        guard let selectedPDFURL else {
            postFeedback("No PDF is open.", kind: .warning, action: "Discard Changes")
            return false
        }

        if let currentWorkingCopyURL,
           FileManager.default.fileExists(atPath: currentWorkingCopyURL.path) {
            do {
                try FileManager.default.removeItem(at: currentWorkingCopyURL)
            } catch {
                postFeedback(
                    "Could not delete the working copy. Original PDF was not changed.",
                    kind: .error,
                    action: "Discard Changes"
                )
                return false
            }
        }

        return openPDF(
            from: selectedPDFURL,
            workingCopyURL: nil,
            initialPageIndex: currentPageIndex
        )
    }

    func exportAnnotationsMarkdown(trigger: FeedbackTrigger? = nil) {
        let markdown = MarkdownExportService.annotationsMarkdown(
            documentName: selectedDocumentName,
            annotations: annotations
        )

        writeMarkdown(
            markdown,
            suggestedName: suggestedMarkdownFileName(suffix: "annotations"),
            action: "Export Annotations Markdown",
            trigger: trigger
        )
    }

    func exportFallbackKeywordOutline(trigger: FeedbackTrigger? = nil) {
        let markdown = outlineProvider.keywordOutlineMarkdown(
            documentName: selectedDocumentName,
            annotations: annotations
        )

        writeMarkdown(
            markdown,
            suggestedName: suggestedMarkdownFileName(suffix: "highlight-outline"),
            action: "Export Keyword Outline",
            trigger: trigger
        )
    }

    func refreshAnnotations() {
        guard let document else {
            annotations = []
            return
        }

        annotations = AnnotationExtractor.annotationItems(in: document)

        if let selectedAnnotationID,
           !annotations.contains(where: { $0.id == selectedAnnotationID }) {
            self.selectedAnnotationID = nil
        }
    }

    func refreshDocumentSearchResults(selectFirstResult: Bool = false) {
        let query = documentSearchText.trimmingCharacters(in: .whitespacesAndNewlines)

        guard let document,
              !query.isEmpty
        else {
            documentSearchResults = []
            selectedDocumentSearchResultID = nil
            return
        }

        let selections = document.findString(
            query,
            withOptions: [.caseInsensitive, .diacriticInsensitive]
        )

        documentSearchResults = selections.enumerated().map { resultIndex, selection in
            let pageIndex = selection.pages
                .compactMap { page in document.index(for: page) }
                .first ?? 0

            return PDFSearchResult(
                id: "\(pageIndex):\(resultIndex)",
                pageIndex: pageIndex,
                resultIndex: resultIndex,
                selection: selection,
                snippet: Self.searchSnippet(for: selection)
            )
        }

        if selectFirstResult {
            selectedDocumentSearchResultID = documentSearchResults.first?.id
            currentPageIndex = documentSearchResults.first?.pageIndex ?? currentPageIndex
        } else if let selectedDocumentSearchResultID,
                  !documentSearchResults.contains(where: { $0.id == selectedDocumentSearchResultID }) {
            self.selectedDocumentSearchResultID = nil
        }
    }

    private func writePDF(
        _ document: PDFDocument,
        suggestedName: String,
        successMessage: String,
        action: String,
        trigger: FeedbackTrigger?,
        aiSelection: AIAnnotationExportSelection = .include
    ) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = suggestedName

        guard panel.runModal() == .OK, let destinationURL = panel.url else {
            postFeedback("Export canceled.", action: action, trigger: trigger)
            return
        }

        if isOriginalDocumentURL(destinationURL) {
            postFeedback(
                "Choose a different file name. The original PDF is not overwritten by default.",
                kind: .warning,
                action: action,
                trigger: trigger
            )
            return
        }

        let data: Data
        do {
            data = try AIAnnotationSelectiveExporter.dataRepresentation(
                of: document,
                selection: aiSelection
            )
        } catch {
            postFeedback(
                "Export failed. Original PDF was not changed.",
                kind: .error,
                action: action,
                trigger: trigger
            )
            return
        }

        do {
            try data.write(to: destinationURL, options: [.atomic])
            postFeedback(
                "\(successMessage) to \(destinationURL.lastPathComponent).",
                kind: .success,
                action: action,
                trigger: trigger
            )
        } catch {
            postFeedback(
                "Export failed. Original PDF was not changed.",
                kind: .error,
                action: action,
                trigger: trigger
            )
        }
    }

    private func requestAIAnnotationExportSelection() -> AIAnnotationExportSelection? {
        let alert = NSAlert()
        alert.messageText = String(
            localized: "Choose AI Highlight groups to export"
        )
        alert.informativeText = String(
            localized: "Only the selected groups are written to the new compatible PDF copy. The open working copy and original PDF are unchanged."
        )

        let groups = aiHighlightGroups.sorted { $0.createdAt > $1.createdAt }
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        var buttonsByGroupID: [UUID: NSButton] = [:]

        for group in groups {
            let title = "\(group.displayTitle)  (\(aiHighlightCount(in: group.id)))"
            let button = NSButton(
                checkboxWithTitle: title,
                target: nil,
                action: nil
            )
            button.state = visibleAIHighlightGroupIDs.contains(group.id) ? .on : .off
            button.toolTip = group.question
            stack.addArrangedSubview(button)
            buttonsByGroupID[group.id] = button
        }

        if groups.isEmpty {
            let button = NSButton(
                checkboxWithTitle: String(localized: "Recovered AI Highlights"),
                target: nil,
                action: nil
            )
            button.state = showsAIGeneratedContent ? .on : .off
            stack.addArrangedSubview(button)
            buttonsByGroupID[AIAnnotationProvenance.legacyGroupID] = button
        }

        let contentHeight = max(28, CGFloat(buttonsByGroupID.count) * 26)
        stack.frame = NSRect(
            x: 0,
            y: 0,
            width: 360,
            height: contentHeight
        )
        let scrollView = NSScrollView(
            frame: NSRect(
                x: 0,
                y: 0,
                width: 376,
                height: min(contentHeight, 260)
            )
        )
        scrollView.documentView = stack
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = contentHeight > 260
        scrollView.autohidesScrollers = true
        alert.accessoryView = scrollView
        alert.addButton(withTitle: String(localized: "Export Selected Groups"))
        alert.addButton(withTitle: String(localized: "Cancel"))

        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        let selectedGroupIDs = Set(buttonsByGroupID.compactMap { groupID, button in
            button.state == .on ? groupID : nil
        })
        return .selectedGroups(selectedGroupIDs)
    }

    private func writeMarkdown(
        _ markdown: String,
        suggestedName: String,
        action: String,
        trigger: FeedbackTrigger?
    ) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.markdown]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = suggestedName

        guard panel.runModal() == .OK, let destinationURL = panel.url else {
            postFeedback("Markdown export canceled.", action: action, trigger: trigger)
            return
        }

        do {
            try markdown.write(to: destinationURL, atomically: true, encoding: .utf8)
            postFeedback(
                "Markdown exported to \(destinationURL.lastPathComponent).",
                kind: .success,
                action: action,
                trigger: trigger
            )
        } catch {
            postFeedback(
                "Markdown export failed.",
                kind: .error,
                action: action,
                trigger: trigger
            )
        }
    }

    private func overwriteOriginalPDF(trigger: FeedbackTrigger?) {
        guard let document,
              let selectedPDFURL
        else {
            return
        }

        guard currentWorkingCopyURL != nil else {
            postFeedback(
                "No working-copy changes to save to the original PDF.",
                kind: .warning,
                action: "Save to Original",
                trigger: trigger
            )
            return
        }

        let alert = NSAlert()
        alert.messageText = "Overwrite original PDF?"
        alert.informativeText = "This writes the current working copy back to the original file. Export keeps the original unchanged."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Overwrite Original")
        alert.addButton(withTitle: "Cancel")

        guard alert.runModal() == .alertFirstButtonReturn else {
            postFeedback(
                "Save to original canceled.",
                action: "Save to Original",
                trigger: trigger
            )
            return
        }

        guard let data = document.dataRepresentationWithAIAnnotationsDisplayed() else {
            postFeedback(
                "Could not prepare PDF data. Original PDF was not changed.",
                kind: .error,
                action: "Save to Original",
                trigger: trigger
            )
            return
        }

        enqueueCurrentDocumentSave(
            successMessage: "Working copy saved.",
            action: "Save Working Copy",
            trigger: trigger
        )

        let documentID = openedDocumentID
        let generation = saveGeneration
        let didStartAccessing = selectedPDFURL.startAccessingSecurityScopedResource()

        hasUnsavedChanges = true
        postFeedback(
            "Saving to original PDF.",
            action: "Save to Original",
            trigger: trigger
        )

        saveQueue.enqueue(data: data, to: selectedPDFURL) { [weak self] result in
            if didStartAccessing {
                selectedPDFURL.stopAccessingSecurityScopedResource()
            }

            guard let self,
                  self.openedDocumentID == documentID
            else {
                return
            }

            switch result {
            case .success:
                if self.saveGeneration == generation {
                    self.currentWorkingCopyURL = nil
                    self.hasUnsavedChanges = false
                    self.postFeedback(
                        "Original PDF overwritten: \(selectedPDFURL.lastPathComponent).",
                        kind: .success,
                        action: "Save to Original",
                        trigger: trigger
                    )
                }
            case .failure:
                if self.saveGeneration == generation {
                    self.postFeedback(
                        "Overwrite failed. Working copy was kept.",
                        kind: .error,
                        action: "Save to Original",
                        trigger: trigger
                    )
                }
            }
        }
    }

    private func suggestedFileName(suffix: String) -> String {
        guard let selectedPDFURL else {
            return "\(suffix).pdf"
        }

        let baseName = selectedPDFURL.deletingPathExtension().lastPathComponent
        return "\(baseName)-\(suffix).pdf"
    }

    private func registerUndoForRemovedAnnotation(
        _ annotation: PDFAnnotation,
        page: PDFPage,
        actionName: String
    ) {
        undoManager?.registerUndo(withTarget: self) { target in
            target.restoreAnnotation(annotation, to: page, actionName: actionName)
        }
        undoManager?.setActionName(actionName)
    }

    private struct AIAnnotationUndoRecord {
        let page: PDFPage
        let annotation: PDFAnnotation
    }

    private func registerUndoForAddedAIAnnotationBatch(
        _ records: [AIAnnotationUndoRecord],
        group: AIHighlightGroup,
        actionName: String
    ) {
        undoManager?.registerUndo(withTarget: self) { target in
            target.removeAIAnnotationBatchForUndo(
                records,
                group: group,
                actionName: actionName
            )
        }
        undoManager?.setActionName(actionName)
    }

    private func removeAIAnnotationBatchForUndo(
        _ records: [AIAnnotationUndoRecord],
        group: AIHighlightGroup,
        actionName: String
    ) {
        let wasVisible = visibleAIHighlightGroupIDs.contains(group.id)
        for record in records where record.annotation.page === record.page {
            record.page.removeAnnotation(record.annotation)
        }
        removeAIHighlightGroup(group.id)
        undoManager?.registerUndo(withTarget: self) { target in
            target.restoreAIAnnotationBatchForRedo(
                records,
                group: group,
                visible: wasVisible,
                actionName: actionName
            )
        }
        undoManager?.setActionName(actionName)
        finishUndoableDocumentMutation(actionName: actionName)
    }

    private func restoreAIAnnotationBatchForRedo(
        _ records: [AIAnnotationUndoRecord],
        group: AIHighlightGroup,
        visible: Bool,
        actionName: String
    ) {
        registerAIHighlightGroup(group, visible: visible)
        for record in records where record.annotation.page == nil {
            record.annotation.shouldDisplay = visibleAIHighlightGroupIDs.contains(group.id)
            record.page.addAnnotation(record.annotation)
        }
        registerUndoForAddedAIAnnotationBatch(
            records,
            group: group,
            actionName: actionName
        )
        finishUndoableDocumentMutation(actionName: actionName)
    }

    private func hasDuplicateAIHighlight(
        _ anchor: ResolvedAIHighlightAnchor,
        groupID: UUID,
        on page: PDFPage
    ) -> Bool {
        let expectedBounds = anchor.annotationBounds.cgRect
        let expectedPoints = anchor.quadrilateralPoints.map(\.cgPoint)
        return page.annotations.contains { annotation in
            guard AIAnnotationProvenance.classify(annotation).isAI,
                  AIAnnotationProvenance.groupID(of: annotation) == groupID,
                  annotation.type == "Highlight",
                  approximatelyEqual(annotation.bounds, expectedBounds),
                  let points = annotation.quadrilateralPoints?.map(\.pointValue),
                  points.count == expectedPoints.count
            else {
                return false
            }
            return zip(points, expectedPoints).allSatisfy {
                approximatelyEqual($0.0, $0.1)
            }
        }
    }

    private func approximatelyEqual(_ lhs: CGRect, _ rhs: CGRect) -> Bool {
        approximatelyEqual(lhs.origin, rhs.origin)
            && abs(lhs.width - rhs.width) <= 0.5
            && abs(lhs.height - rhs.height) <= 0.5
    }

    private func approximatelyEqual(_ lhs: CGPoint, _ rhs: CGPoint) -> Bool {
        abs(lhs.x - rhs.x) <= 0.5 && abs(lhs.y - rhs.y) <= 0.5
    }

    private func applyAIAnnotationDisplayPreference() {
        guard let document else { return }
        _ = AIAnnotationDisplayController.setAIAnnotationGroupsShouldDisplay(
            visibleGroupIDs: visibleAIHighlightGroupIDs,
            in: document
        )
    }

    private func registerAIHighlightGroup(
        _ group: AIHighlightGroup,
        visible: Bool
    ) {
        aiHighlightGroups.removeAll { $0.id == group.id }
        aiHighlightGroups.append(group)
        aiHighlightGroups.sort { $0.createdAt > $1.createdAt }
        if visible {
            visibleAIHighlightGroupIDs.insert(group.id)
            activeAIHighlightGroupID = group.id
        } else {
            visibleAIHighlightGroupIDs.remove(group.id)
        }
        persistAIHighlightGroupState()
        synchronizeAIMasterVisibility()
        applyAIAnnotationDisplayPreference()
    }

    private func removeAIHighlightGroup(_ groupID: UUID) {
        aiHighlightGroups.removeAll { $0.id == groupID }
        visibleAIHighlightGroupIDs.remove(groupID)
        if activeAIHighlightGroupID == groupID {
            activeAIHighlightGroupID = nil
        }
        persistAIHighlightGroupState()
        synchronizeAIMasterVisibility()
        applyAIAnnotationDisplayPreference()
    }

    private func refreshAIHighlightGroups(
        refreshAnnotationList: Bool = true
    ) {
        guard let document else {
            aiHighlightGroups = []
            visibleAIHighlightGroupIDs = []
            activeAIHighlightGroupID = nil
            synchronizeAIMasterVisibility()
            return
        }

        var namesByGroupID: [UUID: [String]] = [:]
        var creationDateByGroupID: [UUID: Date] = [:]
        for pageIndex in 0..<document.pageCount {
            guard let page = document.page(at: pageIndex) else { continue }
            for annotation in page.annotations {
                guard let identity = AIAnnotationProvenance.identity(of: annotation) else {
                    continue
                }
                let groupID = identity.groupID ?? AIAnnotationProvenance.legacyGroupID
                namesByGroupID[groupID, default: []].append(identity.uniqueName)
                let date = annotation.modificationDate ?? Date()
                creationDateByGroupID[groupID] = min(
                    creationDateByGroupID[groupID] ?? date,
                    date
                )
            }
        }

        let persistedState = currentLibraryFileID.flatMap {
            aiHighlightGroupStore.documentState(for: $0)
        }
        var groups: [AIHighlightGroup] = []
        var knownGroupIDs: Set<UUID> = []
        let baseGroups = persistedState?.groups ?? aiHighlightGroups
        for var group in baseGroups {
            guard let names = namesByGroupID[group.id], !names.isEmpty else {
                continue
            }
            group.annotationUniqueNames = names.sorted()
            groups.append(group)
            knownGroupIDs.insert(group.id)
        }

        for (groupID, names) in namesByGroupID where !knownGroupIDs.contains(groupID) {
            groups.append(
                AIHighlightGroup(
                    id: groupID,
                    requestKind: .recovered,
                    providerName: AIAnnotationProvenance.authorName,
                    modelName: "",
                    promptVersion: "unknown",
                    annotationUniqueNames: names.sorted(),
                    createdAt: creationDateByGroupID[groupID] ?? Date()
                )
            )
        }

        groups.sort { $0.createdAt > $1.createdAt }
        let availableGroupIDs = Set(groups.map(\.id))
        let baseVisibleGroupIDs = persistedState?.visibleGroupIDs
            ?? visibleAIHighlightGroupIDs
        var visibleGroupIDs = baseVisibleGroupIDs.isEmpty && persistedState == nil
            ? availableGroupIDs
            : baseVisibleGroupIDs.intersection(availableGroupIDs)
        if persistedState != nil || !baseGroups.isEmpty {
            let recoveredGroupIDs = availableGroupIDs.subtracting(
                Set(baseGroups.map(\.id))
            )
            visibleGroupIDs.formUnion(recoveredGroupIDs)
        }

        aiHighlightGroups = groups
        visibleAIHighlightGroupIDs = visibleGroupIDs
        if let activeAIHighlightGroupID,
           !visibleGroupIDs.contains(activeAIHighlightGroupID) {
            self.activeAIHighlightGroupID = nil
        }
        persistAIHighlightGroupState()
        synchronizeAIMasterVisibility()
        applyAIAnnotationDisplayPreference()
        if refreshAnnotationList {
            refreshAnnotations()
        }
    }

    private func persistAIHighlightGroupState() {
        guard let currentLibraryFileID else { return }
        if aiHighlightGroups.isEmpty {
            aiHighlightGroupStore.removeDocumentState(for: currentLibraryFileID)
            return
        }
        aiHighlightGroupStore.replaceDocumentState(
            AIHighlightDocumentGroupState(
                documentID: currentLibraryFileID,
                groups: aiHighlightGroups,
                visibleGroupIDs: visibleAIHighlightGroupIDs
            )
        )
    }

    private func synchronizeAIMasterVisibility() {
        let newValue = !visibleAIHighlightGroupIDs.isEmpty
        guard showsAIGeneratedContent != newValue else { return }
        isSynchronizingAIMasterVisibility = true
        showsAIGeneratedContent = newValue
        isSynchronizingAIMasterVisibility = false
    }

    private func restoreAnnotation(
        _ annotation: PDFAnnotation,
        to page: PDFPage,
        actionName: String
    ) {
        guard annotation.page == nil else { return }
        page.addAnnotation(annotation)
        undoManager?.registerUndo(withTarget: self) { target in
            target.removeAnnotationForUndo(annotation, from: page, actionName: actionName)
        }
        undoManager?.setActionName(actionName)
        finishUndoableDocumentMutation(actionName: actionName)
    }

    private func removeAnnotationForUndo(
        _ annotation: PDFAnnotation,
        from page: PDFPage,
        actionName: String
    ) {
        guard annotation.page === page else { return }
        page.removeAnnotation(annotation)
        registerUndoForRemovedAnnotation(annotation, page: page, actionName: actionName)
        finishUndoableDocumentMutation(actionName: actionName)
    }

    private func registerUndoForRemovedPage(
        _ page: PDFPage,
        at index: Int,
        dogearsBeforeDeletion: [DogearMarker],
        actionName: String
    ) {
        undoManager?.registerUndo(withTarget: self) { target in
            target.restorePage(
                page,
                at: index,
                dogearsBeforeDeletion: dogearsBeforeDeletion,
                actionName: actionName
            )
        }
        undoManager?.setActionName(actionName)
    }

    private func restorePage(
        _ page: PDFPage,
        at index: Int,
        dogearsBeforeDeletion: [DogearMarker],
        actionName: String
    ) {
        guard let document, document.index(for: page) == NSNotFound else { return }
        let dogearsBeforeRestoration = dogears
        let insertionIndex = min(max(0, index), document.pageCount)
        document.insert(page, at: insertionIndex)
        if let documentID = currentLibraryFileID {
            metadataStore.replaceDogears(for: documentID, with: dogearsBeforeDeletion)
            refreshDogears()
        }
        undoManager?.registerUndo(withTarget: self) { target in
            target.removePageForUndo(
                page,
                dogearsAfterRemoval: dogearsBeforeRestoration,
                actionName: actionName
            )
        }
        undoManager?.setActionName(actionName)
        currentPageIndex = insertionIndex
        finishUndoableDocumentMutation(actionName: actionName)
    }

    private func removePageForUndo(
        _ page: PDFPage,
        dogearsAfterRemoval: [DogearMarker],
        actionName: String
    ) {
        guard let document else { return }
        let index = document.index(for: page)
        guard index != NSNotFound, document.pageCount > 1 else { return }
        let dogearsBeforeDeletion = dogears
        document.removePage(at: index)
        if let documentID = currentLibraryFileID {
            metadataStore.replaceDogears(for: documentID, with: dogearsAfterRemoval)
            refreshDogears()
        }
        registerUndoForRemovedPage(
            page,
            at: index,
            dogearsBeforeDeletion: dogearsBeforeDeletion,
            actionName: actionName
        )
        currentPageIndex = min(index, max(0, document.pageCount - 1))
        finishUndoableDocumentMutation(actionName: actionName)
    }

    private func finishUndoableDocumentMutation(actionName: String) {
        selectedAnnotationID = nil
        selectedDocumentSearchResultID = nil
        refreshAnnotations()
        refreshDocumentSearchResults(selectFirstResult: false)
        refreshDocumentOutlineAfterPageMutation()
        enqueueCurrentDocumentSave(
            successMessage: "Undo/redo saved to working copy.",
            action: actionName,
            trigger: .command(shortcut: "Command-Z")
        )
    }

    private struct PageArrangementSnapshot {
        struct PageState {
            let page: PDFPage
            let rotation: Int
        }

        let pages: [PageState]
        let dogears: [DogearMarker]
        let currentPage: PDFPage?
        let currentPageIndex: Int
    }

    private func pageArrangementSnapshot() -> PageArrangementSnapshot? {
        guard let document else { return nil }
        let pages = (0..<document.pageCount).compactMap { index -> PageArrangementSnapshot.PageState? in
            guard let page = document.page(at: index) else { return nil }
            return .init(page: page, rotation: page.rotation)
        }
        return PageArrangementSnapshot(
            pages: pages,
            dogears: dogears,
            currentPage: document.page(at: currentPageIndex),
            currentPageIndex: currentPageIndex
        )
    }

    private func performPageArrangement(
        actionName: String,
        trigger: FeedbackTrigger? = nil,
        mutation: () -> Void
    ) {
        guard let document, let before = pageArrangementSnapshot() else { return }
        let previousPages = before.pages.map(\.page)
        mutation()
        let currentPages = (0..<document.pageCount).compactMap { document.page(at: $0) }
        remapDogears(from: previousPages, to: currentPages)

        if let currentPage = before.currentPage {
            let newIndex = document.index(for: currentPage)
            currentPageIndex = newIndex == NSNotFound
                ? min(before.currentPageIndex, max(0, document.pageCount - 1))
                : newIndex
        }

        registerUndoForPageArrangement(before, actionName: actionName)
        finishPageArrangement(actionName: actionName, trigger: trigger)
    }

    private func registerUndoForPageArrangement(
        _ snapshot: PageArrangementSnapshot,
        actionName: String
    ) {
        undoManager?.registerUndo(withTarget: self) { target in
            target.restorePageArrangement(snapshot, actionName: actionName)
        }
        undoManager?.setActionName(actionName)
    }

    private func restorePageArrangement(
        _ snapshot: PageArrangementSnapshot,
        actionName: String
    ) {
        guard let document, let redoSnapshot = pageArrangementSnapshot() else { return }
        for index in stride(from: document.pageCount - 1, through: 0, by: -1) {
            document.removePage(at: index)
        }
        for (index, state) in snapshot.pages.enumerated() {
            state.page.rotation = state.rotation
            document.insert(state.page, at: index)
        }
        if let documentID = currentLibraryFileID {
            metadataStore.replaceDogears(for: documentID, with: snapshot.dogears)
            refreshDogears()
        }
        if let currentPage = snapshot.currentPage {
            let restoredIndex = document.index(for: currentPage)
            currentPageIndex = restoredIndex == NSNotFound
                ? min(snapshot.currentPageIndex, max(0, document.pageCount - 1))
                : restoredIndex
        }
        registerUndoForPageArrangement(redoSnapshot, actionName: actionName)
        finishPageArrangement(actionName: actionName, trigger: .command(shortcut: "Command-Z"))
    }

    private func remapDogears(from oldPages: [PDFPage], to newPages: [PDFPage]) {
        guard let documentID = currentLibraryFileID else { return }
        let newIndexes = Dictionary(
            uniqueKeysWithValues: newPages.enumerated().map { (ObjectIdentifier($0.element), $0.offset) }
        )
        let remapped = dogears.compactMap { marker -> DogearMarker? in
            guard marker.pageIndex >= 0, marker.pageIndex < oldPages.count,
                  let newIndex = newIndexes[ObjectIdentifier(oldPages[marker.pageIndex])]
            else { return nil }
            var marker = marker
            marker.pageIndex = newIndex
            marker.updatedAt = Date()
            return marker
        }
        metadataStore.replaceDogears(for: documentID, with: remapped)
        refreshDogears()
    }

    private func finishPageArrangement(
        actionName: String,
        trigger: FeedbackTrigger?
    ) {
        selectedAnnotationID = nil
        selectedDocumentSearchResultID = nil
        refreshAnnotations()
        refreshDocumentSearchResults(selectFirstResult: false)
        refreshDocumentOutlineAfterPageMutation()
        enqueueCurrentDocumentSave(
            successMessage: "Page changes saved to working copy.",
            action: actionName,
            trigger: trigger
        )
    }

    private func refreshDogears() {
        guard let currentLibraryFileID else {
            dogears = []
            return
        }
        dogears = metadataStore.dogears(for: currentLibraryFileID)
    }

    private func registerUndoForAddedDogear(_ marker: DogearMarker, actionName: String) {
        undoManager?.registerUndo(withTarget: self) { target in
            target.removeDogearForUndo(marker, actionName: actionName)
        }
        undoManager?.setActionName(actionName)
    }

    private func registerUndoForRemovedDogear(_ marker: DogearMarker, actionName: String) {
        undoManager?.registerUndo(withTarget: self) { target in
            target.restoreDogearForUndo(marker, actionName: actionName)
        }
        undoManager?.setActionName(actionName)
    }

    private func removeDogearForUndo(_ marker: DogearMarker, actionName: String) {
        metadataStore.removeDogear(id: marker.id)
        registerUndoForRemovedDogear(marker, actionName: actionName)
        refreshDogears()
    }

    private func restoreDogearForUndo(_ marker: DogearMarker, actionName: String) {
        metadataStore.restoreDogear(marker)
        registerUndoForAddedDogear(marker, actionName: actionName)
        refreshDogears()
    }

    private func registerUndoForDogearSnapshot(
        _ snapshot: [DogearMarker],
        actionName: String
    ) {
        undoManager?.registerUndo(withTarget: self) { target in
            target.restoreDogearSnapshot(snapshot, actionName: actionName)
        }
        undoManager?.setActionName(actionName)
    }

    private func restoreDogearSnapshot(_ snapshot: [DogearMarker], actionName: String) {
        guard let documentID = currentLibraryFileID else { return }
        let redoSnapshot = dogears
        metadataStore.replaceDogears(for: documentID, with: snapshot)
        refreshDogears()
        registerUndoForDogearSnapshot(redoSnapshot, actionName: actionName)
    }

    private func refreshDocumentOutlineAfterPageMutation() {
        guard let document else { return }
        refreshDocumentOutline(for: document)
    }

    private func suggestedMarkdownFileName(suffix: String) -> String {
        guard let selectedPDFURL else {
            return "\(suffix).md"
        }

        let baseName = selectedPDFURL.deletingPathExtension().lastPathComponent
        return "\(baseName)-\(suffix).md"
    }

    private func closeSecurityScopedAccess() {
        accessedSecurityScopedURL?.stopAccessingSecurityScopedResource()
        accessedSecurityScopedURL = nil
    }

    private func enqueueCurrentDocumentSave(
        successMessage: String = "Working copy saved.",
        action: String = "Save Working Copy",
        trigger: FeedbackTrigger? = nil
    ) {
        guard let document,
              let selectedPDFURL
        else {
            return
        }

        guard let data = document.dataRepresentationWithAIAnnotationsDisplayed() else {
            postFeedback(
                "Could not prepare working copy data.",
                kind: .error,
                action: action,
                trigger: trigger
            )
            return
        }

        guard let workingCopyURL = currentWorkingCopyURL ?? workingCopyStore?.workingCopyURL(forOriginalURL: selectedPDFURL) else {
            postFeedback(
                "Could not locate the app-managed working copy directory.",
                kind: .error,
                action: action,
                trigger: trigger
            )
            return
        }

        currentWorkingCopyURL = workingCopyURL

        saveGeneration += 1
        let generation = saveGeneration
        let documentID = openedDocumentID
        hasUnsavedChanges = true

        saveQueue.enqueue(data: data, to: workingCopyURL) { [weak self] result in
            guard let self,
                  self.openedDocumentID == documentID
            else {
                return
            }

            switch result {
            case .success:
                if generation == self.saveGeneration {
                    self.hasUnsavedChanges = false
                    self.postFeedback(
                        successMessage,
                        kind: .success,
                        action: action,
                        trigger: trigger
                    )
                }
            case .failure:
                if generation == self.saveGeneration {
                    self.postFeedback(
                        "Working copy save failed. Original PDF was not changed.",
                        kind: .error,
                        action: action,
                        trigger: trigger
                    )
                }
            }
        }
    }

    private func selectRelativeFilteredAnnotation(offset: Int) {
        let visibleAnnotations = filteredAnnotations

        guard !visibleAnnotations.isEmpty else {
            postFeedback(
                "No annotation matches to navigate.",
                kind: .warning,
                action: "Navigate Annotation"
            )
            return
        }

        let currentIndex = visibleAnnotations.firstIndex { $0.id == selectedAnnotationID }
        let nextIndex: Int

        if let currentIndex {
            nextIndex = (currentIndex + offset + visibleAnnotations.count) % visibleAnnotations.count
        } else {
            nextIndex = offset < 0 ? visibleAnnotations.count - 1 : 0
        }

        selectAnnotation(visibleAnnotations[nextIndex])
    }

    private func selectRelativeDocumentSearchResult(offset: Int) {
        guard !documentSearchResults.isEmpty else {
            postFeedback(
                "No full-text matches to navigate.",
                kind: .warning,
                action: "Navigate Search Results"
            )
            return
        }

        let currentIndex = documentSearchResults.firstIndex { $0.id == selectedDocumentSearchResultID }
        let nextIndex: Int

        if let currentIndex {
            nextIndex = (currentIndex + offset + documentSearchResults.count) % documentSearchResults.count
        } else {
            nextIndex = offset < 0 ? documentSearchResults.count - 1 : 0
        }

        selectDocumentSearchResult(documentSearchResults[nextIndex])
    }

    private func refreshDocumentOutline(for document: PDFDocument) {
        outlineLoadingTask?.cancel()
        outlineEntries = []
        isLoadingOutline = true
        let documentID = openedDocumentID

        outlineLoadingTask = Task { [weak self, weak document] in
            guard let self, let document else {
                return
            }

            let entries = await documentOutlineProvider.outline(for: document)
            guard !Task.isCancelled, openedDocumentID == documentID else {
                return
            }

            outlineEntries = entries
            isLoadingOutline = false
        }
    }

    private func postFeedback(
        _ message: String,
        kind: OperationFeedbackKind = .info,
        action: String? = nil,
        trigger: FeedbackTrigger? = nil
    ) {
        feedbackCenter.post(
            message,
            kind: kind,
            action: action,
            trigger: trigger
        )
    }

    private static func searchSnippet(for selection: PDFSelection) -> String {
        let text = selection.string?
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        guard text.count > 140 else {
            return text
        }

        let endIndex = text.index(text.startIndex, offsetBy: 140)
        return "\(text[..<endIndex])..."
    }

    deinit {
        outlineLoadingTask?.cancel()
        accessedSecurityScopedURL?.stopAccessingSecurityScopedResource()
    }
}

private extension UTType {
    static var markdown: UTType {
        UTType(filenameExtension: "md") ?? .plainText
    }
}
