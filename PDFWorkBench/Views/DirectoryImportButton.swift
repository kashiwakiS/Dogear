import SwiftUI
import UniformTypeIdentifiers

/// The view owns presentation; the caller retains authorization and validates
/// mutable application state again before using the selected directory.
struct DirectoryImportButton: View {
    let title: LocalizedStringKey
    let prepare: @MainActor () async -> Bool
    let onCompletion: @MainActor (Result<URL, Error>) -> Void
    @State private var isPreparing = false
    @State private var isPresented = false
    @State private var preparationTask: Task<Void, Never>?

    var body: some View {
        Button(title) {
            guard !isPreparing, !isPresented else { return }
            isPreparing = true
            preparationTask = Task { @MainActor in
                let canPresent = await prepare()
                guard !Task.isCancelled else { return }
                isPreparing = false
                preparationTask = nil
                if canPresent { isPresented = true }
            }
        }
        .disabled(isPreparing || isPresented)
        .onDisappear {
            preparationTask?.cancel()
            preparationTask = nil
            isPreparing = false
        }
        .fileImporter(isPresented: $isPresented, allowedContentTypes: [.folder],
                      allowsMultipleSelection: false) { result in
            switch result {
            case .success(let urls):
                if let url = urls.first { onCompletion(.success(url)) }
            case .failure(let error):
                let cocoaError = error as NSError
                if error is CancellationError || (cocoaError.domain == NSCocoaErrorDomain
                    && cocoaError.code == CocoaError.userCancelled.rawValue) { return }
                onCompletion(.failure(error))
            }
        }
    }
}
