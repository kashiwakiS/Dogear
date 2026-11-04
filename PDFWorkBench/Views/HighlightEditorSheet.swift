import PDFKit
import SwiftUI

struct HighlightEditorSheet: View {
    @ObservedObject var documentStore: PDFDocumentStore
    let draft: HighlightEditDraft
    @Environment(\.dismiss) private var dismiss
    @State private var values: HighlightEditValues
    @State private var saveFailed = false
    @State private var confirmsDiscard = false
    @StateObject private var textCommands = ResearchTextEditingCommands()

    init(documentStore: PDFDocumentStore, draft: HighlightEditDraft) {
        self.documentStore = documentStore
        self.draft = draft
        _values = State(initialValue: draft.values)
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
            ColorPicker("Highlight Color", selection: Binding(get: {
                Color(pdfColor: values.color.withAlphaComponent(1))
            }, set: {
                values.color = $0.pdfPlatformColor.withAlphaComponent(PDFPlatformStyle.alphaComponent(of: draft.color))
            }), supportsOpacity: false)
            Text("Comment")
                .font(.caption.weight(.semibold))
            ResearchTextEditor(text: $values.comment, placeholder: L10n.string("Comment"),
                onSubmit: save, commands: textCommands, identity: draft.id)
                .frame(minHeight: 120, maxHeight: 180)
                .padding(6)
                .background(Color.dogearTextBackground)
                .overlay(RoundedRectangle(cornerRadius: 5).stroke(Color.secondary.opacity(0.3)))
                .accessibilityLabel("Comment")
            if saveFailed {
                Text("The document changed. Your unsubmitted text has been kept; copy it or cancel explicitly.")
                    .font(.caption).foregroundStyle(.red)
            }
            HStack {
                Spacer()
                Button("Cancel") {
                    guard !textCommands.hasMarkedText, textCommands.finishEditing(identity: draft.id) else { return }
                    if isDirty { confirmsDiscard = true } else { dismiss() }
                }
                    .keyboardShortcut(.cancelAction)
                Button("Save", action: save)
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(!documentStore.canEditDocument)
            }
        }
        .padding(22)
        .frame(width: 430)
        .task { await Task.yield(); textCommands.focus(identity: draft.id) }
        .interactiveDismissDisabled(isDirty)
        .background(MacAnnotationEditorLifetime(id: draft.id) {
            isDirty || textCommands.hasMarkedText
        }.frame(width: 0, height: 0))
        .confirmationDialog("Discard changes?", isPresented: $confirmsDiscard) {
            Button("Discard changes", role: .destructive) { dismiss() }
            Button("Keep editing", role: .cancel) {}
        }
    }

    private var isDirty: Bool {
        values != draft.values
    }

    private func save() {
        guard !textCommands.hasMarkedText, textCommands.finishEditing(identity: draft.id) else { return }
        if documentStore.updateHighlight(draft, color: values.color, comment: values.comment) { dismiss() }
        else { saveFailed = true; textCommands.focus(identity: draft.id) }
    }
}
