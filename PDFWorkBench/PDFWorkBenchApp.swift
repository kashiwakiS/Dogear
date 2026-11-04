//
//  PDFWorkBenchApp.swift
//  PDFWorkBench
//
//

import SwiftUI
import AppKit
import Combine

struct PDFWorkBenchApp: App {
    @NSApplicationDelegateAdaptor(PDFWorkBenchAppDelegate.self) private var appDelegate
    @StateObject private var libraryStore: LibraryStore
    private let libraryLifecycle: LibraryMacLifecycleAdapter
    private let languageMenuAdapter: AppLanguageMacMenuAdapter
    @StateObject private var languageStore = AppLanguageStore.shared

    init() {
        let library = LibraryStore()
        _libraryStore = StateObject(wrappedValue: library)
        libraryLifecycle = LibraryMacLifecycleAdapter(library: library)
        languageMenuAdapter = AppLanguageMacMenuAdapter(languageStore: .shared)
    }

    var body: some Scene {
        WindowGroup {
            GroupWorkspaceSceneRoot(libraryStore: libraryStore,
                initialWorkspace: GroupWindowPayload(sessionID: libraryStore.initialWindowSessionID,
                    groupID: libraryStore.initialWindowGroupID))
                .environment(\.locale, languageStore.locale)
        }
        .defaultSize(width: 1080, height: 760)
        .windowResizability(.contentMinSize)
        #if os(macOS)
        .windowToolbarStyle(.unified)
        #endif
        .commands {
            PDFWorkBenchCommands(languageStore: languageStore)
        }

        WindowGroup(L10n.string("Group"), for: GroupWindowPayload.self) { payload in
            if let payload = payload.wrappedValue {
                GroupWorkspaceSceneRoot(libraryStore: libraryStore, initialWorkspace: payload)
                    .environment(\.locale, languageStore.locale)
            }
        }
        .defaultSize(width: 1080, height: 760)
        .windowResizability(.contentMinSize)
        #if os(macOS)
        .windowToolbarStyle(.unified)
        #endif

        Settings {
            AISettingsView(
                configurationStore: .shared,
                languageStore: languageStore
            )
            .environment(\.locale, languageStore.locale)
        }

        Window(L10n.string("Working Copies"), id: "working-copies") {
            WorkingCopiesWindow(library: libraryStore)
                .environment(\.locale, languageStore.locale)
        }
        .defaultSize(width: 720, height: 540)

        Window(L10n.string("Research"), id: "research-library") {
            ResearchLibraryWindow(library: libraryStore)
                .environment(\.locale, languageStore.locale)
        }
        .defaultSize(width: 920, height: 760)

        WindowGroup(L10n.string("Research Session"), id: "research-session", for: UUID.self) { value in
            // Scene restoration can supply the UUID after the first evaluation.
            // Do not create a new session while that restored value is pending.
            if value.wrappedValue != nil {
                StandaloneResearchSessionView(library: libraryStore, sessionID: value)
                    .environment(\.locale, languageStore.locale)
            }
        }
        .defaultSize(width: 640, height: 760)

        WindowGroup(L10n.string("Research Note"), id: "research-note", for: UUID.self) { value in
            if let noteID = value.wrappedValue {
                ResearchNoteWindow(noteID: noteID, library: libraryStore)
                    .environment(\.locale, languageStore.locale)
            }
        }
        .defaultSize(width: 720, height: 760)
    }
}

private struct WorkspaceOpenWindowKey: EnvironmentKey {
    static let defaultValue: OpenWindowAction? = nil
}

extension EnvironmentValues {
    var workspaceOpenWindow: OpenWindowAction? {
        get { self[WorkspaceOpenWindowKey.self] }
        set { self[WorkspaceOpenWindowKey.self] = newValue }
    }
}

/// Inject scene actions explicitly because retained workspaces have independent hosting roots.
private struct GroupWorkspaceSceneRoot: View {
    @ObservedObject var libraryStore: LibraryStore
    let initialWorkspace: GroupWindowPayload
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        GroupWorkspaceHostView(initialWorkspace: initialWorkspace) { payload, context in
            AnyView(GroupWorkspaceContentRoot(libraryStore: libraryStore, payload: payload,
                workspace: context).environment(\.workspaceOpenWindow, openWindow))
        }
        .frame(minWidth: 520, minHeight: 680)
        .onOpenURL { ExternalPDFOpenCoordinator.shared.openURLs([$0]) }
    }
}

