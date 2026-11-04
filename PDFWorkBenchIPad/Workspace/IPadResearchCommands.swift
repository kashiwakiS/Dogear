#if os(iOS)
import PDFKit

/// Native presentation supplies bounded commands to the same service used on
/// Mac. Cross-document navigation always creates a detached reference reader.
@MainActor
enum IPadResearchCommands {
    static func register(workspace: IPadGroupWorkspace, library: LibraryStore, commands: ResearchCommandService) {
        let store = workspace.document
        commands.register(viewID: workspace.state.id, handlers: ResearchCommandHandlers(
            snapshot: {
                ResearchWorkspaceViewState(mainFileID: library.file(for: store.selectedPDFURL)?.id,
                    pageIndex: store.currentPageIndex, zoomPercent: workspace.zoomPercent, wideAI: workspace.showsResearch,
                    visibleGroupIDs: Array(store.visibleAIHighlightGroupIDs),
                    pageOffsetX: workspace.pageOffset?.x, pageOffsetY: workspace.pageOffset?.y,
                    zoomMode: workspace.zoomMode.rawValue,
                    highlightGroups: store.aiHighlightGroups.prefix(50).map {
                        .init(id: $0.id, title: String(($0.title ?? "").prefix(160)), visible: store.isAIHighlightGroupVisible($0.id))
                    }, selectedText: store.currentTextSelection.map { String($0.text.prefix(4_000)) },
                    selectedAnnotationText: store.selectedAnnotation.map { String(($0.text + "\n" + $0.note).prefix(4_000)) },
                    selectionWasClipped: (store.currentTextSelection?.text.count ?? 0) > 4_000,
                    highlightGroupsWereClipped: store.aiHighlightGroups.count > 50)
            }, showSource: { fileID, pageIndex in
                guard let file = library.allFiles.first(where: { $0.id == fileID }) else { throw ResearchCommandError.outsideSources }
                let read = try DocumentAccessCoordinator.shared.readSnapshot(fileID: file.id,
                    originalURL: library.resolvedURL(for: file), workingCopyURL: file.workingCopyURL)
                guard read.document.page(at: pageIndex) != nil else { throw ResearchCommandError.invalidArguments }
                if fileID == library.file(for: store.selectedPDFURL)?.id {
                    workspace.showsResearch = false; workspace.navigate(pageIndex: pageIndex)
                } else {
                    workspace.reference = .init(document: read.document, pageIndex: pageIndex, bounds: nil, title: file.displayName)
                }
            }, setZoom: { zoom in
                guard store.document != nil else { throw ResearchCommandError.viewUnavailable }
                workspace.navigate(pageIndex: store.currentPageIndex, zoom: zoom)
            }, setWideAI: { workspace.showsResearch = $0 },
            setGroupVisible: { fileID, groupID, visible in
                guard fileID == library.file(for: store.selectedPDFURL)?.id,
                      store.aiHighlightGroups.contains(where: { $0.id == groupID }) else { throw ResearchCommandError.invalidArguments }
                store.setAIHighlightGroupVisible(groupID, isVisible: visible)
            }, restore: { previous in
                guard previous.mainFileID == library.file(for: store.selectedPDFURL)?.id else { throw ResearchCommandError.viewUnavailable }
                workspace.reference = nil
                workspace.showsResearch = previous.wideAI
                let zoom: ResearchZoomCommand = previous.zoomMode == "fitWidth" ? .fitWidth
                    : (previous.zoomMode == "fitPage" ? .fit : .percent(previous.zoomPercent))
                let offset = previous.pageOffsetX.flatMap { x in previous.pageOffsetY.map { PDFPageOffset(x: x, y: $0) } }
                workspace.navigate(pageIndex: previous.pageIndex, zoom: zoom, pageOffset: offset)
                for group in store.aiHighlightGroups {
                    store.setAIHighlightGroupVisible(group.id, isVisible: previous.visibleGroupIDs.contains(group.id))
                }
            }, validateSource: { source in
                guard let file = library.allFiles.first(where: { $0.id == source.fileID }) else { throw ResearchCommandError.outsideSources }
                let read = try DocumentAccessCoordinator.shared.readSnapshot(fileID: file.id,
                    originalURL: library.resolvedURL(for: file), workingCopyURL: file.workingCopyURL)
                guard read.contentVersion == source.fingerprint else { throw DocumentAccessError.sourceChanged }
            }))
    }
}
#endif
