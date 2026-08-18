import AppKit
import Combine
import Foundation
import PDFKit
import UniformTypeIdentifiers

@MainActor
final class PDFDocumentStore: ObservableObject {
    @Published var selectedPDFURL: URL?
    @Published var document: PDFDocument?
    @Published var hasUnsavedChanges = false
    @Published var annotations: [PDFAnnotationItem] = []
    @Published var selectedAnnotationID: PDFAnnotationItem.ID?
    @Published var searchText = ""
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

    private let outlineProvider: KeywordOutlineProviding
    private let documentOutlineProvider: DocumentOutlineProviding
    private let workingCopyStore: PDFWorkingCopyStore?
    private let saveQueue: PDFSaveQueue
    private let feedbackCenter: OperationFeedbackCenter
    private var accessedSecurityScopedURL: URL?
    private var openedDocumentID = UUID()
    private var saveGeneration = 0
    private var outlineNavigationRequestID = 0
    private var outlineLoadingTask: Task<Void, Never>?

    init(
        feedbackCenter: OperationFeedbackCenter,
        outlineProvider: KeywordOutlineProviding? = nil,
        documentOutlineProvider: DocumentOutlineProviding? = nil,
        workingCopyStore: PDFWorkingCopyStore? = nil,
        saveQueue: PDFSaveQueue? = nil
    ) {
        self.feedbackCenter = feedbackCenter
        self.outlineProvider = outlineProvider ?? FallbackKeywordOutlineProvider()
        self.documentOutlineProvider = documentOutlineProvider ?? DocumentOutlineService()
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
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !query.isEmpty else {
            return annotations
        }

        return annotations.filter {
            $0.searchableText.localizedCaseInsensitiveContains(query)
        }
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
        let noun = count == 1 ? "match" : "matches"
        return "\(count) \(noun)"
    }

    var documentSearchCountDescription: String {
        let count = documentSearchResults.count
        let noun = count == 1 ? "match" : "matches"
        return "\(count) \(noun)"
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
        openedDocumentID = UUID()
        saveGeneration = 0
        hasUnsavedChanges = false
        currentPageIndex = min(max(0, initialPageIndex), max(0, document.pageCount - 1))
        selectedAnnotationID = nil
        selectedDocumentSearchResultID = nil
        outlineNavigationRequest = nil
        currentTextSelection = nil
        refreshAnnotations()
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

    func selectAnnotation(_ annotation: PDFAnnotationItem) {
        selectedDocumentSearchResultID = nil
        selectedAnnotationID = annotation.id
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

        writePDF(
            document,
            suggestedName: suggestedFileName(suffix: "annotated"),
            successMessage: "Annotated copy exported",
            action: "Export Annotated Copy",
            trigger: trigger
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

        document.removePage(at: currentPageIndex)
        currentPageIndex = min(currentPageIndex, max(0, document.pageCount - 1))
        selectedAnnotationID = nil
        selectedDocumentSearchResultID = nil
        refreshAnnotations()
        refreshDocumentSearchResults(selectFirstResult: false)
        enqueueCurrentDocumentSave(
            successMessage: "Page deleted from working copy.",
            action: "Delete Page",
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
        trigger: FeedbackTrigger?
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

        guard let data = document.dataRepresentationWithFreeTextAnnotationsDisplayed() else {
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

        guard let data = document.dataRepresentationWithFreeTextAnnotationsDisplayed() else {
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

        guard let data = document.dataRepresentationWithFreeTextAnnotationsDisplayed() else {
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
