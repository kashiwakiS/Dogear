#if os(iOS)
import Combine
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// Prepared bytes remain tied to their source while the user chooses a folder
/// and filename. The app validates the final URL before making an atomic write.
@MainActor
final class IPadDocumentExportPresenter: ObservableObject, DocumentExportPresenting {
    struct Ticket: Identifiable {
        let id = UUID()
        let request: DocumentExportRequest
        let completion: @MainActor (Result<URL?, Error>) -> Void
    }
    struct Replacement: Identifiable {
        let id = UUID()
        let ticketID: UUID
        let destination: URL
        fileprivate let authorization: SafeDocumentExport.ReplacementAuthorization
    }
    enum WriteOutcome {
        case completed
        case replacementRequired(Replacement)
        case expired
    }
    @Published private(set) var ticket: Ticket?
    private var replacement: Replacement?
    func export(_ request: DocumentExportRequest, completion: @escaping @MainActor (Result<URL?, Error>) -> Void) {
        guard ticket == nil else { completion(.failure(CocoaError(.userCancelled))); return }
        ticket = Ticket(request: request, completion: completion)
    }
    func finish(_ id: UUID, result: Result<URL?, Error>) {
        guard let current = ticket, current.id == id else { return }
        ticket = nil
        replacement = nil
        current.completion(result)
    }

    /// Native UI supplies a destination, while this service owns ticket and
    /// replacement authorization. A dismissed/older sheet cannot write bytes.
    func write(_ id: UUID, to destination: URL) throws -> WriteOutcome {
        guard let current = ticket, current.id == id else { return .expired }
        replacement = nil
        do {
            try current.request.write(to: destination, existingFilePolicy: .forbidReplacement)
            finish(id, result: .success(destination))
            return .completed
        } catch SafeDocumentExportError.destinationExists {
            return try requestReplacement(for: current, destination: destination)
        }
    }

    func replace(_ confirmation: Replacement) throws -> WriteOutcome {
        guard canReplace(confirmation), let current = ticket else { return .expired }
        do {
            try current.request.write(to: confirmation.destination,
                                      existingFilePolicy: .replaceConfirmed(confirmation.authorization))
            finish(current.id, result: .success(confirmation.destination))
            return .completed
        } catch SafeDocumentExportError.destinationChanged {
            // Retry the exclusive-create path if the old file disappeared. If
            // it was edited/replaced, capture a fresh identity and ask again.
            return try write(current.id, to: confirmation.destination)
        }
    }

    func canReplace(_ confirmation: Replacement) -> Bool {
        ticket?.id == confirmation.ticketID && replacement?.id == confirmation.id
    }

    func cancelReplacement(_ confirmation: Replacement) {
        if replacement?.id == confirmation.id { replacement = nil }
    }

    private func requestReplacement(for current: Ticket, destination: URL) throws -> WriteOutcome {
        if let original = current.request.protectedOriginalURL,
           SafeDocumentExport.isSameFile(destination, original) {
            throw SafeDocumentExportError.originalDestination
        }
        let confirmation = Replacement(ticketID: current.id, destination: destination,
            authorization: try SafeDocumentExport.replacementAuthorization(for: destination))
        replacement = confirmation
        return .replacementRequired(confirmation)
    }
}

struct IPadExportPicker: View {
    let ticket: IPadDocumentExportPresenter.Ticket
    let presenter: IPadDocumentExportPresenter
    @State private var name: String
    @State private var directory: URL?
    @State private var hasAccess = false
    @State private var choosingFolder = false
    @State private var replacement: IPadDocumentExportPresenter.Replacement?
    @State private var error: String?
    init(ticket: IPadDocumentExportPresenter.Ticket, presenter: IPadDocumentExportPresenter) {
        self.ticket = ticket; self.presenter = presenter
        _name = State(initialValue: URL(fileURLWithPath: ticket.request.suggestedName).lastPathComponent)
    }
    var body: some View {
        NavigationStack {
            Form {
                TextField("File Name", text: $name).autocorrectionDisabled().textInputAutocapitalization(.never)
                Button("Choose Destination Folder") { choosingFolder = true }
                if let directory { Text(verbatim: directory.lastPathComponent).foregroundStyle(.secondary) }
                if let error { Text(verbatim: error).foregroundStyle(.red) }
            }.navigationTitle("Export Copy").toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { presenter.finish(ticket.id, result: .success(nil)) } }
                ToolbarItem(placement: .confirmationAction) { Button("Export") { prepareWrite() }.disabled(directory == nil || name.isEmpty) }
            }
        }
        .sheet(isPresented: $choosingFolder) { IPadFolderPicker { url in
            guard presenter.ticket?.id == ticket.id else { return }
            if let url {
                stopAccess()
                directory = url
                hasAccess = url.startAccessingSecurityScopedResource()
            }
            choosingFolder = false
        } }
        .alert("Replace Existing File?", isPresented: Binding(get: { replacement != nil }, set: { if !$0 { replacement = nil } })) {
            if let confirmation = replacement {
                Button("Replace", role: .destructive) { replacement = nil; replace(confirmation) }
                Button("Cancel", role: .cancel) { presenter.cancelReplacement(confirmation); replacement = nil }
            }
        } message: {
            Text("The existing exported file will be replaced. The original PDF cannot be selected.")
            if let replacement { Text(verbatim: replacement.destination.lastPathComponent) }
        }
        .onDisappear { stopAccess() }
    }
    private func stopAccess() { if hasAccess { directory?.stopAccessingSecurityScopedResource(); hasAccess = false } }
    private func prepareWrite() {
        guard presenter.ticket?.id == ticket.id else { return }
        guard let directory else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != ".", trimmed != "..", !trimmed.contains("/"), !trimmed.contains("\\"), !trimmed.contains("\0") else {
            error = L10n.string("Enter a file name without folder separators."); return
        }
        let destination = directory.appendingPathComponent(trimmed)
        do { handle(try presenter.write(ticket.id, to: destination)) }
        catch { self.error = error.localizedDescription }
    }
    private func replace(_ confirmation: IPadDocumentExportPresenter.Replacement) {
        do { handle(try presenter.replace(confirmation)) }
        catch { self.error = error.localizedDescription }
    }
    private func handle(_ outcome: IPadDocumentExportPresenter.WriteOutcome) {
        error = nil
        if case .replacementRequired(let confirmation) = outcome {
            // Allow the preceding confirmation to dismiss before presenting
            // consent for a newly observed file at the same destination.
            DispatchQueue.main.async {
                guard presenter.canReplace(confirmation) else { return }
                replacement = confirmation
            }
        }
    }
}

private struct IPadFolderPicker: UIViewControllerRepresentable {
    let onChoose: (URL?) -> Void
    func makeCoordinator() -> Coordinator { Coordinator(onChoose: onChoose) }
    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let controller = UIDocumentPickerViewController(forOpeningContentTypes: [.folder], asCopy: false)
        controller.delegate = context.coordinator
        return controller
    }
    func updateUIViewController(_ controller: UIDocumentPickerViewController, context: Context) {}
    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let onChoose: (URL?) -> Void
        init(onChoose: @escaping (URL?) -> Void) { self.onChoose = onChoose }
        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) { onChoose(urls.first) }
        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) { onChoose(nil) }
    }
}
#endif
