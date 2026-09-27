import SwiftUI

extension View {
    func documentInteractions(store: PDFDocumentStore, scope: DocumentInteractionScope = .reader) -> some View {
        modifier(DocumentInteractionPresenter(store: store, scope: scope))
    }
}

private struct DocumentInteractionPresenter: ViewModifier {
    @ObservedObject var store: PDFDocumentStore
    let scope: DocumentInteractionScope
    @State private var completionAfterDismiss: (() -> Void)?

    private var confirmation: DocumentConfirmationRequest? {
        store.pendingConfirmation.flatMap { $0.scope == scope ? $0 : nil }
    }

    func body(content: Content) -> some View {
        content
            .alert(confirmation?.title ?? "", isPresented: Binding(
                get: { confirmation != nil },
                set: { if !$0 && confirmation != nil { store.pendingConfirmation = nil } }
            ), presenting: confirmation) { request in
                Button(request.confirmTitle, role: .destructive) {
                    store.pendingConfirmation = nil
                    request.onConfirm()
                }
                Button(L10n.string("Cancel"), role: .cancel) {}
            } message: { request in
                Text(request.message)
            }
            .sheet(item: Binding(
                get: { scope == .reader ? store.pendingExportOptions : nil },
                set: { if scope == .reader { store.pendingExportOptions = $0 } }
            ), onDismiss: {
                let completion = completionAfterDismiss
                completionAfterDismiss = nil
                completion?()
            }) { request in
                DocumentExportOptionsView(request: request) { selected in
                    if let selected { completionAfterDismiss = { request.onConfirm(selected) } }
                    store.pendingExportOptions = nil
                }
                .environment(\.locale, AppLanguageStore.shared.locale)
            }
    }
}

private struct DocumentExportOptionsView: View {
    let request: DocumentExportOptionsRequest
    let completion: (Set<String>?) -> Void
    @State private var selected: Set<String>

    init(request: DocumentExportOptionsRequest, completion: @escaping (Set<String>?) -> Void) {
        self.request = request
        self.completion = completion
        _selected = State(initialValue: Set(request.options.filter { $0.isSelected && $0.isEnabled }.map(\.id)))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(request.title).font(.headline)
            Text(request.message).font(.callout).foregroundStyle(.secondary)
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(request.options) { option in
                        Toggle(isOn: Binding(
                            get: { selected.contains(option.id) },
                            set: { enabled in
                                if request.allowsMultipleSelection {
                                    if enabled { selected.insert(option.id) } else { selected.remove(option.id) }
                                } else if enabled { selected = [option.id] }
                            }
                        )) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(option.title)
                                if let detail = option.detail, !detail.isEmpty {
                                    Text(detail).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                        .disabled(!option.isEnabled)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 4)
            }
            .frame(maxHeight: 260)
            HStack {
                Spacer()
                Button(L10n.string("Cancel"), role: .cancel) { completion(nil) }
                    .keyboardShortcut(.cancelAction)
                Button(request.confirmTitle) { completion(selected) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!request.allowsMultipleSelection && selected.isEmpty)
            }
        }
        .padding(20)
        .frame(minWidth: 400, idealWidth: 460, maxWidth: 560)
        .fixedSize(horizontal: false, vertical: true)
    }
}
