import SwiftUI
import AppKit
import Observation
import PDFKit
import UniformTypeIdentifiers

struct ContentView: View {
    @StateObject private var documentStore: PDFDocumentStore
    @StateObject private var feedbackCenter: OperationFeedbackCenter
    @StateObject private var aiReadingStore: AIReadingStore
    @State private var windowFrameController = WindowFrameController()
    @State private var nativeTabPreviewController = NativeTabGroupPreviewController()
    @ObservedObject private var externalPDFOpenCoordinator = ExternalPDFOpenCoordinator.shared
    @ObservedObject var libraryStore: LibraryStore
    let initialGroupID: UUID?

    @Environment(\.openWindow) private var openWindow
    @State private var activeGroupID: UUID
    @State private var didOpenLaunchArgument = false
    @State private var didApplyInitialGroup = false
    @State private var isShowingNewGroupSheet = false
    @State private var isShowingPageOrganizer = false
    @State private var isLibraryNavigatorVisible = false
    @State private var annotationSidebarState = WindowAnnotationSidebarState()
    @State private var newGroupName = ""
    @State private var librarySidebarWidth: CGFloat = 300
    @State private var librarySidebarDragStartWidth: CGFloat = 300
    @State private var annotationSidebarDragStartWidth: CGFloat = 268
    @State private var latestContentWidth: CGFloat = 984
    @State private var lockedWorkspaceWidth: CGFloat?
    @State private var workspaceLockID = UUID()
    @State private var lockedReaderWorkspaceWidth: CGFloat?
    @State private var readerWorkspaceLockID = UUID()
    @State private var pageJumpText = "1"
    @State private var readingDisplayStyle: PDFReadingDisplayStyle = .continuous
    @State private var isNightMode = false
    @State private var zoomCommandCounter = 0
    @State private var zoomCommand: PDFZoomCommand?
    @State private var zoomScalePercent = 100

    private let librarySidebarRange: ClosedRange<CGFloat> = 240...440
    private let annotationSidebarRange: ClosedRange<CGFloat> = 220...390
    private let centerMinimumWidth: CGFloat = 520
    private let sidebarHandleWidth: CGFloat = 16
    private let minimumWorkspaceWithoutAnnotation: CGFloat = 520

    private var isAnnotationSidebarVisible: Bool {
        get { annotationSidebarState.isVisible }
        nonmutating set { annotationSidebarState.isVisible = newValue }
    }

    private var annotationSidebarWidth: CGFloat {
        get { annotationSidebarState.width }
        nonmutating set { annotationSidebarState.width = newValue }
    }

    init(libraryStore: LibraryStore, initialGroupID: UUID? = nil) {
        let feedbackCenter = OperationFeedbackCenter()
        _feedbackCenter = StateObject(wrappedValue: feedbackCenter)
        _documentStore = StateObject(
            wrappedValue: PDFDocumentStore(feedbackCenter: feedbackCenter)
        )
        _aiReadingStore = StateObject(wrappedValue: AIReadingStore())
        self.libraryStore = libraryStore
        self.initialGroupID = initialGroupID
        _activeGroupID = State(initialValue: initialGroupID ?? libraryStore.initialWindowGroupID)
    }

    var body: some View {
        GeometryReader { proxy in
            let workspaceWidth = workspaceWidth(for: proxy.size.width)

            ZStack(alignment: .bottomTrailing) {
                ZStack(alignment: .leading) {
                    if isLibraryNavigatorVisible {
                        librarySidebar
                    }

                    workspace(availableWidth: workspaceWidth)
                        .frame(width: workspaceWidth, height: proxy.size.height)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)

                    if isLibraryNavigatorVisible {
                        librarySidebarResizeHandle(availableWidth: proxy.size.width)
                            .offset(x: librarySidebarWidth - sidebarHandleWidth / 2)
                            .zIndex(1)
                    }
                }

                OperationFeedbackHUD(feedbackCenter: feedbackCenter)
                    .padding(16)
                    .zIndex(10)
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
            .clipped()
            .onAppear {
                latestContentWidth = proxy.size.width
                constrainSidebarWidths(totalAvailableWidth: proxy.size.width)
            }
            .onChange(of: proxy.size.width) { _, newWidth in
                latestContentWidth = newWidth
                constrainSidebarWidths(totalAvailableWidth: newWidth)
            }
        }
        .background(
            HostingWindowAccessor { window in
                windowFrameController.setWindow(window)
                documentStore.setUndoManager(window?.undoManager)
                nativeTabPreviewController.update(
                    window: window,
                    context: nativeTabPreviewContext,
                    onOpen: openTabPreviewItem
                )
                if let window {
                    annotationSidebarState = WindowAnnotationSidebarRegistry.shared.state(
                        for: window,
                        fallback: annotationSidebarState
                    )
                }
                if isLibraryNavigatorVisible {
                    windowFrameController.expandIfNeeded(
                        by: libraryExpansionWidth,
                        minimumWidth: minimumWindowWidth
                    )
                }
            }
        )
        .frame(minWidth: minimumWindowWidth, minHeight: 680)
        .navigationTitle(documentStore.displayedDocumentTitle)
        .toolbar {
            titleBarToolbar
        }
        .sheet(isPresented: $isShowingNewGroupSheet) {
            NewGroupSheet(groupName: $newGroupName) {
                createGroupFromSheet()
            }
        }
        .sheet(isPresented: $isShowingPageOrganizer) {
            PageOrganizerView(documentStore: documentStore)
        }
        .focusedValue(\.pdfWorkbenchCommandHandlers, commandHandlers)
        .onAppear {
            applyInitialGroupIfNeeded()
            openLaunchArgumentIfNeeded()
            openPendingExternalPDFIfNeeded()
        }
        .onOpenURL { url in
            importURLs([url], destination: .currentWindow)
        }
        .onReceive(externalPDFOpenCoordinator.$pendingOpenRequest) { request in
            guard let request else {
                return
            }

            importURLs(request.urls, destination: .currentWindow)
            externalPDFOpenCoordinator.clear(request)
        }
        .onChange(of: documentStore.currentWorkingCopyURL) { _, newWorkingCopyURL in
            updateCurrentDocumentWorkingCopyURL(newWorkingCopyURL)
        }
        .onChange(of: documentStore.currentPageIndex) { _, _ in
            syncPageJumpText()
        }
        .onChange(of: documentStore.selectedPDFURL) { _, _ in
            syncPageJumpText()
            aiReadingStore.documentDidChange(
                to: documentStore.selectedPDFURL?.libraryComparablePath
            )
        }
        .onDrop(of: [UTType.fileURL], isTargeted: nil) { providers in
            FileDropSupport.loadFileURLs(from: providers) { urls in
                importURLs(urls, destination: .currentWindow)
            }
        }
    }

    private var librarySidebar: some View {
        LibrarySidebarView(
            libraryStore: libraryStore,
            selectedGroupID: activeGroupID,
            selectedURL: documentStore.selectedPDFURL,
            currentWorkingCopyURL: documentStore.currentWorkingCopyURL,
            onSelectGroup: selectGroup,
            onCreateGroup: showNewGroupSheet,
            onOpenGroupInNewWindow: openGroupInNewWindow,
            onOpen: openLibraryItem,
            onDiscardAllChanges: discardAllChanges,
            onImportURLsToGroup: { urls, group in
                importURLs(urls, destination: .group(group.id))
            },
            onImportURLsToCurrentWindow: { urls in
                importURLs(urls, destination: .currentWindow)
            }
        )
        .frame(width: librarySidebarWidth)
    }

    private func librarySidebarResizeHandle(availableWidth: CGFloat) -> some View {
        SidebarResizeHandle(
            width: sidebarHandleWidth,
            onBegin: {
                librarySidebarDragStartWidth = librarySidebarWidth
                lockWorkspaceWidth()
            },
            onDrag: { translation in
                resizeLibrarySidebar(
                    by: translation,
                    availableWidth: availableWidth
                )
            },
            onEnd: {
                librarySidebarDragStartWidth = librarySidebarWidth
                releaseWorkspaceWidthAfterWindowSettles()
            }
        )
    }