private struct GroupWorkspaceContentRoot: View {
    let libraryStore: LibraryStore
    let payload: GroupWindowPayload
    let workspace: GroupWorkspaceContext
    @ObservedObject private var language = AppLanguageStore.shared

    var body: some View {
        let groupID = libraryStore.group(withID: payload.groupID)?.id ?? LibraryGroup.ungroupedID
        ContentView(libraryStore: libraryStore, initialGroupID: groupID,
            initialSessionID: payload.sessionID, workspaceContext: workspace)
            .environment(\.locale, language.locale)
            .onAppear { workspace.updateGroupID(groupID) }
    }
}

@main
enum DogearEntryPoint {
    @MainActor static func main() {
        if CommandLine.arguments.contains("--run-research-acceptance") {
            // Explicit opt-in only; never initialize the user's Library or windows.
            Task { @MainActor in
                exit(await ResearchLiveAcceptance.run(arguments: CommandLine.arguments))
            }
            RunLoop.main.run()
        } else if CommandLine.arguments.contains("--run-annotation-ui-diagnostics") {
            // Exercise production sheets against authored PDFs without loading
            // the user's Library, windows, documents or preferences.
            let application = NSApplication.shared
            application.setActivationPolicy(.accessory)
            application.finishLaunching()
            application.activate(ignoringOtherApps: true)
            Task { @MainActor in
                let result = await MacAnnotationSheetDiagnostics.run()
                for observation in result.observations { print("OBSERVATION: \(observation)") }
                for failure in result.failures { print("FAIL: \(failure)") }
                print("ANNOTATION UI DIAGNOSTICS: \(result.checks) checks, \(result.failures.count) failures")
                exit(result.failures.isEmpty ? EXIT_SUCCESS : EXIT_FAILURE)
            }
            application.run()
        } else if CommandLine.arguments.contains("--run-native-ui-diagnostics") {
            // Foreground native focus checks run separately from offline fixtures.
            // Neither entry constructs the user's SwiftUI scenes or Library.
            let application = NSApplication.shared
            application.setActivationPolicy(.accessory)
            application.finishLaunching()
            Task { @MainActor in
                let result = await NativeTabPreviewInteractionDiagnostics.run()
                for failure in result.failures { print("FAIL: \(failure)") }
                print("NATIVE UI DIAGNOSTICS: \(result.checks) checks, \(result.failures.count) failures")
                exit(result.failures.isEmpty ? EXIT_SUCCESS : EXIT_FAILURE)
            }
            application.run()
        } else if CommandLine.arguments.contains("--run-ai-diagnostics") {
            // Enter before constructing the SwiftUI app or its persisted Library.
            Task { @MainActor in
                let succeeded = await AIWorkflowDiagnosticSuite.run()
                exit(succeeded ? EXIT_SUCCESS : EXIT_FAILURE)
            }
            RunLoop.main.run()
        } else {
            PDFWorkBenchApp.main()
        }
    }
}

