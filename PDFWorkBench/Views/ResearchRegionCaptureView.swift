import AppKit
import PDFKit
import SwiftUI

struct ResearchRegionCaptureSheet: View {
    let document: PDFDocument
    let pageIndex: Int
    let source: ResearchSourceSnapshot
    let sessionID: UUID
    @Environment(\.dismiss) private var dismiss
    @State private var region: CGRect?
    @State private var error: String?
    @State private var captureVersion: String?
    @State private var pendingSave = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Add page region to question").font(.headline)
            Text(source.displayName + " · " + L10n.string("Page") + " \(pageIndex + 1)").foregroundStyle(.secondary)
            Text("Drag a rectangle inside the page. The region will be added as an image; the PDF is unchanged.")
                .font(.caption)
            ResearchRegionCaptureView(document: document, pageIndex: pageIndex, region: region, onRegion: { region = $0 })
                .frame(minWidth: 500, minHeight: 430)
                .allowsHitTesting(!pendingSave)
                .border(Color.secondary.opacity(0.2))
            Button("Use whole page") {
                region = document.page(at: pageIndex)?.bounds(for: .cropBox)
            }.disabled(pendingSave)
            if let error { Text(error).font(.caption).foregroundStyle(.orange) }
            HStack {
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button(pendingSave ? "Retry saving" : "Add to question") { addRegion() }
                    .buttonStyle(.borderedProminent).disabled(region == nil)
            }
        }.padding(20).frame(width: 650, height: 690)
            .onAppear { if captureVersion == nil { captureVersion = DocumentAccessCoordinator.contentVersion(of: document) } }
    }

    private func addRegion() {
        if pendingSave {
            ResearchStore.shared.retryFailedSaves()
            if ResearchStore.shared.saveFailures["sessions/\(sessionID.uuidString)"] == nil { dismiss() }
            else { error = ResearchImageError.saveFailed.localizedDescription }
            return
        }
        guard let region, let page = document.page(at: pageIndex) else { return }
        do {
            guard captureVersion == DocumentAccessCoordinator.contentVersion(of: document) else {
                throw ResearchRuntimeError.sourceChanged(source.displayName)
            }
            let image = try ResearchImagePipeline.renderRegion(page: page, rect: region)
            let anchor = ResearchPageAnchor(pageIndex: pageIndex, x: region.minX, y: region.minY,
                width: region.width, height: region.height)
            let evidence = ResearchEvidence(source: source, kind: .image, anchor: anchor,
                excerpt: L10n.string("Page region") + " \(pageIndex + 1)")
            try ResearchImagePipeline.importImage(data: image,
                displayName: source.displayName + " – \(pageIndex + 1)", source: evidence, sessionID: sessionID)
            dismiss()
        } catch ResearchImageError.saveFailed {
            pendingSave = ResearchStore.shared.saveFailures["sessions/\(sessionID.uuidString)"] != nil
            error = ResearchImageError.saveFailed.localizedDescription
        } catch { self.error = error.localizedDescription }
    }
}

private struct ResearchRegionCaptureView: NSViewRepresentable {
    let document: PDFDocument
    let pageIndex: Int
    let region: CGRect?
    let onRegion: (CGRect?) -> Void
    func makeNSView(context: Context) -> RegionPDFView {
        let view = RegionPDFView()
        view.document = document
        view.displayMode = .singlePage
        view.autoScales = true
        view.displaysPageBreaks = false
        view.onRegion = onRegion
        if let page = document.page(at: pageIndex) { view.go(to: page); view.capturePage = page }
        return view
    }
    func updateNSView(_ nsView: RegionPDFView, context: Context) {
        nsView.onRegion = onRegion
        if nsView.document !== document || nsView.capturePage !== document.page(at: pageIndex) {
            nsView.document = document
            nsView.capturePage = document.page(at: pageIndex)
            if let page = nsView.capturePage { nsView.go(to: page) }
        }
        nsView.showRegion(region)
    }
}

private final class RegionPDFView: PDFView {
    var onRegion: ((CGRect?) -> Void)?
    var capturePage: PDFPage?
    private var start: CGPoint?
    private var displayedRegion: CGRect?
    private let selectionLayer = CAShapeLayer()

    override init(frame: CGRect) {
        super.init(frame: frame)
        wantsLayer = true
        selectionLayer.fillColor = NSColor.controlAccentColor.withAlphaComponent(0.15).cgColor
        selectionLayer.strokeColor = NSColor.controlAccentColor.cgColor
        selectionLayer.lineWidth = 2
        layer?.addSublayer(selectionLayer)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func hitTest(_ point: NSPoint) -> NSView? { bounds.contains(convert(point, from: superview)) ? self : nil }
    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation { [] }
    override func prepareForDragOperation(_ sender: any NSDraggingInfo) -> Bool { false }
    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool { false }
    override func menu(for event: NSEvent) -> NSMenu? { nil }
    override func keyDown(with event: NSEvent) { /* Capture mode has no PDF editing commands. */ }
    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        start = nil
        showRegion(nil)
        onRegion?(nil)
        guard let page = capturePage else { return }
        let point = convert(convert(event.locationInWindow, from: nil), to: page)
        guard page.bounds(for: .cropBox).contains(point) else { start = nil; return }
        start = point
        onRegion?(nil)
    }
    override func mouseDragged(with event: NSEvent) { updateRegion(event) }
    override func mouseUp(with event: NSEvent) { updateRegion(event); start = nil }
    private func updateRegion(_ event: NSEvent) {
        guard let start, let page = capturePage else { return }
        let end = convert(convert(event.locationInWindow, from: nil), to: page)
        let region = CGRect(x: min(start.x, end.x), y: min(start.y, end.y),
                            width: abs(end.x - start.x), height: abs(end.y - start.y)).intersection(page.bounds(for: .cropBox))
        let valid = region.width >= 1 && region.height >= 1 ? region : nil
        showRegion(valid)
        onRegion?(valid)
    }
    func showRegion(_ region: CGRect?) {
        displayedRegion = region
        guard let region, let page = capturePage else { selectionLayer.path = nil; return }
        selectionLayer.path = CGPath(rect: convert(region, from: page), transform: nil)
        if selectionLayer.superlayer !== layer { layer?.addSublayer(selectionLayer) }
    }
    override func layout() {
        super.layout()
        showRegion(displayedRegion)
    }

}
