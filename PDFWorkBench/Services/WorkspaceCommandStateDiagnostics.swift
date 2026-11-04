import Foundation
import PDFKit

/// Shared routing fixtures have no key window, native menu, user data or provider.
@MainActor
enum WorkspaceCommandStateDiagnostics {
    static func run() -> (checks: Int, failures: [String]) {
        var checks = 0
        var failures: [String] = []
        func check(_ condition: @autoclosure () -> Bool, _ message: String) {
            checks += 1
            if !condition() { failures.append(message) }
        }

        let routing = WorkspaceCommandState()
        let groupID = UUID()
        let first = GroupWorkspaceState(id: UUID(), groupID: groupID)
        let second = GroupWorkspaceState(id: UUID(), groupID: groupID)
        var firstCalls = 0
        var secondCalls = 0
        check(routing.workspaceID == nil && routing.handlers == nil, "Empty routing exposed reader commands.")
        routing.activate(workspace: first, handlers: handlers { firstCalls += 1 })
        check(routing.handlers == nil, "An inactive workspace registered reader commands.")
        first.setActive(true)
        routing.activate(workspace: first, handlers: handlers { firstCalls += 1 })
        check(routing.workspaceID == first.id, "Activation lost the selected workspace identity.")
        routing.handlers?.openPDF()
        check(firstCalls == 1 && secondCalls == 0, "Reader actions did not route to their owning workspace.")
        check(routing.handlers?.canAddHighlight == false && routing.handlers?.canDeleteCurrentPage == false,
              "Routing changed the document's command availability.")

        first.setActive(false)
        check(routing.handlers == nil && routing.workspaceID == nil, "Hidden workspace commands remained available.")
        second.setActive(true)
        routing.activate(workspace: second, handlers: handlers { secondCalls += 1 })
        routing.deactivate(workspaceID: first.id)
        routing.handlers?.openPDF()
        check(routing.workspaceID == second.id && firstCalls == 1 && secondCalls == 1,
              "A late deactivation cleared the newer workspace's commands.")
        routing.activate(workspace: first, handlers: handlers { firstCalls += 100 })
        check(routing.workspaceID == second.id, "An ineligible registration replaced the active workspace.")
        second.finishClosing()
        check(routing.handlers == nil && routing.workspaceID == nil, "A closed workspace exposed stale actions.")
        second.setActive(true)
        routing.activate(workspace: second, handlers: handlers { secondCalls += 100 })
        check(routing.handlers == nil, "Terminal workspace close was bypassed by command registration.")
        routing.deactivate(workspaceID: second.id)
        first.setActive(true)
        routing.activate(workspace: first, handlers: handlers { firstCalls += 10 })
        routing.handlers?.openPDF()
        check(firstCalls == 11, "Reactivation reused stale closures instead of the latest reader state.")
        first.updateGroupID(UUID())
        check(routing.workspaceID == first.id, "Changing Group replaced the command workspace identity.")
        routing.deactivate(workspaceID: UUID())
        check(routing.workspaceID == first.id, "An unrelated workspace unregistered the selected reader.")
        routing.deactivate(workspaceID: first.id)
        check(routing.handlers == nil, "Workspace deactivation retained executable reader actions.")

        weak var capturedProbe: Probe?
        func registerProbe() {
            let probe = Probe()
            capturedProbe = probe
            routing.activate(workspace: first, handlers: handlers { probe.calls += 1 })
        }
        registerProbe()
        check(capturedProbe != nil, "An active command lost its captured reader lifetime.")
        routing.deactivate(workspaceID: first.id)
        check(capturedProbe == nil, "Unregistering commands retained their captured reader resources.")

        check(PDFReadingDisplayStyle.singlePage.pdfDisplayMode == .singlePage
              && PDFReadingDisplayStyle.continuous.pdfDisplayMode == .singlePageContinuous
              && PDFReadingDisplayStyle.twoUp.pdfDisplayMode == .twoUpContinuous,
              "Extracting layout values changed native PDFKit reading modes.")
        check(PDFReadingDisplayStyle.allCases.allSatisfy { !$0.displaysAsBook },
              "Shared layout values changed consecutive two-up page pairing.")
        check(URL(fileURLWithPath: "/tmp/fixture.PDF").isPDFFileURL
              && !URL(string: "https://example.invalid/fixture.pdf")!.isPDFFileURL,
              "Shared file URL filtering accepted remote PDFs or rejected uppercase extensions.")
        return (checks, failures)
    }

    private final class Probe { var calls = 0 }

    private static func handlers(openPDF: @escaping () -> Void) -> PDFWorkbenchCommandHandlers {
        PDFWorkbenchCommandHandlers(openPDF: openPDF, savePDF: {}, showFileInfo: {}, createLibraryGroup: {},
            toggleLibraryNavigator: {}, toggleAnnotationSidebar: {}, addCurrentDocumentToSelectedGroup: {},
            removeCurrentDocumentFromSelectedGroup: {}, addHighlight: {}, addFreeTextNote: {}, showPageOrganizer: {},
            toggleDogear: {}, deleteCurrentPage: {}, goToPreviousPage: {}, goToNextPage: {}, goToFirstPage: {},
            goToLastPage: {}, zoomIn: {}, zoomOut: {}, actualSize: {}, fitWidth: {}, fitPage: {}, setDisplayStyle: { _ in },
            showFind: {}, findNext: {}, findPrevious: {}, exportAnnotatedCopy: {}, exportAnnotationsMarkdown: {},
            exportKeywordOutline: {}, isLibraryNavigatorVisible: false, isAnnotationSidebarVisible: false,
            canUseDocumentCommands: false, canAddCurrentDocumentToSelectedGroup: false,
            canRemoveCurrentDocumentFromSelectedGroup: false, canAddHighlight: false,
            canGoToPreviousPage: false, canGoToNextPage: false, canDeleteCurrentPage: false)
    }
}
