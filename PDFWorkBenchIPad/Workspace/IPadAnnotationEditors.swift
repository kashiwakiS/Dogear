#if os(iOS)
import SwiftUI

struct IPadFreeTextEditor: View {
    let draft: FreeTextEditDraft
    let store: PDFDocumentStore
    @Environment(\.dismiss) private var dismiss
    @State private var values: FreeTextEditValues
    @State private var error: String?
    @State private var confirmsDiscard = false
    @StateObject private var textCommands = IPadResearchTextEditingCommands()
    private var hasChanges: Bool { values != draft.values }
    init(draft: FreeTextEditDraft, store: PDFDocumentStore) {
        self.draft = draft; self.store = store
        _values = State(initialValue: draft.values)
    }
    var body: some View {
        NavigationStack {
            Form {
                Section("Text") {
                    IPadResearchNativeTextEditor(text: $values.text, commands: textCommands,
                        identity: draft.id, accessibilityLabel: L10n.string("Text"))
                        .id(draft.id).frame(minHeight: 160)
                }
                Section("Appearance") {
                    Stepper("Font size: \(Int(values.fontSize))", value: $values.fontSize, in: 6...96)
                    HStack { Text("Width"); TextField("Width", value: $values.width, format: .number).keyboardType(.decimalPad) }
                    HStack { Text("Height"); TextField("Height", value: $values.height, format: .number).keyboardType(.decimalPad) }
                }
                if let error { Text(verbatim: error).foregroundStyle(.red) }
            }
            .navigationTitle(draft.isNew ? "New Note" : "Edit Note")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") {
                    guard textCommands.commitMarkedTextAndEndEditing(identity: draft.id) else { return }
                    if hasChanges { confirmsDiscard = true } else { dismiss() }
                } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        guard textCommands.commitMarkedTextAndEndEditing(identity: draft.id) else { return }
                        if let message = FreeTextAnnotationEditing.validationMessage(values, draft: draft) { error = message }
                        else if store.saveFreeText(draft, values: values) { dismiss() }
                        else { error = L10n.string("The document changed. Reopen this note before editing it.") }
                    }
                }
            }
        }
        .interactiveDismissDisabled(hasChanges || textCommands.hasMarkedText)
        .confirmationDialog("Discard changes?", isPresented: $confirmsDiscard, titleVisibility: .visible) {
            Button("Discard changes", role: .destructive) { dismiss() }
            Button("Keep editing", role: .cancel) {}
        }
    }
}

struct IPadHighlightEditor: View {
    @ObservedObject private var session: IPadHighlightEditingSession
    @ObservedObject private var commands: IPadResearchTextEditingCommands
    private let store: PDFDocumentStore
    private let canCommit: () -> Bool
    private let onFinish: () -> Void
    @Environment(\.dismiss) private var dismiss

    init(session: IPadHighlightEditingSession, store: PDFDocumentStore,
         canCommit: @escaping () -> Bool = { true }, onFinish: @escaping () -> Void = {}) {
        _session = ObservedObject(wrappedValue: session)
        _commands = ObservedObject(wrappedValue: session.textCommands)
        self.store = store; self.canCommit = canCommit; self.onFinish = onFinish
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Selected Text") { Text(verbatim: session.draft.quote).textSelection(.enabled) }
                ColorPicker("Highlight Color", selection: session.colorBinding, supportsOpacity: false)
                    .disabled(session.isFinished || !canCommit())
                Section("Comment") {
                    IPadResearchNativeTextEditor(text: session.commentBinding, commands: commands,
                        identity: session.id, isEditable: !session.isFinished && canCommit(),
                        accessibilityLabel: L10n.string("Comment"))
                        .id(session.id).frame(minHeight: 140)
                }
                if let error = session.error { Text(verbatim: error).foregroundStyle(.red) }
            }.navigationTitle("Edit Highlight").toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") {
                    if session.requestDiscard(), session.discard() { finishPresentation() }
                } }
                ToolbarItem(placement: .confirmationAction) { Button("Save") {
                    if session.save(in: store, canCommit: canCommit) { finishPresentation() }
                }.disabled(session.isFinished || !canCommit()) }
            }
        }
        .interactiveDismissDisabled(session.isDirty || commands.hasMarkedText)
        .confirmationDialog("Discard changes?", isPresented: $session.confirmsDiscard, titleVisibility: .visible) {
            Button("Discard changes", role: .destructive) { if session.discard() { finishPresentation() } }
            Button("Keep editing", role: .cancel) {}
        }
        .onDisappear { _ = session.finishIME() }
    }

    private func finishPresentation() {
        onFinish()
        dismiss()
    }
}

struct IPadExportOptionsView: View {
    let request: DocumentExportOptionsRequest
    let onFinish: (Set<String>?) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var selected: Set<String>
    init(request: DocumentExportOptionsRequest, onFinish: @escaping (Set<String>?) -> Void) {
        self.request = request; self.onFinish = onFinish
        _selected = State(initialValue: Set(request.options.filter(\.isSelected).map(\.id)))
    }
    var body: some View {
        NavigationStack {
            List {
                Text(verbatim: request.message)
                ForEach(request.options) { option in
                    Button {
                        if request.allowsMultipleSelection {
                            if selected.contains(option.id) { selected.remove(option.id) } else { selected.insert(option.id) }
                        } else { selected = [option.id] }
                    } label: {
                        HStack { VStack(alignment: .leading) {
                            Text(verbatim: option.title)
                            if let detail = option.detail { Text(verbatim: detail).font(.caption).foregroundStyle(.secondary) }
                        }; Spacer(); if selected.contains(option.id) { Image(systemName: "checkmark") } }
                    }.disabled(!option.isEnabled)
                }
            }.navigationTitle(request.title).toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { onFinish(nil); dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button(request.confirmTitle) {
                    let result = selected
                    onFinish(result); dismiss()
                }.disabled(selected.isEmpty) }
            }
        }
    }
}
#endif
