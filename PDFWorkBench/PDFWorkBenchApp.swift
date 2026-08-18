//
//  PDFWorkBenchApp.swift
//  PDFWorkBench
//
//

import SwiftUI
import AppKit
import Combine

@main
struct PDFWorkBenchApp: App {
    @NSApplicationDelegateAdaptor(PDFWorkBenchAppDelegate.self) private var appDelegate
    @StateObject private var libraryStore = LibraryStore()
    @StateObject private var languageStore = AppLanguageStore.shared

    var body: some Scene {
        WindowGroup {
            ContentView(libraryStore: libraryStore)
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
            ContentView(
                libraryStore: libraryStore,
                initialGroupID: payload.wrappedValue?.groupID
            )
            .environment(\.locale, languageStore.locale)
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
    }
}

@MainActor
final class PDFWorkBenchAppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        PDFSaveQueue.shared.waitUntilDrained()
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

extension URL {
    var isPDFFileURL: Bool {
        isFileURL && pathExtension.localizedCaseInsensitiveCompare("pdf") == .orderedSame
    }
}

struct PDFWorkbenchCommandHandlers {
    let openPDF: () -> Void
    let savePDF: () -> Void
    let createLibraryGroup: () -> Void
    let toggleLibraryNavigator: () -> Void
    let toggleAnnotationSidebar: () -> Void
    let addCurrentDocumentToSelectedGroup: () -> Void
    let removeCurrentDocumentFromSelectedGroup: () -> Void
    let addFreeTextNote: () -> Void
    let deleteCurrentPage: () -> Void
    let goToPreviousPage: () -> Void
    let goToNextPage: () -> Void
    let goToFirstPage: () -> Void
    let goToLastPage: () -> Void
    let zoomIn: () -> Void
    let zoomOut: () -> Void
    let actualSize: () -> Void
    let fitWidth: () -> Void
    let fitPage: () -> Void
    let setDisplayStyle: (PDFReadingDisplayStyle) -> Void
    let exportAnnotatedCopy: () -> Void
    let exportAnnotationsMarkdown: () -> Void
    let exportKeywordOutline: () -> Void
    let isLibraryNavigatorVisible: Bool
    let isAnnotationSidebarVisible: Bool
    let canUseDocumentCommands: Bool
    let canAddCurrentDocumentToSelectedGroup: Bool
    let canRemoveCurrentDocumentFromSelectedGroup: Bool
    let canGoToPreviousPage: Bool
    let canGoToNextPage: Bool
    let canDeleteCurrentPage: Bool
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
    @FocusedValue(\.pdfWorkbenchCommandHandlers) private var commandHandlers
    @ObservedObject var languageStore: AppLanguageStore

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button(L10n.string("Open...")) {
                commandHandlers?.openPDF()
            }
            .keyboardShortcut("o")
            .disabled(commandHandlers == nil)
        }

        CommandGroup(replacing: .saveItem) {
            Button(L10n.string("Save to Original...")) {
                commandHandlers?.savePDF()
            }
            .keyboardShortcut("s")
            .disabled(!canUseDocumentCommands)
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

        CommandMenu(L10n.string("Annotation")) {
            Button(L10n.string("Add Free Text Note")) {
                commandHandlers?.addFreeTextNote()
            }
            .disabled(!canUseDocumentCommands)

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