@MainActor
final class PDFWorkBenchAppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        NSWindow.allowsAutomaticWindowTabbing = false
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppLanguageStore.shared.refreshMenuBarLocalization()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if let editor = MacAnnotationEditorLifecycle.unfinishedWindow {
            editor.makeKeyAndOrderFront(nil)
            let alert = NSAlert()
            alert.messageText = L10n.string("Finish editing the annotation before quitting")
            alert.informativeText = L10n.string("Your unsubmitted text is still in the editor. Save it or explicitly discard it, then quit again.")
            alert.addButton(withTitle: L10n.string("Keep editing"))
            alert.runModal()
            return .terminateCancel
        }
        PDFSaveQueue.shared.waitUntilDrained()
        ResearchRuntime.shared.shutdown()
        if DocumentAccessCoordinator.shared.hasUnrecoverableChanges || !ResearchStore.shared.saveFailures.isEmpty {
            let alert = NSAlert()
            alert.messageText = L10n.string("Some changes could not be saved")
            alert.informativeText = L10n.string("Dogear will stay open to protect your changes. Retry saving or export your work before quitting.")
            alert.addButton(withTitle: L10n.string("Retry Saving"))
            alert.addButton(withTitle: L10n.string("Cancel"))
            if alert.runModal() == .alertFirstButtonReturn {
                DocumentAccessCoordinator.shared.retryPendingSaves()
                ResearchStore.shared.retryFailedSaves()
            }
            return .terminateCancel
        }
        GroupWorkspaceHostRegistry.shared.prepareForApplicationTermination()
        return .terminateNow
    }

    func application(_ sender: NSApplication, openFile filename: String) -> Bool {
        ExternalPDFOpenCoordinator.shared.openURLs([URL(fileURLWithPath: filename)])
        return true
    }

    func application(_ sender: NSApplication, openFiles filenames: [String]) {
        ExternalPDFOpenCoordinator.shared.openURLs(filenames.map(URL.init(fileURLWithPath:)))
        sender.reply(toOpenOrPrint: .success)
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        ExternalPDFOpenCoordinator.shared.openURLs(urls)
    }
}

struct ExternalPDFOpenRequest: Equatable, Identifiable {
    let id = UUID()
    let urls: [URL]
}

@MainActor
final class ExternalPDFOpenCoordinator: ObservableObject {
    static let shared = ExternalPDFOpenCoordinator()

    @Published private(set) var pendingOpenRequest: ExternalPDFOpenRequest?

    private init() {}

    func openURLs(_ urls: [URL]) {
        let importableURLs = urls.filter { $0.isPDFFileURL || $0.isDirectoryURL }
        guard !importableURLs.isEmpty else {
            return
        }

        pendingOpenRequest = ExternalPDFOpenRequest(urls: importableURLs)
    }

    func clear(_ request: ExternalPDFOpenRequest) {
        guard pendingOpenRequest?.id == request.id else {
            return
        }
        pendingOpenRequest = nil
    }
}

private struct PDFWorkbenchCommandHandlersKey: FocusedValueKey {
    typealias Value = PDFWorkbenchCommandHandlers
}

extension FocusedValues {
    var pdfWorkbenchCommandHandlers: PDFWorkbenchCommandHandlers? {
        get { self[PDFWorkbenchCommandHandlersKey.self] }
        set { self[PDFWorkbenchCommandHandlersKey.self] = newValue }
    }
}

private struct PDFWorkBenchCommands: Commands {
    @Environment(\.openWindow) private var openWindow
    @ObservedObject private var workspaceCommands = WorkspaceMacCommandRouter.shared
    private var commandHandlers: PDFWorkbenchCommandHandlers? { workspaceCommands.handlers }
    @ObservedObject var languageStore: AppLanguageStore