    private func workspace(availableWidth: CGFloat) -> some View {
        let readerWidth = readerWorkspaceWidth(for: availableWidth)

        return ZStack(alignment: .leading) {
            readerWorkspace
                .frame(width: readerWidth)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)

            if isAnnotationSidebarVisible {
                ReaderSidebarView(
                    documentStore: documentStore,
                    aiStore: aiReadingStore
                )
                    .frame(width: annotationSidebarWidth)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
            }

            if isAnnotationSidebarVisible {
                annotationResizeHandle(availableWidth: availableWidth)
                    .offset(x: availableWidth - annotationSidebarWidth - sidebarHandleWidth / 2)
                    .zIndex(1)
            }
        }
    }

    private var readerWorkspace: some View {
        documentArea
            .frame(minWidth: centerMinimumWidth, maxWidth: .infinity, maxHeight: .infinity)
    }

    private func annotationResizeHandle(availableWidth: CGFloat) -> some View {
        SidebarResizeHandle(
            width: sidebarHandleWidth,
            onBegin: {
                annotationSidebarDragStartWidth = annotationSidebarWidth
                lockReaderWorkspaceWidth()
            },
            onDrag: { translation in
                resizeAnnotationSidebar(
                    by: translation,
                    availableWidth: availableWidth
                )
            },
            onEnd: {
                annotationSidebarDragStartWidth = annotationSidebarWidth
                releaseReaderWorkspaceWidthAfterWindowSettles()
            }
        )
    }

    @ToolbarContentBuilder
    private var titleBarToolbar: some ToolbarContent {
        if #available(macOS 26.0, *) {
            leadingTitleBarToolbarItems
                .sharedBackgroundVisibility(.hidden)
            trailingTitleBarToolbarItem
                .sharedBackgroundVisibility(.hidden)
        } else {
            leadingTitleBarToolbarItems
            trailingTitleBarToolbarItem
        }
    }

    @ToolbarContentBuilder
    private var leadingTitleBarToolbarItems: some ToolbarContent {
        ToolbarItemGroup(placement: .navigation) {
            FlatToolbarIconControl(
                title: "Library",
                systemImage: "sidebar.left"
            ) {
                toggleLibraryNavigator(trigger: .toolbar)
            }
            .help(isLibraryNavigatorVisible ? "Hide Library Navigator" : "Show Library Navigator")

            FlatToolbarIconControl(
                title: "Open",
                systemImage: "folder"
            ) {
                openPDF(trigger: .toolbar)
            }
            .help("Open PDF")

            FlatToolbarIconControl(
                title: "Free Text",
                systemImage: "text.bubble",
                isEnabled: documentStore.document != nil
            ) {
                documentStore.requestFreeTextNote(trigger: .toolbar)
            }
            .help("Add Free Text Note")

            FlatToolbarIconControl(
                title: "Page Organizer",
                systemImage: "rectangle.stack",
                isEnabled: documentStore.document != nil
            ) {
                isShowingPageOrganizer = true
            }
            .help("Organize Pages")

            FlatToolbarIconControl(
                title: "Delete Page",
                systemImage: "trash",
                isEnabled: documentStore.document != nil
            ) {
                documentStore.deleteCurrentPageFromWorkingCopy(trigger: .toolbar)
            }
            .help("Delete Current Page")
        }
    }

    @ToolbarContentBuilder
    private var trailingTitleBarToolbarItem: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            FlatToolbarIconControl(
                title: "Annotations",
                systemImage: "sidebar.right"
            ) {
                toggleAnnotationSidebar(trigger: .toolbar)
            }
            .help(isAnnotationSidebarVisible ? "Hide Annotations and AI Sidebar" : "Show Annotations and AI Sidebar")
        }
    }

    private var commandHandlers: PDFWorkbenchCommandHandlers {
        PDFWorkbenchCommandHandlers(
            openPDF: {
                openPDF(trigger: .command(shortcut: "Command-O"))
            },
            savePDF: {
                documentStore.savePDF(
                    trigger: .command(shortcut: "Command-S")
                )
            },
            createLibraryGroup: showNewGroupSheet,
            toggleLibraryNavigator: {
                toggleLibraryNavigator(
                    trigger: .command(shortcut: "Command-Option-L")
                )
            },
            toggleAnnotationSidebar: {
                toggleAnnotationSidebar(
                    trigger: .command(shortcut: "Command-Option-R")
                )
            },
            addCurrentDocumentToSelectedGroup: addCurrentDocumentToSelectedGroup,
            removeCurrentDocumentFromSelectedGroup: removeCurrentDocumentFromSelectedGroup,
            addFreeTextNote: {
                documentStore.requestFreeTextNote(trigger: .command(shortcut: nil))
            },
            showPageOrganizer: {
                isShowingPageOrganizer = true
            },
            toggleDogear: {
                documentStore.toggleDogearOnCurrentPage(
                    trigger: .command(shortcut: "D")
                )
            },
            deleteCurrentPage: {
                documentStore.deleteCurrentPageFromWorkingCopy(
                    trigger: .command(shortcut: nil)
                )
            },
            goToPreviousPage: {
                documentStore.goToRelativePage(
                    offset: -1,
                    trigger: .command(shortcut: "Command-Up")
                )
            },
            goToNextPage: {
                documentStore.goToRelativePage(
                    offset: 1,
                    trigger: .command(shortcut: "Command-Down")
                )
            },
            goToFirstPage: {
                documentStore.goToFirstPage(
                    trigger: .command(shortcut: "Command-Option-Up")
                )
            },
            goToLastPage: {
                documentStore.goToLastPage(
                    trigger: .command(shortcut: "Command-Option-Down")
                )
            },
            zoomIn: {
                runZoomCommand(
                    .zoomIn,
                    trigger: .command(shortcut: "Command-Plus")
                )
            },
            zoomOut: {
                runZoomCommand(
                    .zoomOut,
                    trigger: .command(shortcut: "Command-Minus")
                )
            },
            actualSize: {
                runZoomCommand(
                    .actualSize,
                    trigger: .command(shortcut: "Command-0")
                )
            },
            fitWidth: {
                runZoomCommand(
                    .fitWidth,
                    trigger: .command(shortcut: "Command-2")
                )
            },
            fitPage: {
                runZoomCommand(
                    .fitPage,
                    trigger: .command(shortcut: "Command-1")
                )
            },
            setDisplayStyle: { style in
                setReadingDisplayStyle(style, trigger: .command(shortcut: nil))
            },
            exportAnnotatedCopy: {
                documentStore.exportAnnotatedCopy(trigger: .command(shortcut: nil))
            },
            exportAnnotationsMarkdown: {
                documentStore.exportAnnotationsMarkdown(trigger: .command(shortcut: nil))
            },
            exportKeywordOutline: {
                documentStore.exportFallbackKeywordOutline(trigger: .command(shortcut: nil))
            },
            isLibraryNavigatorVisible: isLibraryNavigatorVisible,
            isAnnotationSidebarVisible: isAnnotationSidebarVisible,
            canUseDocumentCommands: documentStore.document != nil,
            canAddCurrentDocumentToSelectedGroup: canAddCurrentDocumentToSelectedGroup,
            canRemoveCurrentDocumentFromSelectedGroup: canRemoveCurrentDocumentFromSelectedGroup,
            canGoToPreviousPage: canGoToPreviousPage,
            canGoToNextPage: canGoToNextPage,
            canDeleteCurrentPage: documentStore.canDeleteCurrentPage
        )
    }

    @ViewBuilder
    private var documentArea: some View {
        if let document = documentStore.document {
            VStack(spacing: 0) {
                PDFKitView(
                    document: document,
                    selectedAnnotation: documentStore.selectedAnnotation,
                    selectedSearchResult: documentStore.selectedDocumentSearchResult,
                    targetPageIndex: documentStore.currentPageIndex,
                    displayStyle: readingDisplayStyle,
                    zoomCommand: zoomCommand,
                    outlineNavigationRequest: documentStore.outlineNavigationRequest,
                    outlineEntries: documentStore.outlineEntries,
                    dogears: documentStore.dogears,
                    isLoadingOutline: documentStore.isLoadingOutline,
                    isNightMode: isNightMode,
                    freeTextRequestID: documentStore.freeTextRequestID,
                    onSelectOutlineEntry: documentStore.navigate,
                    onSelectDogear: documentStore.navigate,
                    onToggleDogear: {
                        documentStore.toggleDogearOnCurrentPage(
                            trigger: .keyboard(shortcut: "D")
                        )
                    },
                    onToggleDogearAtPage: { pageIndex in
                        documentStore.toggleDogear(onPage: pageIndex, trigger: .pointer)
                    },
                    onHighlightCreated: {
                        documentStore.markAnnotationsChanged(
                            message: "Highlight added. Saving working copy.",
                            action: "Add Highlight",
                            trigger: .keyboard(shortcut: "H")
                        )
                    },
                    onHighlightRemoved: { trigger in
                        documentStore.markAnnotationsChanged(
                            message: "Highlight removed. Saving working copy.",
                            action: "Remove Highlight",
                            trigger: trigger
                        )
                    },
                    onAnnotationChanged: {
                        documentStore.markAnnotationsChanged(
                            message: "Annotation changed. Saving working copy.",
                            action: "Move Annotation",
                            trigger: .pointer
                        )
                    },
                    onUndoableAnnotationMutation: { actionName in
                        documentStore.markAnnotationsChanged(
                            message: "Undo/redo applied. Saving working copy.",
                            action: actionName,
                            trigger: .command(shortcut: "Command-Z")
                        )
                    },
                    onFreeTextShortcut: {
                        documentStore.requestFreeTextNote(
                            trigger: .keyboard(shortcut: "T")
                        )
                    },
                    onShortcutActivated: { action, shortcut in
                        postFeedback(
                            action.feedbackMessage,
                            action: action.feedbackAction,
                            trigger: .keyboard(shortcut: shortcut)
                        )
                    },
                    onPageChanged: { pageIndex in
                        documentStore.recordCurrentPage(pageIndex)
                        if let selectedPDFURL = documentStore.selectedPDFURL {
                            libraryStore.updateLastPage(for: selectedPDFURL, pageIndex: pageIndex)
                        }
                    },
                    onScaleChanged: { scaleFactor in
                        updateZoomScalePercent(scaleFactor)
                    },
                    onSelectionChanged: { selection in
                        documentStore.recordTextSelection(selection)
                    }
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                Divider()

                readerControlStrip
            }
        } else {
            ContentUnavailableView(
                "No PDF Open",
                systemImage: "doc.richtext",
                description: Text("Choose a PDF file to display it here.")
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var readerControlStrip: some View {
        ViewThatFits(in: .horizontal) {
            readerControls(isCompact: false)
            readerControls(isCompact: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private func readerControls(isCompact: Bool) -> some View {
        HStack(spacing: isCompact ? 6 : 10) {
            Button {
                documentStore.goToFirstPage(trigger: .pointer)
            } label: {
                Image(systemName: "backward.end")
            }
            .disabled(!canGoToPreviousPage)
            .help("First page")

            Button {
                documentStore.goToRelativePage(offset: -1, trigger: .pointer)
            } label: {
                Image(systemName: "chevron.up")
            }
            .disabled(!canGoToPreviousPage)
            .help("Previous page")

            TextField("Page", text: $pageJumpText)
                .textFieldStyle(.roundedBorder)
                .multilineTextAlignment(.trailing)
                .frame(width: isCompact ? 48 : 56)
                .onSubmit {
                    jumpToTypedPage()
                }
                .help("Page number")

            Text("/ \(documentStore.pageCount)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: isCompact ? 40 : 52, alignment: .leading)

            Button {
                documentStore.goToRelativePage(offset: 1, trigger: .pointer)
            } label: {
                Image(systemName: "chevron.down")
            }
            .disabled(!canGoToNextPage)
            .help("Next page")

            Button {
                documentStore.goToLastPage(trigger: .pointer)
            } label: {
                Image(systemName: "forward.end")
            }
            .disabled(!canGoToNextPage)
            .help("Last page")

            Divider()
                .frame(height: 20)

            Button {
                runZoomCommand(.zoomOut, trigger: .pointer)
            } label: {
                Image(systemName: "minus.magnifyingglass")
            }
            .help("Zoom out")

            Text("\(zoomScalePercent)%")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: isCompact ? 42 : 48)

            Button {
                runZoomCommand(.zoomIn, trigger: .pointer)
            } label: {
                Image(systemName: "plus.magnifyingglass")
            }
            .help("Zoom in")

            Menu {
                Button("Actual Size") {
                    runZoomCommand(.actualSize, trigger: .pointer)
                }

                Button("Fit Width") {
                    runZoomCommand(.fitWidth, trigger: .pointer)
                }

                Button("Fit Page") {
                    runZoomCommand(.fitPage, trigger: .pointer)
                }
            } label: {
                Image(systemName: "arrow.up.left.and.arrow.down.right")
            }
            .menuStyle(.borderlessButton)
            .help("Zoom presets")

            if isCompact {
                Menu {
                    ForEach(PDFReadingDisplayStyle.allCases) { style in
                        Button {
                            setReadingDisplayStyle(style, trigger: .pointer)
                        } label: {
                            Label(style.title, systemImage: style.systemImage)
                        }
                    }
                } label: {
                    Image(systemName: readingDisplayStyle.systemImage)
                }
                .menuStyle(.borderlessButton)
                .help("Reading layout")
            } else {
                Picker(
                    "Display",
                    selection: Binding(
                        get: { readingDisplayStyle },
                        set: { setReadingDisplayStyle($0, trigger: .pointer) }
                    )
                ) {
                    ForEach(PDFReadingDisplayStyle.allCases) { style in
                        Label(style.title, systemImage: style.systemImage)
                            .tag(style)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 260)
                .help("Reading layout")
            }

            Button {
                withAnimation(.easeInOut(duration: 0.18)) {
                    isNightMode.toggle()
                }
                postFeedback(
                    isNightMode ? "Night mode enabled." : "Night mode disabled.",
                    action: "Toggle Night Mode",
                    trigger: .pointer
                )
            } label: {
                Image(systemName: isNightMode ? "sun.max.fill" : "moon.fill")
            }
            .help(isNightMode ? "Use light PDF display" : "Use night PDF display")

            Spacer(minLength: 0)
        }
        .fixedSize(horizontal: true, vertical: false)
    }

    private func resizeLibrarySidebar(by translation: CGFloat, availableWidth: CGFloat) {
        let maximumWidth = maximumLibrarySidebarWidth(availableWidth: availableWidth)
        let previousWidth = librarySidebarWidth
        librarySidebarWidth = clamped(
            librarySidebarDragStartWidth + translation,
            to: librarySidebarRange.lowerBound...maximumWidth
        )
        windowFrameController.resizeExpandedWindow(by: librarySidebarWidth - previousWidth)
    }

    private func resizeAnnotationSidebar(by translation: CGFloat, availableWidth: CGFloat) {
        let maximumWidth = maximumAnnotationSidebarWidth(availableWidth: availableWidth)
        let previousWidth = annotationSidebarWidth
        annotationSidebarWidth = clamped(
            annotationSidebarDragStartWidth - translation,
            to: annotationSidebarRange.lowerBound...maximumWidth
        )
        windowFrameController.resizeAnnotationExpandedWindow(
            by: annotationSidebarWidth - previousWidth
        )
    }

    private func constrainSidebarWidths(totalAvailableWidth: CGFloat) {
        let leftSidebarAvailableWidth = totalAvailableWidth
            + (isLibraryNavigatorVisible ? 0 : libraryExpansionWidth)
        librarySidebarWidth = clamped(
            librarySidebarWidth,
            to: librarySidebarRange.lowerBound...maximumLibrarySidebarWidth(
                availableWidth: leftSidebarAvailableWidth
            )
        )
        let workspaceAvailableWidth = workspaceWidth(for: totalAvailableWidth)
        annotationSidebarWidth = clamped(
            annotationSidebarWidth,
            to: annotationSidebarRange.lowerBound...maximumAnnotationSidebarWidth(availableWidth: workspaceAvailableWidth)
        )
        librarySidebarDragStartWidth = librarySidebarWidth
        annotationSidebarDragStartWidth = annotationSidebarWidth
    }

    private func maximumLibrarySidebarWidth(availableWidth: CGFloat) -> CGFloat {
        max(
            librarySidebarRange.lowerBound,
            min(
                librarySidebarRange.upperBound,
                availableWidth
                    - visibleAnnotationSidebarWidth
                    - centerMinimumWidth
            )
        )
    }

    private func maximumAnnotationSidebarWidth(availableWidth: CGFloat) -> CGFloat {
        max(
            annotationSidebarRange.lowerBound,
            min(
                annotationSidebarRange.upperBound,
                availableWidth - centerMinimumWidth
            )
        )
    }

    private var visibleLibraryNavigatorWidth: CGFloat {
        isLibraryNavigatorVisible ? libraryExpansionWidth : 0
    }

    private var libraryExpansionWidth: CGFloat {
        librarySidebarWidth
    }

    private var visibleAnnotationSidebarWidth: CGFloat {
        isAnnotationSidebarVisible ? annotationSidebarWidth : 0
    }

    private var annotationExpansionWidth: CGFloat {
        annotationSidebarWidth
    }

    private var minimumWindowWidth: CGFloat {
        minimumWorkspaceWithoutAnnotation
            + visibleAnnotationSidebarWidth
            + visibleLibraryNavigatorWidth
    }

    private func minimumWindowWidth(
        libraryVisible: Bool,
        annotationVisible: Bool
    ) -> CGFloat {
        minimumWorkspaceWithoutAnnotation
            + (annotationVisible ? annotationExpansionWidth : 0)
            + (libraryVisible ? libraryExpansionWidth : 0)
    }

    private func workspaceWidth(for totalAvailableWidth: CGFloat) -> CGFloat {
        if let lockedWorkspaceWidth {
            return min(lockedWorkspaceWidth, totalAvailableWidth)
        }

        return totalAvailableWidth - visibleLibraryNavigatorWidth
    }

    private func readerWorkspaceWidth(for availableWidth: CGFloat) -> CGFloat {
        if let lockedReaderWorkspaceWidth {
            return min(lockedReaderWorkspaceWidth, availableWidth)
        }

        return availableWidth - visibleAnnotationSidebarWidth
    }

    private func clamped(_ value: CGFloat, to range: ClosedRange<CGFloat>) -> CGFloat {
        min(max(value, range.lowerBound), range.upperBound)
    }

    private func toggleLibraryNavigator(trigger: FeedbackTrigger? = nil) {
        lockWorkspaceWidth()

        if isLibraryNavigatorVisible {
            withoutViewAnimation {
                isLibraryNavigatorVisible = false
            }
            windowFrameController.setLibraryNavigatorVisible(
                false,
                expansionWidth: libraryExpansionWidth,
                minimumWidth: minimumWindowWidth(
                    libraryVisible: false,
                    annotationVisible: isAnnotationSidebarVisible
                )
            )
        } else {
            windowFrameController.setLibraryNavigatorVisible(
                true,
                expansionWidth: libraryExpansionWidth,
                minimumWidth: minimumWindowWidth(
                    libraryVisible: true,
                    annotationVisible: isAnnotationSidebarVisible
                )
            )
            withoutViewAnimation {
                isLibraryNavigatorVisible = true
            }
        }

        postFeedback(
            isLibraryNavigatorVisible ? "Library shown." : "Library hidden.",
            action: "Toggle Library",
            trigger: trigger
        )
        releaseWorkspaceWidthAfterWindowSettles()
    }

    private func toggleAnnotationSidebar(trigger: FeedbackTrigger? = nil) {
        lockReaderWorkspaceWidth()

        if isAnnotationSidebarVisible {
            withoutViewAnimation {
                isAnnotationSidebarVisible = false
            }
            windowFrameController.setAnnotationSidebarVisible(
                false,
                expansionWidth: annotationExpansionWidth,
                minimumWidth: minimumWindowWidth(
                    libraryVisible: isLibraryNavigatorVisible,
                    annotationVisible: false
                )
            )
        } else {
            windowFrameController.setAnnotationSidebarVisible(
                true,
                expansionWidth: annotationExpansionWidth,
                minimumWidth: minimumWindowWidth(
                    libraryVisible: isLibraryNavigatorVisible,
                    annotationVisible: true
                )
            )
            withoutViewAnimation {
                isAnnotationSidebarVisible = true
            }
        }

        postFeedback(
            isAnnotationSidebarVisible
                ? "Annotation sidebar shown."
                : "Annotation sidebar hidden.",
            action: "Toggle Annotation Sidebar",
            trigger: trigger
        )
        releaseReaderWorkspaceWidthAfterWindowSettles()
    }

    private func lockWorkspaceWidth() {
        guard !windowFrameController.isFullScreen else {
            lockedWorkspaceWidth = nil
            workspaceLockID = UUID()
            return
        }

        lockedWorkspaceWidth = workspaceWidth(for: latestContentWidth)
        workspaceLockID = UUID()
    }

    private func lockReaderWorkspaceWidth() {
        guard !windowFrameController.isFullScreen else {
            lockedReaderWorkspaceWidth = nil
            readerWorkspaceLockID = UUID()
            return
        }

        let availableWidth = workspaceWidth(for: latestContentWidth)
        lockedReaderWorkspaceWidth = readerWorkspaceWidth(for: availableWidth)
        readerWorkspaceLockID = UUID()
    }

    private func releaseWorkspaceWidthAfterWindowSettles() {
        let lockID = workspaceLockID

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.28) {
            guard workspaceLockID == lockID else {
                return
            }

            lockedWorkspaceWidth = nil
        }
    }

    private func releaseReaderWorkspaceWidthAfterWindowSettles() {
        let lockID = readerWorkspaceLockID

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.28) {
            guard readerWorkspaceLockID == lockID else {
                return
            }

            lockedReaderWorkspaceWidth = nil
        }
    }

    private func withoutViewAnimation(_ updates: () -> Void) {
        var transaction = Transaction()
        transaction.disablesAnimations = true

        withTransaction(transaction) {
            updates()
        }
    }

    private var canGoToPreviousPage: Bool {
        documentStore.currentPageNumber > 1
    }

    private var canGoToNextPage: Bool {
        documentStore.currentPageNumber > 0
            && documentStore.currentPageNumber < documentStore.pageCount
    }

    private func jumpToTypedPage() {
        let trimmedPage = pageJumpText.trimmingCharacters(in: .whitespacesAndNewlines)

        guard let pageNumber = Int(trimmedPage) else {
            syncPageJumpText()
            postFeedback(
                "Enter a page number from 1 to \(max(1, documentStore.pageCount)).",
                kind: .warning,
                action: "Go to Page",
                trigger: .keyboard(shortcut: "Return")
            )
            return
        }

        documentStore.goToPageNumber(
            pageNumber,
            trigger: .keyboard(shortcut: "Return")
        )
        syncPageJumpText()
    }

    private func syncPageJumpText() {
        pageJumpText = documentStore.currentPageNumber > 0
            ? "\(documentStore.currentPageNumber)"
            : "1"
    }

    private func runZoomCommand(
        _ action: PDFZoomAction,
        trigger: FeedbackTrigger? = nil
    ) {
        guard documentStore.document != nil else {
            return
        }

        zoomCommandCounter += 1
        zoomCommand = PDFZoomCommand(id: zoomCommandCounter, action: action)
        postFeedback(
            action.feedbackMessage,
            action: action.feedbackAction,
            trigger: trigger
        )
    }

    private func setReadingDisplayStyle(
        _ style: PDFReadingDisplayStyle,
        trigger: FeedbackTrigger?
    ) {
        readingDisplayStyle = style
        postFeedback(
            "Reading layout: \(style.title).",
            action: "Change Reading Layout",
            trigger: trigger
        )
    }

    private func updateZoomScalePercent(_ scaleFactor: CGFloat) {
        guard scaleFactor.isFinite, scaleFactor > 0 else {
            return
        }

        zoomScalePercent = Int((scaleFactor * 100).rounded())
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

    private func openPDF(trigger: FeedbackTrigger? = nil) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.pdf]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.prompt = "Import"

        guard panel.runModal() == .OK else {
            return
        }

        let selectedURLs = panel.urls
        let folderURLs = selectedURLs.filter(\.isDirectoryURL)
        let pdfURLs = selectedURLs.filter(\.isPDFFileURL)
        let currentWindowGroupID = activeGroupID

        importFolders(folderURLs)

        if pdfURLs.count == 1, folderURLs.isEmpty, let url = pdfURLs.first {
            openPDFInSelectedGroup(url, trigger: trigger)
        } else {
            importPDFsToCurrentWindow(pdfURLs, in: currentWindowGroupID)
        }
    }

    private func openPDFInSelectedGroup(
        _ url: URL,
        trigger: FeedbackTrigger? = nil
    ) {
        guard url.isPDFFileURL else {
            postFeedback(
                "Only PDF files can be opened.",
                kind: .warning,
                action: "Open PDF",
                trigger: trigger
            )
            return
        }

        let existingItem = libraryStore.file(for: url)
        guard documentStore.openPDF(
            from: url,
            workingCopyURL: existingItem?.workingCopyURL,
            trigger: trigger
        ) else {
            return
        }

        let item = libraryStore.upsertOpenedURL(url, groupID: activeGroupID)
        documentStore.bindLibraryFile(item.id)
        libraryStore.updateWorkingCopyURL(documentStore.currentWorkingCopyURL, for: item)
    }

    private func importURLs(_ urls: [URL], destination: ImportDestination) {
        let normalizedURLs = uniqueFileURLs(urls)
        let folderURLs = normalizedURLs.filter(\.isDirectoryURL)
        let pdfURLs = normalizedURLs.filter(\.isPDFFileURL)
        let currentWindowGroupID = activeGroupID

        importFolders(folderURLs)

        switch destination {
        case .currentWindow:
            importPDFsToCurrentWindow(pdfURLs, in: currentWindowGroupID)
        case .group(let groupID):
            importPDFs(pdfURLs, toGroup: groupID)
        }

        if folderURLs.isEmpty, pdfURLs.isEmpty, !urls.isEmpty {
            postFeedback(
                "No PDF files were found in the dropped items.",
                kind: .warning,
                action: "Import PDFs",
                trigger: .pointer
            )
        }
    }

    private func importFolders(_ folderURLs: [URL]) {
        for folderURL in folderURLs {
            let didAccess = folderURL.startAccessingSecurityScopedResource()
            defer {
                if didAccess {
                    folderURL.stopAccessingSecurityScopedResource()
                }
            }

            let pdfURLs = PDFImportScanner.pdfURLs(in: folderURL)
            guard let group = libraryStore.createImportedFolderGroup(
                named: folderURL.lastPathComponent
            ) else {
                continue
            }

            for url in pdfURLs {
                let item = libraryStore.upsertOpenedURL(url, groupID: nil)
                libraryStore.addFile(item.id, to: group.id)
                libraryStore.recordOpenedFile(item.id, in: group.id)
            }

            activeGroupID = group.id
            if let firstItem = libraryStore.filesForWindow(in: group.id).first {
                openLibraryItem(firstItem)
            }

            postFeedback(
                pdfURLs.isEmpty
                    ? "Created group \(group.name). No PDFs were found in the folder."
                    : "Imported \(pdfURLs.count) PDF\(pdfURLs.count == 1 ? "" : "s") into group \(group.name).",
                kind: pdfURLs.isEmpty ? .warning : .success,
                action: "Import Folder",
                trigger: .pointer
            )
        }
    }

    private func importPDFsToCurrentWindow(_ urls: [URL], in groupID: UUID) {
        guard !urls.isEmpty else {
            return
        }

        var importedItems: [LibraryItem] = []
        for url in urls {
            let item = libraryStore.upsertOpenedURL(url, groupID: nil)
            libraryStore.recordOpenedFile(item.id, in: groupID)
            importedItems.append(item)
        }

        if let firstItem = importedItems.first {
            activeGroupID = groupID
            openLibraryItem(firstItem)
        }

        postFeedback(
            "Opened \(importedItems.count) PDF\(importedItems.count == 1 ? "" : "s") in \(libraryStore.group(withID: groupID)?.name ?? "this Group").",
            kind: .success,
            action: "Open PDFs"
        )
    }

    private func importPDFs(_ urls: [URL], toGroup groupID: UUID) {
        guard let group = libraryStore.group(withID: groupID), !urls.isEmpty else {
            return
        }

        for url in urls {
            let item = libraryStore.upsertOpenedURL(url, groupID: nil)
            if group.id == LibraryGroup.ungroupedID {
                libraryStore.recordOpenedFile(item.id, in: group.id)
            } else {
                libraryStore.addFile(item.id, to: group.id)
            }
        }

        postFeedback(
            "Imported \(urls.count) PDF\(urls.count == 1 ? "" : "s") into \(group.name).",
            kind: .success,
            action: "Import PDFs",
            trigger: .pointer
        )
    }

    private func uniqueFileURLs(_ urls: [URL]) -> [URL] {
        var seenPaths = Set<String>()
        return urls.filter { url in
            seenPaths.insert(url.libraryComparablePath).inserted
        }
    }

    private func openLibraryItem(_ item: LibraryItem) {
        openLibraryItem(item, inGroupID: activeGroupID)
    }

    private func openLibraryItem(_ item: LibraryItem, in group: LibraryGroup) {
        activeGroupID = group.id
        openLibraryItem(item, inGroupID: group.id)
    }

    private func openLibraryItem(_ item: LibraryItem, inGroupID groupID: UUID) {
        let url = libraryStore.resolvedURL(for: item)
        if documentStore.openPDF(
            from: url,
            workingCopyURL: item.workingCopyURL,
            initialPageIndex: item.lastPageIndex,
            trigger: .pointer
        ) {
            documentStore.bindLibraryFile(item.id)
            libraryStore.refreshResolvedURL(url, for: item)
            libraryStore.updateWorkingCopyURL(documentStore.currentWorkingCopyURL, for: item)
            libraryStore.recordOpenedFile(item.id, in: groupID)
            return
        }

        libraryStore.markUnavailable(item)
        postFeedback(
            "Library item is unavailable: \(item.displayName).",
            kind: .error,
            action: "Open Library Item",
            trigger: .pointer
        )
    }

    private var nativeTabPreviewContext: NativeTabPreviewContext {
        let items = libraryStore.filesForWindow(in: activeGroupID)
        let duplicateNames = Set(
            Dictionary(grouping: items, by: { $0.displayName.lowercased() })
                .filter { $0.value.count > 1 }
                .keys
        )

        return NativeTabPreviewContext(
            documentTitle: documentStore.document == nil
                ? "No PDF Open"
                : documentStore.selectedDocumentName,
            groupName: libraryStore.group(withID: activeGroupID)?.name ?? "Ungrouped",
            pageDescription: documentStore.pageCount > 0
                ? "Page \(documentStore.currentPageNumber) of \(documentStore.pageCount)"
                : nil,
            hasWorkingCopy: documentStore.currentWorkingCopyURL != nil,
            items: items.map { item in
                let isTemporary = libraryStore.isTemporaryFile(item, in: activeGroupID)
                let isUnavailable = item.isUnavailable
                    || (item.bookmarkData == nil
                        && !FileManager.default.fileExists(atPath: item.path))
                let detail: String?

                if duplicateNames.contains(item.displayName.lowercased()) {
                    detail = item.url.deletingLastPathComponent().path
                } else if isUnavailable {
                    detail = "Unavailable"
                } else if isTemporary {
                    detail = "Temporary in this window"
                } else {
                    detail = nil
                }

                return NativeTabPreviewItem(
                    id: item.id,
                    displayName: item.displayName,
                    detail: detail,
                    path: item.path,
                    isSelected: documentStore.selectedPDFURL?.libraryComparablePath == item.path,
                    isTemporary: isTemporary,
                    isUnavailable: isUnavailable,
                    hasWorkingCopy: item.workingCopyURL != nil
                )
            }
        )
    }

    private func openTabPreviewItem(_ fileID: UUID) {
        guard let item = libraryStore.state.files.first(where: { $0.id == fileID }) else {
            return
        }

        openLibraryItem(item)
    }

    private func discardAllChanges(for item: LibraryItem) {
        guard let workingCopyURL = workingCopyURL(for: item) else {
            postFeedback(
                "This document has no working-copy changes to discard.",
                kind: .warning,
                action: "Discard Changes",
                trigger: .pointer
            )
            return
        }

        let alert = NSAlert()
        alert.messageText = "Discard all changes?"
        alert.informativeText = "This deletes the app-managed working copy for \(item.displayName) and reopens the original PDF. The original file will not be changed."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Discard Changes")
        alert.addButton(withTitle: "Save As...")
        alert.addButton(withTitle: "Cancel")

        switch alert.runModal() {
        case .alertFirstButtonReturn:
            discardWorkingCopy(workingCopyURL, for: item)
        case .alertSecondButtonReturn:
            exportWorkingCopy(for: item)
        default:
            postFeedback(
                "Discard canceled.",
                action: "Discard Changes",
                trigger: .pointer
            )
        }
    }

    private func workingCopyURL(for item: LibraryItem) -> URL? {
        if documentStore.selectedPDFURL?.libraryComparablePath == item.path {
            return documentStore.currentWorkingCopyURL ?? item.workingCopyURL
        }

        return item.workingCopyURL
    }

    private func discardWorkingCopy(_ workingCopyURL: URL, for item: LibraryItem) {
        PDFSaveQueue.shared.waitUntilDrained()

        let isCurrentDocument = documentStore.selectedPDFURL?.libraryComparablePath == item.path

        if isCurrentDocument {
            guard documentStore.discardCurrentWorkingCopyAndReopenOriginal() else {
                return
            }
            documentStore.bindLibraryFile(item.id)
        } else if FileManager.default.fileExists(atPath: workingCopyURL.path) {
            do {
                try FileManager.default.removeItem(at: workingCopyURL)
            } catch {
                postFeedback(
                    "Could not delete the working copy. Original PDF was not changed.",
                    kind: .error,
                    action: "Discard Changes",
                    trigger: .pointer
                )
                return
            }
        }

        libraryStore.updateWorkingCopyURL(nil, for: item)
        postFeedback(
            "Discarded working-copy changes for \(item.displayName).",
            kind: .success,
            action: "Discard Changes",
            trigger: .pointer
        )
    }

    private func exportWorkingCopy(for item: LibraryItem) {
        guard let sourceURL = workingCopyURL(for: item) else {
            postFeedback(
                "No working copy is available to save.",
                kind: .warning,
                action: "Save Working Copy",
                trigger: .pointer
            )
            return
        }

        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = suggestedDiscardSaveAsName(for: item)

        guard panel.runModal() == .OK, let destinationURL = panel.url else {
            postFeedback(
                "Save As canceled.",
                action: "Save Working Copy",
                trigger: .pointer
            )
            return
        }

        if destinationURL.libraryComparablePath == item.path {
            postFeedback(
                "Choose a different file name. The original PDF is not overwritten by default.",
                kind: .warning,
                action: "Save Working Copy",
                trigger: .pointer
            )
            return
        }

        do {
            let data: Data
            if documentStore.selectedPDFURL?.libraryComparablePath == item.path,
               let document = documentStore.document,
               let currentData = document.dataRepresentationWithFreeTextAnnotationsDisplayed() {
                data = currentData
            } else {
                data = try Data(contentsOf: sourceURL)
            }

            try data.write(to: destinationURL, options: [.atomic])
            postFeedback(
                "Saved copy to \(destinationURL.lastPathComponent). Working copy was kept.",
                kind: .success,
                action: "Save Working Copy",
                trigger: .pointer
            )
        } catch {
            postFeedback(
                "Save As failed. Working copy was kept.",
                kind: .error,
                action: "Save Working Copy",
                trigger: .pointer
            )
        }
    }

    private func suggestedDiscardSaveAsName(for item: LibraryItem) -> String {
        let baseName = item.url.deletingPathExtension().lastPathComponent
        return "\(baseName)-working-copy.pdf"
    }

    private func openLaunchArgumentIfNeeded() {
        guard !didOpenLaunchArgument else {
            return
        }

        didOpenLaunchArgument = true

        guard let path = ProcessInfo.processInfo.arguments.dropFirst().first,
              path.lowercased().hasSuffix(".pdf")
        else {
            return
        }

        let url = URL(fileURLWithPath: path)
        let existingItem = libraryStore.file(for: url)
        if documentStore.openPDF(
            from: url,
            workingCopyURL: existingItem?.workingCopyURL,
            trigger: .system
        ) {
            let item = libraryStore.upsertOpenedURL(url, refreshBookmark: false, groupID: nil)
            documentStore.bindLibraryFile(item.id)
            libraryStore.updateWorkingCopyURL(documentStore.currentWorkingCopyURL, for: item)
        }
    }

    private func openPendingExternalPDFIfNeeded() {
        guard let request = externalPDFOpenCoordinator.pendingOpenRequest else {
            return
        }

        importURLs(request.urls, destination: .currentWindow)
        externalPDFOpenCoordinator.clear(request)
    }

    private func updateCurrentDocumentWorkingCopyURL(_ workingCopyURL: URL?) {
        guard let file = libraryStore.file(for: documentStore.selectedPDFURL) else {
            return
        }

        libraryStore.updateWorkingCopyURL(workingCopyURL, for: file)
    }

    private func applyInitialGroupIfNeeded() {
        guard !didApplyInitialGroup else {
            return
        }

        didApplyInitialGroup = true

        let targetGroupID = initialGroupID ?? activeGroupID

        guard libraryStore.group(withID: targetGroupID) != nil
        else {
            return
        }

        activeGroupID = targetGroupID

        if let session = libraryStore.openSession(for: targetGroupID),
           let selectedFileID = session.selectedFileID,
           let file = libraryStore.state.files.first(where: { $0.id == selectedFileID }) {
            openLibraryItem(file)
        }
    }

    private var canAddCurrentDocumentToSelectedGroup: Bool {
        guard let file = libraryStore.file(for: documentStore.selectedPDFURL),
              activeGroupID != LibraryGroup.ungroupedID,
              let group = libraryStore.group(withID: activeGroupID)
        else {
            return false
        }

        return !libraryStore.isFile(file, in: group)
    }

    private var canRemoveCurrentDocumentFromSelectedGroup: Bool {
        guard let file = libraryStore.file(for: documentStore.selectedPDFURL),
              activeGroupID != LibraryGroup.ungroupedID,
              let group = libraryStore.group(withID: activeGroupID)
        else {
            return false
        }

        return libraryStore.isFile(file, in: group)
    }

    private func addCurrentDocumentToSelectedGroup() {
        guard let file = libraryStore.file(for: documentStore.selectedPDFURL),
              let group = libraryStore.group(withID: activeGroupID)
        else {
            return
        }

        libraryStore.addFile(file, to: group)
    }

    private func removeCurrentDocumentFromSelectedGroup() {
        guard let file = libraryStore.file(for: documentStore.selectedPDFURL),
              let group = libraryStore.group(withID: activeGroupID)
        else {
            return
        }

        libraryStore.removeFile(file, from: group)
    }

    private func showNewGroupSheet() {
        newGroupName = ""
        isShowingNewGroupSheet = true
    }

    private func createGroupFromSheet() {
        if let group = libraryStore.createGroup(named: newGroupName) {
            activeGroupID = group.id
        }
        isShowingNewGroupSheet = false
    }

    private func selectGroup(_ group: LibraryGroup) {
        activeGroupID = group.id
    }

    private func openGroupInNewWindow(_ group: LibraryGroup) {
        guard !group.isSystemGroup else {
            return
        }

        openWindow(value: GroupWindowPayload(groupID: group.id))
    }
}

private struct FlatToolbarIconControl: View {
    let title: LocalizedStringKey
    let systemImage: String
    var isEnabled = true
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Image(systemName: systemImage)
            .font(.system(size: 14, weight: .medium))
            .symbolRenderingMode(.monochrome)
            .foregroundStyle(foregroundColor)
            .frame(width: 28, height: 28)
            .contentShape(Rectangle())
            .allowsHitTesting(isEnabled)
            .onTapGesture(perform: action)
            .onHover { isHovering = isEnabled && $0 }
            .accessibilityElement()
            .accessibilityLabel(Text(title))
            .accessibilityAddTraits(.isButton)
            .accessibilityAction {
                guard isEnabled else { return }
                action()
            }
    }

    private var foregroundColor: Color {
        guard isEnabled else {
            return .secondary.opacity(0.45)
        }

        return isHovering ? .primary : .secondary
    }
}

private struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        ContentView(libraryStore: LibraryStore())
    }
}

private enum ImportDestination {
    case currentWindow
    case group(UUID)
}

private extension PDFZoomAction {
    var feedbackAction: String {
        switch self {
        case .zoomIn:
            return "Zoom In"
        case .zoomOut:
            return "Zoom Out"
        case .actualSize:
            return "Actual Size"
        case .fitWidth:
            return "Fit Width"
        case .fitPage:
            return "Fit Page"
        }
    }

    var feedbackMessage: String {
        "\(feedbackAction)."
    }
}

private extension PDFReadingShortcutAction {
    var feedbackAction: String {
        switch self {
        case .highlight:
            return "Add Highlight"
        case .note:
            return "Add Free Text Note"
        case .dogear:
            return "Toggle Dog-ear"
        case .pageUp:
            return "Previous Page"
        case .pageDown:
            return "Next Page"
        }
    }

    var feedbackMessage: String {
        "\(feedbackAction)."
    }
}

@MainActor
@Observable
private final class WindowAnnotationSidebarState {
    var isVisible: Bool
    var width: CGFloat

    init(isVisible: Bool = true, width: CGFloat = 268) {
        self.isVisible = isVisible
        self.width = width
    }
}

@MainActor
private final class WindowAnnotationSidebarRegistry {
    static let shared = WindowAnnotationSidebarRegistry()

    private let statesByWindow = NSMapTable<NSWindow, WindowAnnotationSidebarState>.weakToStrongObjects()

    private init() {}

    func state(
        for window: NSWindow,
        fallback: WindowAnnotationSidebarState
    ) -> WindowAnnotationSidebarState {
        let tabbedWindows = window.tabbedWindows ?? [window]

        if let siblingState = tabbedWindows.lazy
            .filter({ $0 !== window })
            .compactMap({ self.statesByWindow.object(forKey: $0) })
            .first {
            associate(siblingState, with: tabbedWindows)
            return siblingState
        }

        if let existingState = statesByWindow.object(forKey: window) {
            associate(existingState, with: tabbedWindows)
            return existingState
        }

        associate(fallback, with: tabbedWindows)
        return fallback
    }

    private func associate(
        _ state: WindowAnnotationSidebarState,
        with windows: [NSWindow]
    ) {
        for window in windows {
            statesByWindow.setObject(state, forKey: window)
        }
    }
}

@MainActor
private enum DeferredWindowFrameChange {
    case libraryVisibility(isVisible: Bool, expansionWidth: CGFloat, minimumWidth: CGFloat)
    case annotationVisibility(isVisible: Bool, expansionWidth: CGFloat, minimumWidth: CGFloat)
    case libraryResize(delta: CGFloat)
    case annotationResize(delta: CGFloat)
}

@MainActor
private final class WindowFrameController {
    private weak var window: NSWindow?
    private var collapsedFrameBeforeExpansion: NSRect?
    private var collapsedFrameBeforeAnnotationExpansion: NSRect?
    private var expectedLibraryExpandedFrame: NSRect?
    private var expectedAnnotationExpandedFrame: NSRect?
    private var fullScreenObservers: [NSObjectProtocol] = []
    private var deferredFullScreenChanges: [DeferredWindowFrameChange] = []

    var isFullScreen: Bool {
        window?.styleMask.contains(.fullScreen) == true
    }

    func setWindow(_ window: NSWindow?) {
        guard self.window !== window else {
            return
        }

        let notificationCenter = NotificationCenter.default
        fullScreenObservers.forEach(notificationCenter.removeObserver)
        fullScreenObservers.removeAll()

        self.window = window
        collapsedFrameBeforeExpansion = nil
        collapsedFrameBeforeAnnotationExpansion = nil
        expectedLibraryExpandedFrame = nil
        expectedAnnotationExpandedFrame = nil
        deferredFullScreenChanges.removeAll()

        if let window {
            fullScreenObservers = [
                notificationCenter.addObserver(
                    forName: NSWindow.didExitFullScreenNotification,
                    object: window,
                    queue: .main
                ) { [weak self] _ in
                    Task { @MainActor [weak self] in
                        self?.applyDeferredFullScreenChangesAfterWindowSettles()
                    }
                }
            ]
        }
    }

    func expandIfNeeded(by expansionWidth: CGFloat, minimumWidth: CGFloat) {
        guard !isFullScreen, collapsedFrameBeforeExpansion == nil else {
            return
        }

        setLibraryNavigatorVisible(
            true,
            expansionWidth: expansionWidth,
            minimumWidth: minimumWidth
        )
    }

    func setLibraryNavigatorVisible(
        _ isVisible: Bool,
        expansionWidth: CGFloat,
        minimumWidth: CGFloat
    ) {
        guard let window else {
            return
        }

        let change = DeferredWindowFrameChange.libraryVisibility(
            isVisible: isVisible,
            expansionWidth: expansionWidth,
            minimumWidth: minimumWidth
        )
        guard !isFullScreen else {
            deferFullScreenChange(change)
            return
        }

        apply(change, to: window, animate: true)
    }

    func setAnnotationSidebarVisible(
        _ isVisible: Bool,
        expansionWidth: CGFloat,
        minimumWidth: CGFloat
    ) {
        guard let window else {
            return
        }

        let change = DeferredWindowFrameChange.annotationVisibility(
            isVisible: isVisible,
            expansionWidth: expansionWidth,
            minimumWidth: minimumWidth
        )
        guard !isFullScreen else {
            deferFullScreenChange(change)
            return
        }

        apply(change, to: window, animate: true)
    }

    func resizeExpandedWindow(by delta: CGFloat) {
        guard delta != 0, let window else {
            return
        }

        if isFullScreen {
            deferFullScreenChange(.libraryResize(delta: delta))
            return
        }

        guard collapsedFrameBeforeExpansion != nil else {
            return
        }

        resizeExpandedWindow(window, by: delta)
    }

    func resizeAnnotationExpandedWindow(by delta: CGFloat) {
        guard delta != 0, let window else {
            return
        }

        if isFullScreen {
            deferFullScreenChange(.annotationResize(delta: delta))
            return
        }

        resizeAnnotationExpandedWindow(window, by: delta)
    }

    private func resizeExpandedWindow(_ window: NSWindow, by delta: CGFloat) {
        var resizedFrame = window.frame
        resizedFrame.origin.x -= delta
        resizedFrame.size.width += delta
        resizedFrame = constrainedToVisibleScreen(resizedFrame, for: window)

        adjustRightCollapsedFrameForLeftChange(delta)
        expectedLibraryExpandedFrame = resizedFrame
        if expectedAnnotationExpandedFrame != nil {
            expectedAnnotationExpandedFrame = resizedFrame
        }
        window.setFrame(resizedFrame, display: true, animate: false)
    }

    private func resizeAnnotationExpandedWindow(_ window: NSWindow, by delta: CGFloat) {
        var resizedFrame = window.frame
        resizedFrame.size.width += delta
        resizedFrame = constrainedToVisibleScreen(resizedFrame, for: window)

        adjustLeftCollapsedFrameForRightChange(delta)
        expectedAnnotationExpandedFrame = resizedFrame
        if expectedLibraryExpandedFrame != nil {
            expectedLibraryExpandedFrame = resizedFrame
        }
        window.setFrame(resizedFrame, display: true, animate: false)
    }

    private func expandLeft(
        _ window: NSWindow,
        by expansionWidth: CGFloat,
        minimumWidth: CGFloat,
        animate: Bool
    ) {
        guard collapsedFrameBeforeExpansion == nil else {
            return
        }

        let currentFrame = window.frame
        collapsedFrameBeforeExpansion = currentFrame

        var expandedFrame = currentFrame
        expandedFrame.origin.x -= expansionWidth
        expandedFrame.size.width = max(currentFrame.width + expansionWidth, minimumWidth)
        expandedFrame = constrainedToVisibleScreen(expandedFrame, for: window)

        adjustRightCollapsedFrameForLeftChange(expansionWidth)
        expectedLibraryExpandedFrame = expandedFrame
        if expectedAnnotationExpandedFrame != nil {
            expectedAnnotationExpandedFrame = expandedFrame
        }
        window.setFrame(expandedFrame, display: true, animate: animate)
    }

    private func collapseLeft(
        _ window: NSWindow,
        by expansionWidth: CGFloat,
        minimumWidth: CGFloat,
        animate: Bool
    ) {
        let collapsedFrame: NSRect

        if let collapsedFrameBeforeExpansion,
           let expectedLibraryExpandedFrame,
           framesApproximatelyEqual(window.frame, expectedLibraryExpandedFrame) {
            collapsedFrame = collapsedFrameBeforeExpansion
        } else {
            var fallbackFrame = window.frame
            fallbackFrame.size.width = max(window.frame.width - expansionWidth, minimumWidth)
            fallbackFrame.origin.x += window.frame.width - fallbackFrame.width
            collapsedFrame = fallbackFrame
        }

        self.collapsedFrameBeforeExpansion = nil
        expectedLibraryExpandedFrame = nil
        adjustRightCollapsedFrameForLeftChange(-expansionWidth)
        if expectedAnnotationExpandedFrame != nil {
            expectedAnnotationExpandedFrame = collapsedFrame
        }
        window.setFrame(
            constrainedToVisibleScreen(collapsedFrame, for: window),
            display: true,
            animate: animate
        )
    }

    private func expandRight(
        _ window: NSWindow,
        by expansionWidth: CGFloat,
        minimumWidth: CGFloat,
        animate: Bool
    ) {
        guard collapsedFrameBeforeAnnotationExpansion == nil else {
            return
        }

        let currentFrame = window.frame
        collapsedFrameBeforeAnnotationExpansion = currentFrame

        var expandedFrame = currentFrame
        expandedFrame.size.width = max(currentFrame.width + expansionWidth, minimumWidth)
        expandedFrame = constrainedToVisibleScreen(expandedFrame, for: window)

        adjustLeftCollapsedFrameForRightChange(expansionWidth)
        expectedAnnotationExpandedFrame = expandedFrame
        if expectedLibraryExpandedFrame != nil {
            expectedLibraryExpandedFrame = expandedFrame
        }
        window.setFrame(expandedFrame, display: true, animate: animate)
    }

    private func collapseRight(
        _ window: NSWindow,
        by expansionWidth: CGFloat,
        minimumWidth: CGFloat,
        animate: Bool
    ) {
        let collapsedFrame: NSRect

        if let collapsedFrameBeforeAnnotationExpansion,
           let expectedAnnotationExpandedFrame,
           framesApproximatelyEqual(window.frame, expectedAnnotationExpandedFrame) {
            collapsedFrame = collapsedFrameBeforeAnnotationExpansion
        } else {
            var fallbackFrame = window.frame
            fallbackFrame.size.width = max(window.frame.width - expansionWidth, minimumWidth)
            collapsedFrame = fallbackFrame
        }

        collapsedFrameBeforeAnnotationExpansion = nil
        expectedAnnotationExpandedFrame = nil
        adjustLeftCollapsedFrameForRightChange(-expansionWidth)
        if expectedLibraryExpandedFrame != nil {
            expectedLibraryExpandedFrame = collapsedFrame
        }
        window.setFrame(
            constrainedToVisibleScreen(collapsedFrame, for: window),
            display: true,
            animate: animate
        )
    }

    private func apply(
        _ change: DeferredWindowFrameChange,
        to window: NSWindow,
        animate: Bool
    ) {
        switch change {
        case let .libraryVisibility(isVisible, expansionWidth, minimumWidth):
            if isVisible {
                expandLeft(
                    window,
                    by: expansionWidth,
                    minimumWidth: minimumWidth,
                    animate: animate
                )
            } else {
                collapseLeft(
                    window,
                    by: expansionWidth,
                    minimumWidth: minimumWidth,
                    animate: animate
                )
            }
        case let .annotationVisibility(isVisible, expansionWidth, minimumWidth):
            if isVisible {
                expandRight(
                    window,
                    by: expansionWidth,
                    minimumWidth: minimumWidth,
                    animate: animate
                )
            } else {
                collapseRight(
                    window,
                    by: expansionWidth,
                    minimumWidth: minimumWidth,
                    animate: animate
                )
            }
        case let .libraryResize(delta):
            guard collapsedFrameBeforeExpansion != nil else {
                return
            }
            resizeExpandedWindow(window, by: delta)
        case let .annotationResize(delta):
            resizeAnnotationExpandedWindow(window, by: delta)
        }
    }

    private func deferFullScreenChange(_ change: DeferredWindowFrameChange) {
        switch (deferredFullScreenChanges.last, change) {
        case let (.libraryResize(previousDelta)?, .libraryResize(delta)):
            deferredFullScreenChanges[deferredFullScreenChanges.count - 1] =
                .libraryResize(delta: previousDelta + delta)
        case let (.annotationResize(previousDelta)?, .annotationResize(delta)):
            deferredFullScreenChanges[deferredFullScreenChanges.count - 1] =
                .annotationResize(delta: previousDelta + delta)
        default:
            deferredFullScreenChanges.append(change)
        }
    }

    private func applyDeferredFullScreenChangesAfterWindowSettles() {
        DispatchQueue.main.async { [weak self] in
            guard let self,
                  let window = self.window,
                  !self.isFullScreen,
                  !self.deferredFullScreenChanges.isEmpty
            else {
                return
            }

            let changes = self.deferredFullScreenChanges
            self.deferredFullScreenChanges.removeAll()
            for change in changes {
                self.apply(change, to: window, animate: false)
            }
        }
    }

    private func framesApproximatelyEqual(_ lhs: NSRect, _ rhs: NSRect) -> Bool {
        let tolerance: CGFloat = 1
        return abs(lhs.minX - rhs.minX) <= tolerance
            && abs(lhs.minY - rhs.minY) <= tolerance
            && abs(lhs.width - rhs.width) <= tolerance
            && abs(lhs.height - rhs.height) <= tolerance
    }

    private func adjustRightCollapsedFrameForLeftChange(_ delta: CGFloat) {
        guard var frame = collapsedFrameBeforeAnnotationExpansion else {
            return
        }

        frame.origin.x -= delta
        frame.size.width += delta
        collapsedFrameBeforeAnnotationExpansion = frame
    }

    private func adjustLeftCollapsedFrameForRightChange(_ delta: CGFloat) {
        guard var frame = collapsedFrameBeforeExpansion else {
            return
        }

        frame.size.width += delta
        collapsedFrameBeforeExpansion = frame
    }

    private func constrainedToVisibleScreen(_ frame: NSRect, for window: NSWindow) -> NSRect {
        guard let visibleFrame = (window.screen ?? NSScreen.main)?.visibleFrame else {
            return frame
        }

        var constrainedFrame = frame
        constrainedFrame.size.width = min(constrainedFrame.width, visibleFrame.width)

        if constrainedFrame.minX < visibleFrame.minX {
            constrainedFrame.origin.x = visibleFrame.minX
        }

        if constrainedFrame.maxX > visibleFrame.maxX {
            constrainedFrame.origin.x = visibleFrame.maxX - constrainedFrame.width
        }

        if constrainedFrame.minY < visibleFrame.minY {
            constrainedFrame.origin.y = visibleFrame.minY
        }

        if constrainedFrame.maxY > visibleFrame.maxY {
            constrainedFrame.origin.y = visibleFrame.maxY - constrainedFrame.height
        }

        return constrainedFrame
    }
}

private struct HostingWindowAccessor: NSViewRepresentable {
    let onWindowChange: (NSWindow?) -> Void

    func makeNSView(context: Context) -> HostingWindowAccessorView {
        let view = HostingWindowAccessorView()
        view.onWindowChange = onWindowChange
        return view
    }

    func updateNSView(_ nsView: HostingWindowAccessorView, context: Context) {
        nsView.onWindowChange = onWindowChange

        DispatchQueue.main.async {
            nsView.notifyWindowChanged()
        }
    }
}

private final class HostingWindowAccessorView: NSView {
    var onWindowChange: ((NSWindow?) -> Void)?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        notifyWindowChanged()
    }

    func notifyWindowChanged() {
        onWindowChange?(window)
    }
}

