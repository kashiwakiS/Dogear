import AppKit
import PDFKit
import SwiftUI

struct ResearchEvidencePreview: View {
    let evidence: ResearchEvidence
    @ObservedObject var library: LibraryStore
    @Environment(\.dismiss) private var dismiss
    @State private var resolved: ResolvedResearchEvidence?
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading) {
                    Text(evidence.source?.displayName ?? L10n.string("Research evidence")).font(.headline)
                    Text("Read-only evidence preview").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Back to reading") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            if let attachmentID = evidence.attachmentID,
               let url = ResearchStore.shared.attachmentURL(id: attachmentID),
               let image = NSImage(contentsOf: url) {
                Image(nsImage: image).resizable().scaledToFit().frame(maxHeight: 240)
            }
            Text(evidence.excerpt).font(.callout).textSelection(.enabled).lineLimit(6)
            if let error {
                Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                Text("The saved excerpt is still available. Dogear did not guess a new source location.")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
            } else if let resolved {
                if resolved.revalidated {
                    Text("The PDF version changed; this text passage was revalidated.").font(.caption).foregroundStyle(.secondary)
                }
                ResearchReadOnlyPDFView(resolved: resolved).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if evidence.source != nil { ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity) }
            else { Spacer() }
        }
        .padding(18).frame(minWidth: 520, idealWidth: 680, minHeight: 500, idealHeight: 740)
        .task(id: evidence.id) {
            resolved = nil
            error = nil
            guard evidence.source != nil else { return }
            do {
                let value = try await ResearchEvidenceResolver.resolve(evidence, library: library)
                guard !Task.isCancelled else { return }
                resolved = value
            } catch {
                guard !Task.isCancelled else { return }
                self.error = error.localizedDescription
            }
        }
    }
}

struct ResearchReadOnlyPDFView: NSViewRepresentable {
    let resolved: ResolvedResearchEvidence
    func makeNSView(context: Context) -> ReadOnlyEvidencePDFView {
        let view = ReadOnlyEvidencePDFView()
        view.document = resolved.document
        view.displayMode = .singlePageContinuous
        view.autoScales = true
        return view
    }
    final class Coordinator {
        weak var document: PDFDocument?
        var pageIndex: Int?
        var rect: CGRect?
    }
    func makeCoordinator() -> Coordinator { Coordinator() }
    func updateNSView(_ view: ReadOnlyEvidencePDFView, context: Context) {
        let state = context.coordinator
        guard state.document !== resolved.document || state.pageIndex != resolved.pageIndex || state.rect != resolved.rect else { return }
        state.document = resolved.document
        state.pageIndex = resolved.pageIndex
        state.rect = resolved.rect
        if view.document !== resolved.document { view.document = resolved.document }
        guard let page = resolved.document.page(at: resolved.pageIndex) else { return }
        if let rect = resolved.rect {
            view.go(to: rect.insetBy(dx: -12, dy: -30), on: page)
            if let selection = page.selection(for: rect) { view.setCurrentSelection(selection, animate: false) }
        } else { view.go(to: page) }
    }
}

/// No native annotation menu, dragging, or editing shortcuts reach this reader.
/// It receives a detached snapshot and has no persistence or editing store.
final class ReadOnlyEvidencePDFView: PDFView {
    private var startPage: PDFPage?
    private var startPoint = CGPoint.zero
    override func hitTest(_ point: NSPoint) -> NSView? {
        bounds.contains(convert(point, from: superview)) ? self : nil
    }
    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation { [] }
    override func prepareForDragOperation(_ sender: any NSDraggingInfo) -> Bool { false }
    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool { false }
    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let location = convert(event.locationInWindow, from: nil)
        startPage = page(for: location, nearest: false)
        if let startPage { startPoint = convert(location, to: startPage); clearSelection() }
    }
    override func mouseDragged(with event: NSEvent) {
        let location = convert(event.locationInWindow, from: nil)
        guard let startPage, let endPage = page(for: location, nearest: true),
              let selection = document?.selection(from: startPage, at: startPoint,
                                                   to: endPage, at: convert(location, to: endPage)) else { return }
        setCurrentSelection(selection, animate: false)
    }
    override func mouseUp(with event: NSEvent) { startPage = nil }
    override func keyDown(with event: NSEvent) {
        if event.modifierFlags.contains(.command), event.charactersIgnoringModifiers == "c" { copyEvidence(nil) }
        else if event.keyCode == 125 || event.keyCode == 121 { goToNextPage(nil) }
        else if event.keyCode == 126 || event.keyCode == 116 { goToPreviousPage(nil) }
    }
    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu()
        let copy = NSMenuItem(title: L10n.string("Copy"), action: #selector(copyEvidence(_:)), keyEquivalent: "")
        copy.target = self
        copy.isEnabled = currentSelection?.string?.isEmpty == false
        menu.addItem(copy)
        return menu
    }
    @objc private func copyEvidence(_ sender: Any?) {
        guard let text = currentSelection?.string else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