    var body: some Commands {
        let _ = languageStore.selection

        CommandGroup(replacing: .newItem) {
            Button(L10n.string("Open...")) {
                commandHandlers?.openPDF()
            }
            .keyboardShortcut("o")
            .disabled(commandHandlers == nil)

            Button(L10n.string(workspaceCommands.activeWorkspace == nil ? "Close Window" : "Close Workspace")) {
                if let workspace = workspaceCommands.activeWorkspace { workspace.close() }
                else { workspaceCommands.commandWindow?.performClose(nil) }
            }
                .keyboardShortcut("w")
                .disabled(workspaceCommands.commandWindow == nil)
        }

        CommandGroup(after: .windowList) {
            Button(workspaceCommands.commandWindow?.styleMask.contains(.fullScreen) == true
                   ? L10n.string("Exit Full Screen") : L10n.string("Enter Full Screen")) {
                workspaceCommands.commandWindow?.toggleFullScreen(nil)
            }
            .keyboardShortcut("f", modifiers: [.command, .control])
            .disabled(workspaceCommands.commandWindow == nil)
            Divider()
            Button(L10n.string("Previous Workspace")) { workspaceCommands.activeWorkspace?.selectNextWorkspace(backward: true) }
                .keyboardShortcut("[", modifiers: [.command, .shift])
                .disabled(workspaceCommands.activeWorkspace == nil)
            Button(L10n.string("Next Workspace")) { workspaceCommands.activeWorkspace?.selectNextWorkspace() }
                .keyboardShortcut("]", modifiers: [.command, .shift])
                .disabled(workspaceCommands.activeWorkspace == nil)
        }

        CommandGroup(after: .newItem) {
            Button(L10n.string("File Info…")) { commandHandlers?.showFileInfo() }
                .disabled(!canUseDocumentCommands)
            Button(L10n.string("Working Copies…")) { openWindow(id: "working-copies") }
        }

        CommandGroup(replacing: .saveItem) {
            Button(L10n.string("Save to Original...")) {
                commandHandlers?.savePDF()
            }
            .keyboardShortcut("s")
            .disabled(!canUseDocumentCommands)
        }

        CommandGroup(after: .pasteboard) {
            Divider()

            Button(L10n.string("Find…")) {
                commandHandlers?.showFind()
            }
            .keyboardShortcut("f")
            .disabled(commandHandlers == nil)

            Button(L10n.string("Find Next")) {
                commandHandlers?.findNext()
            }
            .keyboardShortcut("g")
            .disabled(commandHandlers == nil)

            Button(L10n.string("Find Previous")) {
                commandHandlers?.findPrevious()
            }
            .keyboardShortcut("g", modifiers: [.command, .shift])
            .disabled(commandHandlers == nil)
        }

        CommandMenu(L10n.string("Research")) {
            Button(L10n.string("Research sessions and notes")) { openWindow(id: "research-library") }
                .keyboardShortcut("r", modifiers: [.command, .shift])
        }

        CommandMenu(L10n.string("Library")) {
            Button(libraryNavigatorCommandTitle) {
                commandHandlers?.toggleLibraryNavigator()
            }
            .keyboardShortcut("l", modifiers: [.command, .option])
            .disabled(commandHandlers == nil)

            Button(annotationSidebarCommandTitle) {
                commandHandlers?.toggleAnnotationSidebar()
            }
            .keyboardShortcut("r", modifiers: [.command, .option])
            .disabled(commandHandlers == nil)

            Divider()

            Button(L10n.string("New Group...")) {
                commandHandlers?.createLibraryGroup()
            }
            .keyboardShortcut("n", modifiers: [.command, .shift])
            .disabled(commandHandlers == nil)

            Divider()

            Button(L10n.string("Add Current Document to Selected Group")) {
                commandHandlers?.addCurrentDocumentToSelectedGroup()
            }
            .disabled(commandHandlers?.canAddCurrentDocumentToSelectedGroup != true)

            Button(L10n.string("Remove Current Document from Selected Group")) {
                commandHandlers?.removeCurrentDocumentFromSelectedGroup()
            }
            .disabled(commandHandlers?.canRemoveCurrentDocumentFromSelectedGroup != true)
        }

        CommandMenu(L10n.string("Export")) {
            Button(L10n.string("Annotated PDF Copy")) {
                commandHandlers?.exportAnnotatedCopy()
            }
            .disabled(!canUseDocumentCommands)

            Button(L10n.string("Annotations Markdown")) {
                commandHandlers?.exportAnnotationsMarkdown()
            }
            .disabled(!canUseDocumentCommands)

            Button(L10n.string("Keyword Outline")) {
                commandHandlers?.exportKeywordOutline()
            }
            .disabled(!canUseDocumentCommands)
        }

        CommandGroup(after: .toolbar) {
            Button(L10n.string("Previous Page")) {
                commandHandlers?.goToPreviousPage()
            }
            .keyboardShortcut(.upArrow, modifiers: [.command])
            .disabled(commandHandlers?.canGoToPreviousPage != true)

            Button(L10n.string("Next Page")) {
                commandHandlers?.goToNextPage()
            }
            .keyboardShortcut(.downArrow, modifiers: [.command])
            .disabled(commandHandlers?.canGoToNextPage != true)

            Button(L10n.string("First Page")) {
                commandHandlers?.goToFirstPage()
            }
            .keyboardShortcut(.upArrow, modifiers: [.command, .option])
            .disabled(commandHandlers?.canGoToPreviousPage != true)

            Button(L10n.string("Last Page")) {
                commandHandlers?.goToLastPage()
            }
            .keyboardShortcut(.downArrow, modifiers: [.command, .option])
            .disabled(commandHandlers?.canGoToNextPage != true)

            Divider()

            Button(L10n.string("Zoom In")) {
                commandHandlers?.zoomIn()
            }
            .keyboardShortcut("+", modifiers: [.command])
            .disabled(!canUseDocumentCommands)

            Button(L10n.string("Zoom Out")) {
                commandHandlers?.zoomOut()
            }
            .keyboardShortcut("-", modifiers: [.command])
            .disabled(!canUseDocumentCommands)

            Button(L10n.string("Actual Size")) {
                commandHandlers?.actualSize()
            }
            .keyboardShortcut("0", modifiers: [.command])
            .disabled(!canUseDocumentCommands)

            Button(L10n.string("Fit Page")) {
                commandHandlers?.fitPage()
            }
            .keyboardShortcut("1", modifiers: [.command])
            .disabled(!canUseDocumentCommands)

            Button(L10n.string("Fit Width")) {
                commandHandlers?.fitWidth()
            }
            .keyboardShortcut("2", modifiers: [.command])
            .disabled(!canUseDocumentCommands)

            Divider()

            Button(L10n.string("Single Page")) {
                commandHandlers?.setDisplayStyle(.singlePage)
            }
            .disabled(!canUseDocumentCommands)

            Button(L10n.string("Continuous")) {
                commandHandlers?.setDisplayStyle(.continuous)
            }
            .disabled(!canUseDocumentCommands)

            Button(L10n.string("Two-Up Continuous")) {
                commandHandlers?.setDisplayStyle(.twoUp)
            }
            .disabled(!canUseDocumentCommands)
        }

        annotationAndPageCommands
    }