private struct NewGroupSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var groupName: String
    let onCreate: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("New Group")
                .font(.headline)

            TextField("Group name", text: $groupName)
                .textFieldStyle(.roundedBorder)
                .onSubmit(createIfPossible)

            HStack {
                Spacer()

                Button("Cancel") {
                    dismiss()
                }

                Button("Create") {
                    createIfPossible()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(groupName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 320)
    }

    private func createIfPossible() {
        guard !groupName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return
        }

        onCreate()
    }
}

private struct SidebarResizeHandle: View {
    let width: CGFloat
    let onBegin: () -> Void
    let onDrag: (CGFloat) -> Void
    let onEnd: () -> Void

    var body: some View {
        ZStack {
            Divider()
                .frame(width: 1)
                .allowsHitTesting(false)

            SidebarResizeHitTarget(
                onBegin: onBegin,
                onDrag: onDrag,
                onEnd: onEnd
            )
        }
        .frame(width: width)
        .frame(maxHeight: .infinity)
    }
}

private struct SidebarResizeHitTarget: NSViewRepresentable {
    let onBegin: () -> Void
    let onDrag: (CGFloat) -> Void
    let onEnd: () -> Void

    func makeNSView(context: Context) -> SidebarResizeHitTargetView {
        let view = SidebarResizeHitTargetView()
        view.onBegin = onBegin
        view.onDrag = onDrag
        view.onEnd = onEnd
        return view
    }

