import Foundation

/// Offline fixtures only: never use configured credentials or open user PDFs.
@MainActor
enum AIWorkflowDiagnosticSuite {
    static func run() async -> Bool {
        var failures: [String] = []
        var total = 0
        func report(_ name: String, checks: Int, failures items: [String]) {
            total += checks
            failures.append(contentsOf: items.map { "\(name): \($0)" })
            print("\(items.isEmpty ? "PASS" : "FAIL") \(name): \(checks) checks")
            for item in items { print("  \(item)") }
        }
        let sharedAPIs = SharedNativeAPIDiagnostics.run()
        report("shared native APIs", checks: sharedAPIs.checkCount, failures: sharedAPIs.failures)
        let imageImport = ResearchImageImportDiagnostics.run()
        report("Research image import", checks: imageImport.checks, failures: imageImport.failures)
        let freeTextPreview = FreeTextPreviewDiagnostics.run()
        report("FreeText preview", checks: freeTextPreview.checkCount, failures: freeTextPreview.failures)
        let libraryWorkflow = await LibraryWorkflowDiagnostics.run()
        report("Library workflows", checks: libraryWorkflow.checks, failures: libraryWorkflow.failures)
        let libraryImport = await LibraryImportDiagnostics.run()
        report("Library import", checks: libraryImport.checkCount, failures: libraryImport.failures)
        let interactions = DocumentInteractionDiagnostics.run()
        report("document interactions", checks: interactions.checkCount, failures: interactions.failures)
        let readingPosition = await PDFReadingPositionDiagnostics.run()
        report("reading position", checks: readingPosition.checkCount, failures: readingPosition.failures)
        let readingNavigation = await ReadingNavigationDiagnostics.run()
        report("reading navigation persistence", checks: readingNavigation.checks, failures: readingNavigation.failures)
        let scrolling = PDFScrollPerformanceDiagnostics.run()
        report("scroll invalidation", checks: scrolling.checks, failures: scrolling.failures)
        let marginLayout = MarginCanvasLayoutDiagnostics.run()
        report("margin canvas layout", checks: marginLayout.checks, failures: marginLayout.failures)
        let sidebarLayout = ReaderSidebarLayoutDiagnostics.run()
        report("reader sidebar layout", checks: sidebarLayout.checks, failures: sidebarLayout.failures)
        let sidebarSharing = WindowSidebarSharingDiagnostics.run()
        report("window sidebar sharing", checks: sidebarSharing.checks, failures: sidebarSharing.failures)
        let libraryPersistence = await LibraryPersistenceDiagnostics.run()
        report("library persistence", checks: libraryPersistence.checks, failures: libraryPersistence.failures)
        let commands = await ResearchCommandDiagnostics.run()
        report("research commands", checks: commands.checkCount, failures: commands.failures)
        let commandWorkflow = await ResearchCommandWorkflowDiagnostics.run()
        report("research command workflow", checks: commandWorkflow.checks, failures: commandWorkflow.failures)
        let textEditor = ResearchTextEditorDiagnostics.run()
        report("research native text editor", checks: textEditor.checks, failures: textEditor.failures)
        let ranking = await MultiSourceRankingDiagnostics.run()
        report("multi-source global ranking", checks: ranking.checks, failures: ranking.failures)
        let workspace = GroupWorkspacePersistenceDiagnostics.run()
        report("Group workspace persistence", checks: workspace.checks, failures: workspace.failures)
        let titlebarAppearance = GroupWorkspaceTitlebarAppearanceDiagnostics.run()
        report("Group titlebar appearance", checks: titlebarAppearance.checks, failures: titlebarAppearance.failures)
        let titlebarInteraction = GroupWorkspaceTitlebarInteractionDiagnostics.run()
        report("Group titlebar interaction", checks: titlebarInteraction.checks, failures: titlebarInteraction.failures)
        let research = ResearchPersistenceDiagnostics.run()
        report("research persistence", checks: research.checks, failures: research.failures)
        let contextReceipt = ResearchContextSummaryDiagnostics.run()
        report("research context receipt", checks: contextReceipt.checks, failures: contextReceipt.failures)
        let researchRuntime = await ResearchRuntimeDiagnostics.run()
        report("research runtime and trace", checks: researchRuntime.checkCount, failures: researchRuntime.failures)
        let access = await DocumentAccessDiagnostics.run()
        report("document ownership", checks: access.checkCount, failures: access.failures)
        let multiSource = await MultiSourceEvidenceDiagnostics.run()
        report("multi-source evidence", checks: multiSource.checks, failures: multiSource.failures)
        let visual = await ResearchVisualEvidenceDiagnostics.run()
        report("visual evidence", checks: visual.checks, failures: visual.failures)
        let images = await ResearchImageProviderDiagnostics.run()
        report("image provider", checks: images.checks, failures: images.failures)
        let foundation = await AIHighlightFoundationDiagnostics.run()
        let bugfix = await AIRAGBugfixDiagnostics.run()
        report("RAG bugfix", checks: bugfix.checkCount, failures: bugfix.failures)
        let bm25 = AIBM25Diagnostics.run()
        report("BM25 lexical core", checks: bm25.checks, failures: bm25.failures)
        let sharedMemoryBM25 = await AISharedMemoryBM25CacheDiagnostics.run()
        report(
            "shared memory BM25 cache",
            checks: sharedMemoryBM25.checks,
            failures: sharedMemoryBM25.failures
        )
        let fusion = AIRetrievalFusionDiagnostics.run()
        report("weighted RRF", checks: fusion.checks, failures: fusion.failures)
        let persistentLexical = await AIPersistentLexicalIndexDiagnostics.run()
        report(
            "persistent lexical index",
            checks: persistentLexical.checks,
            failures: persistentLexical.failures
        )
        let sourceSnapshots = await AIRetrievalSourceSnapshotCacheDiagnostics.run()
        report(
            "retrieval source snapshot cache",
            checks: sourceSnapshots.checks,
            failures: sourceSnapshots.failures
        )
        let retrieval = await AIEvidenceRetrievalDiagnostics.run()
        report("evidence retrieval", checks: retrieval.checks, failures: retrieval.failures)
        let denseCache = await AIDenseEmbeddingCacheDiagnostics.run()
        report("dense embedding cache", checks: denseCache.checks, failures: denseCache.failures)
        report("foundation", checks: foundation.checkCount, failures: foundation.failures)
        let runtime = await AIToolRuntimeDiagnostics.run()
        report("bounded runtime", checks: runtime.checks, failures: runtime.failures)
        let codec = await AIHighlightCodecDiagnostics.run()
        report("wire codec", checks: codec.checks, failures: codec.failures)
        let workflow = await AIHighlightToolWorkflowDiagnostics.run()
        report("workflow", checks: workflow.checks, failures: workflow.failures)
        let provider = await OpenAICompatibleToolProviderDiagnostics.run()
        report("provider", checks: provider.checks, failures: provider.failures)
        let native = AIHighlightNativePDFDiagnostics.run()
        report("native PDF", checks: native.checkCount, failures: native.failures)
        let safety = await AIHighlightPublicationSafetyDiagnostics.run()
        report("publication safety", checks: safety.checkCount, failures: safety.failures)
        let reviewBounds = await AIAnswerReviewBoundsDiagnostics.run()
        report("answer review bounds", checks: reviewBounds.checks, failures: reviewBounds.failures)
        let fallback = await AILocalOutlineFallbackDiagnostics.run()
        report("local fallback", checks: fallback.checks, failures: fallback.failures)
        let presentation = AIPresentationDiagnostics.run()
        report("consent and localization", checks: presentation.checkCount, failures: presentation.failures)
        let credentials = await AIConfigurationAccessDiagnostics.run()
        report("credential access", checks: credentials.checks, failures: credentials.failures)
        let annotation = AIHighlightNativeAnnotationDiagnostics.run()
        report("native annotation", checks: annotation.checkCount, failures: annotation.failures)
        let annotationEditing = AnnotationEditingDiagnostics.run()
        report("annotation editing and export", checks: annotationEditing.checkCount, failures: annotationEditing.failures)
        let freeTextEditing = FreeTextEditingDiagnostics.run()
        report("FreeText editing", checks: freeTextEditing.checkCount, failures: freeTextEditing.failures)
        let nightSelection = PDFNightSelectionDiagnostics.run()
        report("night selection rendering", checks: nightSelection.checkCount, failures: nightSelection.failures)
        let application = AIHighlightApplicationDiagnostics.run()
        report("atomic application", checks: application.checkCount, failures: application.failures)
        let persistence = await AIHighlightPersistenceDiagnostics.run()
        report("isolated persistence", checks: persistence.checkCount, failures: persistence.failures)
        print("AI DIAGNOSTICS: \(total) checks, \(failures.count) failures")
        return failures.isEmpty
    }
}
