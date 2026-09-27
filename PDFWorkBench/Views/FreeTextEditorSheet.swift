import PDFKit
import SwiftUI

/// A detached draft shared by new notes and the annotation sidebar. Editing
/// controls and preview never mutate the page-owned annotation.
struct FreeTextEditorSheet: View {
    let draft: FreeTextEditDraft
    let onSave: (FreeTextEditValues) -> Bool
    let onDismiss: () -> Void
    @Environment(\.locale) private var locale
    @State private var text: String
    @State private var widthText: String
    @State private var heightText: String
    @State private var fontSizeText: String
    @State private var saveFailed = false
    @FocusState private var textIsFocused: Bool

    init(draft: FreeTextEditDraft, onSave: @escaping (FreeTextEditValues) -> Bool, onDismiss: @escaping () -> Void) {
        self.draft = draft
        self.onSave = onSave
        self.onDismiss = onDismiss
        _text = State(initialValue: draft.values.text)
        _widthText = State(initialValue: String(draft.values.width))
        _heightText = State(initialValue: String(draft.values.height))
        _fontSizeText = State(initialValue: String(draft.values.fontSize))
    }

    private var values: FreeTextEditValues {
        FreeTextEditValues(text: text, width: number(widthText), height: number(heightText), fontSize: number(fontSizeText))
    }

    private func number(_ text: String) -> Double {
        let normalized = locale.decimalSeparator == "," ? text.replacingOccurrences(of: ",", with: ".") : text
        return Double(normalized.trimmingCharacters(in: .whitespaces)) ?? .nan
    }

    private var validationMessage: String? {
        FreeTextAnnotationEditing.validationMessage(values, draft: draft)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(draft.isNew ? "Add Free Text Note" : "Edit Free Text Note")
                .font(.headline)
            Text("Note Text").font(.caption.weight(.semibold))
            TextEditor(text: $text)
                .font(.body)
                .frame(height: 140)
                .padding(6)
                .background(Color.dogearTextBackground)
                .overlay(RoundedRectangle(cornerRadius: 5).stroke(Color.secondary.opacity(0.3)))
                .accessibilityLabel("Note Text")
                .focused($textIsFocused)
            HStack(spacing: 12) {
                dimension("Width (pt)", text: $widthText)
                dimension("Height (pt)", text: $heightText)
                dimension("Font Size (pt)", text: $fontSizeText)
            }
            Text("Note Preview")
                .font(.caption.weight(.semibold))
            FreeTextPreview(draft: draft, values: values)
                .frame(height: 140)
                .overlay(RoundedRectangle(cornerRadius: 5).stroke(Color.secondary.opacity(0.3)))
                .accessibilityLabel("Note Preview")
            Text("Dimensions use PDF points and stay inside the page. Text outside the note box is clipped.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if draft.annotation.hasAppearanceStream {
                Text("Saving regenerates the PDF appearance from this note’s text and style. Custom artwork in the appearance is not preserved.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let validationMessage {
                Text(validationMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else if saveFailed {
                Text("The note could not be saved. It may no longer be present in this document.")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
            HStack {
                Spacer()
                Button("Cancel", action: onDismiss)
                    .keyboardShortcut(.cancelAction)
                Button("Save") {
                    if onSave(values) { onDismiss() } else { saveFailed = true }
                }
                // Return remains a newline in the multi-line editor.
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(validationMessage != nil)
            }
        }
        .padding(22)
        .frame(width: 440)
        .onAppear { textIsFocused = true }
    }

    private func dimension(_ title: LocalizedStringKey, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.caption)
            TextField(title, text: text)
                .textFieldStyle(.roundedBorder)
        }
    }
}

struct FreeTextPreview: View {
    let draft: FreeTextEditDraft
    let values: FreeTextEditValues
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        GeometryReader { geometry in
            if let image = FreeTextPreviewRenderer.image(draft: draft, values: values,
                                                         size: geometry.size, displayScale: displayScale) {
                Image(decorative: image, scale: displayScale, orientation: .up)
                    .resizable()
                    .frame(width: geometry.size.width, height: geometry.size.height)
            } else {
                Color.white
            }
        }
    }
}
