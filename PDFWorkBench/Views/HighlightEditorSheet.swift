import PDFKit
import SwiftUI

struct HighlightEditorSheet: View {
    @ObservedObject var documentStore: PDFDocumentStore
    let draft: HighlightEditDraft
    @Environment(\.dismiss) private var dismiss
    @State private var color: Color
    @State private var comment: String

    init(documentStore: PDFDocumentStore, draft: HighlightEditDraft) {
        self.documentStore = documentStore
        self.draft = draft
        _color = State(initialValue: Color(nsColor: draft.color.withAlphaComponent(1)))
        _comment = State(initialValue: draft.comment)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Edit Highlight")
                .font(.headline)
            if !draft.quote.isEmpty {
                Text("Quoted Text")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                ScrollView {
                    Text(draft.quote)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 110)
            }
            ColorPicker("Highlight Color", selection: $color, supportsOpacity: false)
            Text("Comment")
                .font(.caption.weight(.semibold))
            TextEditor(text: $comment)
                .font(.body)
                .frame(minHeight: 120, maxHeight: 180)
                .padding(6)
                .background(Color(nsColor: .textBackgroundColor))
                .overlay(RoundedRectangle(cornerRadius: 5).stroke(Color.secondary.opacity(0.3)))
                .accessibilityLabel("Comment")
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") {
                    if documentStore.updateHighlight(draft, color: NSColor(color), comment: comment) {
                        dismiss()
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!documentStore.canEditDocument)
            }
        }
        .padding(22)
        .frame(width: 430)
    }
}
