import Foundation

/// Reader actions and availability shared by menus, toolbars and platform scenes.
@MainActor
struct PDFWorkbenchCommandHandlers {
    let openPDF: () -> Void
    let savePDF: () -> Void
    let showFileInfo: () -> Void
    let createLibraryGroup: () -> Void
    let toggleLibraryNavigator: () -> Void
    let toggleAnnotationSidebar: () -> Void
    let addCurrentDocumentToSelectedGroup: () -> Void
    let removeCurrentDocumentFromSelectedGroup: () -> Void
    let addHighlight: () -> Void
    let addFreeTextNote: () -> Void
    let showPageOrganizer: () -> Void
    let toggleDogear: () -> Void
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
    let showFind: () -> Void
    let findNext: () -> Void
    let findPrevious: () -> Void
    let exportAnnotatedCopy: () -> Void
    let exportAnnotationsMarkdown: () -> Void
    let exportKeywordOutline: () -> Void
    let isLibraryNavigatorVisible: Bool
    let isAnnotationSidebarVisible: Bool
    let canUseDocumentCommands: Bool
    let canAddCurrentDocumentToSelectedGroup: Bool
    let canRemoveCurrentDocumentFromSelectedGroup: Bool
    let canAddHighlight: Bool
    let canGoToPreviousPage: Bool
    let canGoToNextPage: Bool
    let canDeleteCurrentPage: Bool
}
