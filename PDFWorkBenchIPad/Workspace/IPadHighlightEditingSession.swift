#if os(iOS)
import Combine
import PDFKit
import SwiftUI
import UIKit

/// Retained editor values belong to one native annotation, independently of
/// the sheet's lifetime. The shared Store remains the only PDF mutation owner.
@MainActor
final class IPadHighlightEditingSession: ObservableObject, Identifiable {
    typealias Values = HighlightEditValues
    enum Completion: Equatable { case saved, discarded }

    let id: UUID
    let draft: HighlightEditDraft
    let textCommands = IPadResearchTextEditingCommands()
    let baselineBounds: CGRect
    let baselinePoints: [CGPoint]?
    @Published var values: Values
    @Published var error: String?
    @Published var confirmsDiscard = false
    @Published private(set) var completion: Completion?
    /// A failed durable intent keeps both the PDF and the live editor unchanged.
    var beforeSave: (() -> Bool)?
    var beforeDiscard: (() -> Bool)?

    init(draft: HighlightEditDraft, id: UUID? = nil) {
        self.draft = draft; self.id = id ?? draft.id
        baselineBounds = draft.baselineBounds
        baselinePoints = draft.baselinePoints
        values = Values(comment: draft.comment, color: draft.color)
    }

    var isFinished: Bool { completion != nil }
    var isDirty: Bool {
        !isFinished && (values != Values(comment: draft.comment, color: draft.color) || textCommands.hasMarkedText)
    }
    var commentBinding: Binding<String> {
        Binding(get: { self.values.comment }, set: { if !self.isFinished { self.values.comment = $0 } })
    }
    var colorBinding: Binding<Color> {
        Binding(get: { Color(pdfColor: self.values.color) }, set: {
            if !self.isFinished {
                self.values.color = $0.pdfPlatformColor.withAlphaComponent(PDFPlatformStyle.alphaComponent(of: self.draft.color))
            }
        })
    }

    @discardableResult
    func finishIME() -> Bool {
        isFinished || textCommands.commitMarkedTextAndEndEditing(identity: id)
    }

    @discardableResult
    func requestDiscard() -> Bool {
        guard finishIME() else { return false }
        if isDirty { confirmsDiscard = true; return false }
        return true
    }

    @discardableResult
    func discard() -> Bool {
        guard !isFinished, finishIME(), beforeDiscard?() != false else { return false }
        completion = .discarded; confirmsDiscard = false
        return true
    }

    @discardableResult
    func save(in store: PDFDocumentStore, canCommit: () -> Bool) -> Bool {
        guard !isFinished, canCommit(), matchesBaseline(in: store), finishIME(),
              canCommit(), matchesBaseline(in: store) else { return rejectChangedDocument() }
        guard beforeSave?() != false else { return false }
        guard canCommit(), matchesBaseline(in: store),
              store.updateHighlight(draft, color: values.color, comment: values.comment) else {
            return rejectChangedDocument()
        }
        completion = .saved
        return true
    }

    /// Exact object identity is necessary but insufficient: another document
    /// command may have changed that same annotation while this sheet was hidden.
    func matchesBaseline(in store: PDFDocumentStore) -> Bool {
        store.canEditDocument && HighlightAnnotationEditing.matchesBaseline(draft, in: store.document)
    }

    private func rejectChangedDocument() -> Bool {
        error = L10n.string("The document changed. Reopen this highlight before editing it.")
        return false
    }
}
#endif
