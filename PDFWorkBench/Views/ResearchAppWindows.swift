import AppKit
import SwiftUI

struct ResearchLibraryWindow: View {
    @ObservedObject var library: LibraryStore
    @ObservedObject private var languageStore = AppLanguageStore.shared
    @Environment(\.openWindow) private var openWindow
    @State private var evidence: ResearchEvidence?
    var body: some View {
        ResearchLibraryView(library: library,
            onOpenSession: { openWindow(id: "research-session", value: $0) },
            onViewEvidence: { evidence = $0 })
            .sheet(item: $evidence) {
                ResearchEvidencePreview(evidence: $0, library: library)
                    .environment(\.locale, languageStore.locale)
            }
            .environment(\.locale, languageStore.locale)
    }
}

struct StandaloneResearchSessionView: View {
    @ObservedObject var library: LibraryStore
    @ObservedObject private var researchStore = ResearchStore.shared
    @ObservedObject private var languageStore = AppLanguageStore.shared
    @Binding var sessionID: UUID?
    @State private var evidence: ResearchEvidence?
    @State private var viewID = UUID()
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        ResearchPanelView(library: library, sessionID: $sessionID, currentFileID: nil,
            mainStore: nil, viewID: viewID, compact: false,
            onAddSelection: {}, onCaptureRegion: {}, onViewEvidence: { evidence = $0 },
            onShowLibrary: { openWindow(id: "research-library") }, onToggleWide: {})
            .frame(minWidth: 420, minHeight: 500)
            .navigationTitle(Text(verbatim: sessionID.flatMap { researchStore.session(id: $0)?.title }
                ?? L10n.string("Research Session")))
            .background(ResearchSessionWindowCloseObserver {
                if let sessionID { ResearchRuntime.shared.cancel(sessionID: sessionID) }
                ResearchCommandService.shared.unregister(viewID: viewID)
            })
            .sheet(item: $evidence) {
                ResearchEvidencePreview(evidence: $0, library: library)
                    .environment(\.locale, languageStore.locale)
            }
            .environment(\.locale, languageStore.locale)
    }
}

struct ResearchNoteWindow: View {
    let noteID: UUID
    @Environment(\.openWindow) private var openWindow
    @ObservedObject var library: LibraryStore
    @ObservedObject private var languageStore = AppLanguageStore.shared
    @State private var evidence: ResearchEvidence?
    var body: some View {
        ResearchNoteEditorView(noteID: noteID, onViewEvidence: { evidence = $0 }, onQuote: quoteIntoNewSession)
            .sheet(item: $evidence) {
                ResearchEvidencePreview(evidence: $0, library: library)
                    .environment(\.locale, languageStore.locale)
            }
            .environment(\.locale, languageStore.locale)
    }

    private func quoteIntoNewSession(_ block: ResearchInputBlock) {
        let store = ResearchStore.shared
        guard let note = store.note(id: noteID),
              block.kind == .note, block.evidence?.noteID == noteID,
              block.evidence?.noteRevision != nil else { return }
        let sources = note.relatedFileIDs.sorted { $0.uuidString < $1.uuidString }
        let id = store.createSession(title: note.title, sourceSelection: ResearchSourceSelection(fileIDs: sources))
        _ = store.saveDraft(ResearchDraft(blocks: [block]), sessionID: id)
        openWindow(id: "research-session", value: id)
    }
}

/// SwiftUI disappearance also occurs during tab, layout and presentation changes.
/// Only an actual close of this standalone session's owning NSWindow cancels it.
private struct ResearchSessionWindowCloseObserver: NSViewRepresentable {
    let onClose: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onClose: onClose) }
    func makeNSView(context: Context) -> WindowView {
        let view = WindowView()
        view.onWindowChanged = { [weak coordinator = context.coordinator] window in coordinator?.observe(window) }
        return view
    }
    func updateNSView(_ view: WindowView, context: Context) {
        context.coordinator.onClose = onClose
        context.coordinator.observe(view.window)
    }
    static func dismantleNSView(_ view: WindowView, coordinator: Coordinator) {
        view.onWindowChanged = nil
        coordinator.stopObserving()
    }

    final class WindowView: NSView {
        var onWindowChanged: ((NSWindow?) -> Void)?
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            onWindowChanged?(window)
        }
    }

    final class Coordinator {
        var onClose: () -> Void
        private weak var window: NSWindow?
        private var observer: NSObjectProtocol?
        init(onClose: @escaping () -> Void) { self.onClose = onClose }

        func observe(_ window: NSWindow?) {
            guard self.window !== window else { return }
            stopObserving()
            self.window = window
            guard let window else { return }
            observer = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification,
                object: window, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.onClose() }
                }
        }
        func stopObserving() {
            if let observer { NotificationCenter.default.removeObserver(observer) }
            observer = nil
            window = nil
        }
        deinit { if let observer { NotificationCenter.default.removeObserver(observer) } }
    }
}