    func updateNSView(_ nsView: SidebarResizeHitTargetView, context: Context) {
        nsView.onBegin = onBegin
        nsView.onDrag = onDrag
        nsView.onEnd = onEnd
    }
}

private final class SidebarResizeHitTargetView: NSView {
    var onBegin: (() -> Void)?
    var onDrag: ((CGFloat) -> Void)?
    var onEnd: (() -> Void)?

    private var dragStartX: CGFloat?
    private var trackingArea: NSTrackingArea?
    private var cursorIsPushed = false

    override var isFlipped: Bool {
        true
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        return nil
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()

        if let trackingArea {
            removeTrackingArea(trackingArea)
        }

        let area = NSTrackingArea(
            rect: bounds,
            options: [.activeInKeyWindow, .inVisibleRect, .mouseEnteredAndExited, .cursorUpdate],
            owner: self
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        pushResizeCursorIfNeeded()
    }

    override func mouseExited(with event: NSEvent) {
        popResizeCursorIfNeeded()
    }

    override func mouseDown(with event: NSEvent) {
        dragStartX = event.locationInWindow.x
        onBegin?()
        pushResizeCursorIfNeeded()
    }

    override func mouseDragged(with event: NSEvent) {
        guard let dragStartX else {
            return
        }

        onDrag?(event.locationInWindow.x - dragStartX)
    }

    override func mouseUp(with event: NSEvent) {
        dragStartX = nil
        onEnd?()
    }

    override func cursorUpdate(with event: NSEvent) {
        NSCursor.resizeLeftRight.set()
    }

    deinit {
        popResizeCursorIfNeeded()
    }

    private func pushResizeCursorIfNeeded() {
        guard !cursorIsPushed else {
            return
        }

        NSCursor.resizeLeftRight.push()
        cursorIsPushed = true
    }

    private func popResizeCursorIfNeeded() {
        guard cursorIsPushed else {
            return
        }

        NSCursor.pop()
        cursorIsPushed = false
    }
}