    @CommandsBuilder
    private var annotationAndPageCommands: some Commands {
        CommandMenu(L10n.string("Annotation")) {
            Button(L10n.string("Add Highlight")) {
                commandHandlers?.addHighlight()
            }
            .disabled(commandHandlers?.canAddHighlight != true)

            Button(L10n.string("Toggle Dog-ear")) {
                commandHandlers?.toggleDogear()
            }
            .disabled(!canUseDocumentCommands)

            Button(L10n.string("Add Free Text Note")) {
                commandHandlers?.addFreeTextNote()
            }
            .disabled(!canUseDocumentCommands)
        }

        CommandMenu(L10n.string("Pages")) {
            Button(L10n.string("Organize Pages…")) {
                commandHandlers?.showPageOrganizer()
            }
            .disabled(!canUseDocumentCommands)

            Divider()

            Button(L10n.string("Delete Current Page...")) {
                commandHandlers?.deleteCurrentPage()
            }
            .disabled(commandHandlers?.canDeleteCurrentPage != true)
        }
    }

    private var canUseDocumentCommands: Bool {
        commandHandlers?.canUseDocumentCommands == true
    }

    private var libraryNavigatorCommandTitle: String {
        if commandHandlers?.isLibraryNavigatorVisible == true {
            return L10n.string("Hide Library Navigator")
        }

        return L10n.string("Show Library Navigator")
    }

    private var annotationSidebarCommandTitle: String {
        if commandHandlers?.isAnnotationSidebarVisible == true {
            return L10n.string("Hide Annotation Sidebar")
        }

        return L10n.string("Show Annotation Sidebar")
    }
}

private struct WorkingCopiesWindow: View {
    @ObservedObject var library: LibraryStore
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        WorkingCopiesView(library: library, onOpen: { file in
            let original = library.resolvedURL(for: file)
            if DocumentAccessCoordinator.shared.activateExistingEditor(fileID: file.id)
                || DocumentAccessCoordinator.shared.activateExistingEditor(for: original) { return }
            let groupID = library.groups(containing: file).first?.id ?? LibraryGroup.ungroupedID
            let sessionID = UUID()
            library.recordOpenedFile(file.id, in: groupID, sessionID: sessionID)
            openWindow(value: GroupWindowPayload(sessionID: sessionID, groupID: groupID))
        }, onReveal: { NSWorkspace.shared.activateFileViewerSelecting([$0]) })
    }
}
